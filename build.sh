#!/usr/bin/env bash
# Build NotchHub.app with Command Line Tools only (no Xcode).
#   ./build.sh            build + assemble + ad-hoc sign into ./dist
#   ./build.sh --install  also copy to ~/Applications and (re)launch it
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="NotchHub"
APP="dist/${APP_NAME}.app"

echo "==> swift build -c release"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> assembling ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> codesign (ad-hoc)"
codesign --force --sign - "$APP"
codesign --verify "$APP"
echo "built: $APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
    pkill -x "$APP_NAME" 2>/dev/null || true
    # v2 replaces v1: quit the old NotchPomodoro so two panels never overlap (it is not deleted).
    pkill -x NotchPomodoro 2>/dev/null || true
    sleep 0.5
    rm -rf "$DEST/${APP_NAME}.app"
    cp -R "$APP" "$DEST/"
    open "$DEST/${APP_NAME}.app"
    echo "installed and launched: $DEST/${APP_NAME}.app"
fi
