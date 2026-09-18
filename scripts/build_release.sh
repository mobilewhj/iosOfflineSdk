#!/bin/bash
set -euo pipefail
sdk_root="$(cd "$(dirname "$0")/.." && pwd)"
sdk_version="$(cat "$sdk_root/VERSION")"
sdk_work="$sdk_root/build/release-$sdk_version"
sdk_package="$sdk_root/dist/SLCOfflineSDK-$sdk_version"
if [[ -e "$sdk_package" || -e "$sdk_package.zip" ]]; then
  echo "Release output exists: $sdk_package. Move it aside or update VERSION before rebuilding." >&2
  exit 1
fi
mkdir -p "$sdk_work" "$sdk_package"
for sdk_platform in device simulator; do
  sdk_destination='generic/platform=iOS'
  if [[ "$sdk_platform" == simulator ]]; then sdk_destination='generic/platform=iOS Simulator'; fi
  xcodebuild archive -project "$sdk_root/SLCOfflineSDK.xcodeproj" -scheme SLCOfflineSDK \
    -configuration Release -destination "$sdk_destination" \
    -archivePath "$sdk_work/$sdk_platform.xcarchive" -derivedDataPath "$sdk_work/$sdk_platform-build" \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES SKIP_INSTALL=NO CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION="$sdk_version" > "$sdk_work/$sdk_platform.log" 2>&1 || {
      tail -60 "$sdk_work/$sdk_platform.log"; exit 1;
    }
done
xcodebuild -create-xcframework \
  -framework "$sdk_work/device.xcarchive/Products/Library/Frameworks/SLCOfflineSDK.framework" \
  -framework "$sdk_work/simulator.xcarchive/Products/Library/Frameworks/SLCOfflineSDK.framework" \
  -output "$sdk_package/SLCOfflineSDK.xcframework"
cp "$sdk_root/LICENSE" "$sdk_root/THIRD_PARTY_NOTICES.md" "$sdk_root/README.md" "$sdk_root/VERSION" "$sdk_package/"
cp -R "$sdk_root/docs" "$sdk_package/docs"
mkdir -p "$sdk_package/Licenses"
cp "$sdk_root/Vendor/ZIPFoundation/LICENSE" "$sdk_package/Licenses/ZIPFoundation-LICENSE.txt"
ditto -c -k --keepParent "$sdk_package" "$sdk_package.zip"
(cd "$sdk_root/dist" && shasum -a 256 "SLCOfflineSDK-$sdk_version.zip" > "SLCOfflineSDK-$sdk_version.zip.sha256")
echo "Local release: $sdk_package.zip"
