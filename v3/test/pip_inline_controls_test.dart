import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leeplayer/app_localizations.dart';
import 'package:leeplayer/glass_ui.dart';
import 'package:leeplayer/playback_page.dart';
import 'package:leeplayer/player_model.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

// These are Flutter interaction/channel regressions, not AVKit integration or
// decoder tests. Both production surface widgets stay mounted: UIKit creation
// is acknowledged by a channel mock, and Video gets a no-output controller.
// Actual iOS PiP chrome, frames and restoration still need an Apple SDK/device.
class _NoOutputPlayer extends PlatformPlayer {
  _NoOutputPlayer() : super(configuration: const PlayerConfiguration());
}

class _NoOutputVideoController extends Fake implements VideoController {
  _NoOutputVideoController(this.player);

  @override
  final Player player;
  @override
  final notifier = ValueNotifier<PlatformVideoController?>(null);
}

class _PlaybackHarness {
  _PlaybackHarness(this.tester, this.locale, this.engine);

  static const methods = MethodChannel('lei.player/methods');
  static const libraryKey = Key('pip-test-library');
  final WidgetTester tester;
  final Locale locale;
  final String engine;
  final model = PlayerModel();
  final navigator = GlobalKey<NavigatorState>();
  final calls = <MethodCall>[];
  final platformCalls = <MethodCall>[];
  _NoOutputVideoController? controller;
  late Map<String, dynamic> state;

  AppLocalizations get strings => AppLocalizations(locale);
  Finder tooltip(String source, [Map<String, Object>? args]) =>
      find.byTooltip(strings.text(source, args: args ?? const {}));
  Finder get back => tooltip('返回课程库');
  Finder get rewind => tooltip('后退 {seconds} 秒', {'seconds': 15});
  Finder get forward => tooltip('前进 {seconds} 秒', {'seconds': 15});
  Finder get surface => find.byType(engine == 'AVPlayer' ? UiKitView : Video);
  Rect get bounds => tester.getRect(find.byType(PlaybackPage));
  Offset get leftGesturePoint =>
      Offset(bounds.left + bounds.width * .25, bounds.top + bounds.height * .4);
  Offset get rightGesturePoint =>
      Offset(bounds.left + bounds.width * .75, bounds.top + bounds.height * .4);

  Iterable<MethodCall> named(String name) =>
      calls.where((call) => call.method == name);
  Iterable<MethodCall> configured(String key) => named('configure').where(
      (call) => (call.arguments as Map).containsKey(key));

  Future<void> mount() async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    state = {
      'path': engine == 'AVPlayer' ? 'Lesson.mp4' : 'Lesson.mkv',
      'queue': [engine == 'AVPlayer' ? 'Lesson.mp4' : 'Lesson.mkv'],
      'index': 0,
      'engine': engine,
      'engineId': 'inline-test',
      'generation': 1,
      'revision': 1,
      'isAudio': false,
      'duration': 180.0,
      'position': 60.0,
      'playing': false,
      'seekable': true,
      'pipAvailable': true,
      'pipRequesting': false,
      'pipActive': false,
      'volume': .5,
      'brightness': .5,
    };
    model.state = state;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'state':
          return state;
        case 'configure':
          state = {
            ...state,
            ...Map<String, dynamic>.from(call.arguments as Map),
            'revision': (state['revision'] as int) + 1,
          };
          return state;
        case 'play':
        case 'pause':
          state = {
            ...state,
            'playing': call.method == 'play',
            'revision': (state['revision'] as int) + 1,
          };
          return state;
        case 'seek':
          return true;
        default:
          return null;
      }
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (call) async {
      platformCalls.add(call);
      if (call.method == 'create') {
        expect((call.arguments as Map)['viewType'], 'lei.player/video');
      }
      return null;
    });
    if (engine == 'media_kit') {
      controller = _NoOutputVideoController(
          Player(platformPlayer: _NoOutputPlayer()));
      model.mediaKit.controller = controller;
      model.mediaKit.engineId = 'inline-test';
    }
    addTearDown(() async {
      model.dispose();
      await controller?.player.dispose();
      controller?.notifier.dispose();
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    });
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigator,
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const Scaffold(body: Center(child: Text('Library', key: libraryKey))),
    ));
    navigator.currentState!.push<void>(MaterialPageRoute<void>(
      builder: (_) => PlaybackPage(model: model),
    ));
    await tester.pumpAndSettle();
    expect(surface, findsOneWidget);
    expect(back.hitTestable(), findsOneWidget);
    if (engine == 'AVPlayer') {
      expect(platformCalls.where((call) => call.method == 'create'), hasLength(1));
    } else {
      expect(tester.widget<Video>(surface).controls, NoVideoControls);
      expect(tester.widget<Video>(surface).pauseUponEnteringBackgroundMode, isFalse);
    }
    calls.clear(); // Ignore the existing enter-player brightness application.
  }

  Future<void> update(Map<String, dynamic> changes) async {
    state = {...state, ...changes, 'revision': (state['revision'] as int) + 1};
    await model.command('state', onValue: (value) {
      model.state = Map<String, dynamic>.from(value as Map);
    });
    await tester.pump();
  }

  void expectSameSurface(State<StatefulWidget> original) {
    expect(surface, findsOneWidget);
    expect(tester.state(surface), same(original),
        reason: 'PiP must not replace the mounted $engine surface');
    expect(platformCalls.where((call) => call.method == 'dispose'), isEmpty);
    if (engine == 'AVPlayer') {
      expect(platformCalls.where((call) => call.method == 'create'), hasLength(1));
    }
  }

  Finder get sourcePointerGate =>
      find.byKey(const ValueKey('pip-source-pointer-gate'));

  Element get sourceStackElement {
    Element? result;
    tester.element(surface).visitAncestorElements((element) {
      if (element.widget is Stack) {
        result = element;
        return false;
      }
      return true;
    });
    expect(result, isNotNull);
    return result!;
  }

  bool sourceReceivesPointers(Offset point) {
    final sourceObjects = <RenderObject>{};
    void visit(RenderObject object) {
      sourceObjects.add(object);
      object.visitChildren(visit);
    }
    visit(tester.renderObject(surface));
    return tester.hitTestOnBinding(point).path.any(
        (entry) => sourceObjects.contains(entry.target));
  }

  void expectExposedNoninteractiveSource() {
    // Check the built production Stack and its actual paint-order children.
    // An extra full-screen layer would obscure AVKit's original inline
    // placeholder even if the source remains mounted. This fails on r4's
    // opaque cover; it is deliberately stronger than checking a removed key.
    final element = sourceStackElement;
    final stack = element.widget as Stack;
    expect(stack.children, hasLength(2),
        reason: 'PiP must expose the original source, with only Back above it');
    expect(sourcePointerGate, findsOneWidget);
    final gate = tester.widget<IgnorePointer>(sourcePointerGate);
    expect(stack.children.first, same(gate));
    expect(gate.ignoring, isTrue);
    expect(gate.child, isA<ColoredBox>());
    expect(tester.getRect(sourcePointerGate), tester.getRect(surface));
    final renderStack = element.renderObject! as RenderStack;
    final sourceLayer = renderStack.firstChild!;
    expect(sourceLayer, same(tester.renderObject(sourcePointerGate)));
    final backLayer = renderStack.childAfter(sourceLayer)!;
    expect(renderStack.childAfter(backLayer), isNull);
    final backBounds = backLayer.localToGlobal(Offset.zero) & backLayer.size;
    expect(backBounds, tester.getRect(back),
        reason: 'The only layer above the source must be the Back button');
    expect(backBounds.contains(leftGesturePoint), isFalse);
    expect(backBounds.contains(rightGesturePoint), isFalse);
    expect(sourceReceivesPointers(leftGesturePoint), isFalse);
    expect(sourceReceivesPointers(rightGesturePoint), isFalse);
  }

  void expectOnlyBack() {
    expectExposedNoninteractiveSource();
    expect(tester.widget<PopScope>(find.byWidgetPredicate((w) => w is PopScope)).canPop,
        isTrue, reason: 'PiP navigation must remain available even when locked');
    expect(back.hitTestable(), findsOneWidget);
    expect(find.byType(Tooltip), findsOneWidget);
    expect(find.byType(GlassSlider), findsNothing);
    expect(rewind, findsNothing);
    expect(forward, findsNothing);
    for (final label in [
      '播放', '暂停', '播放队列', '画中画', '横竖屏', '隐藏控件',
      '锁定控件', '解锁控件', '播放速度', 'A–B 片段复读', '更多播放选项',
    ]) {
      expect(tooltip(label), findsNothing, reason: '$label must not survive PiP');
    }
  }

  Future<void> doubleTap(Offset position) async {
    await tester.tapAt(position);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(position);
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> verticalGestures() async {
    for (final point in [leftGesturePoint, rightGesturePoint]) {
      await tester.dragFrom(point, const Offset(0, -140));
      await tester.pump(const Duration(milliseconds: 80));
    }
  }

  Future<void> expectInertGestures({List<Offset> formerButtons = const []}) async {
    calls.clear();
    final platformCallStart = platformCalls.length;
    for (final point in formerButtons) {
      await tester.tapAt(point);
      await tester.pump(const Duration(milliseconds: 350));
    }
    await doubleTap(leftGesturePoint);
    await doubleTap(rightGesturePoint);
    await verticalGestures();
    // A single tap must not revive the controls or a hidden unlock target.
    await tester.tapAt(leftGesturePoint);
    await tester.pump(const Duration(seconds: 3));
    expect(calls, isEmpty,
        reason: 'Hidden App hit targets must not send seek, transport or level commands');
    if (model.state['pipActive'] == true) {
      final subsequent = platformCalls.skip(platformCallStart);
      expect(subsequent.where((call) => call.method == 'acceptGesture'), isEmpty,
          reason: 'Active PiP must not accept touches for the native source');
      if (engine == 'AVPlayer') {
        // Flutter's RenderDarwinPlatformView global pointer route explicitly
        // rejects a native touch when IgnorePointer kept it out of hit testing.
        expect(subsequent.where((call) => call.method == 'rejectGesture'),
            isNotEmpty, reason: 'The still-mounted native source must reject touches');
      }
    }
  }

  Future<void> closeWithBack() async {
    calls.clear();
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(find.byType(PlaybackPage), findsNothing);
    expect(find.byKey(libraryKey), findsOneWidget);
    expect(named('playerDismissed'), hasLength(1));
    expect(named('pause'), isEmpty,
        reason: 'Returning must not pause native-owned PiP playback');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final locale in AppLocalizations.supportedLocales) {
    for (final engine in ['AVPlayer', 'media_kit']) {
      testWidgets('$locale $engine: active PiP removes App controls and hit targets, '
          'then restores normal interaction', (tester) async {
        final h = _PlaybackHarness(tester, locale, engine);
        await h.mount();
        final surfaceState = tester.state(h.surface);
        final oldButtons = [
          tester.getCenter(h.rewind),
          tester.getCenter(h.forward),
          tester.getCenter(h.tooltip('播放')),
          tester.getCenter(h.tooltip('锁定控件')),
          tester.getCenter(h.tooltip('画中画')),
          tester.getCenter(h.tooltip('播放队列')),
          tester.getCenter(h.tooltip('更多播放选项')),
        ];

        // Establish positive controls so missing gesture setup cannot make the
        // negative PiP assertions pass accidentally.
        await tester.tap(h.rewind);
        await tester.pumpAndSettle();
        await tester.tap(h.forward);
        await tester.pumpAndSettle();
        expect(h.named('seek').map((call) => (call.arguments as Map)['seconds']),
            [45.0, 75.0]);
        h.calls.clear();
        await h.doubleTap(h.leftGesturePoint);
        await h.doubleTap(h.rightGesturePoint);
        expect(h.named('seek').map((call) => (call.arguments as Map)['seconds']),
            [45.0, 75.0]);
        await h.verticalGestures();
        expect(h.configured('volume'), isNotEmpty);
        expect(h.configured('brightness'), isNotEmpty);
        await tester.tap(h.tooltip('播放'));
        await tester.pumpAndSettle();
        await tester.tap(h.tooltip('暂停'));
        await tester.pumpAndSettle();
        expect(h.named('play'), hasLength(1));
        expect(h.named('pause'), hasLength(1));

        await h.update({'pipActive': true});
        h.expectSameSurface(surfaceState);
        h.expectOnlyBack();
        await h.expectInertGestures(formerButtons: oldButtons);
        h.expectOnlyBack();
        h.expectSameSurface(surfaceState);

        await h.update({'pipActive': false});
        h.expectSameSurface(surfaceState);
        expect(h.rewind.hitTestable(), findsOneWidget);
        expect(h.forward.hitTestable(), findsOneWidget);
        expect(h.tooltip('锁定控件').hitTestable(), findsOneWidget);
        h.calls.clear();
        await h.doubleTap(h.leftGesturePoint);
        await h.doubleTap(h.rightGesturePoint);
        await h.verticalGestures();
        expect(h.named('seek').map((call) => (call.arguments as Map)['seconds']),
            [45.0, 75.0]);
        expect(h.configured('volume'), isNotEmpty);
        expect(h.configured('brightness'), isNotEmpty);
        await h.closeWithBack();
      });

      testWidgets('$locale $engine: PiP keeps the original source exposed '
          'while blocking source pointer delivery', (tester) async {
        final h = _PlaybackHarness(tester, locale, engine);
        await h.mount();
        final surfaceState = tester.state(h.surface);
        final sourceRenderObject = tester.renderObject(h.surface);
        final pointerGate = tester.renderObject(h.sourcePointerGate);
        for (var cycle = 0; cycle < 2; cycle++) {
          // Positive hit-test controls prevent a permanently disabled source
          // or a no-output fake from making the PiP checks vacuous.
          expect(h.sourceReceivesPointers(h.leftGesturePoint), isTrue);
          expect(h.sourceReceivesPointers(h.rightGesturePoint), isTrue);
          expect(tester.widget<IgnorePointer>(h.sourcePointerGate).ignoring,
              isFalse);
          await h.update({'pipActive': true});
          h.expectOnlyBack();
          h.expectSameSurface(surfaceState);
          expect(tester.renderObject(h.surface), same(sourceRenderObject));
          expect(tester.renderObject(h.sourcePointerGate), same(pointerGate));
          await h.expectInertGestures();
          await h.update({'pipActive': false});
          h.expectSameSurface(surfaceState);
          expect(tester.renderObject(h.surface), same(sourceRenderObject));
          expect(tester.renderObject(h.sourcePointerGate), same(pointerGate));
          expect(h.sourceReceivesPointers(h.leftGesturePoint), isTrue);
          h.calls.clear();
          await h.doubleTap(h.rightGesturePoint);
          expect(h.named('seek'), hasLength(1));
        }
        await h.update({'pipActive': true});
        h.expectOnlyBack();
        await h.closeWithBack();
      });

      testWidgets('$locale $engine: locked PiP permits Back and preserves '
          'the ordinary lock on exit', (tester) async {
        final h = _PlaybackHarness(tester, locale, engine);
        await h.mount();
        final surfaceState = tester.state(h.surface);
        await tester.tap(h.tooltip('锁定控件'));
        await tester.pumpAndSettle();
        expect(h.tooltip('解锁控件').hitTestable(), findsOneWidget);
        expect(h.rewind, findsNothing);
        expect(await h.navigator.currentState!.maybePop(), isTrue);
        await tester.pumpAndSettle();
        expect(find.byType(PlaybackPage), findsOneWidget,
            reason: 'Ordinary locked playback still blocks navigation');
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(h.tooltip('解锁控件').hitTestable(), findsNothing);
        await h.expectInertGestures();
        expect(h.named('seek'), isEmpty);
        expect(h.configured('volume'), isEmpty);
        expect(h.configured('brightness'), isEmpty);

        await h.update({'pipActive': true});
        h.expectOnlyBack();
        h.expectSameSurface(surfaceState);
        await h.expectInertGestures();
        h.expectOnlyBack();

        await h.update({'pipActive': false});
        h.expectSameSurface(surfaceState);
        expect(h.rewind, findsNothing);
        expect(h.tooltip('锁定控件'), findsNothing);
        expect(h.tooltip('解锁控件').hitTestable(), findsNothing);
        await tester.tapAt(h.leftGesturePoint);
        await tester.pumpAndSettle();
        expect(h.tooltip('解锁控件').hitTestable(), findsOneWidget);
        await tester.tap(h.tooltip('解锁控件'));
        await tester.pumpAndSettle();
        expect(h.rewind.hitTestable(), findsOneWidget);
        h.calls.clear();
        await h.doubleTap(h.rightGesturePoint);
        expect(h.named('seek'), hasLength(1));

        // Re-lock, then enter PiP. The same Back control must pop even though
        // the ordinary player lock remains set internally.
        await tester.tap(h.tooltip('锁定控件'));
        await tester.pumpAndSettle();
        await h.update({'pipActive': true});
        h.expectOnlyBack();
        await h.closeWithBack();
      });

      testWidgets('$locale $engine: entering PiP cancels unfinished App gestures',
          (tester) async {
        final h = _PlaybackHarness(tester, locale, engine);
        await h.mount();
        for (final kind in ['volume', 'brightness']) {
          final point = kind == 'volume'
              ? h.leftGesturePoint : h.rightGesturePoint;
          h.calls.clear();
          final gesture = await tester.startGesture(point);
          await gesture.moveBy(const Offset(0, -30));
          await gesture.moveBy(const Offset(0, -80));
          await tester.pump();
          expect(find.byIcon(kind == 'volume'
              ? Icons.volume_up_rounded : Icons.brightness_6_rounded),
              findsOneWidget, reason: 'The level gesture must actually start');
          expect(h.configured(kind), isEmpty,
              reason: 'The 40ms level write should still be queued');
          await h.update({'pipActive': true});
          await gesture.up();
          await tester.pump(const Duration(seconds: 1));
          expect(h.configured(kind), isEmpty,
              reason: 'PiP entry must discard queued $kind changes');
          h.expectOnlyBack();
          await h.update({'pipActive': false});
        }

        final slider = tester.getRect(find.byType(GlassSlider));
        final gesture = await tester.startGesture(
            Offset(slider.left + slider.width * .3, slider.center.dy));
        await gesture.moveTo(
            Offset(slider.left + slider.width * .6, slider.center.dy));
        await tester.pump();
        expect(h.named('previewSeek'), isNotEmpty,
            reason: 'The progress scrub must actually start');
        await h.update({'pipActive': true});
        expect(h.named('cancelScrub'), hasLength(1));
        h.calls.clear();
        await gesture.moveBy(const Offset(20, 0));
        await gesture.up();
        await tester.pump(const Duration(seconds: 1));
        expect(h.named('previewSeek'), isEmpty);
        expect(h.named('seek'), isEmpty);
        h.expectOnlyBack();
        await h.closeWithBack();
      });

      testWidgets('$locale $engine: hidden controls stay hidden after PiP exit',
          (tester) async {
        final h = _PlaybackHarness(tester, locale, engine);
        await h.mount();
        final surfaceState = tester.state(h.surface);
        await tester.tap(h.tooltip('隐藏控件'));
        await tester.pumpAndSettle();
        expect(h.rewind, findsNothing);
        expect(h.back, findsNothing);
        await h.update({'pipActive': true});
        h.expectOnlyBack();
        h.expectSameSurface(surfaceState);
        await h.expectInertGestures();
        await h.update({'pipActive': false});
        h.expectSameSurface(surfaceState);
        expect(h.rewind, findsNothing);
        expect(h.back, findsNothing);
        await tester.tapAt(h.leftGesturePoint);
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        expect(h.rewind.hitTestable(), findsOneWidget);
        await h.closeWithBack();
      });
    }
  }
}
