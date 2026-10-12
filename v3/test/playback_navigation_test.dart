import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leeplayer/app_localizations.dart';
import 'package:leeplayer/library_page.dart';
import 'package:leeplayer/playback_page.dart';
import 'package:leeplayer/player_model.dart';

// Exercise the production widgets and PlayerModel against the native channel
// contract. No media player/plugin or successful decoding is simulated here.
class _NativePlayback {
  static const methods = MethodChannel('lei.player/methods');
  static const events = MethodChannel('lei.player/events');
  static const tips = MethodChannel('lei.player/developer_tip');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  final pending = <String, Completer<Object?>>{};
  Map<String, Object> state = {};
  String? restoreToken;
  bool waitForPresentation = false;
  int generation = 0;

  void install() {
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      if (call.method == 'playerDismissed') restoreToken = null;
      if (pending.containsKey(call.method)) return pending[call.method]!.future;
      switch (call.method) {
        case 'pipRestoreAllowed':
          return restoreToken != null &&
              (call.arguments as Map)['restoreToken'] == restoreToken;
        case 'pipRestored':
          restoreToken = null;
          return null;
        case 'state':
        case 'configure':
          return state;
        case 'appearance':
          return 'dark';
        case 'language':
          return 'zh-Hans';
        case 'libraryPreferences':
          return {'layout': 'list', 'sort': 'name', 'ascending': true};
        case 'scan':
          return [
            for (final name in ['Broken.mp4', 'Next.mp4'])
              {'path': name, 'name': name, 'parent': '', 'kind': 'video',
               'size': 2048, 'modified': 1.0},
          ];
        case 'records':
          return <String, Object>{};
        case 'play':
        case 'pause':
          final playing = call.method == 'play';
          state = {...state, 'revision': (state['revision'] as int? ?? 0) + 1,
            'playing': playing, 'wantsPlayback': playing, 'loading': false,
            'interrupted': false, 'audioRecovery': 'idle', 'error': ''};
          return state;
        case 'open':
          final args = call.arguments as Map;
          final paths = (args['paths'] as List).cast<String>();
          final index = args['index'] as int;
          state = {
            'path': paths[index], 'queue': paths, 'index': index,
            'generation': ++generation, 'revision': 1,
            'engine': 'media_kit', 'engineId': 'test-$generation',
            'error': !waitForPresentation && paths[index] == 'Broken.mp4'
                ? 'media_playback_failed' : '',
            'playing': !waitForPresentation && paths[index] != 'Broken.mp4',
            'loading': false, 'presentationWaiting': waitForPresentation,
            'position': 0.0, 'duration': 120.0, 'seekable': !waitForPresentation,
            'background': true, 'rememberProgress': true,
          };
          // Deliberately send no player event: the command reply is sufficient.
          return state;
        case 'playbackInfo':
          return {'engine': 'AVPlayer', 'durationSeconds': 120, 'seekable': false,
            'errorCode': state['error'] ?? '',
            'technicalDetail': 'Native test failure detail'};
        default:
          return null;
      }
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(tips, (_) async => {
      'revision': 1, 'canPay': false, 'products': <Object>[],
    });
  }

  Future<void> emitState(Map<String, Object> value) async {
    await messenger.handlePlatformMessage(events.name,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'type': 'player', 'state': value,
      }), (_) {});
  }

  Future<void> emitRestore(String? token) async {
    await messenger.handlePlatformMessage(events.name,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'type': 'openPlayer', if (token != null) 'restoreToken': token,
      }), (_) {});
  }

  void dispose() {
    for (final completer in pending.values) {
      if (!completer.isCompleted) completer.complete(null);
    }
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(events, null);
    messenger.setMockMethodCallHandler(tips, null);
  }
}

Future<({PlayerModel model, _NativePlayback native})> _mountLibrary(
    WidgetTester tester, {Locale locale = const Locale('en')}) async {
  tester.view.physicalSize = const Size(430, 932);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final native = _NativePlayback()..install();
  final model = PlayerModel();
  addTearDown(() { model.dispose(); native.dispose(); });
  await tester.pumpWidget(MaterialApp(
    locale: locale,
    supportedLocales: AppLocalizations.supportedLocales,
    localizationsDelegates: const [
      AppLocalizations.delegate, GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
    ],
    home: LibraryPage(model: model),
  ));
  await tester.pumpAndSettle();
  return (model: model, native: native);
}

Future<void> _openBroken(WidgetTester tester) async {
  await tester.tap(find.text('Broken.mp4').last);
  await tester.pumpAndSettle();
  expect(find.byType(PlaybackPage), findsOneWidget);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets('error does not block Back then another file in $locale', (tester) async {
      final (:model, :native) = await _mountLibrary(tester, locale: locale);
      final strings = AppLocalizations(locale);
      await _openBroken(tester);
      final failedState = Map<String, Object>.from(native.state);
      expect(model.state['error'], 'media_playback_failed');
      expect(find.text('暂时无法播放'), findsNothing);
      expect(find.text('重试播放'), findsNothing);
      expect(find.byIcon(Icons.error_outline_rounded), findsNothing);
      expect(find.byTooltip(strings.text('返回课程库')).hitTestable(), findsOneWidget);
      expect(find.byTooltip(strings.text('播放队列')).hitTestable(), findsOneWidget);

      // Returning is independent of a native cleanup/brightness reply.
      native.pending['playerDismissed'] = Completer<Object?>();
      await tester.tap(find.byTooltip(strings.text('返回课程库')));
      await tester.pumpAndSettle();
      expect(find.byType(PlaybackPage), findsNothing);
      expect(native.pending['playerDismissed']!.isCompleted, isFalse);
      expect(native.calls.where((c) => c.method == 'pause'), isEmpty);

      await tester.tap(find.text('Next.mp4').last);
      await tester.pumpAndSettle();
      expect(find.byType(PlaybackPage), findsOneWidget);
      expect(model.path, 'Next.mp4');
      expect(model.state['error'], isEmpty);
      expect(model.playing, isTrue);

      // A delayed old failure must not repaint/replace the selected session.
      await native.emitState(failedState);
      await tester.pump();
      expect(model.path, 'Next.mp4');
      expect(model.state['error'], isEmpty);
      native.pending['playerDismissed']!.complete(null);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('error leaves queue selectable and applies its native open reply', (tester) async {
    final (:model, :native) = await _mountLibrary(tester);
    await _openBroken(tester);
    final failedState = Map<String, Object>.from(native.state);
    await tester.tap(find.byTooltip(AppLocalizations(const Locale('en')).text('播放队列')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next.mp4'));
    await tester.pumpAndSettle();
    expect(model.path, 'Next.mp4');
    expect(model.state['error'], isEmpty);
    expect(model.playing, isTrue);
    expect(find.byType(PlaybackPage), findsOneWidget);
    expect(native.calls.where((c) => c.method == 'open').length, 2);
    expect(native.calls.lastWhere((c) => c.method == 'open').arguments, {
      'paths': ['Broken.mp4', 'Next.mp4'], 'index': 1, 'resume': true,
    });
    await native.emitState(failedState);
    await tester.pump();
    expect(model.path, 'Next.mp4');
    expect(model.state['error'], isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  for (final exhausted in [false, true]) {
    for (final fromLibrary in [false, true]) {
      testWidgets('${exhausted ? 'exhausted recovery' : 'interruption'} first Play '
          'from ${fromLibrary ? 'mini-player' : 'playback'} sends play, not pause', (tester) async {
        final (:model, :native) = await _mountLibrary(tester);
        final strings = AppLocalizations(const Locale('en'));
        await tester.tap(find.text('Next.mp4').last);
        await tester.pumpAndSettle();
        native.state = {...native.state, 'revision': 2,
          'playing': false, 'loading': false, 'wantsPlayback': true,
          'interrupted': !exhausted, 'audioRecovery': exhausted ? 'exhausted' : 'idle',
          'error': exhausted ? 'media_playback_failed' : ''};
        await native.emitState(native.state);
        await tester.pumpAndSettle();
        expect(find.byTooltip(strings.text('播放')), findsOneWidget);
        if (fromLibrary) {
          await tester.tap(find.byTooltip(strings.text('返回课程库')));
          await tester.pumpAndSettle();
          await tester.tap(find.text(strings.text('继续播放')));
        } else {
          await tester.tap(find.byTooltip(strings.text('播放')));
        }
        await tester.pumpAndSettle();
        expect(native.calls.where((c) => c.method == 'play' || c.method == 'pause')
            .map((c) => c.method), ['play']);
        expect(model.playing, isTrue);
        expect(model.state['interrupted'], isFalse);
        expect(model.state['audioRecovery'], 'idle');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }
  }

  for (final loading in [false, true]) {
    testWidgets('${loading ? 'loading' : 'pending automatic recovery'} button cancels with pause', (tester) async {
      final (:model, :native) = await _mountLibrary(tester);
      final strings = AppLocalizations(const Locale('en'));
      await tester.tap(find.text('Next.mp4').last);
      await tester.pumpAndSettle();
      native.state = {...native.state, 'revision': 2, 'playing': false,
        'loading': loading, 'wantsPlayback': !loading, 'interrupted': false,
        'audioRecovery': loading ? 'idle' : 'pending'};
      await native.emitState(native.state);
      await tester.pump();
      final action = strings.text(loading ? '取消加载' : '暂停');
      expect(find.byTooltip(action), findsOneWidget);
      await tester.tap(find.byTooltip(action));
      await tester.pumpAndSettle();
      expect(native.calls.where((c) => c.method == 'play' || c.method == 'pause')
          .map((c) => c.method), ['pause']);
      expect(model.state['wantsPlayback'], isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  testWidgets('pending toggle updates its icon and a second click cancels Play', (tester) async {
    final (:model, :native) = await _mountLibrary(tester);
    final strings = AppLocalizations(const Locale('en'));
    await _openBroken(tester);
    final starting = Completer<Object?>();
    native.pending['play'] = starting;
    await tester.tap(find.byTooltip(strings.text('播放')));
    await tester.pump();
    expect(find.byTooltip(strings.text('暂停')), findsOneWidget);
    await tester.tap(find.byTooltip(strings.text('暂停')));
    await tester.pump();
    expect(find.byTooltip(strings.text('播放')), findsOneWidget);
    starting.complete({...native.state, 'revision': 2, 'playing': true,
      'wantsPlayback': true, 'loading': false, 'error': ''});
    await tester.pumpAndSettle();
    expect(native.calls.where((c) => c.method == 'play' || c.method == 'pause')
        .map((c) => c.method), ['play', 'pause']);
    expect(model.playing, isFalse);
    expect(find.byTooltip(strings.text('播放')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('late PiP restoration cannot reopen playback after Back', (tester) async {
    final (:model, :native) = await _mountLibrary(tester);
    final strings = AppLocalizations(const Locale('en'));
    await _openBroken(tester);
    native.restoreToken = 'old-restore';
    final checking = Completer<Object?>();
    native.pending['pipRestoreAllowed'] = checking;
    await native.emitRestore('old-restore');
    await tester.pump();
    await tester.tap(find.byTooltip(strings.text('返回课程库')));
    await tester.pumpAndSettle();
    expect(find.byType(PlaybackPage), findsNothing);
    // An already-issued native read can complete true after the user leaves.
    checking.complete(true);
    await tester.pumpAndSettle();
    expect(find.byType(PlaybackPage), findsNothing);
    native.pending.remove('pipRestoreAllowed');
    await native.emitRestore('old-restore');
    await native.emitRestore(null);
    await tester.pumpAndSettle();
    expect(find.byType(PlaybackPage), findsNothing);
    expect(native.calls.where((c) => c.method == 'playerDismissed'), hasLength(1));
    expect(native.calls.where((c) => c.method == 'pause'), isEmpty);
    expect(model.path, 'Broken.mp4');
    await tester.tap(find.text('Next.mp4').last);
    await tester.pumpAndSettle();
    expect(model.path, 'Next.mp4');
    expect(model.playing, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('current manual PiP restoration still opens and acknowledges once', (tester) async {
    final (:model, :native) = await _mountLibrary(tester);
    final strings = AppLocalizations(const Locale('en'));
    await tester.tap(find.text('Next.mp4').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(strings.text('返回课程库')));
    await tester.pumpAndSettle();
    expect(model.playing, isTrue);
    native.restoreToken = 'current-restore';
    await native.emitRestore('current-restore');
    await tester.pumpAndSettle();
    expect(find.byType(PlaybackPage), findsOneWidget);
    expect(model.playing, isTrue);
    expect(native.calls.where((c) => c.method == 'pipRestored' &&
        c.arguments is Map && (c.arguments as Map)['restoreToken'] == 'current-restore'),
        hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets('presentation wait exposes only Pause and preserves other gates in $locale', (tester) async {
      final (:model, :native) = await _mountLibrary(tester, locale: locale);
      final strings = AppLocalizations(locale);
      await tester.tap(find.text('Next.mp4').last);
      await tester.pumpAndSettle();
      native.state = {...native.state, 'revision': 2,
        'presentationWaiting': true, 'playing': false, 'loading': false,
        // A deferred new-media load may hide its autoplay in a separate native
        // request. The first button action must still cancel, never send Play.
        'wantsPlayback': false, 'seekable': false, 'error': ''};
      await native.emitState(native.state);
      await tester.pumpAndSettle();
      expect(find.text(strings.text('正在等待画中画结束')), findsOneWidget);
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      for (var tap = 0; tap < 2; tap++) {
        await tester.tap(find.byTooltip(strings.text('暂停')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip(strings.text('画中画')));
      await tester.tap(find.byTooltip(strings.text('后退 {seconds} 秒', args: {'seconds': 15})));
      await tester.tap(find.byTooltip(strings.text('前进 {seconds} 秒', args: {'seconds': 15})));
      await tester.pumpAndSettle();
      expect(native.calls.where((c) => const {'play', 'pause', 'pip', 'seek', 'previewSeek'}
          .contains(c.method)).map((c) => c.method), ['pause', 'pause']);
      expect(model.state['wantsPlayback'], isFalse);
      native.state = {...native.state, 'revision': 5,
        'presentationWaiting': false, 'seekable': true};
      await native.emitState(native.state);
      await tester.pumpAndSettle();
      expect(model.playing, isFalse);
      expect(find.byTooltip(strings.text('播放')), findsOneWidget);
      expect(native.calls.where((c) => c.method == 'play'), isEmpty);
      // Once ownership is ready, only a fresh explicit tap may start playback.
      await tester.tap(find.byTooltip(strings.text('播放')));
      await tester.pumpAndSettle();
      expect(native.calls.where((c) => c.method == 'play'), hasLength(1));
      expect(model.playing, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  testWidgets('shared-output wait stays visible and allows Back and a new selection', (tester) async {
    final (:model, :native) = await _mountLibrary(tester);
    final strings = AppLocalizations(const Locale('en'));
    await tester.tap(find.text('Next.mp4').last);
    await tester.pumpAndSettle();
    native.state = {...native.state, 'revision': 2,
      'presentationWaiting': true, 'playing': false, 'loading': false,
      'seekable': false, 'error': ''};
    await native.emitState(native.state);
    await tester.pumpAndSettle();
    expect(find.text(strings.text('正在等待画中画结束')), findsOneWidget);
    expect(model.presentationWaiting, isTrue);
    expect(model.playing, isFalse);
    await tester.tap(find.byTooltip(strings.text('暂停')));
    await tester.pump();
    expect(native.calls.where((c) => c.method == 'pause'), hasLength(1));
    expect(native.calls.where((c) => c.method == 'play'), isEmpty);
    await tester.tap(find.byTooltip(strings.text('返回课程库')));
    await tester.pumpAndSettle();
    expect(find.byType(PlaybackPage), findsNothing);
    expect(model.presentationWaiting, isTrue);
    native.waitForPresentation = true;
    await tester.tap(find.text('Broken.mp4').last);
    await tester.pumpAndSettle();
    expect(model.path, 'Broken.mp4');
    expect(model.presentationWaiting, isTrue);
    expect(model.playing, isFalse);
    expect(find.byType(PlaybackPage), findsOneWidget);
    expect(native.calls.where((c) => c.method == 'open'), hasLength(2));
    await native.emitState({...native.state, 'revision': 2,
      'presentationWaiting': false, 'error': 'media_playback_failed'});
    await tester.pumpAndSettle();
    expect(model.path, 'Broken.mp4');
    expect(model.presentationWaiting, isFalse);
    expect(find.text(strings.message(const AppMessage('media_playback_failed'))), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('error does not replace the normal hidden-controls and unlock exit', (tester) async {
    final (:model, :native) = await _mountLibrary(tester);
    await tester.tap(find.text('Next.mp4').last);
    await tester.pumpAndSettle();
    final strings = AppLocalizations(const Locale('en'));
    await tester.tap(find.byTooltip(strings.text('锁定控件')));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    await native.emitState({...native.state, 'revision': 2,
      'error': 'media_playback_failed', 'playing': false});
    await tester.pumpAndSettle();
    expect(model.state['error'], 'media_playback_failed');
    // The user's explicit lock remains in effect; the usual unlock path works.
    final popScope = find.byWidgetPredicate((widget) => widget is PopScope);
    expect(tester.widget<PopScope>(popScope).canPop, isFalse);
    await tester.tapAt(const Offset(215, 350));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(strings.text('解锁控件')));
    await tester.pumpAndSettle();
    expect(tester.widget<PopScope>(popScope).canPop, isTrue);
    await tester.tap(find.byTooltip(strings.text('隐藏控件')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(215, 350));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(strings.text('返回课程库')));
    await tester.pumpAndSettle();
    expect(find.byType(PlaybackPage), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('real failure remains available in the existing playback information', (tester) async {
    final (:model, :native) = await _mountLibrary(tester);
    final strings = AppLocalizations(const Locale('en'));
    await _openBroken(tester);
    expect(find.text(strings.message(const AppMessage('media_playback_failed'))), findsOneWidget);
    await tester.tap(find.byTooltip(strings.text('更多播放选项')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text(strings.text('播放信息')), 240);
    await tester.tap(find.text(strings.text('播放信息')));
    await tester.pumpAndSettle();
    expect(native.calls.where((c) => c.method == 'playbackInfo'), hasLength(1));
    expect(find.textContaining('media_playback_failed'), findsNothing);
    expect(find.textContaining('Native test failure detail'), findsOneWidget);
    expect(model.state['error'], 'media_playback_failed');
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(strings.text('返回课程库')));
    await tester.pumpAndSettle();
    expect(find.byType(PlaybackPage), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
