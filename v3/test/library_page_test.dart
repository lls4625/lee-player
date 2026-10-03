import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leeplayer/library_page.dart';
import 'package:leeplayer/player_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('legal document route is opaque and disables transition snapshots', () {
    final route = legalDocumentRoute(title: '隐私政策', content: '正文');

    expect(route.opaque, isTrue);
    expect(route.allowSnapshotting, isFalse);
    expect(route.transitionDuration, const Duration(milliseconds: 160));
  });

  test('open source licenses use the same opaque transition', () {
    final route = openSourceLicensesRoute(ThemeData(useMaterial3: true));

    expect(route.opaque, isTrue);
    expect(route.allowSnapshotting, isFalse);
    expect(route.transitionDuration, const Duration(milliseconds: 160));
    expect(route.reverseTransitionDuration, const Duration(milliseconds: 120));
  });

  for (final brightness in Brightness.values) {
    testWidgets('legal document stays readable in ${brightness.name} mode', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final theme = ThemeData(
        useMaterial3: true,
        brightness: brightness,
        scaffoldBackgroundColor: Colors.transparent,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const LegalDocumentPage(
            title: '隐私政策',
            content:
                '雷player 隐私政策\n\n生效日期：2026 年 10 月 2 日\n开发者：李连顺'
                '\n\n一、适用范围\n\n这是一段用于验证清晰显示的正文。',
          ),
        ),
      );
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(LegalDocumentPage));
      final colors = Theme.of(context).colorScheme;
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      final appBar = tester.widget<AppBar>(find.byType(AppBar));
      final bodyText = tester.widget<Text>(find.text('这是一段用于验证清晰显示的正文。'));
      expect(tester.takeException(), isNull);
      expect(scaffold.backgroundColor, colors.surface);
      expect(appBar.backgroundColor, colors.surface);
      expect(appBar.foregroundColor, colors.onSurface);
      expect(bodyText.style?.color, colors.onSurface);
      expect(find.text('雷player 隐私政策'), findsNothing);
      expect(find.text('一、适用范围'), findsOneWidget);
    });
  }

  testWidgets('empty library content is centered across its card', (
    tester,
  ) async {
    const methods = MethodChannel('lei.player/methods');
    const events = MethodChannel('lei.player/events');
    const tips = MethodChannel('lei.player/developer_tip');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(methods, (call) async {
      return switch (call.method) {
        'state' => <String, Object>{},
        'libraryPreferences' => <String, Object>{
          'layout': 'list',
          'sort': 'name',
          'ascending': true,
        },
        'scan' => <Object>[],
        'records' => <String, Object>{},
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(
      tips,
      (_) async => <String, Object>{
        'revision': 1,
        'canPay': false,
        'products': <Object>[],
      },
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(events, null);
      messenger.setMockMethodCallHandler(tips, null);
    });

    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = PlayerModel();
    addTearDown(model.dispose);

    await tester.pumpWidget(MaterialApp(home: LibraryPage(model: model)));
    await tester.pumpAndSettle();

    final content = find.byKey(const Key('library-empty-content'));
    final icon = find.byIcon(Icons.folder_outlined);
    expect(content, findsOneWidget);
    expect(icon, findsOneWidget);
    expect(
      tester.getCenter(icon).dx,
      closeTo(tester.getCenter(content).dx, 0.01),
    );
    expect(
      tester.getCenter(find.text('当前文件夹为空')).dx,
      closeTo(tester.getCenter(content).dx, 0.01),
    );
  });

  testWidgets('settings builds lazily and only a left-edge swipe exits', (
    tester,
  ) async {
    const methods = MethodChannel('lei.player/methods');
    const events = MethodChannel('lei.player/events');
    const tips = MethodChannel('lei.player/developer_tip');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(methods, (call) async {
      return switch (call.method) {
        'state' => <String, Object>{},
        'libraryPreferences' => <String, Object>{
          'layout': 'list',
          'sort': 'name',
          'ascending': true,
        },
        'scan' => <Object>[],
        'records' => <String, Object>{},
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(
      tips,
      (_) async => <String, Object>{
        'revision': 1,
        'canPay': false,
        'products': <Object>[],
      },
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(methods, null);
      messenger.setMockMethodCallHandler(events, null);
      messenger.setMockMethodCallHandler(tips, null);
    });

    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = PlayerModel();
    addTearDown(model.dispose);

    await tester.pumpWidget(MaterialApp(home: LibraryPage(model: model)));
    await tester.pumpAndSettle();

    Future<void> openSettings() async {
      await tester.tap(find.byTooltip('综合设置'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-heading')), findsOneWidget);
    }

    await openSettings();
    expect(find.text('版权与用户内容'), findsNothing);

    await tester.timedDrag(
      find.byKey(const Key('settings-list')),
      const Offset(0, -240),
      const Duration(milliseconds: 400),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-swipe-area')), findsOneWidget);

    final settingsScrollable = find.descendant(
      of: find.byKey(const Key('settings-list')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.text('隐私政策'),
      320,
      scrollable: settingsScrollable,
    );
    await tester.ensureVisible(find.text('隐私政策'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('隐私政策'));
    await tester.pumpAndSettle();
    expect(find.byType(LegalDocumentPage), findsOneWidget);
    expect(find.text('隐私政策'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('版权与用户内容'),
      180,
      scrollable: settingsScrollable,
    );
    await tester.ensureVisible(find.text('版权与用户内容'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('版权与用户内容'));
    await tester.pumpAndSettle();
    expect(find.byType(LegalDocumentPage), findsOneWidget);
    expect(find.text('版权与用户内容'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-swipe-area')), findsOneWidget);

    await tester.ensureVisible(find.text('开源软件许可'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开源软件许可'));
    await tester.pump(const Duration(milliseconds: 300));
    debugDumpApp();
    expect(find.byType(LicensePage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-swipe-area')), findsOneWidget);

    await tester.timedDragFrom(
      const Offset(8, 400),
      const Offset(-40, 0),
      const Duration(milliseconds: 500),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-swipe-area')), findsOneWidget);

    await tester.timedDrag(
      find.byKey(const Key('settings-swipe-area')),
      const Offset(120, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-swipe-area')), findsOneWidget);

    await tester.timedDragFrom(
      const Offset(8, 400),
      const Offset(120, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-swipe-area')), findsNothing);
    expect(find.text('当前文件夹为空'), findsOneWidget);

    for (var i = 0; i < 2; i++) {
      await openSettings();
      await tester.timedDragFrom(
        const Offset(8, 400),
        const Offset(120, 0),
        const Duration(milliseconds: 300),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-swipe-area')), findsNothing);
    }
  });
}
