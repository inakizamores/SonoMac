#!/bin/zsh
# Builds SonoMac.app (arm64 release). Use --install to copy to /Applications and launch.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/SonoMac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SonoMac "$APP/Contents/MacOS/SonoMac"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP" 2>/dev/null

echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x SonoMac 2>/dev/null || true
    sleep 0.4
    rm -rf /Applications/SonoMac.app
    cp -R "$APP" /Applications/SonoMac.app
    open /Applications/SonoMac.app
    echo "Installed to /Applications/SonoMac.app and launched"
fi
