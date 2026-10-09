import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app_localizations.dart';

export 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

const leiGold = Color(0xffffc83d);
const leiRoundedControlShape = LiquidRoundedSuperellipse(borderRadius: 12);
Color leiAccent(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? leiGold
    : const Color(0xff805900);

class LeiGlassBackground extends StatelessWidget {
  const LeiGlassBackground({super.key});
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: dark
              ? const [Color(0xff20303f), Color(0xff111820), Color(0xff302e28)]
              : const [Color(0xffe6edf5), Color(0xfff3f5f7), Color(0xffeee4d2)],
        ),
      ),
    );
  }
}

/// Shared, quiet surfaces keep navigation and media controls visually related.
class LeiSurface extends StatelessWidget {
  const LeiSurface({
    super.key,
    required this.child,
    this.accent = false,
    this.padding = const EdgeInsets.all(20),
  });
  final Widget child;
  final bool accent;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) {
    // Keep controls beside the surface, so their own glass effects stay active.
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: GlassContainer(
              shape: const LiquidRoundedSuperellipse(borderRadius: 22),
              glowIntensity: accent ? .12 : 0,
              child: const SizedBox.expand(),
            ),
          ),
        ),
        Padding(padding: padding, child: child),
      ],
    );
  }
}

class LeiSectionHeading extends StatelessWidget {
  const LeiSectionHeading({
    super.key,
    required this.title,
    required this.subtitle,
  });
  final String title, subtitle;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LText(title, style: Theme.of(context).textTheme.headlineLarge),
        const SizedBox(height: 6),
        LText(
          subtitle,
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    ),
  );
}

class LeiMediaIcon extends StatelessWidget {
  const LeiMediaIcon({super.key, required this.icon});
  final IconData icon;
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 48,
    child: GlassContainer(
      shape: leiRoundedControlShape,
      child: Icon(icon, color: leiAccent(context), size: 24),
    ),
  );
}

class LeiSheetHeading extends StatelessWidget {
  const LeiSheetHeading({
    super.key,
    required this.title,
    this.subtitle,
    this.platformViewBackdrop = false,
  });
  final String title;
  final String? subtitle;
  final bool platformViewBackdrop;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: LText(
                  AppLocalizations.of(context).text(title),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 6),
                LText(subtitle!, style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        LeiGlassIconButton(
          icon: const Icon(Icons.close_rounded),
          tooltip: AppLocalizations.of(context).text('关闭面板'),
          platformViewBackdrop: platformViewBackdrop,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    ),
  );
}

class LeiGlassIconButton extends StatelessWidget {
  const LeiGlassIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.tooltipArgs = const <String, Object?>{},
    this.platformViewBackdrop = false,
  });
  final Widget icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final Map<String, Object?> tooltipArgs;
  final bool platformViewBackdrop;
  @override
  Widget build(BuildContext context) {
    final button = GlassIconButton(
      icon: icon,
      onPressed: onPressed,
      semanticLabel: tooltip == null
          ? null
          : AppLocalizations.of(context).text(tooltip!, args: tooltipArgs),
      platformViewBackdrop: platformViewBackdrop,
    );
    return tooltip == null
        ? button
        : Tooltip(
            message: AppLocalizations.of(
              context,
            ).text(tooltip!, args: tooltipArgs),
            child: button,
          );
  }
}

/// Labels, spacing and centering belong here, never to the calling page.
class LeiGlassButton extends StatelessWidget {
  const LeiGlassButton({
    super.key,
    required this.onPressed,
    required this.label,
    this.icon,
  });
  final VoidCallback? onPressed;
  final String label;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => GlassButton.custom(
    onTap: onPressed ?? () {},
    enabled: onPressed != null,
    label: AppLocalizations.of(context).text(label),
    height: 48,
    shape: leiRoundedControlShape,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            ExcludeSemantics(child: Icon(icon)),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: LText(label, textAlign: TextAlign.center, softWrap: true),
          ),
        ],
      ),
    ),
  );
}

Future<T?> showLeiDialog<T>({
  required BuildContext context,
  required String? title,
  String? message,
  Map<String, Object?> titleArgs = const <String, Object?>{},
  Map<String, Object?> messageArgs = const <String, Object?>{},
  bool localizeTitle = true,
  bool localizeMessage = true,
  Widget? content,
  bool platformViewBackdrop = false,
  bool fixedNearTop = false,
  required List<GlassDialogAction> actions,
}) {
  // General-dialog routes are built under the navigator, outside any local
  // playback theme. Carry the caller's theme, text and icon styles with them.
  final themes = InheritedTheme.capture(
    from: context,
    to: Navigator.of(context, rootNavigator: true).context,
  );
  final theme = Theme.of(context);
  final cupertinoTheme = theme.cupertinoOverrideTheme == null
      ? CupertinoTheme.of(context)
      : MaterialBasedCupertinoThemeData(materialTheme: theme);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black54,
    pageBuilder: (context, animation, secondaryAnimation) => themes.wrap(
      CupertinoTheme(
        data: cupertinoTheme,
        child: DefaultTextStyle(
          style: theme.textTheme.bodyMedium!,
          child: SafeArea(
            child: AnimatedPadding(
              duration: fixedNearTop
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              padding: fixedNearTop
                  ? const EdgeInsets.fromLTRB(24, 56, 24, 24)
                  : EdgeInsets.fromLTRB(
                      24,
                      24,
                      24,
                      MediaQuery.viewInsetsOf(context).bottom + 24,
                    ),
              child: Align(
                alignment: fixedNearTop
                    ? Alignment.topCenter
                    : Alignment.center,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: SingleChildScrollView(
                    child: AdaptiveLiquidGlassLayer(
                      quality: platformViewBackdrop
                          ? GlassQuality.minimal
                          : GlassQuality.standard,
                      platformViewBackdrop: platformViewBackdrop,
                      child: GlassDialog(
                        title: title == null
                            ? null
                            : localizeTitle
                            ? AppLocalizations.of(context)
                                  .text(title, args: titleArgs)
                            : title,
                        message: message == null
                            ? null
                            : localizeMessage
                            ? AppLocalizations.of(context)
                                  .text(message, args: messageArgs)
                            : message,
                        content: content,
                        quality: platformViewBackdrop
                            ? GlassQuality.minimal
                            : GlassQuality.standard,
                        actions: [
                          for (final action in actions)
                            GlassDialogAction(
                              label: AppLocalizations.of(context)
                                  .text(action.label),
                              onPressed: action.onPressed,
                              isPrimary: action.isPrimary,
                              isDestructive: action.isDestructive,
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Trailing controls are siblings of the tile surface so their glass remains active.
class LeiGlassTile extends StatelessWidget {
  const LeiGlassTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.dense = false,
    this.flat = false,
  });
  final Widget title;
  final Widget? subtitle, leading, trailing;
  final VoidCallback? onTap;
  final bool dense, flat;
  @override
  Widget build(BuildContext context) {
    final labelColor =
        CupertinoTheme.of(context).textTheme.textStyle.color ??
        CupertinoColors.label;
    final content = leading == null
        ? null
        : Row(
            children: [
              leading!,
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DefaultTextStyle(
                      style: TextStyle(
                        color: labelColor,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                      child: title,
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      DefaultTextStyle(
                        style: TextStyle(
                          color: labelColor.withValues(alpha: .65),
                          fontSize: 13,
                        ),
                        child: subtitle!,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
    final tile = flat
        ? Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: dense ? 8 : 12,
                ),
                child:
                    content ??
                    DefaultTextStyle(
                      style: TextStyle(
                        color: labelColor,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          title,
                          if (subtitle != null) ...[
                            const SizedBox(height: 2),
                            DefaultTextStyle(
                              style: TextStyle(
                                color: labelColor.withValues(alpha: .65),
                                fontSize: 13,
                              ),
                              child: subtitle!,
                            ),
                          ],
                        ],
                      ),
                    ),
              ),
            ),
          )
        : GlassListTile.standalone(
            title: content ?? title,
            subtitle: content == null ? subtitle : null,
            onTap: onTap,
            contentPadding: EdgeInsets.symmetric(
              horizontal: 16,
              vertical: dense ? 8 : 12,
            ),
          );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Expanded(child: tile),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}

class LeiGlassMenu extends StatelessWidget {
  LeiGlassMenu({
    super.key,
    this.choices = const {},
    required this.onSelected,
    this.items,
    this.icon = Icons.more_vert,
    this.tooltip = '更多操作',
    this.tooltipArgs = const <String, Object?>{},
    this.selected,
  }) : assert(items == null || choices.isEmpty);
  final Map<String, String> choices;
  final ValueChanged<String> onSelected;
  final List<Widget>? items;
  final IconData icon;
  final String tooltip;
  final Map<String, Object?> tooltipArgs;
  final String? selected;
  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final itemHeight = math
        .max(48.0, mediaQuery.textScaler.scale(17) * 1.35 + 16)
        .toDouble();
    final menuItems =
        items ??
        [
          for (final entry in choices.entries)
            GlassMenuItem(
              title: AppLocalizations.of(context).text(entry.value),
              height: itemHeight,
              onTap: () => onSelected(entry.key),
              isSelected: entry.key == selected,
              isDestructive: entry.key == 'trash',
            ),
        ];
    double heightOf(Widget item) => switch (item) {
      GlassMenuItem() => math.max(item.height, itemHeight).toDouble(),
      GlassMenuDivider() => item.height,
      GlassMenuLabel() => item.height,
      _ => itemHeight,
    };
    final gaps = math.max(0, menuItems.length - 1) * 2.0;
    final naturalHeight =
        menuItems.fold<double>(24.0, (sum, item) => sum + heightOf(item)) +
        gaps;
    const menuPadding = EdgeInsets.all(12);
    final availableHeight = math.max(
      0.0,
      mediaQuery.size.height -
          mediaQuery.padding.vertical -
          menuPadding.vertical,
    );
    final menuHeight = math.min(naturalHeight, availableHeight).toDouble();
    return GlassMenu(
      autoAdjustToScreen: true,
      menuHeight: menuHeight,
      menuPadding: menuPadding,
      triggerBuilder: (context, toggle) => LeiGlassIconButton(
        icon: Icon(icon),
        tooltip: tooltip,
        tooltipArgs: tooltipArgs,
        onPressed: toggle,
      ),
      items: menuItems,
    );
  }
}

void showLeiToast(BuildContext context, String message) {
  _showLocalizedToast(context, (context) => AppLocalizations.of(context).text(message));
}

void showLeiMessageToast(BuildContext context, AppMessage message) {
  _showLocalizedToast(context, (context) => AppLocalizations.of(context).message(message));
}

void _showLocalizedToast(BuildContext context, String Function(BuildContext) text) {
  _messageToast?.remove();
  _messageToast?.dispose();
  _messageToastTimer?.cancel();
  final entry = OverlayEntry(builder: (context) => Positioned(
    top: MediaQuery.paddingOf(context).top + 12,
    left: 20, right: 20,
    child: IgnorePointer(child: Material(
      color: Colors.transparent,
      child: LeiSurface(child: Text(
        text(context), textAlign: TextAlign.center,
      )),
    )),
  ));
  _messageToast = entry;
  Overlay.of(context, rootOverlay: true).insert(entry);
  _messageToastTimer = Timer(const Duration(seconds: 4), () {
    if (identical(_messageToast, entry)) { entry.remove(); entry.dispose(); _messageToast = null; }
  });
}

OverlayEntry? _messageToast;
Timer? _messageToastTimer;

Future<T?> showLeiSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool platformViewBackdrop = false,
}) => GlassSheet.show<T>(
  context: context,
  isScrollable: false,
  quality: platformViewBackdrop ? GlassQuality.minimal : GlassQuality.standard,
  builder: (context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: GlassTheme(
      data: GlassThemeData.simple(
        quality: platformViewBackdrop
            ? GlassQuality.minimal
            : GlassQuality.standard,
      ),
      child: AdaptiveLiquidGlassLayer(
        quality: platformViewBackdrop
            ? GlassQuality.minimal
            : GlassQuality.standard,
        platformViewBackdrop: platformViewBackdrop,
        child: builder(context),
      ),
    ),
  ),
);
