#!/usr/bin/env python3
"""Verify the exact 2.0.1 package and its single render-order correction."""
from pathlib import Path
import hashlib
import json
root = Path(__file__).resolve().parents[1]
vendor = root / 'third_party/media_kit_video'
baseline = json.loads((vendor / 'UPSTREAM_FILE_HASHES.json').read_text())
changed = 'lib/src/video_controller/native_video_controller/real.dart'
added = {'UPSTREAM_FILE_HASHES.json', 'LOCAL_PATCH.md'}
errors = []
for name, expected in baseline.items():
    path = vendor / name
    if not path.is_file():
        errors.append(f'Missing upstream file: {name}')
    elif name != changed and hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        errors.append(f'Unexpected upstream change: {name}')
for path in vendor.rglob('*'):
    if path.is_file() and str(path.relative_to(vendor)) not in baseline.keys() | added:
        errors.append(f'Unexpected file: {path}')
source = (vendor / changed).read_text()
start = source.index('    // A loaded audio-only player')
end = source.index("    await controller.setProperty('vid', 'auto');\n", start) + len("    await controller.setProperty('vid', 'auto');\n\n")
original = source[:start] + source[end:]
original = original.replace("        'hwdec': configuration.hwdec!,\n", "        'hwdec': configuration.hwdec!,\n        'vid': 'auto',\n", 1)
if hashlib.sha256(original.encode()).hexdigest() != baseline[changed]:
    errors.append('Patch contains changes beyond delayed vid=auto')
if errors:
    raise SystemExit('\n'.join(errors))
print(f'PASS: {len(baseline)} upstream files verified; only vid=auto ordering changed; native renderer/API/LICENSE unchanged.')
