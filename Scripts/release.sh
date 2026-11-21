#!/bin/zsh
# Builds a Container Desktop release zip for GitHub.
#
#   TEAM_ID=<team> Scripts/release.sh   Developer ID signed, notarized and stapled.
#                                       Xcode must be signed in to that team's account; it
#                                       creates the Developer ID certificate if needed and
#                                       submits to the notary service with the same login.
#   Scripts/release.sh                  Ad-hoc signed (macOS will ask users to allow it).
#
# Output: build/Container-Desktop-<version>.zip and .sha256
set -euo pipefail
cd "${0:A:h}/.."

OUT=build/release
rm -rf "$OUT"
mkdir -p "$OUT"

if [[ -n "${TEAM_ID:-}" ]]; then
  xcodebuild archive -project ContainerDesktop.xcodeproj -scheme ContainerDesktop -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$OUT/ContainerDesktop.xcarchive" \
    DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates -quiet

  cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>upload</string>
</dict></plist>
PLIST
  echo "Submitting for notarization…"
  xcodebuild -exportArchive -archivePath "$OUT/ContainerDesktop.xcarchive" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/upload" -allowProvisioningUpdates -quiet

  # Apple usually answers within a minute or two; give up after 30.
  for attempt in {1..120}; do
    if xcodebuild -exportNotarizedApp -archivePath "$OUT/ContainerDesktop.xcarchive" \
         -exportPath "$OUT/app" -allowProvisioningUpdates >"$OUT/notarize.log" 2>&1; then
      break
    fi
    if ! grep -q "not ready for distribution" "$OUT/notarize.log"; then
      cat "$OUT/notarize.log" >&2
      exit 1
    fi
    (( attempt == 120 )) && { echo "Notarization did not finish in 30 minutes" >&2; exit 1; }
    sleep 15
  done
  APP="$OUT/app/Container Desktop.app"
  xcrun stapler validate "$APP"
  spctl --assess --type exec "$APP"
else
  xcodebuild -project ContainerDesktop.xcodeproj -scheme ContainerDesktop -configuration Release \
    -derivedDataPath build/dd -destination 'platform=macOS,arch=arm64' build -quiet
  APP="build/dd/Build/Products/Release/Container Desktop.app"
fi

codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="build/Container-Desktop-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd build && shasum -a 256 "${ZIP:t}" > "${ZIP:t}.sha256")
echo "$ZIP"
cat "$ZIP.sha256"
