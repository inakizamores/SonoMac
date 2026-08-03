#!/bin/zsh
# Builds release artifacts: dist/SonoMac.dmg and dist/SonoMac.zip
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

mkdir -p dist
rm -f dist/SonoMac.dmg dist/SonoMac.zip

ditto -c -k --keepParent build/SonoMac.app dist/SonoMac.zip

# Styled installer window: background + Finder layout template (Support/dmg).
STAGE=$(mktemp -d)
cp -R build/SonoMac.app "$STAGE/SonoMac.app"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp Support/dmg/background.tiff "$STAGE/.background/background.tiff"
cp Support/dmg/DS_Store "$STAGE/.DS_Store"
hdiutil create -volname "SonoMac" -srcfolder "$STAGE" -ov -format UDZO -quiet dist/SonoMac.dmg
rm -rf "$STAGE"

echo "Release artifacts ready:"
du -h dist/SonoMac.dmg dist/SonoMac.zip
