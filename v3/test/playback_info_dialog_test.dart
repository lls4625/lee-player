import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoTheme;
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leeplayer/app_localizations.dart';
import 'package:leeplayer/glass_ui.dart';
import 'package:leeplayer/playback_page.dart';
import 'package:leeplayer/player_model.dart';

const _methods = MethodChannel('lei.player/methods');
const _reportScroll = ValueKey('playback-info-scroll');

class _InfoHarness {
  _InfoHarness(this.locale, this.response);

  final Locale locale;
  final Object response;
  final copied = <String>[];
  final calls = <String>[];
  final model = PlayerModel();
  bool failCopy = false;

  AppLocalizations get strings => AppLocalizations(locale);

  Future<void> mount(WidgetTester tester, {required Size size,
    double textScale = 1}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_methods, (call) async {
      calls.add(call.method);
      if (call.method == 'playbackInfo') return response;
      return null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        if (failCopy) throw PlatformException(code: 'clipboard_unavailable');
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    model.state = {'path': 'Report.mkv', 'isAudio': true, 'duration': 120.0,
      'position': 4.0, 'playing': false, 'seekable': true};
    addTearDown(() {
      model.dispose();
      messenger.setMockMethodCallHandler(_methods, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });
    await tester.pumpWidget(MaterialApp(
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate, GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          padding: size.width > size.height
            ? const EdgeInsets.fromLTRB(44, 0, 44, 21)
            : const EdgeInsets.only(top: 20),
        ),
        child: child!,
      ),
      home: Builder(builder: (context) => Scaffold(body: Center(
        child: TextButton(onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => PlaybackPage(model: model))),
          child: const Text('Open player'))))),
    ));
    await tester.tap(find.text('Open player'));
    await tester.pumpAndSettle();
  }

  Future<void> openInfo(WidgetTester tester) async {
    await tester.tap(find.byTooltip(strings.text('更多播放选项')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text(strings.text('播放信息')), 240);
    await tester.tap(find.text(strings.text('播放信息')));
    await tester.pumpAndSettle();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final detail = List.generate(140,
    (i) => 'Diagnostic $i · 简体 / 繁體 / 日本語 · frame=$i').join('\n');
  final info = <String, dynamic>{
    'engine': 'media_kit', 'durationSeconds': 120, 'seekable': true,
    'errorCode': 'media_playback_failed',
    'technicalDetail': '$detail\nEND-OF-COMPLETE-REPORT',
  };

  for (final locale in AppLocalizations.supportedLocales) {
    for (final viewport in [
      (size: const Size(430, 932), scale: 1.0),
      (size: const Size(320, 568), scale: 2.0),
      (size: const Size(568, 320), scale: 1.5),
      (size: const Size(568, 320), scale: 2.0),
    ]) {
      testWidgets('copy stays at the top for $locale ${viewport.size} '
        'scale ${viewport.scale}', (tester) async {
        final harness = _InfoHarness(locale, info);
        await harness.mount(tester, size: viewport.size, textScale: viewport.scale);
        await harness.openInfo(tester);
        final dialogFinder = find.byType(Dialog);
        final dialog = tester.widget<Dialog>(dialogFinder);
        // The outer app is light; playback's Material and Cupertino colors
        // must both remain dark inside the modal route.
        expect(Theme.of(tester.element(dialogFinder)).brightness, Brightness.dark);
        expect(CupertinoTheme.of(tester.element(dialogFinder)).brightness,
          Brightness.dark);
        expect(dialog.constraints, const BoxConstraints(maxWidth: 280));
        expect(dialog.insetPadding, const EdgeInsets.all(24));
        expect(dialog.insetAnimationDuration, const Duration(milliseconds: 180));
        expect(dialog.insetAnimationCurve, Curves.linear);
        final surface = dialog.child! as GlassContainer;
        expect((surface.shape as LiquidRoundedSuperellipse).borderRadius, 12);
        final route = ModalRoute.of(tester.element(dialogFinder))!;
        expect(route.transitionDuration, const Duration(milliseconds: 200));
        expect(route.reverseTransitionDuration, const Duration(milliseconds: 200));
        final copy = find.text(harness.strings.text('复制信息'));
        final closeIcon = find.byIcon(Icons.close_rounded);
        final scroll = find.byKey(_reportScroll);
        final title = find.text(harness.strings.text('播放信息'));
        final expected = harness.strings.playbackInfo(info);
        expect(tester.takeException(), isNull);
        expect(copy.hitTestable(), findsOneWidget);
        expect(closeIcon.hitTestable(), findsOneWidget);
        expect(tester.getRect(copy).bottom, lessThan(tester.getRect(title).top));
        expect(tester.getRect(title).top, tester.getRect(scroll).top);
        expect(tester.widget<SelectableText>(find.byType(SelectableText)).data, expected);
        final copyButtonRect = tester.getRect(find.byKey(const ValueKey('playback-info-copy')));
        expect(copyButtonRect.contains(tester.getRect(copy).topLeft), isTrue);
        expect(copyButtonRect.contains(tester.getRect(copy).bottomRight), isTrue);
        final initialCopyRect = tester.getRect(copy);
        final initialCloseRect = tester.getRect(closeIcon);
        // No body scroll is needed to copy all diagnostics, including the tail.
        await tester.tap(copy);
        await tester.pumpAndSettle();
        expect(harness.copied, [expected]);
        expect(harness.copied.single, contains('END-OF-COMPLETE-REPORT'));
        expect(scroll, findsOneWidget);
        final bodyScrollable = find.descendant(of: scroll,
          matching: find.byType(Scrollable)).first;
        final position = tester.state<ScrollableState>(bodyScrollable).position;
        expect(position.maxScrollExtent, greaterThan(0));
        await tester.drag(scroll, const Offset(0, -120));
        await tester.pumpAndSettle();
        expect(position.pixels, greaterThan(0));
        expect(tester.getRect(copy), initialCopyRect);
        expect(tester.getRect(closeIcon), initialCloseRect);
        expect(copy.hitTestable(), findsOneWidget);
        await tester.tap(copy);
        await tester.pumpAndSettle();
        expect(harness.copied, [expected, expected]);
        // Reaching the last line does not move either top action.
        position.jumpTo(position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(tester.getRect(copy), initialCopyRect);
        expect(tester.getRect(closeIcon), initialCloseRect);
        expect(tester.takeException(), isNull);
        await tester.tap(closeIcon);
        await tester.pumpAndSettle();
        expect(scroll, findsNothing);
        expect(find.byType(PlaybackPage), findsOneWidget);
        expect(harness.calls, isNot(contains('playerDismissed')));
        // The existing bottom Close action also only dismisses the dialog.
        await harness.openInfo(tester);
        final bottomClose = find.text(harness.strings.text('关闭'));
        expect(bottomClose.hitTestable(), findsOneWidget);
        await tester.tap(bottomClose);
        await tester.pumpAndSettle();
        expect(scroll, findsNothing);
        expect(find.byType(PlaybackPage), findsOneWidget);
        expect(harness.calls.where((call) => call == 'playbackInfo'), hasLength(2));
        expect(harness.calls, isNot(contains('pause')));
        expect(tester.takeException(), isNull);
        await harness.unmount(tester);
      });
    }
  }

  testWidgets('legacy text is copied in full and barrier does not close dialog',
    (tester) async {
    final harness = _InfoHarness(const Locale('en'), '$detail\nLEGACY-TAIL');
    await harness.mount(tester, size: const Size(430, 932));
    await harness.openInfo(tester);
    await tester.tap(find.text(harness.strings.text('复制信息')));
    await tester.pumpAndSettle();
    expect(harness.copied, [harness.strings.text(harness.response as String)]);
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(find.byKey(_reportScroll), findsOneWidget);
    await harness.unmount(tester);
  });

  testWidgets('clipboard failure keeps fixed copy action available for retry',
    (tester) async {
    final harness = _InfoHarness(const Locale('en'), info)..failCopy = true;
    await harness.mount(tester, size: const Size(430, 932));
    await harness.openInfo(tester);
    final copy = find.text(harness.strings.text('复制信息'));
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(harness.copied, isEmpty);
    expect(copy.hitTestable(), findsOneWidget);
    expect(find.text(harness.strings.text('复制失败，请重试')), findsOneWidget);
    harness.failCopy = false;
    await tester.tap(copy);
    await tester.pumpAndSettle();
    expect(harness.copied, [harness.strings.playbackInfo(info)]);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await harness.unmount(tester);
  });
}
