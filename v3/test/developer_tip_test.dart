import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leeplayer/developer_tip.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parses complete StoreKit product metadata only', () {
    expect(
      DeveloperTipProduct.fromNative(<String, Object>{
        'id': 'vip.ichiki.javalee.leeplayer.tip.small',
        'name': '一份鼓励',
        'price': '¥6.00',
      })?.price,
      '¥6.00',
    );
    expect(
      DeveloperTipProduct.fromNative(<String, Object>{
        'id': 'vip.ichiki.javalee.leeplayer.tip.small',
        'name': '一份鼓励',
      }),
      isNull,
    );
  });

  test('applies native products in the intended display order', () {
    final controller = DeveloperTipController();
    addTearDown(controller.dispose);

    controller.applyNativeState(<String, Object>{
      'revision': 1,
      'canPay': true,
      'products': <Map<String, String>>[
        <String, String>{
          'id': 'vip.ichiki.javalee.leeplayer.tip.small',
          'name': '一份鼓励',
          'price': '¥6.00',
        },
        <String, String>{
          'id': 'vip.ichiki.javalee.leeplayer.tip.medium',
          'name': '暖心支持',
          'price': '¥18.00',
        },
      ],
    });

    expect(controller.canPay, isTrue);
    expect(controller.products.map((product) => product.id), <String>[
      'vip.ichiki.javalee.leeplayer.tip.medium',
      'vip.ichiki.javalee.leeplayer.tip.small',
    ]);
  });

  test('ignores an older native snapshot and parses celebration identity', () {
    final controller = DeveloperTipController();
    addTearDown(controller.dispose);
    controller.applyNativeState(<String, Object>{
      'revision': 2,
      'canPay': true,
      'products': <Object>[],
      'celebration': <String, String>{
        'productId': 'vip.ichiki.javalee.leeplayer.tip.large',
        'transactionId': '123',
      },
    });
    controller.applyNativeState(<String, Object>{
      'revision': 1,
      'canPay': false,
      'products': <Object>[],
    });

    expect(controller.canPay, isTrue);
    expect(controller.celebration?.transactionId, '123');
  });

  testWidgets('unavailable page shows only the real error and retry action', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('lei.player/developer_tip');
    final state = <String, Object>{
      'revision': 1,
      'canPay': true,
      'message': '商品暂不可用，请稍后重新加载',
      'products': <Object>[],
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => state);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = DeveloperTipController()..applyNativeState(state);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: DeveloperTipPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('打赏开发者'), findsOneWidget);
    expect(find.text('感谢你的支持'), findsOneWidget);
    expect(find.text('商品暂不可用，请稍后重新加载'), findsOneWidget);
    expect(find.text('重新加载商品'), findsOneWidget);
    expect(find.text('暖心支持'), findsNothing);
    expect(find.text('配置预览 · 暂不可购买'), findsNothing);
    expect(
      tester.getTopLeft(find.text('感谢你的支持')).dy,
      greaterThan(tester.getBottomLeft(find.text('打赏开发者')).dy),
    );
    debugDefaultTargetPlatformOverride = null;
  });
}
