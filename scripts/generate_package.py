#!/usr/bin/env python3
"""Generate the SwiftPM manifest from the exact immutable release artifact."""
import subprocess
from pathlib import Path
import zipfile
root = Path(__file__).resolve().parents[1]
version = (root / 'VERSION').read_text().strip()
archive = root / 'dist' / f'OfflineTool-{version}.xcframework.zip'
with zipfile.ZipFile(archive) as package:
    assert 'OfflineTool.xcframework/Info.plist' in package.namelist()
checksum = subprocess.check_output(['swift', 'package', 'compute-checksum', str(archive)], text=True).strip()
manifest = f'''// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "OfflineTool",
    platforms: [.iOS(.v12)],
    products: [.library(name: "OfflineTool", targets: ["OfflineTool"])],
    targets: [
        .binaryTarget(
            name: "OfflineTool",
            url: "https://github.com/mobilewhj/iosOfflineSdk/releases/download/v{version}/OfflineTool-{version}.xcframework.zip",
            checksum: "{checksum}"
        )
    ]
)
'''
(root / 'Package.swift').write_text(manifest)
(archive.parent / (archive.name + '.sha256')).write_text(checksum + '  ' + archive.name + '\n')
print('Generated Package.swift for ' + version + ': ' + checksum)
