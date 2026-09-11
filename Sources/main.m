#import <ApplicationServices/ApplicationServices.h>
#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDUsageTables.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <math.h>
#import <stdbool.h>
#import <stdio.h>
#import <string.h>
#import <sys/file.h>
#import <unistd.h>

static int gSingleInstanceLockFD = -1;

static BOOL AcquireSingleInstanceLock(void) {
    NSString *lockPath = [NSString stringWithFormat:
        @"/private/tmp/com.jino.magic-tap-click.%u.lock",
        getuid()];
    int lockFD = open(lockPath.fileSystemRepresentation,
                      O_CREAT | O_RDWR,
                      0600);
    if (lockFD < 0) {
        NSLog(@"MagicTapClick: single-instance lock open failed");
        return NO;
    }
    if (flock(lockFD, LOCK_EX | LOCK_NB) != 0) {
        close(lockFD);
        return NO;
    }
    gSingleInstanceLockFD = lockFD;
    return YES;
}

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
typedef void (*MTButtonStateCallbackFunction)(MTDeviceRef device,
                                               uint32_t newState,
                                               uint32_t oldState,
                                               void *refCon);
typedef bool (*MTRegisterButtonStateCallbackFunction)(
    MTDeviceRef,
    MTButtonStateCallbackFunction,
    void *);
typedef bool (*MTUnregisterButtonStateCallbackFunction)(
    MTDeviceRef,
    MTButtonStateCallbackFunction);
typedef int32_t (*MTDeviceStartFunction)(MTDeviceRef, int32_t);
typedef void (*MTDeviceStopFunction)(MTDeviceRef);
typedef bool (*MTDeviceIsBuiltInFunction)(MTDeviceRef);
typedef int32_t (*MTDeviceGetFamilyIDFunction)(MTDeviceRef,
                                                uint32_t *familyID);
typedef io_service_t (*MTDeviceGetServiceFunction)(MTDeviceRef);

// Current Apple drivers identify Magic Mouse devices with family ID 112 and
// product IDs 617 or 803. Require both so every trackpad fails closed.
static const uint32_t kMagicMouseFamilyID = 112;
static const uint32_t kAppleBluetoothVendorID = 76;
static const uint32_t kMagicMouseProductIDLightning = 617;
static const uint32_t kMagicMouseProductIDUSBC = 803;

static NSString *const kFrameworkPath =
    @"/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport";

static BOOL InputMonitoringIsGranted(void) {
    return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted;
}

static BOOL PostEventAccessIsGranted(void) {
    return CGPreflightPostEventAccess();
}

static int32_t DeviceGetProductID(MTDeviceRef device,
                                  MTDeviceGetServiceFunction getService,
                                  uint32_t *productIDOut) {
    if (productIDOut != NULL) {
        *productIDOut = 0;
    }
    if (getService == NULL) {
        return -1;
    }

    io_service_t service = getService(device);
    if (service == IO_OBJECT_NULL) {
        return -2;
    }

    CFTypeRef value = IORegistryEntrySearchCFProperty(
        service,
        kIOServicePlane,
        CFSTR("ProductID"),
        kCFAllocatorDefault,
        kIORegistryIterateRecursively | kIORegistryIterateParents);
    if (value == NULL || CFGetTypeID(value) != CFNumberGetTypeID()) {
        if (value != NULL) {
            CFRelease(value);
        }
        return -3;
    }

    int32_t signedProductID = 0;
    BOOL converted = CFNumberGetValue((CFNumberRef)value,
                                      kCFNumberSInt32Type,
                                      &signedProductID);
    CFRelease(value);
    if (!converted || signedProductID < 0) {
        return -4;
    }
    if (productIDOut != NULL) {
        *productIDOut = (uint32_t)signedProductID;
    }
    return 0;
}

static BOOL DeviceIsMagicMouse(MTDeviceRef device,
                               MTDeviceIsBuiltInFunction isBuiltIn,
                               MTDeviceGetFamilyIDFunction getFamilyID,
                               MTDeviceGetServiceFunction getService,
                               uint32_t *familyIDOut,
                               int32_t *familyResultOut,
                               uint32_t *productIDOut,
                               int32_t *productResultOut) {
    uint32_t familyID = 0;
    int32_t familyResult = -1;
    if (getFamilyID != NULL) {
        familyResult = getFamilyID(device, &familyID);
    }
    uint32_t productID = 0;
    int32_t productResult = DeviceGetProductID(device,
                                                getService,
                                                &productID);
    if (familyIDOut != NULL) {
        *familyIDOut = familyID;
    }
    if (familyResultOut != NULL) {
        *familyResultOut = familyResult;
    }
    if (productIDOut != NULL) {
        *productIDOut = productID;
    }
    if (productResultOut != NULL) {
        *productResultOut = productResult;
    }

    return isBuiltIn != NULL && !isBuiltIn(device) &&
           familyResult == 0 && familyID == kMagicMouseFamilyID &&
           productResult == 0 &&
           (productID == kMagicMouseProductIDLightning ||
            productID == kMagicMouseProductIDUSBC);
}

@class MagicTouchBridge;

typedef void (^MTFrameBlock)(const MTTouch *touches,
                             size_t count,
                             double timestamp);
typedef void (^MTButtonStateBlock)(uint32_t newState,
                                   uint32_t oldState);

@interface MagicTouchBridge : NSObject
- (BOOL)startWithCallback:(MTFrameBlock)callback
           buttonCallback:(MTButtonStateBlock)buttonCallback;
- (void)stop;
@end

@interface MagicTouchBridge () {
    void *_framework;
    MTDeviceStopFunction _stopDevice;
    MTUnregisterButtonStateCallbackFunction _unregisterButtonStateCallback;
    NSMutableArray<NSValue *> *_devices;
    MTFrameBlock _callback;
    MTButtonStateBlock _buttonCallback;
    BOOL _running;
    NSInteger _previousTouchCount;
}
- (void)handleTouches:(const MTTouch *)touches
                count:(size_t)count
            timestamp:(double)timestamp;
- (void)handleButtonState:(uint32_t)newState oldState:(uint32_t)oldState;
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

static void magicMouseButtonStateCallback(MTDeviceRef device,
                                          uint32_t newState,
                                          uint32_t oldState,
                                          void *refCon) {
    (void)device;
    MagicTouchBridge *bridge = (__bridge MagicTouchBridge *)refCon;
    [bridge handleButtonState:newState oldState:oldState];
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

- (BOOL)startWithCallback:(MTFrameBlock)callback
           buttonCallback:(MTButtonStateBlock)buttonCallback {
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
    MTRegisterButtonStateCallbackFunction registerButtonStateCallback =
        (MTRegisterButtonStateCallbackFunction)dlsym(
            _framework,
            "MTRegisterButtonStateCallback");
    MTDeviceStartFunction startDevice =
        (MTDeviceStartFunction)dlsym(_framework, "MTDeviceStart");
    MTDeviceIsBuiltInFunction isBuiltIn =
        (MTDeviceIsBuiltInFunction)dlsym(_framework, "MTDeviceIsBuiltIn");
    MTDeviceGetFamilyIDFunction getFamilyID =
        (MTDeviceGetFamilyIDFunction)dlsym(_framework, "MTDeviceGetFamilyID");
    MTDeviceGetServiceFunction getService =
        (MTDeviceGetServiceFunction)dlsym(_framework, "MTDeviceGetService");
    _stopDevice = (MTDeviceStopFunction)dlsym(_framework, "MTDeviceStop");
    _unregisterButtonStateCallback =
        (MTUnregisterButtonStateCallbackFunction)dlsym(
            _framework,
            "MTUnregisterButtonStateCallback");

    if (createList == NULL || registerCallback == NULL || startDevice == NULL ||
        registerButtonStateCallback == NULL ||
        _unregisterButtonStateCallback == NULL || isBuiltIn == NULL ||
        getFamilyID == NULL || getService == NULL) {
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
    _buttonCallback = [buttonCallback copy];
    CFIndex deviceCount = CFArrayGetCount(deviceList);
    NSLog(@"MagicTapClick: multitouch devices=%ld", (long)deviceCount);
    for (CFIndex index = 0; index < deviceCount; index++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(deviceList, index);
        uint32_t familyID = 0;
        int32_t familyResult = -1;
        uint32_t productID = 0;
        int32_t productResult = -1;
        BOOL isMagicMouse = DeviceIsMagicMouse(device,
                                                isBuiltIn,
                                                getFamilyID,
                                                getService,
                                                &familyID,
                                                &familyResult,
                                                &productID,
                                                &productResult);
        NSLog(@"MagicTapClick: device[%ld] built-in=%d family-id=%u family-result=%d product-id=%u product-result=%d accepted=%@",
              (long)index,
              (int)isBuiltIn(device),
              familyID,
              (int)familyResult,
              productID,
              (int)productResult,
              isMagicMouse ? @"yes" : @"no");
        if (!isMagicMouse) {
            continue;
        }

        registerCallback(device, magicTouchFrameCallback, (__bridge void *)self);
        BOOL buttonCallbackRegistered = registerButtonStateCallback(
            device,
            magicMouseButtonStateCallback,
            (__bridge void *)self);
        int32_t startResult = startDevice(device, 0);
        NSLog(@"MagicTapClick: device[%ld] button callback=%@ start result=%d",
              (long)index,
              buttonCallbackRegistered ? @"registered" : @"failed",
              (int)startResult);
        [_devices addObject:[NSValue valueWithPointer:device]];
    }

    CFRelease(deviceList);
    if (_devices.count == 0) {
        _callback = nil;
        _buttonCallback = nil;
        dlclose(_framework);
        _framework = NULL;
        NSLog(@"MagicTapClick: no supported Magic Mouse found");
        return NO;
    }
    _previousTouchCount = -1;
    _running = YES;
    return YES;
}

- (void)stop {
    if (!_running) {
        return;
    }

    _callback = nil;
    _buttonCallback = nil;
    if (_unregisterButtonStateCallback != NULL) {
        for (NSValue *value in _devices) {
            _unregisterButtonStateCallback(
                (MTDeviceRef)value.pointerValue,
                magicMouseButtonStateCallback);
        }
    }
    if (_stopDevice != NULL) {
        for (NSValue *value in _devices) {
            _stopDevice((MTDeviceRef)value.pointerValue);
        }
    }
    [_devices removeAllObjects];
    _running = NO;
    _previousTouchCount = -1;
    _unregisterButtonStateCallback = NULL;

    if (_framework != NULL) {
        dlclose(_framework);
        _framework = NULL;
    }
}

- (void)handleButtonState:(uint32_t)newState oldState:(uint32_t)oldState {
    MTButtonStateBlock callback = _buttonCallback;
    if (callback != nil) {
        callback(newState, oldState);
    }
}

- (void)handleTouches:(const MTTouch *)touches
                count:(size_t)count
            timestamp:(double)timestamp {
    if ((NSInteger)count != _previousTouchCount) {
        _previousTouchCount = (NSInteger)count;
        NSLog(@"MagicTapClick: touch count=%ld", (long)count);
    }
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
typedef NS_ENUM(NSInteger, TouchSensitivity) {
    TouchSensitivityGentle = 0,
    TouchSensitivityNormal = 1,
    TouchSensitivityStrict = 2
};

typedef NS_ENUM(NSInteger, ClickActivationMode) {
    ClickActivationModeTouch = 0,
    ClickActivationModePhysical = 1,
    ClickActivationModeTouchAndPhysical = 2
};

typedef struct {
    float movementThreshold;
    NSTimeInterval movementGracePeriod;
    NSTimeInterval minimumDuration;
    NSTimeInterval maximumDuration;
} TapSensitivityProfile;

static NSString *const kTouchSensitivityDefaultsKey =
    @"MagicTapClick.TouchSensitivity";
static NSString *const kLeftClickModeDefaultsKey =
    @"MagicTapClick.LeftClickMode";
static NSString *const kRightClickModeDefaultsKey =
    @"MagicTapClick.RightClickMode";
static NSString *const kPointerPrecisionEnabledDefaultsKey =
    @"MagicTapClick.PointerPrecisionEnabled";
static NSString *const kPointerFineGainDefaultsKey =
    @"MagicTapClick.PointerFineGain";
static NSString *const kPointerMediumGainDefaultsKey =
    @"MagicTapClick.PointerMediumGain";
static NSString *const kPointerFastGainDefaultsKey =
    @"MagicTapClick.PointerFastGain";
static const float kRightSideTouchBoundary = 0.42f;
static const NSTimeInterval kPhysicalClickCorrelationWindow = 0.10;
static const NSTimeInterval kMagicMouseMotionCorrelationWindow = 0.050;
static const int64_t kSyntheticEventMarker = 0x4D54434C49434B;

static const double kDefaultPointerFineGain = 0.50;
static const double kDefaultPointerMediumGain = 0.80;
static const double kDefaultPointerFastGain = 1.00;

static double ClampFinePointerGain(double gain) {
    return fmax(0.0, fmin(1.0, gain));
}

static double ClampPointerGain(double gain) {
    return fmax(0.25, fmin(1.50, gain));
}

static double SmoothStep(double value) {
    double t = fmax(0.0, fmin(1.0, value));
    return t * t * (3.0 - 2.0 * t);
}

static double PointerGainForRawSpeed(double rawSpeed,
                                     double fineGain,
                                     double mediumGain,
                                     double fastGain) {
    fineGain = ClampFinePointerGain(fineGain);
    mediumGain = ClampPointerGain(mediumGain);
    fastGain = ClampPointerGain(fastGain);
    if (rawSpeed <= 8.0) {
        return fineGain;
    }
    if (rawSpeed <= 32.0) {
        double t = SmoothStep((rawSpeed - 8.0) / 24.0);
        return fineGain + (mediumGain - fineGain) * t;
    }
    if (rawSpeed <= 96.0) {
        double t = SmoothStep((rawSpeed - 32.0) / 64.0);
        return mediumGain + (fastGain - mediumGain) * t;
    }
    return fastGain;
}

static TapSensitivityProfile TapSensitivityProfileForLevel(TouchSensitivity level) {
    switch (level) {
        case TouchSensitivityGentle:
            return (TapSensitivityProfile){
                .movementThreshold = 0.090f,
                .movementGracePeriod = 0.050,
                .minimumDuration = 0.001,
                .maximumDuration = 0.18
            };
        case TouchSensitivityStrict:
            return (TapSensitivityProfile){
                .movementThreshold = 0.055f,
                .movementGracePeriod = 0.030,
                .minimumDuration = 0.020,
                .maximumDuration = 0.14
            };
        case TouchSensitivityNormal:
        default:
            return (TapSensitivityProfile){
                .movementThreshold = 0.075f,
                .movementGracePeriod = 0.045,
                .minimumDuration = 0.005,
                .maximumDuration = 0.18
            };
    }
}

static NSString *TouchSensitivityTitle(TouchSensitivity level) {
    switch (level) {
        case TouchSensitivityGentle:
            return @"약하게";
        case TouchSensitivityStrict:
            return @"강하게";
        case TouchSensitivityNormal:
        default:
            return @"보통";
    }
}

static NSString *ClickActivationModeTitle(ClickActivationMode mode) {
    switch (mode) {
        case ClickActivationModePhysical:
            return @"클릭";
        case ClickActivationModeTouchAndPhysical:
            return @"터치+클릭";
        case ClickActivationModeTouch:
        default:
            return @"터치";
    }
}

static ClickActivationMode ValidClickActivationMode(NSInteger mode) {
    if (mode < ClickActivationModeTouch ||
        mode > ClickActivationModeTouchAndPhysical) {
        return ClickActivationModeTouch;
    }
    return (ClickActivationMode)mode;
}

static BOOL ClickModeAllowsTouch(ClickActivationMode mode) {
    return mode != ClickActivationModePhysical;
}

static BOOL ClickModeAllowsPhysicalClick(ClickActivationMode mode) {
    return mode != ClickActivationModeTouch;
}

static BOOL TouchesHaveThreeFingers(const MTTouch *touches, size_t count) {
    (void)touches;
    return count == 3;
}

@class MagicMouseMotionGate;

static void magicMouseHIDValueCallback(void *context,
                                       IOReturn result,
                                       void *sender,
                                       IOHIDValueRef value);

@interface MagicMouseMotionGate : NSObject
- (BOOL)start;
- (void)stop;
- (BOOL)consumeMotionMatchingDeltaX:(int64_t)deltaX
                             deltaY:(int64_t)deltaY
                       rawSpeedOut:(double *)rawSpeedOut;
@end

@interface MagicMouseMotionGate () {
    IOHIDManagerRef _manager;
    NSTimeInterval _lastMotionTime;
    int64_t _pendingRawX;
    int64_t _pendingRawY;
}
- (void)handleValue:(IOHIDValueRef)value;
@end

static void magicMouseHIDValueCallback(void *context,
                                       IOReturn result,
                                       void *sender,
                                       IOHIDValueRef value) {
    (void)sender;
    if (result != kIOReturnSuccess || value == NULL) {
        return;
    }
    MagicMouseMotionGate *gate = (__bridge MagicMouseMotionGate *)context;
    [gate handleValue:value];
}

@implementation MagicMouseMotionGate

- (BOOL)start {
    if (_manager != NULL) {
        return YES;
    }

    _manager = IOHIDManagerCreate(kCFAllocatorDefault,
                                  kIOHIDOptionsTypeNone);
    if (_manager == NULL) {
        return NO;
    }

    NSArray *productIDs = @[@(kMagicMouseProductIDLightning),
                            @(kMagicMouseProductIDUSBC)];
    NSMutableArray *matches = [NSMutableArray array];
    for (NSNumber *productID in productIDs) {
        [matches addObject:@{
            @kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop),
            @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_Mouse),
            @kIOHIDVendorIDKey: @(kAppleBluetoothVendorID),
            @kIOHIDProductIDKey: productID
        }];
    }
    IOHIDManagerSetDeviceMatchingMultiple(
        _manager,
        (__bridge CFArrayRef)matches);
    IOHIDManagerRegisterInputValueCallback(_manager,
                                            magicMouseHIDValueCallback,
                                            (__bridge void *)self);
    IOHIDManagerScheduleWithRunLoop(_manager,
                                    CFRunLoopGetMain(),
                                    kCFRunLoopCommonModes);
    IOReturn openResult = IOHIDManagerOpen(_manager,
                                           kIOHIDOptionsTypeNone);
    if (openResult != kIOReturnSuccess) {
        [self stop];
        NSLog(@"MagicTapClick: Magic Mouse HID motion gate open failed: 0x%x",
              openResult);
        return NO;
    }

    CFSetRef devices = IOHIDManagerCopyDevices(_manager);
    CFIndex count = devices != NULL ? CFSetGetCount(devices) : 0;
    if (devices != NULL) {
        CFRelease(devices);
    }
    if (count == 0) {
        [self stop];
        NSLog(@"MagicTapClick: Magic Mouse HID motion gate found no device");
        return NO;
    }

    NSLog(@"MagicTapClick: Magic Mouse HID motion gate started devices=%ld",
          (long)count);
    return YES;
}

- (void)stop {
    if (_manager == NULL) {
        return;
    }
    IOHIDManagerUnscheduleFromRunLoop(_manager,
                                      CFRunLoopGetMain(),
                                      kCFRunLoopCommonModes);
    IOHIDManagerClose(_manager, kIOHIDOptionsTypeNone);
    CFRelease(_manager);
    _manager = NULL;
    @synchronized (self) {
        _lastMotionTime = 0.0;
        _pendingRawX = 0;
        _pendingRawY = 0;
    }
}

- (void)handleValue:(IOHIDValueRef)value {
    IOHIDElementRef element = IOHIDValueGetElement(value);
    if (element == NULL ||
        IOHIDElementGetUsagePage(element) != kHIDPage_GenericDesktop ||
        !IOHIDElementIsRelative(element)) {
        return;
    }

    uint32_t usage = IOHIDElementGetUsage(element);
    if (usage != kHIDUsage_GD_X && usage != kHIDUsage_GD_Y) {
        return;
    }
    CFIndex rawValue = IOHIDValueGetIntegerValue(value);
    if (rawValue == 0) {
        return;
    }

    @synchronized (self) {
        NSTimeInterval now = CACurrentMediaTime();
        if (_lastMotionTime == 0.0 ||
            (now - _lastMotionTime) > kMagicMouseMotionCorrelationWindow) {
            _pendingRawX = 0;
            _pendingRawY = 0;
        }
        if (usage == kHIDUsage_GD_X) {
            _pendingRawX = rawValue;
        } else {
            _pendingRawY = rawValue;
        }
        _lastMotionTime = now;
    }
}

- (BOOL)consumeMotionMatchingDeltaX:(int64_t)deltaX
                             deltaY:(int64_t)deltaY
                       rawSpeedOut:(double *)rawSpeedOut {
    @synchronized (self) {
        NSTimeInterval now = CACurrentMediaTime();
        if (_lastMotionTime == 0.0 ||
            now < _lastMotionTime ||
            (now - _lastMotionTime) > kMagicMouseMotionCorrelationWindow) {
            return NO;
        }

        int64_t rawX = _pendingRawX;
        int64_t rawY = _pendingRawY;
        BOOL xMatches = rawX == 0 || deltaX == 0 ||
                        ((rawX > 0) == (deltaX > 0));
        BOOL yMatches = rawY == 0 || deltaY == 0 ||
                        ((rawY > 0) == (deltaY > 0));
        if ((rawX == 0 && rawY == 0) || !xMatches || !yMatches) {
            return NO;
        }

        if (rawSpeedOut != NULL) {
            *rawSpeedOut = hypot((double)rawX, (double)rawY);
        }
        return YES;
    }
}

- (void)dealloc {
    [self stop];
}

@end

@interface ClickInjector : NSObject
+ (void)postClickOnRightSide:(BOOL)rightSide clickCount:(NSInteger)clickCount;
+ (void)postLeftMouseDown;
+ (void)postLeftMouseDownAt:(CGPoint)position;
+ (void)postLeftMouseDraggedAt:(CGPoint)position;
+ (void)postLeftMouseUp;
@end

@interface TapDetector : NSObject
@property(nonatomic, assign, getter=isEnabled) BOOL enabled;
@property(nonatomic, assign) TouchSensitivity sensitivity;
@property(nonatomic, assign) ClickActivationMode leftClickMode;
@property(nonatomic, assign) ClickActivationMode rightClickMode;
@property(nonatomic, assign) BOOL pointerPrecisionEnabled;
@property(nonatomic, assign) double pointerFineGain;
@property(nonatomic, assign) double pointerMediumGain;
@property(nonatomic, assign) double pointerFastGain;
- (BOOL)start;
- (void)stop;
@end

@interface TapDetector () {
    MagicTouchBridge *_bridge;
    MagicMouseMotionGate *_motionGate;
    BOOL _tracking;
    BOOL _moved;
    BOOL _dragCandidate;
    BOOL _dragActive;
    CFMachPortRef _mouseEventTap;
    CFRunLoopSourceRef _mouseEventSource;
    NSTimeInterval _dragCandidateReadyTime;
    double _trackingStart;
    float _initialX;
    int _maxFingerCount;
    NSMutableDictionary<NSNumber *, NSValue *> *_initialPositions;
    NSTimeInterval _doubleClickInterval;
    NSTimeInterval _lastTapTime;
    BOOL _lastTapRightSide;
    BOOL _hasLastTap;
    NSTimeInterval _lastMagicMouseButtonDownTime;
    NSTimeInterval _lastMagicMouseButtonUpTime;
    double _pointerResidualX;
    double _pointerResidualY;
}
- (void)handleFrame:(const MTTouch *)touches
              count:(size_t)count
          timestamp:(double)timestamp;
- (void)resetTracking;
- (void)markDragCandidate;
- (void)activateDrag;
- (void)activateDragAt:(CGPoint)position;
- (void)endDrag;
- (BOOL)startMouseMotionMonitor;
- (void)stopMouseMotionMonitor;
- (void)reenableMouseEventTap;
- (void)handleMouseMoved:(CGEventRef)event;
- (void)filterMagicMouseMotionEvent:(CGEventRef)event;
- (void)handleMagicMouseButtonState:(uint32_t)newState
                           oldState:(uint32_t)oldState;
- (BOOL)shouldSuppressPhysicalEventType:(CGEventType)type;
- (BOOL)isTouchClickEnabledOnRightSide:(BOOL)rightSide;
- (BOOL)isPhysicalClickEnabledOnRightSide:(BOOL)rightSide;
@end

static CGEventRef magicMouseMotionCallback(CGEventTapProxy proxy,
                                           CGEventType type,
                                           CGEventRef event,
                                           void *refCon);

static CGEventRef magicMouseMotionCallback(CGEventTapProxy proxy,
                                           CGEventType type,
                                           CGEventRef event,
                                           void *refCon) {
    (void)proxy;
    TapDetector *detector = (__bridge TapDetector *)refCon;
    if (type == kCGEventTapDisabledByTimeout ||
        type == kCGEventTapDisabledByUserInput) {
        [detector reenableMouseEventTap];
        return event;
    }
    if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) ==
        kSyntheticEventMarker) {
        return event;
    }
    if (type == kCGEventMouseMoved ||
        type == kCGEventLeftMouseDragged ||
        type == kCGEventRightMouseDragged) {
        [detector handleMouseMoved:event];
    } else if ([detector shouldSuppressPhysicalEventType:type]) {
        return NULL;
    }
    return event;
}

@implementation TapDetector

- (instancetype)init {
    self = [super init];
    if (self) {
        _bridge = [MagicTouchBridge new];
        _initialPositions = [NSMutableDictionary dictionary];
        _doubleClickInterval = [NSEvent doubleClickInterval];
        _enabled = YES;

        NSNumber *savedSensitivity =
            [[NSUserDefaults standardUserDefaults] objectForKey:kTouchSensitivityDefaultsKey];
        NSInteger level = savedSensitivity != nil
            ? savedSensitivity.integerValue
            : TouchSensitivityStrict;
        if (level < TouchSensitivityGentle || level > TouchSensitivityStrict) {
            level = TouchSensitivityStrict;
        }
        _sensitivity = (TouchSensitivity)level;

        NSInteger leftMode = [[NSUserDefaults standardUserDefaults]
            integerForKey:kLeftClickModeDefaultsKey];
        NSInteger rightMode = [[NSUserDefaults standardUserDefaults]
            integerForKey:kRightClickModeDefaultsKey];
        _leftClickMode = ValidClickActivationMode(leftMode);
        _rightClickMode = ValidClickActivationMode(rightMode);

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        _pointerPrecisionEnabled = NO;
        [defaults setBool:NO forKey:kPointerPrecisionEnabledDefaultsKey];
        NSNumber *savedFineGain =
            [defaults objectForKey:kPointerFineGainDefaultsKey];
        NSNumber *savedMediumGain =
            [defaults objectForKey:kPointerMediumGainDefaultsKey];
        NSNumber *savedFastGain =
            [defaults objectForKey:kPointerFastGainDefaultsKey];
        _pointerFineGain = ClampFinePointerGain(savedFineGain != nil
            ? savedFineGain.doubleValue
            : kDefaultPointerFineGain);
        _pointerMediumGain = ClampPointerGain(savedMediumGain != nil
            ? savedMediumGain.doubleValue
            : kDefaultPointerMediumGain);
        _pointerFastGain = ClampPointerGain(savedFastGain != nil
            ? savedFastGain.doubleValue
            : kDefaultPointerFastGain);
    }
    return self;
}

- (BOOL)start {
    __weak TapDetector *weakSelf = self;
    BOOL bridgeStarted = [_bridge startWithCallback:^(const MTTouch *touches,
                                                      size_t count,
                                                      double timestamp) {
        TapDetector *strongSelf = weakSelf;
        if (strongSelf != nil) {
            [strongSelf handleFrame:touches count:count timestamp:timestamp];
        }
    } buttonCallback:^(uint32_t newState, uint32_t oldState) {
        TapDetector *strongSelf = weakSelf;
        if (strongSelf != nil) {
            [strongSelf handleMagicMouseButtonState:newState oldState:oldState];
        }
    }];
    if (!bridgeStarted) {
        return NO;
    }
    if (![self startMouseMotionMonitor]) {
        [_bridge stop];
        return NO;
    }
    return YES;
}

- (void)stop {
    [self endDrag];
    [self stopMouseMotionMonitor];
    [_bridge stop];
    [self resetTracking];
    [self clearTapHistory];
}

- (BOOL)startMouseMotionMonitor {
    if (_mouseEventTap != NULL) {
        return YES;
    }

    CGEventMask mask = CGEventMaskBit(kCGEventMouseMoved) |
                       CGEventMaskBit(kCGEventLeftMouseDragged) |
                       CGEventMaskBit(kCGEventRightMouseDragged) |
                       CGEventMaskBit(kCGEventLeftMouseDown) |
                       CGEventMaskBit(kCGEventLeftMouseUp) |
                       CGEventMaskBit(kCGEventRightMouseDown) |
                       CGEventMaskBit(kCGEventRightMouseUp);
    _mouseEventTap = CGEventTapCreate(kCGHIDEventTap,
                                      kCGHeadInsertEventTap,
                                      kCGEventTapOptionDefault,
                                      mask,
                                      magicMouseMotionCallback,
                                      (__bridge void *)self);
    if (_mouseEventTap == NULL) {
        return NO;
    }

    _mouseEventSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault,
                                                       _mouseEventTap,
                                                       0);
    if (_mouseEventSource == NULL) {
        CFMachPortInvalidate(_mouseEventTap);
        CFRelease(_mouseEventTap);
        _mouseEventTap = NULL;
        return NO;
    }

    CFRunLoopAddSource(CFRunLoopGetMain(),
                       _mouseEventSource,
                       kCFRunLoopCommonModes);
    CGEventTapEnable(_mouseEventTap, true);
    return YES;
}

- (void)stopMouseMotionMonitor {
    if (_mouseEventSource != NULL) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(),
                              _mouseEventSource,
                              kCFRunLoopCommonModes);
        CFRelease(_mouseEventSource);
        _mouseEventSource = NULL;
    }
    if (_mouseEventTap != NULL) {
        CGEventTapEnable(_mouseEventTap, false);
        CFMachPortInvalidate(_mouseEventTap);
        CFRelease(_mouseEventTap);
        _mouseEventTap = NULL;
    }
}

- (void)reenableMouseEventTap {
    if (_mouseEventTap != NULL) {
        CGEventTapEnable(_mouseEventTap, true);
    }
}

- (void)handleMouseMoved:(CGEventRef)event {
    if (event == NULL) {
        return;
    }
    CGPoint position = CGEventGetLocation(event);
    [self activateDragAt:position];
}

- (void)filterMagicMouseMotionEvent:(CGEventRef)event {
    (void)event;
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    if (!enabled) {
        [self endDrag];
        [self resetTracking];
        [self clearTapHistory];
    }
}

- (void)setSensitivity:(TouchSensitivity)sensitivity {
    if (sensitivity < TouchSensitivityGentle || sensitivity > TouchSensitivityStrict) {
        sensitivity = TouchSensitivityNormal;
    }
    _sensitivity = sensitivity;
    [[NSUserDefaults standardUserDefaults]
        setInteger:sensitivity forKey:kTouchSensitivityDefaultsKey];
}

- (void)setLeftClickMode:(ClickActivationMode)leftClickMode {
    _leftClickMode = ValidClickActivationMode(leftClickMode);
    [[NSUserDefaults standardUserDefaults]
        setInteger:_leftClickMode forKey:kLeftClickModeDefaultsKey];
    [self clearTapHistory];
}

- (void)setRightClickMode:(ClickActivationMode)rightClickMode {
    _rightClickMode = ValidClickActivationMode(rightClickMode);
    [[NSUserDefaults standardUserDefaults]
        setInteger:_rightClickMode forKey:kRightClickModeDefaultsKey];
    [self clearTapHistory];
}

- (void)setPointerPrecisionEnabled:(BOOL)pointerPrecisionEnabled {
    (void)pointerPrecisionEnabled;
    _pointerPrecisionEnabled = NO;
    _pointerResidualX = 0.0;
    _pointerResidualY = 0.0;
    [[NSUserDefaults standardUserDefaults]
        setBool:NO
          forKey:kPointerPrecisionEnabledDefaultsKey];
}

- (void)setPointerFineGain:(double)pointerFineGain {
    _pointerFineGain = ClampFinePointerGain(pointerFineGain);
    _pointerResidualX = 0.0;
    _pointerResidualY = 0.0;
    [[NSUserDefaults standardUserDefaults]
        setDouble:_pointerFineGain
           forKey:kPointerFineGainDefaultsKey];
}

- (void)setPointerMediumGain:(double)pointerMediumGain {
    _pointerMediumGain = ClampPointerGain(pointerMediumGain);
    _pointerResidualX = 0.0;
    _pointerResidualY = 0.0;
    [[NSUserDefaults standardUserDefaults]
        setDouble:_pointerMediumGain
           forKey:kPointerMediumGainDefaultsKey];
}

- (void)setPointerFastGain:(double)pointerFastGain {
    _pointerFastGain = ClampPointerGain(pointerFastGain);
    _pointerResidualX = 0.0;
    _pointerResidualY = 0.0;
    [[NSUserDefaults standardUserDefaults]
        setDouble:_pointerFastGain
           forKey:kPointerFastGainDefaultsKey];
}

- (BOOL)isTouchClickEnabledOnRightSide:(BOOL)rightSide {
    ClickActivationMode mode = rightSide
        ? _rightClickMode
        : _leftClickMode;
    return ClickModeAllowsTouch(mode);
}

- (BOOL)isPhysicalClickEnabledOnRightSide:(BOOL)rightSide {
    ClickActivationMode mode = rightSide
        ? _rightClickMode
        : _leftClickMode;
    return ClickModeAllowsPhysicalClick(mode);
}

- (void)handleMagicMouseButtonState:(uint32_t)newState
                           oldState:(uint32_t)oldState {
    BOOL isPressed = newState != 0;
    BOOL wasPressed = oldState != 0;
    if (isPressed == wasPressed) {
        return;
    }

    NSTimeInterval now = CACurrentMediaTime();
    @synchronized (self) {
        if (isPressed) {
            _lastMagicMouseButtonDownTime = now;
        } else {
            _lastMagicMouseButtonUpTime = now;
        }
    }
    NSLog(@"MagicTapClick: Magic Mouse physical button %@",
          isPressed ? @"down" : @"up");
}

- (BOOL)shouldSuppressPhysicalEventType:(CGEventType)type {
    BOOL isDown = type == kCGEventLeftMouseDown ||
                  type == kCGEventRightMouseDown;
    BOOL isUp = type == kCGEventLeftMouseUp ||
                type == kCGEventRightMouseUp;
    if (!_enabled || (!isDown && !isUp)) {
        return NO;
    }

    BOOL rightSide = type == kCGEventRightMouseDown ||
                     type == kCGEventRightMouseUp;
    if ([self isPhysicalClickEnabledOnRightSide:rightSide]) {
        return NO;
    }

    NSTimeInterval now = CACurrentMediaTime();
    BOOL correlated = NO;
    @synchronized (self) {
        NSTimeInterval transitionTime = isDown
            ? _lastMagicMouseButtonDownTime
            : _lastMagicMouseButtonUpTime;
        correlated = transitionTime > 0.0 &&
                     now >= transitionTime &&
                     (now - transitionTime) <= kPhysicalClickCorrelationWindow;
        if (correlated) {
            if (isDown) {
                _lastMagicMouseButtonDownTime = 0.0;
            } else {
                _lastMagicMouseButtonUpTime = 0.0;
            }
        }
    }
    if (correlated) {
        NSLog(@"MagicTapClick: suppressed Magic Mouse %@ physical click",
              rightSide ? @"right" : @"left");
    }
    return correlated;
}

- (void)handleFrame:(const MTTouch *)touches
              count:(size_t)count
          timestamp:(double)timestamp {
    if (!_enabled) {
        [self endDrag];
        [self resetTracking];
        return;
    }

    if (count == 0) {
        if (_dragActive) {
            [self endDrag];
            [self resetTracking];
            return;
        }

        if (_dragCandidate) {
            [self resetTracking];
            return;
        }

        if (!_tracking) {
            return;
        }

        double duration = timestamp - _trackingStart;
        int fingerCount = _maxFingerCount;
        float initialX = _initialX;
        TapSensitivityProfile profile =
            TapSensitivityProfileForLevel(_sensitivity);
        BOOL validTap = !_moved && fingerCount == 1 &&
                        duration >= profile.minimumDuration &&
                        duration <= profile.maximumDuration;
        if (validTap) {
            NSLog(@"MagicTapClick: tap recognized side=%@ duration=%.3f",
                  initialX >= kRightSideTouchBoundary ? @"right" : @"left",
                  duration);
        } else {
            NSLog(@"MagicTapClick: tap rejected fingers=%d moved=%@ duration=%.3f",
                  fingerCount,
                  _moved ? @"YES" : @"NO",
                  duration);
        }
        [self resetTracking];

        if (!validTap) {
            return;
        }

        BOOL rightSide = initialX >= kRightSideTouchBoundary;
        if (![self isTouchClickEnabledOnRightSide:rightSide]) {
            NSLog(@"MagicTapClick: tap ignored side=%@ mode=physical-click",
                  rightSide ? @"right" : @"left");
            [self clearTapHistory];
            return;
        }
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
            if (self.isEnabled &&
                [self isTouchClickEnabledOnRightSide:rightSide]) {
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
        _dragCandidate = NO;
        if (TouchesHaveThreeFingers(touches, count)) {
            [self markDragCandidate];
        }
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

    if (_dragCandidate && !TouchesHaveThreeFingers(touches, count)) {
        [self endDrag];
        [self resetTracking];
        return;
    }

    if (!_dragCandidate && !_moved &&
        TouchesHaveThreeFingers(touches, count)) {
        [self markDragCandidate];
        _maxFingerCount = 3;
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
        TapSensitivityProfile profile =
            TapSensitivityProfileForLevel(_sensitivity);
        if ((timestamp - _trackingStart) < profile.movementGracePeriod) {
            continue;
        }
        float movement = sqrtf(dx * dx + dy * dy);
        if (movement > profile.movementThreshold) {
            _moved = YES;
            break;
        }
    }

    if (_dragCandidate && !_dragActive && _moved) {
        [self activateDrag];
    }
}

- (void)resetTracking {
    _tracking = NO;
    _moved = NO;
    _dragCandidate = NO;
    _dragCandidateReadyTime = 0.0;
    _trackingStart = 0.0;
    _initialX = 0.0f;
    _maxFingerCount = 0;
    [_initialPositions removeAllObjects];
}

- (void)markDragCandidate {
    TapSensitivityProfile profile =
        TapSensitivityProfileForLevel(_sensitivity);
    @synchronized (self) {
        _dragCandidate = YES;
        _dragCandidateReadyTime = CACurrentMediaTime() +
                                  profile.movementGracePeriod;
    }
}

- (void)activateDrag {
    CGEventRef currentEvent = CGEventCreate(NULL);
    if (currentEvent == NULL) {
        return;
    }
    CGPoint position = CGEventGetLocation(currentEvent);
    CFRelease(currentEvent);
    [self activateDragAt:position];
}

- (void)activateDragAt:(CGPoint)position {
    BOOL shouldStart = NO;
    @synchronized (self) {
        if (_enabled && _dragCandidate && !_dragActive &&
            CACurrentMediaTime() >= _dragCandidateReadyTime) {
            _dragActive = YES;
            shouldStart = YES;
        }
    }
    if (!shouldStart) {
        return;
    }
    [ClickInjector postLeftMouseDownAt:position];
    [ClickInjector postLeftMouseDraggedAt:position];
}

- (void)endDrag {
    BOOL shouldEnd = NO;
    @synchronized (self) {
        if (_dragActive) {
            _dragActive = NO;
            shouldEnd = YES;
        }
    }
    if (!shouldEnd) {
        return;
    }
    [ClickInjector postLeftMouseUp];
}

- (void)clearTapHistory {
    _lastTapTime = 0.0;
    _lastTapRightSide = NO;
    _hasLastTap = NO;
}

- (void)dealloc {
    [self endDrag];
    [self stopMouseMotionMonitor];
    [_bridge stop];
}

@end

@implementation ClickInjector

static void PostLeftMouseButtonEventAt(CGEventType type, CGPoint position) {
    CGEventRef event = CGEventCreateMouseEvent(NULL,
                                                type,
                                                position,
                                                kCGMouseButtonLeft);
    if (event != NULL) {
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, 1);
        CGEventSetIntegerValueField(event,
                                    kCGEventSourceUserData,
                                    kSyntheticEventMarker);
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
    }
}

static void PostLeftMouseButtonEvent(CGEventType type) {
    CGEventRef currentEvent = CGEventCreate(NULL);
    if (currentEvent == NULL) {
        return;
    }

    CGPoint position = CGEventGetLocation(currentEvent);
    CFRelease(currentEvent);
    PostLeftMouseButtonEventAt(type, position);
}

+ (void)postLeftMouseDown {
    PostLeftMouseButtonEvent(kCGEventLeftMouseDown);
}

+ (void)postLeftMouseDownAt:(CGPoint)position {
    PostLeftMouseButtonEventAt(kCGEventLeftMouseDown, position);
}

+ (void)postLeftMouseDraggedAt:(CGPoint)position {
    PostLeftMouseButtonEventAt(kCGEventLeftMouseDragged, position);
}

+ (void)postLeftMouseUp {
    PostLeftMouseButtonEvent(kCGEventLeftMouseUp);
}

+ (void)postClickOnRightSide:(BOOL)rightSide clickCount:(NSInteger)clickCount {
    BOOL postEventAccessGranted = PostEventAccessIsGranted();
    NSLog(@"MagicTapClick: posting %@ click count=%ld post-event-access=%@",
          rightSide ? @"right" : @"left",
          (long)clickCount,
          postEventAccessGranted ? @"granted" : @"not granted");

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
        CGEventSetIntegerValueField(down,
                                    kCGEventSourceUserData,
                                    kSyntheticEventMarker);
        CGEventSetIntegerValueField(up,
                                    kCGEventSourceUserData,
                                    kSyntheticEventMarker);
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
    NSTimer *_permissionTimer;
    BOOL _engineRunning;
    NSTimeInterval _nextEngineRetryTime;
    NSString *_lastRuntimeFingerprint;
    NSWindow *_pointerSettingsWindow;
    NSButton *_pointerPrecisionCheckbox;
    NSSlider *_pointerFineSlider;
    NSSlider *_pointerMediumSlider;
    NSSlider *_pointerFastSlider;
    NSTextField *_pointerFineValueLabel;
    NSTextField *_pointerMediumValueLabel;
    NSTextField *_pointerFastValueLabel;
}
- (void)toggleEnabled:(id)sender;
- (void)setSensitivity:(id)sender;
- (void)setLeftClickMode:(id)sender;
- (void)setRightClickMode:(id)sender;
- (void)togglePointerPrecision:(id)sender;
- (void)showPointerSettings:(id)sender;
- (void)updatePointerPrecisionEnabled:(id)sender;
- (void)updatePointerGain:(id)sender;
- (void)resetPointerGains:(id)sender;
- (void)refreshPointerSettingsControls;
- (NSStackView *)pointerSliderRowWithTitle:(NSString *)title
                                    slider:(NSSlider *)slider
                                valueLabel:(NSTextField *)valueLabel;
- (void)openAccessibilitySettings:(id)sender;
- (void)quit:(id)sender;
- (void)refreshMenu;
- (void)requestMissingPermissions;
- (void)reconcileRuntimeState;
- (void)permissionTimerFired:(NSTimer *)timer;
- (void)restartForPermissionRefresh:(id)sender;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    _detector = [TapDetector new];
    NSLog(@"MagicTapClick: click modes left=%@ right=%@",
          ClickActivationModeTitle(_detector.leftClickMode),
          ClickActivationModeTitle(_detector.rightClickMode));

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

    [self refreshMenu];
    [self requestMissingPermissions];
    [self reconcileRuntimeState];

    _permissionTimer = [NSTimer timerWithTimeInterval:1.0
                                                target:self
                                              selector:@selector(permissionTimerFired:)
                                              userInfo:nil
                                               repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_permissionTimer
                              forMode:NSRunLoopCommonModes];
}

- (void)requestMissingPermissions {
    // Request first; the input engine is created only after every permission
    // is visible to this process.

    NSDictionary *options = @{
        (__bridge id)kAXTrustedCheckOptionPrompt: @YES
    };
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);

    if (!PostEventAccessIsGranted()) {
        BOOL requested = CGRequestPostEventAccess();
        NSLog(@"MagicTapClick: requested post-event access result=%@",
              requested ? @"granted" : @"pending");
    }

    BOOL inputMonitoringGranted = InputMonitoringIsGranted();
    if (!inputMonitoringGranted) {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
    }
}

- (void)permissionTimerFired:(NSTimer *)timer {
    (void)timer;
    [self reconcileRuntimeState];
}

- (void)reconcileRuntimeState {
    BOOL accessibilityGranted = AXIsProcessTrusted();
    BOOL postEventGranted = PostEventAccessIsGranted();
    BOOL inputMonitoringGranted = InputMonitoringIsGranted();
    BOOL permissionsGranted = accessibilityGranted &&
                              postEventGranted &&
                              inputMonitoringGranted;
    NSTimeInterval now = CACurrentMediaTime();

    if (!permissionsGranted && _engineRunning) {
        [_detector stop];
        _engineRunning = NO;
        _nextEngineRetryTime = 0.0;
        NSLog(@"MagicTapClick: input engine stopped because permission was revoked");
    } else if (permissionsGranted && !_engineRunning &&
               now >= _nextEngineRetryTime) {
        _engineRunning = [_detector start];
        _nextEngineRetryTime = _engineRunning ? 0.0 : now + 5.0;
        NSLog(@"MagicTapClick: input engine %@",
              _engineRunning ? @"started" : @"start failed; retry scheduled");
    }

    NSString *fingerprint = [NSString stringWithFormat:@"%d:%d:%d:%d",
                             accessibilityGranted,
                             postEventGranted,
                             inputMonitoringGranted,
                             _engineRunning];
    if (![_lastRuntimeFingerprint isEqualToString:fingerprint]) {
        _lastRuntimeFingerprint = fingerprint;
        NSLog(@"MagicTapClick: runtime state accessibility=%@ post-event=%@ input-monitoring=%@ engine=%@",
              accessibilityGranted ? @"granted" : @"not-granted",
              postEventGranted ? @"granted" : @"not-granted",
              inputMonitoringGranted ? @"granted" : @"not-granted",
              _engineRunning ? @"running" : @"stopped");
        [self refreshMenu];
    }
}

- (void)restartForPermissionRefresh:(id)sender {
    (void)sender;
    NSString *serviceTarget = [NSString stringWithFormat:
        @"gui/%u/com.jino.magic-tap-click",
        getuid()];
    NSTask *restart = [NSTask new];
    restart.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"];
    restart.arguments = @[@"kickstart", @"-k", serviceTarget];
    restart.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    restart.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *error = nil;
    if (![restart launchAndReturnError:&error]) {
        NSLog(@"MagicTapClick: permission refresh restart failed: %@",
              error);
        return;
    }
    NSLog(@"MagicTapClick: permission refresh restart requested");
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

    NSMenuItem *leftClickModeItem = [[NSMenuItem alloc]
        initWithTitle:[NSString stringWithFormat:
                       @"좌클릭 방식: %@",
                       ClickActivationModeTitle(_detector.leftClickMode)]
        action:nil
        keyEquivalent:@""];
    NSMenu *leftClickModeMenu = [[NSMenu alloc] initWithTitle:@"좌클릭 방식"];
    for (ClickActivationMode mode = ClickActivationModeTouch;
         mode <= ClickActivationModeTouchAndPhysical;
         mode++) {
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:ClickActivationModeTitle(mode)
            action:@selector(setLeftClickMode:)
            keyEquivalent:@""];
        item.target = self;
        item.tag = mode;
        item.state = _detector.leftClickMode == mode
            ? NSControlStateValueOn
            : NSControlStateValueOff;
        [leftClickModeMenu addItem:item];
    }
    leftClickModeItem.submenu = leftClickModeMenu;
    [menu addItem:leftClickModeItem];

    NSMenuItem *rightClickModeItem = [[NSMenuItem alloc]
        initWithTitle:[NSString stringWithFormat:
                       @"우클릭 방식: %@",
                       ClickActivationModeTitle(_detector.rightClickMode)]
        action:nil
        keyEquivalent:@""];
    NSMenu *rightClickModeMenu = [[NSMenu alloc] initWithTitle:@"우클릭 방식"];
    for (ClickActivationMode mode = ClickActivationModeTouch;
         mode <= ClickActivationModeTouchAndPhysical;
         mode++) {
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:ClickActivationModeTitle(mode)
            action:@selector(setRightClickMode:)
            keyEquivalent:@""];
        item.target = self;
        item.tag = mode;
        item.state = _detector.rightClickMode == mode
            ? NSControlStateValueOn
            : NSControlStateValueOff;
        [rightClickModeMenu addItem:item];
    }
    rightClickModeItem.submenu = rightClickModeMenu;
    [menu addItem:rightClickModeItem];

    NSMenuItem *sensitivityItem = [[NSMenuItem alloc]
        initWithTitle:[NSString stringWithFormat:
                       @"터치 감도: %@",
                       TouchSensitivityTitle(_detector.sensitivity)]
        action:nil
        keyEquivalent:@""];
    NSMenu *sensitivityMenu = [[NSMenu alloc] initWithTitle:@"터치 감도"];
    for (TouchSensitivity level = TouchSensitivityGentle;
         level <= TouchSensitivityStrict;
         level++) {
        NSMenuItem *item = [[NSMenuItem alloc]
            initWithTitle:TouchSensitivityTitle(level)
            action:@selector(setSensitivity:)
            keyEquivalent:@""];
        item.target = self;
        item.tag = level;
        item.state = _detector.sensitivity == level
            ? NSControlStateValueOn
            : NSControlStateValueOff;
        [sensitivityMenu addItem:item];
    }
    sensitivityItem.submenu = sensitivityMenu;
    [menu addItem:sensitivityItem];

    NSMenuItem *pointerSafetyItem = [[NSMenuItem alloc]
        initWithTitle:@"포인터 정밀도: 안전 모드로 비활성화"
        action:nil
        keyEquivalent:@""];
    pointerSafetyItem.enabled = NO;
    [menu addItem:pointerSafetyItem];

    BOOL accessibilityGranted = AXIsProcessTrusted();
    BOOL postEventGranted = PostEventAccessIsGranted();
    BOOL inputMonitoringGranted = InputMonitoringIsGranted();
    NSString *accessibilityStatus = accessibilityGranted ? @"허용됨" : @"필요";
    NSString *postEventStatus = postEventGranted ? @"허용됨" : @"필요";
    NSString *inputMonitoringStatus = inputMonitoringGranted ? @"허용됨" : @"필요";
    NSString *permissionTitle = [NSString stringWithFormat:
        @"권한 설정 — 손쉬운 사용: %@ / 이벤트 전송: %@ / 입력 감시: %@",
        accessibilityStatus,
        postEventStatus,
        inputMonitoringStatus];
    _permissionItem = [[NSMenuItem alloc] initWithTitle:permissionTitle
                                                  action:@selector(openAccessibilitySettings:)
                                           keyEquivalent:@""];
    _permissionItem.target = self;
    _permissionItem.enabled = YES;
    [menu addItem:_permissionItem];

    if (!(accessibilityGranted && postEventGranted &&
          inputMonitoringGranted)) {
        NSMenuItem *restartItem = [[NSMenuItem alloc]
            initWithTitle:@"권한 승인 후 앱 재시작"
            action:@selector(restartForPermissionRefresh:)
            keyEquivalent:@""];
        restartItem.target = self;
        [menu addItem:restartItem];
    }

    NSString *status = nil;
    if (!accessibilityGranted) {
        status = @"대기: 손쉬운 사용 권한이 필요함";
    } else if (!postEventGranted) {
        status = @"대기: 클릭 이벤트 전송 권한이 필요함";
    } else if (!inputMonitoringGranted) {
        status = @"대기: 입력 모니터링 권한이 필요함";
    } else if (_engineRunning) {
        status = @"정상 작동 중 — Magic Mouse 전용";
    } else {
        status = @"권한 정상 — Magic Mouse 연결/엔진 재시도 중";
    }
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

- (void)setSensitivity:(id)sender {
    NSMenuItem *item = (NSMenuItem *)sender;
    _detector.sensitivity = (TouchSensitivity)item.tag;
    [self refreshMenu];
}

- (void)setLeftClickMode:(id)sender {
    NSMenuItem *item = (NSMenuItem *)sender;
    _detector.leftClickMode = (ClickActivationMode)item.tag;
    [self refreshMenu];
}

- (void)setRightClickMode:(id)sender {
    NSMenuItem *item = (NSMenuItem *)sender;
    _detector.rightClickMode = (ClickActivationMode)item.tag;
    [self refreshMenu];
}

- (void)togglePointerPrecision:(id)sender {
    (void)sender;
    _detector.pointerPrecisionEnabled = !_detector.pointerPrecisionEnabled;
    [self refreshPointerSettingsControls];
    [self refreshMenu];
}

- (NSStackView *)pointerSliderRowWithTitle:(NSString *)title
                                    slider:(NSSlider *)slider
                                valueLabel:(NSTextField *)valueLabel {
    NSTextField *titleLabel = [NSTextField labelWithString:title];
    titleLabel.alignment = NSTextAlignmentLeft;
    [titleLabel.widthAnchor constraintEqualToConstant:92.0].active = YES;
    valueLabel.alignment = NSTextAlignmentRight;
    valueLabel.font = [NSFont monospacedDigitSystemFontOfSize:12.0
                                                       weight:NSFontWeightRegular];
    [valueLabel.widthAnchor constraintEqualToConstant:52.0].active = YES;

    NSStackView *row = [NSStackView stackViewWithViews:@[
        titleLabel,
        slider,
        valueLabel
    ]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 10.0;
    return row;
}

- (void)showPointerSettings:(id)sender {
    (void)sender;
    if (_pointerSettingsWindow == nil) {
        NSRect frame = NSMakeRect(0.0, 0.0, 480.0, 310.0);
        _pointerSettingsWindow = [[NSWindow alloc]
            initWithContentRect:frame
                      styleMask:NSWindowStyleMaskTitled |
                                NSWindowStyleMaskClosable
                        backing:NSBackingStoreBuffered
                          defer:NO];
        _pointerSettingsWindow.title = @"Magic Mouse 포인터 정밀도";
        _pointerSettingsWindow.releasedWhenClosed = NO;

        NSTextField *heading = [NSTextField labelWithString:
            @"Magic Mouse 이동 속도 곡선"];
        heading.font = [NSFont boldSystemFontOfSize:16.0];
        NSTextField *description = [NSTextField wrappingLabelWithString:
            @"작은 움직임은 정밀하게, 빠른 움직임은 넓은 화면을 빠르게 이동하도록 각 구간의 속도를 조절합니다. 트랙패드에는 적용되지 않습니다."];
        description.textColor = NSColor.secondaryLabelColor;

        _pointerPrecisionCheckbox = [NSButton
            checkboxWithTitle:@"Magic Mouse 포인터 정밀도 사용"
                       target:self
                       action:@selector(updatePointerPrecisionEnabled:)];

        _pointerFineSlider = [NSSlider
            sliderWithValue:_detector.pointerFineGain
                   minValue:0.0
                   maxValue:1.0
                     target:self
                     action:@selector(updatePointerGain:)];
        _pointerMediumSlider = [NSSlider
            sliderWithValue:_detector.pointerMediumGain
                   minValue:0.25
                   maxValue:1.50
                     target:self
                     action:@selector(updatePointerGain:)];
        _pointerFastSlider = [NSSlider
            sliderWithValue:_detector.pointerFastGain
                   minValue:0.25
                   maxValue:1.50
                     target:self
                     action:@selector(updatePointerGain:)];
        _pointerFineSlider.tag = 0;
        _pointerMediumSlider.tag = 1;
        _pointerFastSlider.tag = 2;
        _pointerFineSlider.continuous = YES;
        _pointerMediumSlider.continuous = YES;
        _pointerFastSlider.continuous = YES;
        [_pointerFineSlider.widthAnchor constraintEqualToConstant:260.0].active = YES;
        [_pointerMediumSlider.widthAnchor constraintEqualToConstant:260.0].active = YES;
        [_pointerFastSlider.widthAnchor constraintEqualToConstant:260.0].active = YES;

        _pointerFineValueLabel = [NSTextField labelWithString:@""];
        _pointerMediumValueLabel = [NSTextField labelWithString:@""];
        _pointerFastValueLabel = [NSTextField labelWithString:@""];

        NSButton *resetButton = [NSButton buttonWithTitle:@"기본값으로 복원"
                                                   target:self
                                                   action:@selector(resetPointerGains:)];
        resetButton.bezelStyle = NSBezelStyleRounded;

        NSStackView *stack = [NSStackView stackViewWithViews:@[
            heading,
            description,
            _pointerPrecisionCheckbox,
            [self pointerSliderRowWithTitle:@"미세 이동"
                                      slider:_pointerFineSlider
                                  valueLabel:_pointerFineValueLabel],
            [self pointerSliderRowWithTitle:@"중간 속도"
                                      slider:_pointerMediumSlider
                                  valueLabel:_pointerMediumValueLabel],
            [self pointerSliderRowWithTitle:@"빠른 이동"
                                      slider:_pointerFastSlider
                                  valueLabel:_pointerFastValueLabel],
            resetButton
        ]];
        stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stack.alignment = NSLayoutAttributeLeading;
        stack.spacing = 16.0;
        stack.translatesAutoresizingMaskIntoConstraints = NO;

        NSView *content = _pointerSettingsWindow.contentView;
        [content addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor
                                                constant:24.0],
            [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor
                                                 constant:-24.0],
            [stack.topAnchor constraintEqualToAnchor:content.topAnchor
                                             constant:22.0]
        ]];
    }

    [self refreshPointerSettingsControls];
    [_pointerSettingsWindow center];
    [_pointerSettingsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)refreshPointerSettingsControls {
    _pointerPrecisionCheckbox.state = _detector.pointerPrecisionEnabled
        ? NSControlStateValueOn
        : NSControlStateValueOff;
    _pointerFineSlider.doubleValue = _detector.pointerFineGain;
    _pointerMediumSlider.doubleValue = _detector.pointerMediumGain;
    _pointerFastSlider.doubleValue = _detector.pointerFastGain;
    _pointerFineValueLabel.stringValue = [NSString stringWithFormat:@"%.0f%%",
                                           _detector.pointerFineGain * 100.0];
    _pointerMediumValueLabel.stringValue = [NSString stringWithFormat:@"%.0f%%",
                                             _detector.pointerMediumGain * 100.0];
    _pointerFastValueLabel.stringValue = [NSString stringWithFormat:@"%.0f%%",
                                           _detector.pointerFastGain * 100.0];
    BOOL enabled = _detector.pointerPrecisionEnabled;
    _pointerFineSlider.enabled = enabled;
    _pointerMediumSlider.enabled = enabled;
    _pointerFastSlider.enabled = enabled;
}

- (void)updatePointerPrecisionEnabled:(id)sender {
    NSButton *checkbox = (NSButton *)sender;
    _detector.pointerPrecisionEnabled =
        checkbox.state == NSControlStateValueOn;
    [self refreshPointerSettingsControls];
    [self refreshMenu];
}

- (void)updatePointerGain:(id)sender {
    NSSlider *slider = (NSSlider *)sender;
    if (slider.tag == 0) {
        _detector.pointerFineGain = slider.doubleValue;
    } else if (slider.tag == 1) {
        _detector.pointerMediumGain = slider.doubleValue;
    } else {
        _detector.pointerFastGain = slider.doubleValue;
    }
    [self refreshPointerSettingsControls];
}


- (void)resetPointerGains:(id)sender {
    (void)sender;
    _detector.pointerPrecisionEnabled = NO;
    _detector.pointerFineGain = kDefaultPointerFineGain;
    _detector.pointerMediumGain = kDefaultPointerMediumGain;
    _detector.pointerFastGain = kDefaultPointerFastGain;
    [self refreshPointerSettingsControls];
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

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [_permissionTimer invalidate];
    _permissionTimer = nil;
    [_detector stop];
    _engineRunning = NO;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return NO;
}

@end

static CGEventRef selfTestEventTapCallback(CGEventTapProxy proxy,
                                           CGEventType type,
                                           CGEventRef event,
                                           void *refCon) {
    (void)proxy;
    (void)type;
    (void)refCon;
    return event;
}

static int RunSelfTest(void) {
    void *framework = dlopen(kFrameworkPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (framework == NULL) {
        fprintf(stderr, "MultitouchSupport.framework: FAIL (%s)\n", dlerror());
        return 1;
    }

    const char *symbols[] = {
        "MTDeviceCreateList",
        "MTRegisterContactFrameCallbackWithRefcon",
        "MTRegisterButtonStateCallback",
        "MTUnregisterButtonStateCallback",
        "MTDeviceStart",
        "MTDeviceStop",
        "MTDeviceIsBuiltIn",
        "MTDeviceGetFamilyID",
        "MTDeviceGetService"
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
    MTDeviceIsBuiltInFunction isBuiltIn =
        (MTDeviceIsBuiltInFunction)dlsym(framework, "MTDeviceIsBuiltIn");
    MTDeviceGetFamilyIDFunction getFamilyID =
        (MTDeviceGetFamilyIDFunction)dlsym(framework, "MTDeviceGetFamilyID");
    MTDeviceGetServiceFunction getService =
        (MTDeviceGetServiceFunction)dlsym(framework, "MTDeviceGetService");
    CFArrayRef devices = createList != NULL ? createList() : NULL;
    CFIndex deviceCount = devices != NULL ? CFArrayGetCount(devices) : 0;

    printf("MultitouchSupport.framework: OK\n");
    printf("visible multitouch devices: %ld\n", (long)deviceCount);
    if (devices != NULL && isBuiltIn != NULL && getFamilyID != NULL &&
        getService != NULL) {
        CFIndex acceptedCount = 0;
        for (CFIndex index = 0; index < deviceCount; index++) {
            MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(devices, index);
            uint32_t familyID = 0;
            int32_t familyResult = -1;
            uint32_t productID = 0;
            int32_t productResult = -1;
            BOOL accepted = DeviceIsMagicMouse(device,
                                                isBuiltIn,
                                                getFamilyID,
                                                getService,
                                                &familyID,
                                                &familyResult,
                                                &productID,
                                                &productResult);
            printf("device[%ld]: built-in=%d family-id=%u family-result=%d product-id=%u product-result=%d magic-mouse=%s\n",
                   (long)index,
                   (int)isBuiltIn(device),
                   familyID,
                   (int)familyResult,
                   productID,
                   (int)productResult,
                   accepted ? "yes" : "no");
            if (accepted) {
                acceptedCount++;
            }
        }
    printf("magic mouse devices accepted: %ld\n", (long)acceptedCount);
    }
    if (devices != NULL) {
        CFRelease(devices);
    }
    NSInteger savedLeftClickMode = [[NSUserDefaults standardUserDefaults]
        integerForKey:kLeftClickModeDefaultsKey];
    NSInteger savedRightClickMode = [[NSUserDefaults standardUserDefaults]
        integerForKey:kRightClickModeDefaultsKey];
    ClickActivationMode leftClickMode =
        ValidClickActivationMode(savedLeftClickMode);
    ClickActivationMode rightClickMode =
        ValidClickActivationMode(savedRightClickMode);
    printf("left click mode: %s\n",
           ClickActivationModeTitle(leftClickMode).UTF8String);
    printf("right click mode: %s\n",
           ClickActivationModeTitle(rightClickMode).UTF8String);
    BOOL clickModeMatrixOK =
        ClickModeAllowsTouch(ClickActivationModeTouch) &&
        !ClickModeAllowsPhysicalClick(ClickActivationModeTouch) &&
        !ClickModeAllowsTouch(ClickActivationModePhysical) &&
        ClickModeAllowsPhysicalClick(ClickActivationModePhysical) &&
        ClickModeAllowsTouch(ClickActivationModeTouchAndPhysical) &&
        ClickModeAllowsPhysicalClick(ClickActivationModeTouchAndPhysical);
    printf("click mode matrix: %s\n", clickModeMatrixOK ? "OK" : "FAIL");
    double fineResult = PointerGainForRawSpeed(1.0,
                                               kDefaultPointerFineGain,
                                               kDefaultPointerMediumGain,
                                               kDefaultPointerFastGain);
    double mediumResult = PointerGainForRawSpeed(32.0,
                                                 kDefaultPointerFineGain,
                                                 kDefaultPointerMediumGain,
                                                 kDefaultPointerFastGain);
    double fastResult = PointerGainForRawSpeed(97.0,
                                               kDefaultPointerFineGain,
                                               kDefaultPointerMediumGain,
                                               kDefaultPointerFastGain);
    BOOL pointerCurveOK = fabs(fineResult - kDefaultPointerFineGain) < 0.001 &&
                          fabs(mediumResult - kDefaultPointerMediumGain) < 0.001 &&
                          fabs(fastResult - kDefaultPointerFastGain) < 0.001 &&
                          fineResult <= mediumResult &&
                          mediumResult <= fastResult;
    printf("pointer precision curve: %s (fine=%.2f medium=%.2f fast=%.2f)\n",
           pointerCurveOK ? "OK" : "FAIL",
           fineResult,
           mediumResult,
           fastResult);
    TapDetector *pointerSafetyDetector = [TapDetector new];
    pointerSafetyDetector.pointerPrecisionEnabled = YES;
    BOOL pointerSafetyOK = !pointerSafetyDetector.pointerPrecisionEnabled;
    printf("unsafe pointer rewrite blocked: %s\n",
           pointerSafetyOK ? "OK" : "FAIL");
    printf("caller-context accessibility: %s\n",
           AXIsProcessTrusted() ? "granted" : "not granted");
    printf("caller-context post event access: %s\n",
           PostEventAccessIsGranted() ? "granted" : "not granted");
    printf("caller-context input monitoring: %s\n",
           InputMonitoringIsGranted() ? "granted" : "not granted");
    CFMachPortRef eventTap = CGEventTapCreate(kCGHIDEventTap,
                                              kCGTailAppendEventTap,
                                              kCGEventTapOptionListenOnly,
                                              CGEventMaskBit(kCGEventMouseMoved),
                                              selfTestEventTapCallback,
                                              NULL);
    printf("caller-context mouse event tap: %s\n",
           eventTap != NULL ? "OK" : "not available");
    if (eventTap != NULL) {
        CFMachPortInvalidate(eventTap);
        CFRelease(eventTap);
    }
    dlclose(framework);
    return clickModeMatrixOK && pointerCurveOK && pointerSafetyOK &&
           eventTap != NULL ? 0 : 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--self-test") == 0) {
            return RunSelfTest();
        }

        if (!AcquireSingleInstanceLock()) {
            NSLog(@"MagicTapClick: another instance is already running; exiting");
            return 0;
        }

        NSApplication *application = [NSApplication sharedApplication];
        AppDelegate *delegate = [AppDelegate new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
