#!/usr/bin/env python3
"""Generate the SwiftPM manifest from the exact immutable release artifact."""
import argparse
import subprocess
from pathlib import Path
import zipfile
root = Path(__file__).resolve().parents[1]
version = (root / 'VERSION').read_text().strip()
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--archive', type=Path, help='Exact newly built XCFramework ZIP; defaults to dist for this VERSION')
args = parser.parse_args()
archive = (args.archive or root / 'dist' / f'OfflineTool-{version}.xcframework.zip').resolve()
with zipfile.ZipFile(archive) as package:
    assert 'OfflineTool.xcframework/Info.plist' in package.namelist()
checksum = subprocess.check_output(['swift', 'package', 'compute-checksum', str(archive)], text=True).strip()
manifest = f'''// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "OfflineTool",
    platforms: [.iOS(.v15)],
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
