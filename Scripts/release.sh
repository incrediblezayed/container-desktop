#!/bin/zsh
# Builds an ad-hoc signed Release of Container Desktop and zips it for a GitHub release.
# usage: Scripts/release.sh   ->  build/Container-Desktop-<version>.zip (+ .sha256)
set -euo pipefail
cd "${0:A:h}/.."

rm -rf build/dd
xcodebuild -project ContainerDesktop.xcodeproj -scheme ContainerDesktop -configuration Release \
  -derivedDataPath build/dd -destination 'platform=macOS,arch=arm64' build -quiet

APP="build/dd/Build/Products/Release/Container Desktop.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
codesign --verify --deep --strict "$APP"

ZIP="build/Container-Desktop-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd build && shasum -a 256 "${ZIP:t}" > "${ZIP:t}.sha256")
echo "$ZIP"
cat "$ZIP.sha256"
