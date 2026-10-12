import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leeplayer/app_localizations.dart';
import 'package:leeplayer/glass_ui.dart';
import 'package:leeplayer/playback_page.dart';
import 'package:leeplayer/player_model.dart';

// This is the production button/channel contract. The empty media_kit surface
// avoids a platform view; it does not emulate either engine or AVKit readiness.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('lei.player/methods');

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets('PiP readiness and repeated taps in $locale', (tester) async {
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = PlayerModel();
      final pending = Completer<Object?>();
      var pipCalls = 0;
      var state = <String, dynamic>{
        'path': 'Video.mp4', 'engine': 'media_kit', 'engineId': 'placeholder',
        'generation': 1, 'revision': 1, 'isAudio': false,
        'duration': 120.0, 'position': 4.0, 'playing': false, 'seekable': true,
        'pipAvailable': false, 'pipRequesting': false,
      };
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(methods, (call) async {
        if (call.method == 'pip') { pipCalls++; return pending.future; }
        if (call.method == 'state' || call.method == 'configure') return state;
        return null;
      });
      addTearDown(() {
        if (!pending.isCompleted) pending.complete(null);
        model.dispose();
        messenger.setMockMethodCallHandler(methods, null);
      });
      model.state = state;
      await tester.pumpWidget(MaterialApp(
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate, GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
        ],
        home: PlaybackPage(model: model),
      ));
      await tester.pumpAndSettle();
      final tooltip = find.byTooltip(AppLocalizations(locale).text('画中画'));
      Finder buttonFinder() => find.descendant(of: tooltip, matching: find.byType(GlassIconButton));
      GlassIconButton button() => tester.widget<GlassIconButton>(buttonFinder());
      Future<void> update(Map<String, dynamic> changes) async {
        state = {...state, ...changes, 'revision': (state['revision'] as int) + 1};
        await model.command('state', onValue: (value) {
          model.state = Map<String, dynamic>.from(value as Map);
        });
        await tester.pump();
      }

      expect(tooltip, findsOneWidget);
      expect(button().onPressed, isNull);
      expect(pipCalls, 0);
      // Readiness only enables the button. It never sends a request.
      await update({'pipAvailable': true});
      expect(button().onPressed, isNotNull);
      expect(pipCalls, 0);
      final tap = button().onPressed!;
      tap(); tap();
      await tester.pump();
      expect(pipCalls, 1);
      expect(button().onPressed, isNull);
      expect(find.descendant(of: tooltip, matching: find.byType(CircularProgressIndicator)), findsOneWidget);

      pending.complete(null);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 750));
      await tester.pump();
      expect(button().onPressed, isNotNull);
      await update({'pipRequesting': true});
      expect(button().onPressed, isNull);
      await update({'pipRequesting': false, 'pipAvailable': false});
      expect(button().onPressed, isNull);
      await update({'pipAvailable': true, 'presentationWaiting': true});
      expect(button().onPressed, isNull);
      // MKV uses the same availability contract and remains immediately usable.
      await update({'path': 'Video.mkv', 'presentationWaiting': false, 'pipAvailable': true});
      expect(button().onPressed, isNotNull);
      expect(pipCalls, 1);
      expect(model.message, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    test('prepared-manual build marker survives playback info in $locale', () {
      const marker = 'PiP diagnostics build=pip-placeholder-20261012-r5';
      final report = AppLocalizations(locale).playbackInfo({
        'engine': 'AVPlayer', 'lifecycleEvents': [marker, 'AVPiP prepared request=none'],
      });
      expect(report, contains(marker));
      expect(report, contains('AVPiP prepared request=none'));
    });
  }
}
