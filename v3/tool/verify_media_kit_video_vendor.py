#!/usr/bin/env python3
"""Verify the exact 2.0.1 package and its scoped render-order / PiP foreground corrections."""
from pathlib import Path
import hashlib
import json
root = Path(__file__).resolve().parents[1]
vendor = root / 'third_party/media_kit_video'
baseline = json.loads((vendor / 'UPSTREAM_FILE_HASHES.json').read_text())
# The repository already contains these exact mpv build inputs in HEAD;
# upstream package hashes do not include generated CocoaPods headers/cache.
# Verify their bytes too, rather than ignoring entire generated directories.
packaged_inputs = {
    "common/darwin/.cache/headers/mpv-v0.36.0.tar.gz": "29abc44f8ebee013bb2f9fe14d80b30db19b534c679056e4851ceadf5a5e8bf6",
    "common/darwin/.cache/headers/mpv.tar.gz": "f76bcc9c2245cdaf9b5a34f51667e63942439702d2ea71ee0dfb82fa7bec3799",
    "ios/Headers/mpv/client.h": "287181025de368777fa30f6f636c1915e77cc551ffe132993528f08ff4a64ae4",
    "ios/Headers/mpv/render.h": "0a93aa38bd3994f96860c1d68adafeba87c97b174456d13ec0b18a855180bd19",
    "ios/Headers/mpv/render_gl.h": "7bb28b46420b7c85247ac316cec5e2146469418f03d4c78d7b268beeeb9882f2",
    "ios/Headers/mpv/stream_cb.h": "5d835aedd37cf76c14b7bfdcf91741bdf5fe052623d1ae1253d8de09a7f9bc34"
}
baseline.update(packaged_inputs)
changed = 'lib/src/video_controller/native_video_controller/real.dart'
native_changed = 'ios/Classes/plugin/common/MediaKitVideoPlugin.swift'
added = {'UPSTREAM_FILE_HASHES.json', 'LOCAL_PATCH.md'}
errors = []
for name, expected in baseline.items():
    path = vendor / name
    if not path.is_file():
        errors.append(f'Missing upstream file: {name}')
    else:
        data = str(path.readlink()).encode() if path.is_symlink() and name in packaged_inputs else path.read_bytes()
        if name not in {changed, native_changed} and hashlib.sha256(data).hexdigest() != expected:
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
native = (vendor / native_changed).read_text()
native = native.replace('  import Flutter\n  import UIKit\n', '  import Flutter\n', 1)
begin = native.index('    // PiP restoration opts in;')
end = native.index('    let handleStr =', begin)
patch = native[begin:end]
assert 'args?["requireForeground"] as? Bool == true' in patch
assert 'UIApplication.shared.applicationState != .active' in patch
assert 'video_output_background' in patch
native = native[:begin] + native[end:]
if hashlib.sha256(native.encode()).hexdigest() != baseline[native_changed]:
    errors.append('Native patch contains changes beyond opt-in PiP foreground admission')
if errors:
    raise SystemExit('\n'.join(errors))
print(f'PASS: {len(baseline)} upstream files verified; vid=auto ordering and opt-in PiP foreground admission only; renderer/worker/disposal/LICENSE unchanged.')
