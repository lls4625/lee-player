#!/usr/bin/env python3
"""Verify the unmodified subtitle asset. Requires the fontTools QA package."""

import hashlib
from pathlib import Path

from fontTools.ttLib import TTFont


ROOT = Path(__file__).resolve().parents[1]
FONT = ROOT / "assets/fonts/NotoSansCJKsc-Regular.otf"
SHA256 = "2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b"
SAMPLES = {
    "simplified": "简体中文字幕恢复正常，拖动进度后继续播放。你好世界学习龙国汉语",
    "traditional": "繁體中文字幕恢復正常，拖動進度後繼續播放。你好世界學習龍國漢語臺灣香港",
    "japanese": "日本語の字幕：ひらがな・カタカナ・漢字。映画を再生します。",
    "english": "English subtitles: ABC xyz 0123456789!?.,()[]",
}

data = FONT.read_bytes()
assert len(data) == 16437364, "Unexpected font asset size"
assert hashlib.sha256(data).hexdigest() == SHA256, "Font SHA-256 mismatch"
font = TTFont(FONT)
names = font["name"]
assert names.getDebugName(1) == "Noto Sans CJK SC"
assert names.getDebugName(2) == "Regular"
assert names.getDebugName(5).startswith("Version 2.004;")
cmap = font.getBestCmap()
for language, text in SAMPLES.items():
    missing = sorted({f"U+{ord(char):04X}" for char in text if ord(char) not in cmap})
    assert not missing, f"{language} missing codepoints: {missing}"
    print(f"PASS {language}: {len(set(text))} distinct sample codepoints")
license_text = (ROOT / "assets/legal/licenses/NotoSansCJK-OFL.txt").read_text()
assert "SIL OPEN FONT LICENSE Version 1.1" in license_text
print(f"PASS SHA-256 {SHA256}")
print(f"PASS {len(data):,} bytes; {len(cmap):,} Unicode mappings; license present")
print("Scope: asset integrity/coverage only, not iOS or original-MKV playback.")
