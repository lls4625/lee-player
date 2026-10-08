import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'glass_ui.dart';
import 'app_localizations.dart';

class DeveloperTipProduct {
  const DeveloperTipProduct({
    required this.id,
    required this.name,
    required this.price,
  });

  final String id;
  final String name;
  final String price;

  static DeveloperTipProduct? fromNative(Object? value) {
    if (value is! Map) return null;
    final id = value['id'] as String?;
    final name = value['name'] as String?;
    final price = value['price'] as String?;
    if (id == null || name == null || price == null) return null;
    return DeveloperTipProduct(id: id, name: name, price: price);
  }
}

class DeveloperTipCelebration {
  const DeveloperTipCelebration({
    required this.productId,
    required this.transactionId,
  });

  final String productId;
  final String transactionId;

  static DeveloperTipCelebration? fromNative(Object? value) {
    if (value is! Map) return null;
    final productId = value['productId'] as String?;
    final transactionId = value['transactionId'] as String?;
    if (productId == null || transactionId == null) return null;
    return DeveloperTipCelebration(
      productId: productId,
      transactionId: transactionId,
    );
  }
}

class DeveloperTipController extends ChangeNotifier
    with WidgetsBindingObserver {
  DeveloperTipController() {
    _channel.setMethodCallHandler(_onNativeCall);
    WidgetsBinding.instance.addObserver(this);
  }

  static const _channel = MethodChannel('lei.player/developer_tip');
  static const displayOrder = <String>[
    'vip.ichiki.javalee.leeplayer.tip.medium',
    'vip.ichiki.javalee.leeplayer.tip.small',
    'vip.ichiki.javalee.leeplayer.tip.xlarge',
    'vip.ichiki.javalee.leeplayer.tip.large',
    'vip.ichiki.javalee.leeplayer.tip.strong',
    'vip.ichiki.javalee.leeplayer.tip.premium',
  ];
  static const displayNameKeys = <String, String>{
    'vip.ichiki.javalee.leeplayer.tip.small': '一份鼓励',
    'vip.ichiki.javalee.leeplayer.tip.medium': '暖心支持',
    'vip.ichiki.javalee.leeplayer.tip.large': '特别支持',
    'vip.ichiki.javalee.leeplayer.tip.xlarge': '大力支持',
    'vip.ichiki.javalee.leeplayer.tip.premium': '顶级鼓励',
    'vip.ichiki.javalee.leeplayer.tip.strong': '鼎力支持',
  };
  final List<DeveloperTipProduct> _products = <DeveloperTipProduct>[];
  bool _initialized = false;
  bool _loading = false;
  bool _busy = false;
  bool _canPay = false;
  bool _disposed = false;
  int _revision = -1;
  AppMessage? _message;
  String? _processingProductId;
  DeveloperTipCelebration? _celebration;

  List<DeveloperTipProduct> get products => List.unmodifiable(_products);

  bool get initialized => _initialized;
  bool get loading => _loading;
  bool get busy => _busy;
  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  bool get canPay => _canPay;
  AppMessage? get message => _message;
  String? get processingProductId => _processingProductId;
  DeveloperTipCelebration? get celebration => _celebration;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void applyNativeState(Object? value) {
    if (_disposed || value is! Map) return;
    final revision = (value['revision'] as num?)?.toInt() ?? -1;
    if (revision < _revision) return;
    _revision = revision;
    _canPay = value['canPay'] == true;
    final messageCode = value['messageCode'] as String?;
    final legacyMessage = value['message'] as String?;
    _message = messageCode == null
        ? legacyMessage == null
              ? null
              : AppMessage('legacy_message', fallback: legacyMessage)
        : AppMessage(messageCode);
    _celebration = DeveloperTipCelebration.fromNative(value['celebration']);
    final rawProducts = value['products'];
    if (rawProducts is List) {
      final next =
          rawProducts
              .map(DeveloperTipProduct.fromNative)
              .whereType<DeveloperTipProduct>()
              .toList()
            ..sort(
              (left, right) => displayOrder
                  .indexOf(left.id)
                  .compareTo(displayOrder.indexOf(right.id)),
            );
      _products
        ..clear()
        ..addAll(next);
    }
    _initialized = true;
    _notify();
  }

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method == 'state') applyNativeState(call.arguments);
  }

  void _record(Object error) {
    if (error is PlatformException) {
      final details = error.details;
      _message = details is Map
          ? AppMessage.fromMap(<dynamic, dynamic>{
              ...details,
              'code': error.code,
            }, fallback: error.message)
          : AppMessage(
              error.code,
              fallback: error.message,
              technicalDetail: details == null ? null : '$details',
            );
    } else {
      _message = AppMessage(
        'purchase_service_unavailable',
        technicalDetail: '$error',
      );
    }
    _notify();
  }

  Future<void> reload() async {
    if (_disposed) return;
    if (!supported) {
      _initialized = true;
      _message = const AppMessage('purchase_ios_only');
      _notify();
      return;
    }
    try {
      applyNativeState(await _channel.invokeMethod<Object?>('refresh'));
    } catch (error) {
      _record(error);
    } finally {
      _initialized = true;
      _notify();
    }
    if (!_disposed && _products.isEmpty) unawaited(loadProducts());
  }

  Future<void> loadProducts() async {
    if (_disposed || !supported || _loading || _busy) return;
    _loading = true;
    _message = null;
    _notify();
    try {
      applyNativeState(await _channel.invokeMethod<Object?>('loadProducts'));
    } catch (error) {
      _record(error);
    } finally {
      _loading = false;
      _notify();
    }
  }

  Future<void> purchase(DeveloperTipProduct product) async {
    if (_disposed ||
        !supported ||
        _busy ||
        !_canPay ||
        !_products.any((item) => item.id == product.id)) {
      return;
    }
    _busy = true;
    _processingProductId = product.id;
    _message = null;
    _notify();
    try {
      applyNativeState(
        await _channel.invokeMethod<Object?>('purchase', product.id),
      );
    } catch (error) {
      _record(error);
    } finally {
      _busy = false;
      _processingProductId = null;
      _notify();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(reload());
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}

class DeveloperTipPage extends StatefulWidget {
  const DeveloperTipPage({super.key, required this.controller});

  final DeveloperTipController controller;

  @override
  State<DeveloperTipPage> createState() => _DeveloperTipPageState();
}

class _DeveloperTipPageState extends State<DeveloperTipPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fireworkController;
  Timer? _thanksTimer;
  String? _handledTransactionId;
  _TipCelebrationLevel? _level;
  bool _staticThanks = false;

  DeveloperTipController get tip => widget.controller;

  @override
  void initState() {
    super.initState();
    _fireworkController = AnimationController(vsync: this);
    tip.addListener(_onTipChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onTipChanged();
      unawaited(tip.reload());
    });
  }

  void _onTipChanged() {
    final event = tip.celebration;
    if (!mounted ||
        event == null ||
        event.transactionId == _handledTransactionId) {
      return;
    }
    final level = _TipCelebrationLevel.forProduct(event.productId);
    if (level == null) return;
    _handledTransactionId = event.transactionId;
    _level = level;
    _staticThanks =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    _thanksTimer?.cancel();
    _thanksTimer = Timer(const Duration(seconds: 5), _dismissCelebration);
    if (!_staticThanks) {
      _fireworkController.duration = level.duration;
      _fireworkController.forward(from: 0);
    }
    setState(() {});
  }

  void _dismissCelebration() {
    _thanksTimer?.cancel();
    _thanksTimer = null;
    _fireworkController.stop();
    if (mounted) setState(() => _level = null);
  }

  @override
  void dispose() {
    tip.removeListener(_onTipChanged);
    _thanksTimer?.cancel();
    _fireworkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GlassScaffold(
    background: const LeiGlassBackground(),
    extendBody: false,
    appBar: GlassAppBar(
      centerTitle: false,
      toolbarHeight: 64,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      title: const LText('打赏开发者'),
      leading: LeiGlassIconButton(
        tooltip: '返回',
        icon: const Icon(Icons.arrow_back_rounded),
        onPressed: () => Navigator.of(context).pop(),
      ),
    ),
    body: SafeArea(
      top: false,
      child: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: <Widget>[
              LText('感谢你的支持', style: Theme.of(context).textTheme.headlineLarge),
              const SizedBox(height: 14),
              LeiSurface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const LText('你的每一份鼓励，都是雷player不断完善的动力。'),
                    const SizedBox(height: 8),
                    LText(
                      '打赏完全自愿，是一次性、可重复购买的 App Store 消耗型项目；不解锁任何功能或内容，不影响免费使用，且不可恢复。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              AnimatedBuilder(
                animation: tip,
                builder: (context, _) => _TipProducts(controller: tip),
              ),
            ],
          ),
          if (_level != null)
            Positioned.fill(
              child: _FireworksOverlay(
                level: _level!,
                controller: _fireworkController,
                staticThanks: _staticThanks,
                onDismiss: _dismissCelebration,
              ),
            ),
        ],
      ),
    ),
  );
}

class _TipProducts extends StatelessWidget {
  const _TipProducts({required this.controller});

  final DeveloperTipController controller;

  @override
  Widget build(BuildContext context) {
    final waiting = !controller.initialized || controller.loading;
    final localizations = AppLocalizations.of(context);
    final status = waiting
        ? localizations.text('正在加载商品…')
        : controller.products.isEmpty
        ? controller.message == null
              ? localizations.text('暂未获取到商品，请稍后重试')
              : localizations.message(controller.message!)
        : controller.products.length <
              DeveloperTipController.displayOrder.length
        ? localizations.text('部分商品暂不可用，请稍后重试。')
        : !controller.canPay
        ? localizations.text('当前设备不允许购买。')
        : controller.message == null
        ? null
        : localizations.message(controller.message!);
    return Column(
      children: [
        if (status != null) ...[
          LeiSurface(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (waiting) ...[
                      const GlassProgressIndicator.circular(size: 22),
                      const SizedBox(width: 10),
                    ],
                    Expanded(child: Text(status)),
                  ],
                ),
                if (!waiting &&
                    (controller.products.length <
                            DeveloperTipController.displayOrder.length ||
                        controller.message != null)) ...[
                  const SizedBox(height: 12),
                  LeiGlassButton(
                    onPressed: controller.busy ? null : controller.loadProducts,
                    label: '重新加载商品',
                    icon: Icons.refresh_rounded,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: controller.products.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.24,
          ),
          itemBuilder: (context, index) {
            final product = controller.products[index];
            return _TipCard(
              product: product,
              enabled: !controller.busy && controller.canPay,
              processing: controller.processingProductId == product.id,
              onTap: () => controller.purchase(product),
            );
          },
        ),
      ],
    );
  }
}

class _TipCard extends StatelessWidget {
  const _TipCard({
    required this.product,
    required this.enabled,
    required this.processing,
    required this.onTap,
  });

  final DeveloperTipProduct product;
  final bool enabled;
  final bool processing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context);
    final nameKey = DeveloperTipController.displayNameKeys[product.id];
    final displayName = nameKey == null
        ? product.name
        : localizations.text(nameKey);
    final accessibilityLabel = localizations.text(
      '{name}，{price}',
      args: {'name': displayName, 'price': product.price},
    );

    return Semantics(
      button: true,
      enabled: enabled,
      label: accessibilityLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? onTap : null,
        child: Opacity(
          opacity: enabled ? 1 : .55,
          child: LeiSurface(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    displayName,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (processing) ...[
                        const GlassProgressIndicator.circular(size: 20),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        product.price,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(color: leiAccent(context)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _FireworkStyle { comet, heart, burst, waterfall, ring, finale }

class _TipCelebrationLevel {
  const _TipCelebrationLevel(
    this.productId,
    this.label,
    this.style,
    this.bursts,
    this.particles,
    this.duration,
  );

  final String productId;
  final String label;
  final _FireworkStyle style;
  final int bursts;
  final int particles;
  final Duration duration;

  static const all = <_TipCelebrationLevel>[
    _TipCelebrationLevel(
      'vip.ichiki.javalee.leeplayer.tip.small',
      '一份鼓励',
      _FireworkStyle.comet,
      1,
      40,
      Duration(milliseconds: 1400),
    ),
    _TipCelebrationLevel(
      'vip.ichiki.javalee.leeplayer.tip.medium',
      '暖心支持',
      _FireworkStyle.heart,
      2,
      70,
      Duration(milliseconds: 1800),
    ),
    _TipCelebrationLevel(
      'vip.ichiki.javalee.leeplayer.tip.large',
      '特别支持',
      _FireworkStyle.burst,
      3,
      110,
      Duration(milliseconds: 2200),
    ),
    _TipCelebrationLevel(
      'vip.ichiki.javalee.leeplayer.tip.xlarge',
      '大力支持',
      _FireworkStyle.waterfall,
      5,
      170,
      Duration(milliseconds: 2800),
    ),
    _TipCelebrationLevel(
      'vip.ichiki.javalee.leeplayer.tip.premium',
      '顶级鼓励',
      _FireworkStyle.ring,
      7,
      240,
      Duration(milliseconds: 3400),
    ),
    _TipCelebrationLevel(
      'vip.ichiki.javalee.leeplayer.tip.strong',
      '鼎力支持',
      _FireworkStyle.finale,
      10,
      360,
      Duration(milliseconds: 4500),
    ),
  ];

  static _TipCelebrationLevel? forProduct(String id) {
    for (final level in all) {
      if (level.productId == id) return level;
    }
    return null;
  }
}

class _FireworksOverlay extends StatefulWidget {
  const _FireworksOverlay({
    required this.level,
    required this.controller,
    required this.staticThanks,
    required this.onDismiss,
  });

  final _TipCelebrationLevel level;
  final AnimationController controller;
  final bool staticThanks;
  final VoidCallback onDismiss;

  @override
  State<_FireworksOverlay> createState() => _FireworksOverlayState();
}

class _FireworksOverlayState extends State<_FireworksOverlay> {
  late final List<_FireworkParticle> particles = _FireworkParticle.create(
    widget.level,
  );

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black.withValues(alpha: .58),
    child: Stack(
      children: [
        if (!widget.staticThanks)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _FireworkPainter(
                  widget.controller,
                  widget.level.style,
                  particles,
                ),
              ),
            ),
          ),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: LeiSurface(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.favorite_rounded, size: 38, color: leiGold),
                  const SizedBox(height: 12),
                  LText(
                    '感谢你的「{support}」！',
                    args: {
                      'support': AppLocalizations.of(
                        context,
                      ).text(widget.level.label),
                    },
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 6),
                  LText(
                    widget.staticThanks ? '感谢你的支持。' : '愿每一份热爱都有回响。',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 14),
                  LeiGlassButton(
                    onPressed: widget.onDismiss,
                    label: widget.staticThanks ? '关闭' : '跳过',
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _FireworkParticle {
  const _FireworkParticle(
    this.x,
    this.y,
    this.angle,
    this.distance,
    this.delay,
    this.color,
  );

  final double x;
  final double y;
  final double angle;
  final double distance;
  final double delay;
  final Color color;

  static List<_FireworkParticle> create(_TipCelebrationLevel level) {
    final random = math.Random(level.productId.hashCode);
    const colors = <Color>[
      Color(0xffffd166),
      Color(0xffff7b7b),
      Color(0xff8de0d5),
      Color(0xffb8a1ff),
      Colors.white,
    ];
    return List.generate(level.particles, (index) {
      final burst = index % level.bursts;
      final x = level.bursts == 1
          ? .5
          : .15 + .7 * (burst / (level.bursts - 1));
      final y = level.style == _FireworkStyle.comet
          ? .18
          : .10 + random.nextDouble() * .16;
      return _FireworkParticle(
        x,
        y,
        random.nextDouble() * math.pi * 2,
        .06 + random.nextDouble() * .17,
        (burst / level.bursts) * .44 + random.nextDouble() * .08,
        colors[random.nextInt(colors.length)],
      );
    });
  }
}

class _FireworkPainter extends CustomPainter {
  const _FireworkPainter(this.progress, this.style, this.particles)
    : super(repaint: progress);

  final Animation<double> progress;
  final _FireworkStyle style;
  final List<_FireworkParticle> particles;

  @override
  void paint(Canvas canvas, Size size) {
    if (style == _FireworkStyle.comet) _paintComet(canvas, size);
    for (final particle in particles) {
      final time = ((progress.value - particle.delay) / (1 - particle.delay))
          .clamp(0.0, 1.0)
          .toDouble();
      if (time <= 0 || time >= 1) continue;
      final point = switch (style) {
        _FireworkStyle.heart => _heartPoint(particle, time, size),
        _FireworkStyle.waterfall => _waterfallPoint(particle, time, size),
        _FireworkStyle.ring => _ringPoint(particle, time, size),
        _FireworkStyle.finale => _finalePoint(particle, time, size),
        _ => _burstPoint(particle, time, size),
      };
      final paint = Paint()
        ..color = particle.color.withValues(alpha: (1 - time) * .95);
      canvas.drawCircle(point, 1.6 + (1 - time) * 2.2, paint);
    }
  }

  Offset _burstPoint(_FireworkParticle particle, double time, Size size) {
    final dx = math.cos(particle.angle) * particle.distance * size.width * time;
    final dy =
        math.sin(particle.angle) * particle.distance * size.width * time +
        size.height * .11 * time * time;
    return Offset(particle.x * size.width + dx, particle.y * size.height + dy);
  }

  Offset _heartPoint(_FireworkParticle particle, double time, Size size) {
    final angle = particle.angle;
    final scale = .0085 * size.width * time;
    final x = (16 * math.pow(math.sin(angle), 3) * scale).toDouble();
    final y =
        (-(13 * math.cos(angle) -
                    5 * math.cos(2 * angle) -
                    2 * math.cos(3 * angle) -
                    math.cos(4 * angle)) *
                scale)
            .toDouble();
    final centerX = particle.x < .5 ? size.width * .32 : size.width * .68;
    return Offset(
      centerX + x,
      size.height * .18 + y + size.height * .08 * time * time,
    );
  }

  Offset _waterfallPoint(_FireworkParticle particle, double time, Size size) {
    final dx =
        math.cos(particle.angle) * particle.distance * size.width * .4 * time;
    return Offset(
      particle.x * size.width + dx,
      size.height * (.20 + .62 * time * time),
    );
  }

  Offset _ringPoint(_FireworkParticle particle, double time, Size size) {
    final radius = (.045 + particle.distance * .9) * size.width * time;
    return Offset(
      size.width * .5 + math.cos(particle.angle) * radius,
      size.height * .18 + math.sin(particle.angle) * radius,
    );
  }

  Offset _finalePoint(_FireworkParticle particle, double time, Size size) {
    final point = _burstPoint(particle, time, size);
    final shimmer = math.sin((particle.angle + time * 18) * 2) * 3;
    return Offset(
      point.dx + shimmer,
      point.dy + size.height * .17 * time * time,
    );
  }

  void _paintComet(Canvas canvas, Size size) {
    final flight = (progress.value / .4).clamp(0.0, 1.0).toDouble();
    final start = Offset(size.width * .5, size.height * .88);
    final end = Offset(size.width * .5, size.height * .18);
    final head = Offset.lerp(start, end, flight)!;
    final paint = Paint()
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..shader = const LinearGradient(
        colors: <Color>[Color(0x00ffd166), Color(0xffffd166)],
      ).createShader(Rect.fromPoints(start, head));
    canvas.drawLine(start, head, paint);
    canvas.drawCircle(head, 5, Paint()..color = const Color(0xfffff3bf));
  }

  @override
  bool shouldRepaint(_FireworkPainter oldDelegate) =>
      oldDelegate.style != style || oldDelegate.particles != particles;
}
