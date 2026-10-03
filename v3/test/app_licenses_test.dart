import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leeplayer/app_licenses.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bundled package and native licenses are complete and registered',
    () async {
      await ensureAppLicensesRegistered();
      final entry = await LicenseRegistry.licenses.firstWhere(
        (candidate) => candidate.packages.contains('media_kit 原生播放组件'),
      );
      final text = entry.paragraphs
          .map((paragraph) => paragraph.text)
          .join('\n');
      final bundledCopy = await rootBundle.loadString(
        'assets/legal/LIQUID_GLASS_WIDGETS_LICENSE.txt',
      );

      expect(text, contains('libmpv'));
      expect(text, contains('FFmpeg'));
      expect(text, isNot(contains('【发布前必须替换为实际 HTTPS 地址】')));

      final sourceEntry = await LicenseRegistry.licenses.firstWhere(
        (candidate) => candidate.packages.contains('原生组件对应源码清单'),
      );
      final sourceText = sourceEntry.paragraphs.map((p) => p.text).join('\n');
      expect(sourceText, contains('ffmpeg-6.0.tar.xz'));
      expect(sourceText, contains('57be87c22d9b49c112b6d24bc67d4250'));
      expect(sourceText, contains('不包含雷player 应用源码'));

      final relinkingEntry = await LicenseRegistry.licenses.firstWhere(
        (candidate) => candidate.packages.contains('iOS 原生组件重新构建与替换说明'),
      );
      final relinkingText = relinkingEntry.paragraphs
          .map((p) => p.text)
          .join('\n');
      expect(
        relinkingText,
        contains('flutter build ios --release --no-codesign'),
      );
      expect(relinkingText, contains('不能证明 LGPLv3 §4(d)(1)'));
      expect(relinkingText, contains('不能替代 §4(d)(0)'));
      expect(bundledCopy, contains('MIT License'));
      expect(
        bundledCopy,
        contains('Copyright (c) 2024–2026 Sebastian Degenaar'),
      );
      expect(
        bundledCopy,
        contains(
          'The above copyright notice and this permission notice shall be included',
        ),
      );
      expect(bundledCopy, contains('THE SOFTWARE IS PROVIDED "AS IS"'));
    },
  );
}
