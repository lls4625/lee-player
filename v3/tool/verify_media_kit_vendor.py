#!/usr/bin/env python3
"""Verify the checked-in 1.2.6 baseline and the bounded additive patch."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
vendor = root / 'third_party/media_kit'
baseline = json.loads((vendor / 'UPSTREAM_FILE_HASHES.json').read_text())
modified = {
    'analysis_options.yaml',
    'pubspec.yaml',
    'lib/src/player/native/player/real.dart',
    'lib/src/player/native/player/stub.dart',
}
added = {
    'LOCAL_PATCH.md', 'UPSTREAM_FILE_HASHES.json', 'UPSTREAM_API_HASHES.json',
    'UPSTREAM_PUBSPEC.yaml',
    'lib/src/player/native/utils/async_property_error.dart',
    'lib/src/player/native/utils/async_property_requests.dart',
}
errors = []
for path, expected in baseline.items():
    file = vendor / path
    if not file.is_file():
        errors.append(f'Missing upstream file: {path}')
    elif path not in modified and hashlib.sha256(file.read_bytes()).hexdigest() != expected:
        errors.append(f'Unexpected change: {path}')
for file in vendor.rglob('*'):
    if file.is_file():
        path = str(file.relative_to(vendor))
        if path not in baseline and path not in added:
            errors.append(f'Unexpected added file: {path}')

source = (vendor / 'lib/src/player/native/player/real.dart').read_text()
for marker, expected in json.loads((vendor / 'UPSTREAM_API_HASHES.json').read_text()).items():
    start = source.index(marker)
    end = source.index('\n  }\n', start) + len('\n  }\n')
    if hashlib.sha256(source[start:end].encode()).hexdigest() != expected:
        errors.append(f'Existing API changed: {marker.strip()}')

if 'version: 1.2.6\n' not in (vendor / 'pubspec.yaml').read_text():
    errors.append('Unexpected package version')
if hashlib.sha256((vendor / 'UPSTREAM_PUBSPEC.yaml').read_bytes()).hexdigest() != baseline['pubspec.yaml']:
    errors.append('Original upstream pubspec was changed')
if (vendor / 'pubspec.yaml').read_text() != (vendor / 'UPSTREAM_PUBSPEC.yaml').read_text().replace('sdk: ">=3.1.0 <4.0.0"', 'sdk: ">=3.10.0 <4.0.0"'):
    errors.append('Unexpected local pubspec edit beyond SDK minimum correction')
if errors:
    raise SystemExit('\n'.join(errors))
print(f'Verified {len(baseline)} upstream files; exactly {len(modified)} permitted '
      f'upstream edits and {len(added)} additions; ABI/LICENSE and legacy APIs intact.')
