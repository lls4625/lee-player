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
