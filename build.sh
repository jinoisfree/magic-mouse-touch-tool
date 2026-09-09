#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
APP_DIR="$ROOT_DIR/build/MagicTapClick.app"
STAGING_DIR="$(mktemp -d /private/tmp/magic-tap-click-build.XXXXXX)"
STAGING_APP="$STAGING_DIR/MagicTapClick.app"
CONTENTS_DIR="$STAGING_APP/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
EXECUTABLE="$MACOS_DIR/MagicTapClick"

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
codesign --force --sign - --timestamp=none "$STAGING_APP" >/dev/null
codesign --verify --deep --strict "$STAGING_APP"

mkdir -p "$ROOT_DIR/build"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/_CodeSignature"
install -m 755 "$STAGING_APP/Contents/MacOS/MagicTapClick" "$APP_DIR/Contents/MacOS/MagicTapClick"
install -m 644 "$STAGING_APP/Contents/Info.plist" "$APP_DIR/Contents/Info.plist"
install -m 644 "$STAGING_APP/Contents/_CodeSignature/CodeResources" "$APP_DIR/Contents/_CodeSignature/CodeResources"
xattr -cr "$APP_DIR"
codesign --force --sign - --timestamp=none "$APP_DIR" >/dev/null
xattr -cr "$APP_DIR"

echo "Built: $APP_DIR"
