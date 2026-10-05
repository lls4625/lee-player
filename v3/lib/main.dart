import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoThemeData;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'player_model.dart';
import 'library_page.dart';
import 'app_localizations.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);
  final model = PlayerModel();
  runApp(
    LiquidGlassWidgets.wrap(
      brightnessResolver: Theme.maybeBrightnessOf,
      theme: GlassThemeData.simple(quality: GlassQuality.standard),
      child: LeePlayerApp(model: model),
    ),
  );
}

class LeePlayerApp extends StatefulWidget {
  const LeePlayerApp({super.key, required this.model});
  final PlayerModel model;
  @override
  State<LeePlayerApp> createState() => _LeePlayerAppState();
}

class _LeePlayerAppState extends State<LeePlayerApp> {
  PlayerModel get model => widget.model;
  late String appearance;
  late AppLanguageMode languageMode;
  @override
  void initState() {
    super.initState();
    appearance = model.appearance;
    languageMode = model.languageMode;
    model.addListener(appearanceChanged);
  }

  void appearanceChanged() {
    if (appearance != model.appearance || languageMode != model.languageMode) {
      setState(() {
        appearance = model.appearance;
        languageMode = model.languageMode;
      });
    }
  }

  @override
  void dispose() {
    model.removeListener(appearanceChanged);
    model.dispose();
    super.dispose();
  }

  ThemeData appTheme(Brightness brightness) => ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xffffc83d),
      brightness: brightness,
    ),
    cupertinoOverrideTheme: CupertinoThemeData(
      brightness: brightness,
      primaryColor: brightness == Brightness.dark
          ? const Color(0xffffc83d)
          : const Color(0xff805900),
    ),
    scaffoldBackgroundColor: Colors.transparent,
    visualDensity: VisualDensity.standard,
    textTheme: const TextTheme(
      headlineLarge: TextStyle(
        fontSize: 30,
        fontWeight: FontWeight.w700,
        letterSpacing: -.8,
        height: 1.2,
      ),
      titleLarge: TextStyle(
        fontSize: 21,
        fontWeight: FontWeight.w700,
        height: 1.3,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.35,
      ),
      bodyMedium: TextStyle(fontSize: 14, height: 1.5),
      bodySmall: TextStyle(fontSize: 12, height: 1.45),
    ),
  );
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '雷player',
    debugShowCheckedModeBanner: false,
    locale: languageMode.locale,
    supportedLocales: AppLocalizations.supportedLocales,
    localeListResolutionCallback: AppLocalizations.resolve,
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    theme: appTheme(Brightness.light),
    darkTheme: appTheme(Brightness.dark),
    themeMode: appearance == 'dark'
        ? ThemeMode.dark
        : appearance == 'light'
        ? ThemeMode.light
        : ThemeMode.system,
    builder: (context, child) => DefaultTextStyle(
      style: Theme.of(context).textTheme.bodyMedium!,
      child: IconTheme(
        data: IconThemeData(
          color: Theme.of(context).colorScheme.onSurface,
          size: 24,
        ),
        child: child ?? const SizedBox.shrink(),
      ),
    ),
    home: LibraryPage(model: model),
  );
}
