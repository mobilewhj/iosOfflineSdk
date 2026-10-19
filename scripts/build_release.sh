#!/bin/bash
set -euo pipefail
sdk_root="$(cd "$(dirname "$0")/.." && pwd)"
sdk_version="$(cat "$sdk_root/VERSION")"
sdk_work="${OFT_RELEASE_WORK_DIRECTORY:-$sdk_root/build/release-$sdk_version}"
sdk_dist="${OFT_RELEASE_OUTPUT_ROOT:-$sdk_root/dist}"
sdk_package="$sdk_dist/OfflineTool-$sdk_version"
if [[ -e "$sdk_work" || -e "$sdk_package" || -e "$sdk_package.zip" || -e "$sdk_dist/OfflineTool-$sdk_version.xcframework.zip" ]]; then
  echo "Release work/output exists. Preserve it and choose new OFT_RELEASE_WORK_DIRECTORY/OFT_RELEASE_OUTPUT_ROOT paths." >&2
  exit 1
fi
mkdir -p "$sdk_work" "$sdk_package"
for sdk_platform in device simulator; do
  sdk_destination='generic/platform=iOS'
  if [[ "$sdk_platform" == simulator ]]; then sdk_destination='generic/platform=iOS Simulator'; fi
  xcodebuild archive -project "$sdk_root/OfflineTool.xcodeproj" -scheme OfflineTool \
    -configuration Release -destination "$sdk_destination" \
    -archivePath "$sdk_work/$sdk_platform.xcarchive" -derivedDataPath "$sdk_work/$sdk_platform-build" \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES SKIP_INSTALL=NO CODE_SIGNING_ALLOWED=NO \
    MARKETING_VERSION="$sdk_version" > "$sdk_work/$sdk_platform.log" 2>&1 || {
      tail -60 "$sdk_work/$sdk_platform.log"; exit 1;
    }
  # Remove linker debug-map/AST object paths; keep runtime/exported symbols and the archive dSYM.
  xcrun strip -S "$sdk_work/$sdk_platform.xcarchive/Products/Library/Frameworks/OfflineTool.framework/OfflineTool" \
    > "$sdk_work/$sdk_platform-strip.log" 2>&1 || {
      cat "$sdk_work/$sdk_platform-strip.log"; exit 1;
    }
done
xcodebuild -create-xcframework \
  -framework "$sdk_work/device.xcarchive/Products/Library/Frameworks/OfflineTool.framework" \
  -framework "$sdk_work/simulator.xcarchive/Products/Library/Frameworks/OfflineTool.framework" \
  -output "$sdk_package/OfflineTool.xcframework"
# Check the produced framework, not just compiler settings. Keep diagnostics outside the package.
python3 - "$sdk_package/OfflineTool.xcframework" <<'CHECK_PATHS'
import plistlib,sys
from pathlib import Path
framework=Path(sys.argv[1])
for file in framework.rglob('*'):
    if not file.is_file(): continue
    data=file.read_bytes()
    if any(marker in data for marker in (b'/Users/', b'/private/var/', b'/var/folders/')):
        raise SystemExit('Unmapped private build path in '+str(file.relative_to(framework)))
    if b'OFTLocalCandidate' in data:
        raise SystemExit('Local candidate metadata in formal framework')
    if file.name == 'Info.plist':
        info=plistlib.loads(data)
        if any(key.startswith('OFTLocalCandidate') for key in info):
            raise SystemExit('Local candidate metadata in formal framework')
CHECK_PATHS
cp "$sdk_root/CHANGELOG.md" "$sdk_root/LICENSE" "$sdk_root/THIRD_PARTY_NOTICES.md" "$sdk_root/README.md" "$sdk_root/VERSION" "$sdk_package/"
mkdir -p "$sdk_package/docs"
# Only public root documents; historical private verification is never distributed.
for sdk_doc in "$sdk_root"/docs/*.md; do cp "$sdk_doc" "$sdk_package/docs/"; done
mkdir -p "$sdk_package/Licenses"
cp "$sdk_root/Vendor/ZIPFoundation/LICENSE" "$sdk_package/Licenses/ZIPFoundation-LICENSE.txt"
ditto -c -k --norsrc --noextattr --keepParent "$sdk_package" "$sdk_package.zip"
(cd "$sdk_dist" && shasum -a 256 "OfflineTool-$sdk_version.zip" > "OfflineTool-$sdk_version.zip.sha256")
# SwiftPM requires the XCFramework at the archive root.
sdk_spm_zip="$sdk_dist/OfflineTool-$sdk_version.xcframework.zip"
(cd "$sdk_package" && ditto -c -k --norsrc --noextattr --keepParent OfflineTool.xcframework "$sdk_spm_zip")
python3 "$sdk_root/scripts/generate_package.py" --archive "$sdk_spm_zip"
echo "Local release: $sdk_package.zip"
echo "SwiftPM artifact: $sdk_spm_zip"
