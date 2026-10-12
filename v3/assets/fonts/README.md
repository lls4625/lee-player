# libass subtitle fallback

`NotoSansCJKsc-Regular.otf` is the unmodified, single Regular weight from the
official Noto Sans CJK **Sans2.004** release. It is the full CJK face, not the
SC regional subset: Simplified Chinese, Traditional Chinese, Japanese kana
and Latin subtitles share this one face (SC glyph forms are the default).
This adds 16,437,364 bytes (15.68 MiB) before application-package compression.
No other weights or font collections are bundled.

- Source: https://github.com/notofonts/noto-cjk/tree/Sans2.004
- File: https://raw.githubusercontent.com/notofonts/noto-cjk/Sans2.004/Sans/OTF/SimplifiedChinese/NotoSansCJKsc-Regular.otf
- SHA-256: `2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b`
- License: SIL Open Font License 1.1, copied unmodified from
  https://raw.githubusercontent.com/notofonts/noto-cjk/Sans2.004/LICENSE
  to `../legal/licenses/NotoSansCJK-OFL.txt` and registered in the app's
  open-source-license screen.

The OTF is a Flutter **asset**, not a Flutter `fontFamily`. Before media is
opened, `MediaKitSubtitleFonts` atomically copies it to a versioned, readable
temporary directory and mpv receives that directory as `sub-fonts-dir`.
`sub-font=Noto Sans CJK SC` supplies the plain-text subtitle default. This does
not force `sub-ass-override`, disable embedded fonts, or change encoding.
The helper checks the copied file's size/header and retries after errors or
cache eviction; `python3 tool/verify_subtitle_font.py` verifies the source
asset SHA-256 and representative language coverage using fontTools.

This covers the bundled font's Unicode repertoire, not every Unicode glyph.
Font/cmap and Linux libass checks do not prove iOS or the user's original MKV
playback; those still need the actual device and media.
