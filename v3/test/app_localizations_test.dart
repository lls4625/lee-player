import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:leeplayer/app_localizations.dart';
import 'package:leeplayer/player_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('system locale resolution', () {
    test('recognizes Chinese scripts and regions', () {
      expect(
        AppLocalizations.resolve([const Locale('zh', 'TW')], const []),
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      );
      expect(
        AppLocalizations.resolve(
          [const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans')],
          const [],
        ),
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
      );
      expect(
        AppLocalizations.resolve([const Locale('zh', 'CN')], const []),
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
      );
    });

    test('uses the first supported preferred language and falls back to English', () {
      expect(
        AppLocalizations.resolve(
          [const Locale('fr'), const Locale('ja')],
          const [],
        ),
        const Locale('ja'),
      );
      expect(
        AppLocalizations.resolve([const Locale('fr')], const []),
        const Locale('en'),
      );
    });
  });

  test('language preference values round-trip and unknown values follow system', () {
    for (final mode in AppLanguageMode.values) {
      expect(AppLanguageModeValue.parse(mode.value), mode);
    }
    expect(AppLanguageModeValue.parse(null), AppLanguageMode.system);
    expect(AppLanguageModeValue.parse('fr'), AppLanguageMode.system);
  });

  test('app name and home title remain unchanged in every language', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final strings = AppLocalizations(locale);
      expect(strings.text('雷player'), '雷player');
      expect(strings.text('雷 player'), '雷 player');
    }
  });

  test('core labels are available in all four languages', () {
    expect(AppLocalizations(const Locale('en')).text('设置'), 'Settings');
    expect(AppLocalizations(const Locale('ja')).text('设置'), '設定');
    expect(
      AppLocalizations(
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      ).text('设置'),
      '設定',
    );
    expect(
      AppLocalizations(
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
      ).text('设置'),
      '设置',
    );
  });

  test('manual language selection persists and a new model reloads it', () async {
    const channel = MethodChannel('lei.player/methods');
    var stored = 'system';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'language') return stored;
          if (call.method == 'setLanguage') {
            stored = (call.arguments as Map)['value'] as String;
            return stored;
          }
          return null;
        });
    final first = PlayerModel();
    expect(await first.setLanguage(AppLanguageMode.ja), isTrue);
    expect(stored, 'ja');
    first.dispose();

    final restarted = PlayerModel();
    expect(await restarted.loadLanguage(), isTrue);
    expect(restarted.languageMode, AppLanguageMode.ja);
    restarted.state = {'path': 'course/lesson.mp4', 'position': 123.0};
    expect(await restarted.setLanguage(AppLanguageMode.system), isTrue);
    expect(stored, 'system');
    expect(restarted.path, 'course/lesson.mp4');
    expect(restarted.position, 123.0);
    restarted.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}
