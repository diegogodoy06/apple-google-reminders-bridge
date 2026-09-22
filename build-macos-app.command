#!/bin/zsh
set -euo pipefail

SOURCE_DIR="${0:A:h}"
APP_NAME="Ponte de Lembretes"
EXECUTABLE_NAME="PonteDeLembretes"
BUILD_DIR="${BRIDGE_APP_BUILD_DIR:-$SOURCE_DIR/build/macos}"
INSTALL_ROOT="${BRIDGE_APP_INSTALL_ROOT:-$HOME/Applications}"
APP_PATH="$INSTALL_ROOT/$APP_NAME.app"
STAGING_APP="$BUILD_DIR/$APP_NAME.app"
ICONSET="$BUILD_DIR/AppIcon.iconset"

rm -rf "$STAGING_APP" "$ICONSET"
mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources" "$ICONSET" "$INSTALL_ROOT"

xcrun swiftc \
  -swift-version 5 \
  -parse-as-library \
  -O \
  -framework SwiftUI \
  -framework AppKit \
  "$SOURCE_DIR/macos/PonteLembretesApp.swift" \
  -o "$STAGING_APP/Contents/MacOS/$EXECUTABLE_NAME"

xcrun swift "$SOURCE_DIR/macos/MakeIcon.swift" "$BUILD_DIR/AppIcon-1024.png"
sips -z 16 16 "$BUILD_DIR/AppIcon-1024.png" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$BUILD_DIR/AppIcon-1024.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$BUILD_DIR/AppIcon-1024.png" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$BUILD_DIR/AppIcon-1024.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$BUILD_DIR/AppIcon-1024.png" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$BUILD_DIR/AppIcon-1024.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$BUILD_DIR/AppIcon-1024.png" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$BUILD_DIR/AppIcon-1024.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$BUILD_DIR/AppIcon-1024.png" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$BUILD_DIR/AppIcon-1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$STAGING_APP/Contents/Resources/AppIcon.icns"
install -m 644 "$SOURCE_DIR/macos/Info.plist" "$STAGING_APP/Contents/Info.plist"
codesign --force --deep --sign - "$STAGING_APP" >/dev/null

pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
rm -rf "$APP_PATH"
ditto "$STAGING_APP" "$APP_PATH"
touch "$APP_PATH"
open "$APP_PATH"

echo "Aplicativo instalado em: $APP_PATH"
