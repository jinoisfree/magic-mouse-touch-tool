#import <ApplicationServices/ApplicationServices.h>
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <math.h>
#import <stdbool.h>
#import <stdio.h>
#import <string.h>

// Magic Mouse touch frames are exposed only through this private framework.
// The declarations below match the ABI used by current macOS releases.
typedef void *MTDeviceRef;

typedef struct {
    float x;
    float y;
} MTPoint;

typedef struct {
    MTPoint position;
    MTPoint velocity;
} MTVector;

typedef struct {
    int32_t frame;
    double timestamp;
    int32_t pathIndex;
    int32_t stage;
    int32_t fingerID;
    int32_t handID;
    MTVector normalizedVector;
    float zTotal;
    float zPressure;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absoluteVector;
    int32_t field14;
    int32_t field15;
    float zDensity;
} MTTouch;

typedef void (*MTFrameCallbackFunction)(MTDeviceRef device,
                                        MTTouch *touches,
                                        size_t numTouches,
                                        double timestamp,
                                        size_t frame,
                                        void *refCon);

typedef CFArrayRef (*MTDeviceCreateListFunction)(void);
typedef void (*MTRegisterCallbackFunction)(MTDeviceRef,
                                           MTFrameCallbackFunction,
                                           void *);
typedef int32_t (*MTDeviceStartFunction)(MTDeviceRef, int32_t);
typedef void (*MTDeviceStopFunction)(MTDeviceRef);
typedef bool (*MTDeviceIsBuiltInFunction)(MTDeviceRef);

static NSString *const kFrameworkPath =
    @"/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport";

static BOOL InputMonitoringIsGranted(void) {
    return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted;
}

@class MagicTouchBridge;

typedef void (^MTFrameBlock)(const MTTouch *touches,
                             size_t count,
                             double timestamp);

@interface MagicTouchBridge : NSObject
- (BOOL)startWithCallback:(MTFrameBlock)callback;
- (void)stop;
@end

@interface MagicTouchBridge () {
    void *_framework;
    MTDeviceStopFunction _stopDevice;
    NSMutableArray<NSValue *> *_devices;
    MTFrameBlock _callback;
    BOOL _running;
    NSInteger _previousTouchCount;
}
- (void)handleTouches:(const MTTouch *)touches
                count:(size_t)count
            timestamp:(double)timestamp;
@end

static void magicTouchFrameCallback(MTDeviceRef device,
                                    MTTouch *touches,
                                    size_t numTouches,
                                    double timestamp,
                                    size_t frame,
                                    void *refCon) {
    (void)device;
    (void)frame;
    MagicTouchBridge *bridge = (__bridge MagicTouchBridge *)refCon;
    [bridge handleTouches:touches count:numTouches timestamp:timestamp];
}

@implementation MagicTouchBridge

- (instancetype)init {
    self = [super init];
    if (self) {
        _devices = [NSMutableArray array];
        _previousTouchCount = -1;
    }
    return self;
}

- (BOOL)startWithCallback:(MTFrameBlock)callback {
    if (_running) {
        return YES;
    }

    _framework = dlopen(kFrameworkPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (_framework == NULL) {
        return NO;
    }

    MTDeviceCreateListFunction createList =
        (MTDeviceCreateListFunction)dlsym(_framework, "MTDeviceCreateList");
    MTRegisterCallbackFunction registerCallback =
        (MTRegisterCallbackFunction)dlsym(_framework,
                                          "MTRegisterContactFrameCallbackWithRefcon");
    MTDeviceStartFunction startDevice =
        (MTDeviceStartFunction)dlsym(_framework, "MTDeviceStart");
    MTDeviceIsBuiltInFunction isBuiltIn =
        (MTDeviceIsBuiltInFunction)dlsym(_framework, "MTDeviceIsBuiltIn");
    _stopDevice = (MTDeviceStopFunction)dlsym(_framework, "MTDeviceStop");

    if (createList == NULL || registerCallback == NULL || startDevice == NULL) {
        dlclose(_framework);
        _framework = NULL;
        return NO;
    }

    CFArrayRef deviceList = createList();
    if (deviceList == NULL) {
        dlclose(_framework);
        _framework = NULL;
        return NO;
    }

    _callback = [callback copy];
    CFIndex deviceCount = CFArrayGetCount(deviceList);
    for (CFIndex index = 0; index < deviceCount; index++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(deviceList, index);
        if (isBuiltIn != NULL && isBuiltIn(device)) {
            continue;
        }

        registerCallback(device, magicTouchFrameCallback, (__bridge void *)self);
        startDevice(device, 0);
        [_devices addObject:[NSValue valueWithPointer:device]];
    }

    CFRelease(deviceList);
    _previousTouchCount = -1;
    _running = YES;
    return YES;
}

- (void)stop {
    if (!_running) {
        return;
    }

    _callback = nil;
    if (_stopDevice != NULL) {
        for (NSValue *value in _devices) {
            _stopDevice((MTDeviceRef)value.pointerValue);
        }
    }
    [_devices removeAllObjects];
    _running = NO;
    _previousTouchCount = -1;

    if (_framework != NULL) {
        dlclose(_framework);
        _framework = NULL;
    }
}

- (void)handleTouches:(const MTTouch *)touches
                count:(size_t)count
            timestamp:(double)timestamp {
    MTFrameBlock callback = _callback;
    if (callback != nil) {
        callback(touches, count, timestamp);
    }
}

- (void)dealloc {
    [self stop];
}

@end

typedef struct {
    float x;
    float y;
} InitialTouchPosition;

// Leave room for the small position shift that occurs while a finger settles,
// but reject a real scroll before the touch is released.
static const float kTapMovementThreshold = 0.075f;
static const NSTimeInterval kTapMovementGracePeriod = 0.045;
static const NSTimeInterval kMinimumTapDuration = 0.005;
static const NSTimeInterval kMaximumTapDuration = 0.18;
static const float kTapVelocityThreshold = 0.35f;

@interface ClickInjector : NSObject
+ (void)postClickOnRightSide:(BOOL)rightSide clickCount:(NSInteger)clickCount;
@end

@interface TapDetector : NSObject
@property(nonatomic, assign, getter=isEnabled) BOOL enabled;
- (BOOL)start;
- (void)stop;
@end

@interface TapDetector () {
    MagicTouchBridge *_bridge;
    BOOL _tracking;
    BOOL _moved;
    double _trackingStart;
    float _initialX;
    int _maxFingerCount;
    NSMutableDictionary<NSNumber *, NSValue *> *_initialPositions;
    NSTimeInterval _doubleClickInterval;
    NSTimeInterval _lastTapTime;
    BOOL _lastTapRightSide;
    BOOL _hasLastTap;
}
- (void)handleFrame:(const MTTouch *)touches
              count:(size_t)count
          timestamp:(double)timestamp;
- (void)resetTracking;
@end

@implementation TapDetector

- (instancetype)init {
    self = [super init];
    if (self) {
        _bridge = [MagicTouchBridge new];
        _initialPositions = [NSMutableDictionary dictionary];
        _doubleClickInterval = [NSEvent doubleClickInterval];
        _enabled = YES;
    }
    return self;
}

- (BOOL)start {
    __weak TapDetector *weakSelf = self;
    return [_bridge startWithCallback:^(const MTTouch *touches,
                                        size_t count,
                                        double timestamp) {
        TapDetector *strongSelf = weakSelf;
        if (strongSelf != nil) {
            [strongSelf handleFrame:touches count:count timestamp:timestamp];
        }
    }];
}

- (void)stop {
    [_bridge stop];
    [self resetTracking];
    [self clearTapHistory];
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    if (!enabled) {
        [self resetTracking];
        [self clearTapHistory];
    }
}

- (void)handleFrame:(const MTTouch *)touches
              count:(size_t)count
          timestamp:(double)timestamp {
    if (!_enabled) {
        [self resetTracking];
        return;
    }

    if (count == 0) {
        if (!_tracking) {
            return;
        }

        double duration = timestamp - _trackingStart;
        int fingerCount = _maxFingerCount;
        float initialX = _initialX;
        BOOL validTap = !_moved && fingerCount == 1 &&
                        duration >= kMinimumTapDuration &&
                        duration <= kMaximumTapDuration;
        [self resetTracking];

        if (!validTap) {
            return;
        }

        BOOL rightSide = initialX >= 0.50f;
        BOOL isDoubleTap = _hasLastTap &&
                           _lastTapRightSide == rightSide &&
                           (timestamp - _lastTapTime) <= _doubleClickInterval;
        NSInteger clickCount = isDoubleTap ? 2 : 1;

        if (isDoubleTap) {
            _hasLastTap = NO;
        } else {
            _hasLastTap = YES;
            _lastTapTime = timestamp;
            _lastTapRightSide = rightSide;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.isEnabled) {
                [ClickInjector postClickOnRightSide:rightSide clickCount:clickCount];
            }
        });
        return;
    }

    if (!_tracking) {
        _tracking = YES;
        _moved = NO;
        _trackingStart = timestamp;
        _maxFingerCount = (int)count;
        _initialX = 0.0f;
        [_initialPositions removeAllObjects];

        for (size_t index = 0; index < count; index++) {
            const MTTouch touch = touches[index];
            _initialX += touch.normalizedVector.position.x;
            InitialTouchPosition position = {
                touch.normalizedVector.position.x,
                touch.normalizedVector.position.y
            };
            _initialPositions[@(touch.fingerID)] =
                [NSValue valueWithBytes:&position objCType:@encode(InitialTouchPosition)];
        }
        _initialX /= (float)count;
        return;
    }

    if ((int)count > _maxFingerCount) {
        _maxFingerCount = (int)count;
    }

    for (size_t index = 0; index < count; index++) {
        const MTTouch touch = touches[index];
        NSValue *value = _initialPositions[@(touch.fingerID)];
        if (value == nil) {
            InitialTouchPosition position = {
                touch.normalizedVector.position.x,
                touch.normalizedVector.position.y
            };
            _initialPositions[@(touch.fingerID)] =
                [NSValue valueWithBytes:&position objCType:@encode(InitialTouchPosition)];
            continue;
        }

        InitialTouchPosition initial;
        [value getValue:&initial];
        float dx = touch.normalizedVector.position.x - initial.x;
        float dy = touch.normalizedVector.position.y - initial.y;
        if ((timestamp - _trackingStart) < kTapMovementGracePeriod) {
            continue;
        }
        float vx = touch.normalizedVector.velocity.x;
        float vy = touch.normalizedVector.velocity.y;
        float movement = sqrtf(dx * dx + dy * dy);
        float speed = sqrtf(vx * vx + vy * vy);
        if (movement > kTapMovementThreshold || speed > kTapVelocityThreshold) {
            _moved = YES;
            break;
        }
    }
}

- (void)resetTracking {
    _tracking = NO;
    _moved = NO;
    _trackingStart = 0.0;
    _initialX = 0.0f;
    _maxFingerCount = 0;
    [_initialPositions removeAllObjects];
}

- (void)clearTapHistory {
    _lastTapTime = 0.0;
    _lastTapRightSide = NO;
    _hasLastTap = NO;
}

- (void)dealloc {
    [_bridge stop];
}

@end

@implementation ClickInjector

+ (void)postClickOnRightSide:(BOOL)rightSide clickCount:(NSInteger)clickCount {
    CGEventRef currentEvent = CGEventCreate(NULL);
    if (currentEvent == NULL) {
        return;
    }

    CGPoint position = CGEventGetLocation(currentEvent);
    CFRelease(currentEvent);

    CGMouseButton button = rightSide ? kCGMouseButtonRight : kCGMouseButtonLeft;
    CGEventType downType = rightSide ? kCGEventRightMouseDown : kCGEventLeftMouseDown;
    CGEventType upType = rightSide ? kCGEventRightMouseUp : kCGEventLeftMouseUp;

    CGEventRef down = CGEventCreateMouseEvent(NULL, downType, position, button);
    CGEventRef up = CGEventCreateMouseEvent(NULL, upType, position, button);
    if (down != NULL && up != NULL) {
        CGEventSetIntegerValueField(down, kCGMouseEventClickState, clickCount);
        CGEventSetIntegerValueField(up, kCGMouseEventClickState, clickCount);
        CGEventPost(kCGHIDEventTap, down);
        CGEventPost(kCGHIDEventTap, up);
    }

    if (down != NULL) {
        CFRelease(down);
    }
    if (up != NULL) {
        CFRelease(up);
    }
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@interface AppDelegate () {
    NSStatusItem *_statusItem;
    TapDetector *_detector;
    NSMenuItem *_toggleItem;
    NSMenuItem *_permissionItem;
    BOOL _bridgeStarted;
}
- (void)toggleEnabled:(id)sender;
- (void)openAccessibilitySettings:(id)sender;
- (void)quit:(id)sender;
- (void)refreshMenu;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    // Start the multitouch bridge before querying the optional permission
    // status. The original working build used this direct startup path.
    _detector = [TapDetector new];
    _bridgeStarted = [_detector start];

    _statusItem = [[NSStatusBar systemStatusBar]
                   statusItemWithLength:NSSquareStatusItemLength];
    NSImage *image = [NSImage imageWithSystemSymbolName:@"cursorarrow.click.2"
                                 accessibilityDescription:@"Magic Tap Click"];
    if (image != nil) {
        image.template = YES;
        _statusItem.button.image = image;
    } else {
        _statusItem.button.title = @"⌁";
    }
    _statusItem.button.toolTip = @"Magic Tap Click";

    NSDictionary *options = @{
        (__bridge id)kAXTrustedCheckOptionPrompt: @YES
    };
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);

    BOOL inputMonitoringGranted = InputMonitoringIsGranted();
    if (!inputMonitoringGranted) {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
        inputMonitoringGranted = InputMonitoringIsGranted();
    }

    [self refreshMenu];
}

- (void)refreshMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Magic Tap Click"];

    NSMenuItem *titleItem = [[NSMenuItem alloc] initWithTitle:@"Magic Tap Click"
                                                        action:nil
                                                 keyEquivalent:@""];
    titleItem.enabled = NO;
    [menu addItem:titleItem];
    [menu addItem:[NSMenuItem separatorItem]];

    _toggleItem = [[NSMenuItem alloc] initWithTitle:@"터치 클릭 켜기"
                                              action:@selector(toggleEnabled:)
                                       keyEquivalent:@""];
    _toggleItem.target = self;
    _toggleItem.state = _detector.isEnabled ? NSControlStateValueOn
                                            : NSControlStateValueOff;
    [menu addItem:_toggleItem];

    NSString *accessibilityStatus = AXIsProcessTrusted() ? @"허용됨" : @"필요";
    NSString *inputMonitoringStatus = InputMonitoringIsGranted() ? @"허용됨" : @"필요";
    NSString *permissionTitle = [NSString stringWithFormat:
        @"권한 설정 — 손쉬운 사용: %@ / 입력 감시: %@",
        accessibilityStatus,
        inputMonitoringStatus];
    _permissionItem = [[NSMenuItem alloc] initWithTitle:permissionTitle
                                                  action:@selector(openAccessibilitySettings:)
                                           keyEquivalent:@""];
    _permissionItem.target = self;
    _permissionItem.enabled = YES;
    [menu addItem:_permissionItem];

    NSString *status = _bridgeStarted
        ? @"매직마우스 터치 감지 중"
        : @"터치 프레임워크를 시작하지 못함";
    NSMenuItem *statusItem = [[NSMenuItem alloc] initWithTitle:status
                                                         action:nil
                                                  keyEquivalent:@""];
    statusItem.enabled = NO;
    [menu addItem:statusItem];

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"종료"
                                                       action:@selector(quit:)
                                                keyEquivalent:@"q"];
    quitItem.target = self;
    [menu addItem:quitItem];

    _statusItem.menu = menu;
}

- (void)toggleEnabled:(id)sender {
    (void)sender;
    _detector.enabled = !_detector.isEnabled;
    [self refreshMenu];
}

- (void)openAccessibilitySettings:(id)sender {
    (void)sender;
    NSString *privacyAnchor = InputMonitoringIsGranted()
        ? @"Privacy_Accessibility"
        : @"Privacy_ListenEvent";
    NSString *settingsURL = [NSString stringWithFormat:
        @"x-apple.systempreferences:com.apple.preference.security?%@",
        privacyAnchor];
    NSURL *url = [NSURL URLWithString:
                  settingsURL];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)quit:(id)sender {
    (void)sender;
    [_detector stop];
    [NSApp terminate:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return NO;
}

@end

static int RunSelfTest(void) {
    void *framework = dlopen(kFrameworkPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (framework == NULL) {
        fprintf(stderr, "MultitouchSupport.framework: FAIL (%s)\n", dlerror());
        return 1;
    }

    const char *symbols[] = {
        "MTDeviceCreateList",
        "MTRegisterContactFrameCallbackWithRefcon",
        "MTDeviceStart",
        "MTDeviceStop"
    };
    for (size_t index = 0; index < sizeof(symbols) / sizeof(symbols[0]); index++) {
        if (dlsym(framework, symbols[index]) == NULL) {
            fprintf(stderr, "symbol %s: FAIL\n", symbols[index]);
            dlclose(framework);
            return 1;
        }
    }

    MTDeviceCreateListFunction createList =
        (MTDeviceCreateListFunction)dlsym(framework, "MTDeviceCreateList");
    CFArrayRef devices = createList != NULL ? createList() : NULL;
    CFIndex deviceCount = devices != NULL ? CFArrayGetCount(devices) : 0;
    if (devices != NULL) {
        CFRelease(devices);
    }

    printf("MultitouchSupport.framework: OK\n");
    printf("visible multitouch devices: %ld\n", (long)deviceCount);
    printf("input monitoring: %s\n",
           InputMonitoringIsGranted() ? "granted" : "not granted");
    dlclose(framework);
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--self-test") == 0) {
            return RunSelfTest();
        }

        NSApplication *application = [NSApplication sharedApplication];
        AppDelegate *delegate = [AppDelegate new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
