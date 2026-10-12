import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leeplayer/app_licenses.dart';
import 'package:leeplayer/media_kit_subtitle_fonts.dart';

class _FontBundle extends CachingAssetBundle {
  _FontBundle(this.data);

  final ByteData data;
  int reads = 0;
  Future<ByteData> Function(int read)? onLoad;

  @override
  Future<ByteData> load(String key) async {
    expect(key, MediaKitSubtitleFonts.asset);
    reads++;
    return onLoad == null ? data : await onLoad!(reads);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ByteData font;
  late Directory cache;
  late _FontBundle bundle;
  late MediaKitSubtitleFonts fonts;

  setUpAll(() async {
    font = await rootBundle.load(MediaKitSubtitleFonts.asset);
  });

  setUp(() async {
    cache = await Directory.systemTemp.createTemp('subtitle-font-test-');
    bundle = _FontBundle(font);
    fonts = MediaKitSubtitleFonts(bundle: bundle, cacheRoot: cache);
  });

  tearDown(() async {
    if (await cache.exists()) await cache.delete(recursive: true);
  });

  test(
    'actual font asset is bundled and its OFL license is registered',
    () async {
      expect(font.lengthInBytes, MediaKitSubtitleFonts.fontByteLength);
      expect(font.buffer.asUint8List(font.offsetInBytes, 4), [79, 84, 84, 79]);
      final license = await rootBundle.loadString(
        'assets/legal/licenses/NotoSansCJK-OFL.txt',
      );
      expect(license, contains('SIL OPEN FONT LICENSE Version 1.1'));
      await ensureAppLicensesRegistered();
      final entry = await LicenseRegistry.licenses.firstWhere(
        (entry) => entry.packages.contains('Noto Sans CJK SC 2.004'),
      );
      expect(
        entry.paragraphs.map((paragraph) => paragraph.text).join('\n'),
        contains('SIL OPEN FONT LICENSE Version 1.1'),
      );
    },
  );

  test(
    'prepares a readable native directory with the exact font bytes',
    () async {
      final directory = await fonts.prepare();
      final file = File('${directory.path}/${MediaKitSubtitleFonts.fileName}');
      expect(directory.isAbsolute, isTrue);
      expect(await file.exists(), isTrue);
      expect(
        await file.readAsBytes(),
        font.buffer.asUint8List(font.offsetInBytes, font.lengthInBytes),
      );
      expect((await directory.list().toList()).length, 1);
      final parentEntries = await directory.parent.list().toList();
      expect(parentEntries.map((entry) => entry.path), [directory.path]);
    },
  );

  test('reuses a valid file and coalesces concurrent preparations', () async {
    final first = fonts.prepare();
    final second = fonts.prepare();
    expect(identical(first, second), isTrue);
    final directory = await first;
    expect((await second).path, directory.path);
    expect((await fonts.prepare()).path, directory.path);
    expect(bundle.reads, 1);
  });

  test(
    'repairs a truncated cached font instead of returning its path',
    () async {
      final directory = await fonts.prepare();
      final file = File('${directory.path}/${MediaKitSubtitleFonts.fileName}');
      await file.writeAsBytes([79, 84, 84, 79]);
      expect((await fonts.prepare()).path, directory.path);
      expect(await file.length(), MediaKitSubtitleFonts.fontByteLength);
      expect(bundle.reads, 2);
    },
  );

  test('repairs an invalid cached OTF header', () async {
    final directory = await fonts.prepare();
    final file = File('${directory.path}/${MediaKitSubtitleFonts.fileName}');
    final invalid = await file.readAsBytes();
    invalid.fillRange(0, 4, 0);
    await file.writeAsBytes(invalid);
    expect(await file.length(), MediaKitSubtitleFonts.fontByteLength);
    await fonts.prepare();
    final repaired = await file.open();
    expect(await repaired.read(4), [79, 84, 84, 79]);
    await repaired.close();
    expect(bundle.reads, 2);
  });

  test(
    'recreates the font after the OS evicts its temporary directory',
    () async {
      final directory = await fonts.prepare();
      await directory.delete(recursive: true);
      expect((await fonts.prepare()).path, directory.path);
      expect(await directory.exists(), isTrue);
      expect(bundle.reads, 2);
    },
  );

  test('a failed asset read does not poison later playback sessions', () async {
    bundle.onLoad = (read) async {
      if (read == 1) throw StateError('temporary asset failure');
      return font;
    };
    await expectLater(fonts.prepare(), throwsStateError);
    expect(await (await fonts.prepare()).exists(), isTrue);
    expect(bundle.reads, 2);
  });

  test('rejects an invalid asset without installing a partial font', () async {
    bundle.onLoad = (read) async => read == 1 ? ByteData(4) : font;
    await expectLater(fonts.prepare(), throwsFormatException);
    expect(await cache.list().toList(), isEmpty);
    expect(await (await fonts.prepare()).exists(), isTrue);
  });

  test('a hanging load times out and the next preparation can retry', () async {
    final stalled = Completer<ByteData>();
    bundle.onLoad = (read) => read == 1 ? stalled.future : Future.value(font);
    fonts = MediaKitSubtitleFonts(
      bundle: bundle,
      cacheRoot: cache,
      preparationTimeout: const Duration(milliseconds: 200),
    );
    await expectLater(fonts.prepare(), throwsA(isA<TimeoutException>()));
    expect(await (await fonts.prepare()).exists(), isTrue);
    expect(bundle.reads, 2);
    stalled.completeError(StateError('late failure after timeout'));
    await Future<void>.delayed(Duration.zero);
  });

  test('independent preparations converge on a complete font', () async {
    final other = MediaKitSubtitleFonts(bundle: bundle, cacheRoot: cache);
    final results = await Future.wait([fonts.prepare(), other.prepare()]);
    expect(results[0].path, results[1].path);
    final file = File('${results[0].path}/${MediaKitSubtitleFonts.fileName}');
    expect(await file.length(), MediaKitSubtitleFonts.fontByteLength);
    expect((await results[0].parent.list().toList()).length, 1);
  });
}
