#!/bin/zsh
set -euo pipefail

SOURCE_DIR="${0:A:h}"
BUILD_DIR="$SOURCE_DIR/build/beta"
APP="$BUILD_DIR/Reminders Sync Beta.app"
PYTHON_BIN="${BRIDGE_BUILD_PYTHON:-$(command -v python3)}"
REMINDCTL_BIN="${BRIDGE_REMINDCTL:-$(command -v remindctl || true)}"
VENV="$SOURCE_DIR/build/beta-build-venv"

if ! "$PYTHON_BIN" -c 'import sys; raise SystemExit(sys.version_info < (3, 10))'; then
  echo "Python 3.10+ é necessário para criar a beta. Defina BRIDGE_BUILD_PYTHON."
  exit 1
fi
if [[ ! -x "$REMINDCTL_BIN" ]]; then
  echo "remindctl não encontrado. Defina BRIDGE_REMINDCTL para o executável."
  exit 1
fi

if [[ ! -x "$VENV/bin/pyinstaller" ]]; then
  "$PYTHON_BIN" -m venv "$VENV"
fi
"$VENV/bin/python" -m pip install --quiet --disable-pip-version-check -r "$SOURCE_DIR/requirements.txt" pyinstaller

mkdir -p "$BUILD_DIR"
"$VENV/bin/pyinstaller" --noconfirm --clean --onefile \
  --name RemindersSyncBridge \
  --distpath "$BUILD_DIR/engine" \
  --workpath "$SOURCE_DIR/build/beta-pyinstaller-work" \
  --specpath "$SOURCE_DIR/build" \
  "$SOURCE_DIR/bridge.py" >/dev/null

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -parse-as-library -O \
  -framework SwiftUI -framework AppKit -framework EventKit -framework ServiceManagement \
  "$SOURCE_DIR/macos/BetaApp.swift" -o "$APP/Contents/MacOS/RemindersSyncBeta"
install -m 755 "$BUILD_DIR/engine/RemindersSyncBridge" "$APP/Contents/Resources/RemindersSyncBridge"
install -m 755 "$REMINDCTL_BIN" "$APP/Contents/Resources/remindctl"
install -m 644 "$SOURCE_DIR/macos/RemindctlLicense.txt" "$APP/Contents/Resources/RemindctlLicense.txt"
install -m 644 "$SOURCE_DIR/macos/BetaInfo.plist" "$APP/Contents/Info.plist"

ICONSET="$BUILD_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
xcrun swift "$SOURCE_DIR/macos/MakeIcon.swift" "$BUILD_DIR/AppIcon-1024.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$BUILD_DIR/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$BUILD_DIR/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP/Contents/Resources/RemindersSyncBridge" >/dev/null
codesign --force --sign - "$APP/Contents/Resources/remindctl" >/dev/null
codesign --force --deep --sign - "$APP" >/dev/null
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist"

ARCH=$(uname -m)
ditto -c -k --keepParent "$APP" "$BUILD_DIR/RemindersSyncBeta-macOS-$ARCH.zip"
echo "Beta criada em: $APP"
echo "Arquivo para download: $BUILD_DIR/RemindersSyncBeta-macOS-$ARCH.zip"
echo "Nenhuma credencial ou token foi incluído."
