import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const liquidGlassWidgetsLicenseAsset =
    'assets/legal/LIQUID_GLASS_WIDGETS_LICENSE.txt';

const _nativeLicenseAssets = <String, List<String>>{
  'assets/legal/licenses/media_kit-MIT.txt': ['media_kit 1.2.6'],
  'assets/legal/licenses/media_kit_video-MIT.txt': ['media_kit_video 2.0.1'],
  'assets/legal/licenses/media_kit_libs_video-LICENSE.txt': [
    'media_kit_libs_video 1.0.7',
  ],
  'assets/legal/licenses/mpv-Copyright.txt': ['mpv 0.36.0'],
  'assets/legal/licenses/mpv-LGPL-2.1.txt': ['mpv 0.36.0', 'GNU LGPL 2.1'],
  'assets/legal/licenses/FFmpeg-LGPL-3.0.txt': ['FFmpeg 6.0', 'GNU LGPL 3.0'],
  'assets/legal/licenses/FFmpeg-GPL-3.0.txt': [
    'FFmpeg 6.0',
    'GNU GPL 3.0 terms referenced by LGPL 3.0',
  ],
  'assets/legal/licenses/libass-ISC.txt': ['libass 0.17.1'],
  'assets/legal/licenses/FreeType-FTL.txt': ['FreeType 2.13.2'],
  'assets/legal/licenses/HarfBuzz-COPYING.txt': ['HarfBuzz 8.1.1'],
  'assets/legal/licenses/FriBidi-COPYING.txt': ['FriBidi 1.0.13'],
  'assets/legal/licenses/MbedTLS-Apache-2.0.txt': ['Mbed TLS 3.4.1'],
  'assets/legal/licenses/libxml2-Copyright.txt': ['libxml2 2.11.5'],
  'assets/legal/licenses/dav1d-COPYING.txt': ['dav1d 1.2.1'],
  'assets/legal/licenses/uchardet-COPYING.txt': ['uchardet 0.0.8'],
  'assets/legal/licenses/libpng-LICENSE.txt': ['libpng 1.6.40'],
};

Future<void>? _licenseCheck;

/// Keeps the in-app notice complete without duplicating the entry when the
/// Flutter-generated NOTICES bundle already contains this package.
Future<void> ensureAppLicensesRegistered() =>
    _licenseCheck ??= _ensureAppLicensesRegistered();

Future<void> _ensureAppLicensesRegistered() async {
  LicenseRegistry.addLicense(() async* {
    // Dart/Flutter package notices (including liquid_glass_widgets) are
    // supplied by Flutter's generated NOTICES bundle. Only native media
    // components need explicit registration here.
    final notices = await rootBundle.loadString(
      'assets/legal/NATIVE_THIRD_PARTY_NOTICES.txt',
    );
    yield LicenseEntryWithLineBreaks(const [
      'media_kit 原生播放组件',
      'libmpv',
      'FFmpeg',
    ], notices);
    final offer = await rootBundle.loadString(
      'assets/legal/OPEN_SOURCE_OFFER.txt',
    );
    yield LicenseEntryWithLineBreaks(const [
      'libmpv / FFmpeg 对应源码与重新链接说明',
    ], offer);
    for (final entry in _nativeLicenseAssets.entries) {
      final text = await rootBundle.loadString(entry.key);
      yield LicenseEntryWithLineBreaks(entry.value, text);
    }
  });
}
