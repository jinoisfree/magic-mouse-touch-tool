#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
APP_DIR="$ROOT_DIR/build/MagicTapClick.app"
INSTALL_APP_DIR="${MAGIC_TAP_CLICK_INSTALL_PATH:-/Users/jinoisfree/Applications/MagicTapClick.app}"
STAGING_DIR="$(mktemp -d /private/tmp/magic-tap-click-build.XXXXXX)"
STAGING_APP="$STAGING_DIR/MagicTapClick.app"
CONTENTS_DIR="$STAGING_APP/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
EXECUTABLE="$MACOS_DIR/MagicTapClick"
SIGNING_IDENTITY="${MAGIC_TAP_CLICK_SIGNING_IDENTITY:-MagicTapClick Local Development}"
SIGNING_KEYCHAIN="${MAGIC_TAP_CLICK_SIGNING_KEYCHAIN:-/Users/jinoisfree/Library/Keychains/login.keychain-db}"
BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ROOT_DIR/Info.plist")"

SIGNING_CERT_HASH="$(
    /usr/bin/security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" |
    /usr/bin/awk -v identity="$SIGNING_IDENTITY" \
        'index($0, "\"" identity "\"") { print $2; exit }'
)"
if [[ -z "$SIGNING_CERT_HASH" ]]; then
    echo "Missing stable code-signing identity: $SIGNING_IDENTITY" >&2
    echo "Run $ROOT_DIR/setup-signing.sh once, or set MAGIC_TAP_CLICK_SIGNING_IDENTITY to another installed identity." >&2
    exit 1
fi
SIGNING_REQUIREMENT="designated => identifier \"$BUNDLE_IDENTIFIER\" and certificate root = H\"$SIGNING_CERT_HASH\""
NORMALIZED_SIGNING_REQUIREMENT="$(print -r -- "$SIGNING_REQUIREMENT" | tr '[:upper:]' '[:lower:]')"

if [[ -d "$INSTALL_APP_DIR" ]]; then
    EXISTING_REQUIREMENT="$(codesign -d -r- "$INSTALL_APP_DIR" 2>&1 | sed -n '/^designated => /p' | head -1)"
    NORMALIZED_EXISTING_REQUIREMENT="$(print -r -- "$EXISTING_REQUIREMENT" | tr '[:upper:]' '[:lower:]')"
    if [[ "$NORMALIZED_EXISTING_REQUIREMENT" != "$NORMALIZED_SIGNING_REQUIREMENT" ]]; then
        echo "Refusing update because the installed app has a different signing identity." >&2
        echo "Installed: $EXISTING_REQUIREMENT" >&2
        echo "Expected:  $SIGNING_REQUIREMENT" >&2
        exit 1
    fi
fi

trap 'rm -rf "$STAGING_DIR"' EXIT

mkdir -p "$MACOS_DIR"

clang \
  -fobjc-arc \
  -fblocks \
  -O2 \
  -Wno-deprecated-declarations \
  -isysroot "$SDK_PATH" \
  -mmacosx-version-min=13.0 \
  "$ROOT_DIR/Sources/main.m" \
  -framework Cocoa \
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework IOKit \
  -framework QuartzCore \
  -ldl \
  -o "$EXECUTABLE"

install -m 644 "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
codesign --force --sign "$SIGNING_IDENTITY" --keychain "$SIGNING_KEYCHAIN" \
  -r="$SIGNING_REQUIREMENT" --timestamp=none "$STAGING_APP" >/dev/null
codesign --verify --deep --strict "$STAGING_APP"

mkdir -p "$ROOT_DIR/build"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/_CodeSignature"
install -m 755 "$STAGING_APP/Contents/MacOS/MagicTapClick" "$APP_DIR/Contents/MacOS/MagicTapClick"
install -m 644 "$STAGING_APP/Contents/Info.plist" "$APP_DIR/Contents/Info.plist"
install -m 644 "$STAGING_APP/Contents/_CodeSignature/CodeResources" "$APP_DIR/Contents/_CodeSignature/CodeResources"
xattr -cr "$APP_DIR"
for attempt in {1..20}; do
    xattr -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
    if codesign --verify --deep --strict "$APP_DIR" >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done
codesign --verify --deep --strict "$APP_DIR"

mkdir -p "$(dirname "$INSTALL_APP_DIR")"
/usr/bin/ditto --norsrc "$APP_DIR" "$INSTALL_APP_DIR"
xattr -cr "$INSTALL_APP_DIR"
codesign --verify --deep --strict "$INSTALL_APP_DIR"

SERVICE_TARGET="gui/$(/usr/bin/id -u)/com.jino.magic-tap-click"
if /bin/launchctl print "$SERVICE_TARGET" >/dev/null 2>&1; then
    /bin/launchctl kickstart -k "$SERVICE_TARGET"
    echo "Restarted: $SERVICE_TARGET"
fi

echo "Built: $APP_DIR"
echo "Installed: $INSTALL_APP_DIR"
