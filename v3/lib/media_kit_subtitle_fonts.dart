import 'dart:io';

import 'package:flutter/services.dart';

/// A real, readable font directory for libass, independent of Flutter fonts.
///
/// media_kit's bundled-font setting is Android-only. On iOS, prepare this
/// directory and set mpv's `sub-fonts-dir` before opening the media. `sub-font`
/// may use [family] for plain-text subtitles; ASS styles and embedded fonts
/// must remain enabled so their original typography can still take priority.
class MediaKitSubtitleFonts {
  MediaKitSubtitleFonts({
    AssetBundle? bundle,
    Directory? cacheRoot,
    this.preparationTimeout = const Duration(seconds: 3),
  }) : _bundle = bundle ?? rootBundle,
       _cacheRoot = cacheRoot ?? Directory.systemTemp;

  static const asset = 'assets/fonts/NotoSansCJKsc-Regular.otf';
  static const family = 'Noto Sans CJK SC';
  static const fileName = 'NotoSansCJKsc-Regular.otf';
  static const fontByteLength = 16437364;
  static const sha256 =
      '2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b';
  static const _directoryName = 'noto-cjk-sc-2.004-2c76254f6fc379fd';
  static const _otfHeader = [0x4f, 0x54, 0x54, 0x4f]; // OTTO

  final AssetBundle _bundle;
  final Directory _cacheRoot;
  final Duration preparationTimeout;
  Future<Directory>? _pending;

  /// Coalesces concurrent preparation but never caches a failed/timed-out
  /// Future. Rechecks the file on every open because iOS may evict temp files.
  /// Errors are reported to the caller, which should log and continue playback.
  Future<Directory> prepare() => _pending ??= _prepare()
      .timeout(preparationTimeout)
      .whenComplete(() => _pending = null);

  Future<Directory> _prepare() async {
    final parent = Directory(
      '${_cacheRoot.path}${Platform.pathSeparator}leeplayer-subtitle-fonts',
    );
    final directory = Directory(
      '${parent.path}${Platform.pathSeparator}$_directoryName',
    );
    if (await _isReadableFont(directory)) return directory;

    final data = await _bundle.load(asset);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    if (bytes.length != fontByteLength || !_hasOtfHeader(bytes)) {
      throw const FormatException('Bundled libass fallback font is invalid');
    }
    await parent.create(recursive: true);
    // Stage outside the directory libass scans. Only a complete, flushed file
    // becomes visible to another playback session through the final rename.
    final staging = await parent.createTemp('.staging-');
    try {
      final stagedFont = File(
        '${staging.path}${Platform.pathSeparator}$fileName',
      );
      await stagedFont.writeAsBytes(bytes, flush: true);
      if (await _isReadableFont(directory)) return directory;
      await directory.create(recursive: true);
      // Replacing the file is atomic on iOS/POSIX, including when independent
      // instances or a timed-out attempt finish concurrently. Do not remove a
      // destination directory another session may already be using.
      await stagedFont.rename(
        '${directory.path}${Platform.pathSeparator}$fileName',
      );
      if (!await _isReadableFont(directory)) {
        throw const FileSystemException('Libass fallback font is not readable');
      }
      return directory;
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }

  Future<bool> _isReadableFont(Directory directory) async {
    final file = File('${directory.path}${Platform.pathSeparator}$fileName');
    try {
      if (await file.length() != fontByteLength) return false;
      final handle = await file.open();
      try {
        return _hasOtfHeader(await handle.read(_otfHeader.length));
      } finally {
        await handle.close();
      }
    } on FileSystemException {
      return false;
    }
  }

  static bool _hasOtfHeader(List<int> bytes) =>
      bytes.length >= _otfHeader.length &&
      bytes[0] == _otfHeader[0] &&
      bytes[1] == _otfHeader[1] &&
      bytes[2] == _otfHeader[2] &&
      bytes[3] == _otfHeader[3];
}
