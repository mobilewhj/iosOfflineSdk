#!/usr/bin/env python3
"""Build a deterministic, synthetic local package for the managed file URL smoke run."""
from pathlib import Path
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED

root = Path(__file__).resolve().parents[1]
source = root / 'Demo/FileProbeWeb'
output = root / 'Demo/Resources/file-probe.zip'
output.parent.mkdir(parents=True, exist_ok=True)
with ZipFile(output, 'w') as archive:
    for path in sorted(source.rglob('*')):
        if path.is_file():
            info = ZipInfo(path.relative_to(source).as_posix(), date_time=(2026, 1, 1, 0, 0, 0))
            info.compress_type = ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, path.read_bytes())
print(output)
