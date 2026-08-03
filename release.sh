#!/bin/zsh
# Builds release artifacts: dist/SonoMac.dmg and dist/SonoMac.zip
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

mkdir -p dist
rm -f dist/SonoMac.dmg dist/SonoMac.zip

ditto -c -k --keepParent build/SonoMac.app dist/SonoMac.zip

STAGE=$(mktemp -d)
cp -R build/SonoMac.app "$STAGE/SonoMac.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "SonoMac" -srcfolder "$STAGE" -ov -format UDZO -quiet dist/SonoMac.dmg
rm -rf "$STAGE"

echo "Release artifacts ready:"
du -h dist/SonoMac.dmg dist/SonoMac.zip
