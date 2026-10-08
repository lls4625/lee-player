import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'player_model.dart';
import 'glass_ui.dart';
import 'playback_page.dart';
import 'developer_tip.dart';
import 'app_licenses.dart';
import 'app_localizations.dart';

const _privacyPolicyUrl =
    'https://www.wlsp1881.com/leeplayer/privacy-policy.html';
const _appChannel = MethodChannel('lei.player/app');

class LegalDocumentPage extends StatelessWidget {
  const LegalDocumentPage({
    super.key,
    required this.title,
    required this.content,
    this.onlineUrl,
  });

  final String title;
  final String content;
  final String? onlineUrl;

  Future<void> _openOnlineDocument(BuildContext context) async {
    var opened = false;
    try {
      opened =
          await _appChannel.invokeMethod<bool>('openUrl', <String, String>{
            'url': onlineUrl!,
          }) ??
          false;
    } on PlatformException {
      opened = false;
    } on MissingPluginException {
      opened = false;
    }
    if (opened || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          AppLocalizations.of(context).text('无法打开在线隐私政策，请稍后重试。'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final lines = content.trim().split('\n');
    if (lines.isNotEmpty && lines.first.startsWith('雷player')) {
      lines.removeAt(0);
    }
    final blocks = lines
        .join('\n')
        .trim()
        .split(RegExp(r'\n\s*\n'))
        .where((block) => block.trim().isNotEmpty)
        .toList(growable: false);
    return Scaffold(
      backgroundColor: colors.surface,
      appBar: AppBar(
        backgroundColor: colors.surface,
        foregroundColor: colors.onSurface,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: LText(title),
      ),
      body: ColoredBox(
        color: colors.surface,
        child: SafeArea(
          top: false,
          child: Scrollbar(
            child: ListView.separated(
              key: const Key('legal-document-content'),
              padding: const EdgeInsets.fromLTRB(24, 18, 24, 40),
              itemCount: blocks.length + (onlineUrl == null ? 0 : 1),
              separatorBuilder: (_, _) => const SizedBox(height: 18),
              itemBuilder: (context, index) {
                if (index == blocks.length) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: FilledButton.icon(
                      key: const Key('open-online-privacy-policy'),
                      onPressed: () => _openOnlineDocument(context),
                      icon: const Icon(Icons.open_in_new_rounded),
                      label: const LText('查看在线隐私政策'),
                    ),
                  );
                }
                final block = blocks[index].trim();
                final heading = RegExp(r'^(?:[一二三四五六七八九十]+、|\d+[.、])')
                    .hasMatch(block);
                final metadata =
                    index == 0 &&
                    (block.contains('生效日期：') ||
                        block.contains('Effective:') ||
                        block.contains('発効日：'));
                return LText(
                  block,
                  style: heading
                      ? Theme.of(context).textTheme.titleMedium
                            ?.copyWith(color: colors.onSurface, height: 1.45)
                      : Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: metadata
                              ? colors.onSurfaceVariant
                              : colors.onSurface,
                          height: 1.75,
                          letterSpacing: .1,
                        ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

PageRouteBuilder<void> _opaquePageRoute(WidgetBuilder builder) =>
    PageRouteBuilder<void>(
      opaque: true,
      allowSnapshotting: false,
      barrierColor: Colors.black,
      transitionDuration: const Duration(milliseconds: 160),
      reverseTransitionDuration: const Duration(milliseconds: 120),
      pageBuilder: (context, _, _) => builder(context),
      transitionsBuilder: (_, animation, _, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        child: child,
      ),
    );

PageRouteBuilder<void> legalDocumentRoute({
  required String title,
  required String content,
  String? onlineUrl,
}) =>
    _opaquePageRoute(
      (_) => LegalDocumentPage(
        title: title,
        content: content,
        onlineUrl: onlineUrl,
      ),
    );

PageRouteBuilder<void> openSourceLicensesRoute(ThemeData theme) {
  final colors = theme.colorScheme;
  return _opaquePageRoute(
    (context) => Theme(
      key: const Key('open-source-licenses-page'),
      data: theme.copyWith(
        scaffoldBackgroundColor: colors.surface,
        appBarTheme: theme.appBarTheme.copyWith(
          backgroundColor: colors.surface,
          foregroundColor: colors.onSurface,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
        ),
      ),
      child: LicensePage(
        applicationName: '雷player',
        applicationLegalese: AppLocalizations.of(context).text(
          'Copyright © 2026 李连顺. All rights reserved.\n第三方组件适用各自许可证；用户支持 QQ 群：1126527885',
        ),
      ),
    ),
  );
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.model});
  final PlayerModel model;
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> with WidgetsBindingObserver {
  PlayerModel get m => widget.model;
  late final DeveloperTipController developerTip = DeveloperTipController();
  int tab = 0;
  String folder = '';
  bool playerVisible = false;
  int? settingsSwipePointer;
  Offset? settingsSwipeStart;
  Offset? settingsSwipePosition;
  final Set<String> savingPreferences = {};
  bool savingAppearance = false;
  bool savingLanguage = false;
  List<MediaEntry>? cachedSource;
  List<MediaEntry> cachedVisible = [];
  Object? cachedQuery;
  List<MediaEntry>? countedSource;
  final Map<String, int> folderCounts = {};
  int folderCount(String path) {
    if (!identical(countedSource, m.entries)) {
      folderCounts.clear();
      for (final entry in m.entries) {
        folderCounts.update(
          entry.parent,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
      countedSource = m.entries;
    }
    return folderCounts[path] ?? 0;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    m.addListener(changed);
    m.onOpenPlayer = showPlayer;
    unawaited(m.initialize());
  }

  void changed() {
    if (!mounted) return;
    setState(() {});
    if (m.message != null) {
      final message = m.message!;
      m.consumeMessage();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showLeiMessageToast(context, message);
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(m.refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    m.removeListener(changed);
    m.onOpenPlayer = null;
    developerTip.dispose();
    super.dispose();
  }

  Future<void> showDeveloperTip() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DeveloperTipPage(controller: developerTip),
      ),
    );
  }

  Future<void> acknowledgePiPRestore(String? restoreToken) async {
    await m.command(
      'pipRestored',
      args: restoreToken == null ? null : {'restoreToken': restoreToken},
    );
  }

  Future<void> showPlayer([String? restoreToken]) async {
    if (!mounted || m.path.isEmpty) return;
    if (playerVisible) {
      await acknowledgePiPRestore(restoreToken);
      return;
    }
    playerVisible = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(acknowledgePiPRestore(restoreToken));
    });
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => PlaybackPage(model: m)));
    playerVisible = false;
  }

  List<MediaEntry> get visible {
    final query = (
      tab,
      folder,
      m.libraryLayout,
      m.librarySort,
      m.librarySortAscending,
      m.libraryRevision,
      m.path,
    );
    if (identical(cachedSource, m.entries) && cachedQuery == query)
      return cachedVisible;
    final items = m.entries.where((e) {
      if (tab == 1 && (!e.isPlayable || m.record(e.path)['lastPlayed'] == null))
        return false;
      if (tab == 2 && m.record(e.path)['favorite'] != true) return false;
      if ((tab == 0 || tab == 3) && e.parent != folder) return false;
      return true;
    }).toList();
    items.sort((a, b) {
      if (tab == 1)
        return ((m.record(b.path)['lastPlayed'] as num?) ?? 0).compareTo(
          (m.record(a.path)['lastPlayed'] as num?) ?? 0,
        );
      if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
      int result;
      switch (m.librarySort) {
        case 'type':
          result = a.isFolder
              ? naturalCompare(a.name, b.name)
              : naturalCompare(a.extension, b.extension);
          break;
        case 'size':
          result = a.size.compareTo(b.size);
          break;
        case 'date':
          result = a.modified.compareTo(b.modified);
          break;
        default:
          result = naturalCompare(a.name, b.name);
      }
      if (result == 0) result = naturalCompare(a.name, b.name);
      return m.librarySortAscending ? result : -result;
    });
    cachedSource = m.entries;
    cachedQuery = query;
    cachedVisible = items;
    return items;
  }

  Future<void> open(MediaEntry entry, {bool resume = true}) async {
    if (entry.isFolder) {
      setState(() {
        tab = 0;
        folder = entry.path;
      });
      return;
    }
    if (!entry.isPlayable) {
      await info(entry);
      return;
    }
    final files =
        m.entries
            .where((e) => e.isPlayable && e.parent == entry.parent)
            .toList()
          ..sort((a, b) => naturalCompare(a.name, b.name));
    if (await m.open(files, entry, resume: resume)) await showPlayer();
  }

  Future<String?> input(String title, {String value = ''}) async {
    final controller = TextEditingController(text: value);
    var submitted = false;
    void submit(String? value) {
      if (submitted) return;
      submitted = true;
      final navigator = Navigator.of(context, rootNavigator: true);
      if (navigator.canPop()) navigator.pop(value);
    }

    final result = await showLeiDialog<String>(
      context: context,
      title: title,
      content: GlassTextField(
        controller: controller,
        autofocus: true,
        onSubmitted: (value) => submit(value.trim()),
      ),
      actions: [
        GlassDialogAction(label: '取消', onPressed: () => submit(null)),
        GlassDialogAction(
          label: '确定',
          onPressed: () => submit(controller.text.trim()),
        ),
      ],
    );
    // The dialog route can still be animating after its result completes.
    Future<void>.delayed(const Duration(seconds: 1), controller.dispose);
    return result;
  }

  Future<bool> confirm(
    String title,
    String body, {
    Map<String, Object?> bodyArgs = const <String, Object?>{},
  }) async =>
      await showLeiDialog<bool>(
        context: context,
        title: title,
        message: body,
        messageArgs: bodyArgs,
        actions: [
          GlassDialogAction(
            label: '取消',
            onPressed: () =>
                Navigator.of(context, rootNavigator: true).pop(false),
          ),
          GlassDialogAction(
            label: '确定',
            onPressed: () =>
                Navigator.of(context, rootNavigator: true).pop(true),
          ),
        ],
      ) ??
      false;
  Future<void> add() async {
    final action = await showLeiSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .65,
          child: Column(
            children: [
              const LeiSheetHeading(
                title: '添加课程',
                subtitle: '选择导入方式，或先建立课程文件夹。',
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 20),
                  children: [
                    LeiGlassTile(
                      leading: const LeiMediaIcon(
                        icon: Icons.drive_folder_upload_outlined,
                      ),
                      title: const LText('导入课程文件夹'),
                      subtitle: const LText('保留课程目录与子文件夹'),
                      onTap: () => Navigator.pop(context, 'folder'),
                    ),
                    LeiGlassTile(
                      leading: const LeiMediaIcon(
                        icon: Icons.file_upload_outlined,
                      ),
                      title: const LText('选择媒体文件'),
                      subtitle: const LText('视频、音频及外置字幕'),
                      onTap: () => Navigator.pop(context, 'files'),
                    ),
                    LeiGlassTile(
                      leading: const LeiMediaIcon(
                        icon: Icons.create_new_folder_outlined,
                      ),
                      title: const LText('新建文件夹'),
                      subtitle: const LText('按课程或章节整理内容'),
                      onTap: () => Navigator.pop(context, 'new'),
                    ),
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: LText('导入会复制到 App 课程目录，原文件保留；重名文件自动编号。'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'new') {
      final name = await input('新建文件夹');
      if (name != null && name.isNotEmpty) {
        await m.command('createFolder', args: {'parent': folder, 'name': name});
        await m.refresh();
      }
    } else {
      await m.importMedia(folder: action == 'folder', parent: folder);
    }
  }

  Future<void> info(MediaEntry e) async {
    final modified = DateTime.fromMillisecondsSinceEpoch(
      (e.modified * 1000).round(),
    ).toLocal();
    final material = MaterialLocalizations.of(context);
    final modifiedLabel =
        '${material.formatFullDate(modified)} '
        '${material.formatTimeOfDay(TimeOfDay.fromDateTime(modified))}';
    final typeLabel = AppLocalizations.of(context).text(
      switch (e.kind) {
        'folder' => '文件夹',
        'video' => '视频',
        'audio' => '音频',
        'subtitle' => '字幕',
        _ => '文件',
      },
    );
    await showLeiDialog<void>(
      context: context,
      title: e.name,
      localizeTitle: false,
      content: LSelectableText(
        '路径：{path}\n类型：{type}\n大小：{size}\n修改时间：{modified}',
        args: {
          'path': e.path,
          'type': typeLabel,
          'size': sizeLabel(e.size),
          'modified': modifiedLabel,
        },
      ),
      actions: [
        GlassDialogAction(
          label: '关闭',
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
      ],
    );
  }

  Future<void> action(MediaEntry e, String action) async {
    switch (action) {
      case 'favorite':
        await m.favorite(e);
        break;
      case 'start':
        await open(e, resume: false);
        break;
      case 'info':
        await info(e);
        break;
      case 'rename':
        final name = await input('重命名（请保留文件扩展名）', value: e.name);
        if (name != null && name.isNotEmpty && name != e.name) {
          await m.command(
            'move',
            args: {'path': e.path, 'parent': e.parent, 'name': name},
          );
          await m.refresh();
        }
        break;
      case 'move':
        final folders =
            m.entries
                .where(
                  (v) =>
                      v.isFolder &&
                      v.path != e.path &&
                      !v.path.startsWith('${e.path}/'),
                )
                .toList()
              ..sort((a, b) => naturalCompare(a.path, b.path));
        final destination = await showLeiSheet<String>(
          context: context,
          builder: (context) => SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .65,
              child: ListView(
                children: [
                  const LeiSheetHeading(title: '移动到文件夹', subtitle: '选择目标目录'),
                  LeiGlassTile(
                    title: const LText('课程库根目录'),
                    onTap: () => Navigator.pop(context, ''),
                  ),
                  for (final f in folders)
                    LeiGlassTile(
                      leading: const LeiMediaIcon(icon: Icons.folder_outlined),
                      title: Text(f.path),
                      onTap: () => Navigator.pop(context, f.path),
                    ),
                ],
              ),
            ),
          ),
        );
        if (destination != null && destination != e.parent) {
          await m.command(
            'move',
            args: {'path': e.path, 'parent': destination, 'name': e.name},
          );
          await m.refresh();
        }
        break;
      case 'trash':
        if (await confirm(
          '移入回收站？',
          '{name}\n相关播放队列会停止。可在设置中恢复。',
          bodyArgs: {'name': e.name},
        )) {
          await m.command('trash', args: {'path': e.path});
          await m.refresh();
        }
        break;
    }
  }

  Future<void> trash() async {
    List<dynamic> items = [];
    if (!await m.command(
          'trashList',
          onValue: (value) => items = value as List,
        ) ||
        !mounted)
      return;
    final token = await showLeiSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .65,
          child: ListView(
            children: [
              const LeiSheetHeading(
                title: '回收站',
                subtitle: '按删除时间排列，点击文件即可恢复到原位置',
              ),
              if (items.isEmpty)
                const LeiGlassTile(
                  leading: LeiMediaIcon(icon: Icons.delete_outline),
                  title: LText('回收站为空'),
                  subtitle: LText('移除的文件会暂存于此'),
                ),
              for (final item in items)
                LeiGlassTile(
                  title: item['recoverable'] == false
                      ? const LText('异常回收项目')
                      : Text('${item['path']}'),
                  subtitle: item['recoverable'] == false
                      ? const LText('原路径或文件信息已损坏，可通过清空回收站删除')
                      : null,
                  trailing: LeiMediaIcon(
                    icon: item['recoverable'] == false
                        ? Icons.warning_amber_rounded
                        : Icons.restore,
                  ),
                  onTap: item['recoverable'] == false
                      ? null
                      : () => Navigator.pop(context, '${item['token']}'),
                ),
              if (items.isNotEmpty)
                LeiGlassTile(
                  leading: const LeiMediaIcon(icon: Icons.delete_forever),
                  title: LText(
                    '清空回收站',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  onTap: () => Navigator.pop(context, '__empty__'),
                ),
            ],
          ),
        ),
      ),
    );
    if (token == null || !mounted) return;
    if (token == '__empty__') {
      if (await confirm('永久删除？', '回收站内所有文件将永久删除，无法恢复。'))
        await m.command('emptyTrash');
    } else {
      await m.command('restore', args: {'token': token});
    }
    await m.refresh();
  }

  static const appearances = {'system': '跟随系统', 'light': '浅色', 'dark': '深色'};
  Future<void> savePreference(String key, bool value) async {
    if (savingPreferences.contains(key)) return;
    setState(() => savingPreferences.add(key));
    try {
      await m.configure({key: value});
    } finally {
      if (mounted) setState(() => savingPreferences.remove(key));
    }
  }

  Future<void> editJumpSeconds(String key, String title) async {
    if (savingPreferences.contains(key)) return;
    final current = m.number(key, 15).round().clamp(1, 300);
    final controller = TextEditingController(text: '$current');
    String? error;
    StateSetter? dialogSetState;
    void submit() {
      final seconds = int.tryParse(controller.text.trim());
      if (seconds == null || seconds < 1 || seconds > 300) {
        dialogSetState?.call(() => error = '请输入 1～300 之间的整数秒数');
        return;
      }
      Navigator.of(context, rootNavigator: true).pop(seconds);
    }

    final value = await showLeiDialog<int>(
      context: context,
      title: title,
      fixedNearTop: true,
      content: StatefulBuilder(
        builder: (context, setDialogState) {
          dialogSetState = setDialogState;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GlassTextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                maxLength: 3,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (_) {
                  if (error != null) setDialogState(() => error = null);
                },
                onSubmitted: (_) => submit(),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: LText(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
      actions: [
        GlassDialogAction(
          label: '取消',
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
        GlassDialogAction(label: '确定', onPressed: submit),
      ],
    );
    Future<void>.delayed(const Duration(seconds: 1), controller.dispose);
    if (value == null || value == current || !mounted) return;
    setState(() => savingPreferences.add(key));
    try {
      await m.configure({key: value});
    } finally {
      if (mounted) setState(() => savingPreferences.remove(key));
    }
  }

  Widget jumpSecondsPreference(IconData icon, String title, String key) {
    final saving = savingPreferences.contains(key);
    final seconds = m.number(key, 15).round().clamp(1, 300);
    return LeiGlassTile(
      flat: true,
      leading:
          MediaQuery.sizeOf(context).width < 360 ||
              MediaQuery.textScalerOf(context).scale(14) > 20
          ? null
          : LeiMediaIcon(icon: icon),
      title: LText(title),
      subtitle: LText(
        saving ? '正在保存…' : '{seconds} 秒',
        args: {'seconds': seconds},
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: saving
          ? const SizedBox(
              width: 52,
              child: Center(child: GlassProgressIndicator.circular(size: 22)),
            )
          : null,
      onTap: saving ? null : () => editJumpSeconds(key, title),
    );
  }

  Future<void> saveAppearance(String value) async {
    if (savingAppearance || value == m.appearance) return;
    setState(() => savingAppearance = true);
    try {
      await m.setAppearance(value);
    } finally {
      if (mounted) setState(() => savingAppearance = false);
    }
  }

  Future<void> saveLanguage(AppLanguageMode value) async {
    if (savingLanguage || value == m.languageMode) return;
    setState(() => savingLanguage = true);
    try {
      await m.setLanguage(value);
    } finally {
      if (mounted) setState(() => savingLanguage = false);
    }
  }

  Widget languagePreference() {
    const options = <(AppLanguageMode, String)>[
      (AppLanguageMode.system, '跟随系统'),
      (AppLanguageMode.zhHans, '简体中文'),
      (AppLanguageMode.zhHant, '繁體中文'),
      (AppLanguageMode.ja, '日文'),
      (AppLanguageMode.en, '英语'),
    ];
    final localizations = AppLocalizations.of(context);
    final currentLabel = options
        .firstWhere((option) => option.$1 == m.languageMode)
        .$2;
    final currentText = localizations.text(currentLabel);
    final titleText = localizations.text('语言');
    final textScaler = MediaQuery.textScalerOf(context);
    final availableHeight =
        MediaQuery.sizeOf(context).height -
        MediaQuery.paddingOf(context).vertical -
        24;
    final naturalItemHeight = textScaler.scale(17) * 1.35 + 16;
    final itemHeight = naturalItemHeight < 48 ? 48.0 : naturalItemHeight;
    final menuHeight =
        (24 + options.length * itemHeight + (options.length - 1) * 2)
            .clamp(0.0, availableHeight)
            .toDouble();

    return LayoutBuilder(
      builder: (context, constraints) {
        final fieldWidth = constraints.maxWidth > 16
            ? constraints.maxWidth - 16
            : constraints.maxWidth;
        final stacked = fieldWidth < 300 || textScaler.scale(16) > 22;
        final menuWidth = fieldWidth < 220
            ? fieldWidth
            : fieldWidth.clamp(220.0, 300.0).toDouble();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: GlassMenu(
            autoAdjustToScreen: true,
            menuAlignment: GlassMenuAlignment.topRight,
            menuWidth: menuWidth,
            menuHeight: menuHeight,
            menuPadding: const EdgeInsets.all(12),
            triggerBuilder: (context, toggleMenu) => GlassButton.custom(
              label: '$titleText：$currentText',
              enabled: !savingLanguage,
              width: fieldWidth,
              shape: leiRoundedControlShape,
              onTap: toggleMenu,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: stacked ? 64 : 52),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: stacked
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            LText(
                              '语言',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                Flexible(
                                  child: LText(
                                    currentLabel,
                                    maxLines: 2,
                                    textAlign: TextAlign.end,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                if (savingLanguage)
                                  const GlassProgressIndicator.circular(
                                    size: 20,
                                  )
                                else
                                  const Icon(
                                    Icons.unfold_more_rounded,
                                    size: 20,
                                  ),
                              ],
                            ),
                          ],
                        )
                      : Row(
                          children: [
                            Expanded(
                              child: Align(
                                alignment: AlignmentDirectional.centerStart,
                                child: LText(
                                  '语言',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  Flexible(
                                    child: LText(
                                      currentLabel,
                                      maxLines: 1,
                                      textAlign: TextAlign.end,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  if (savingLanguage)
                                    const GlassProgressIndicator.circular(
                                      size: 20,
                                    )
                                  else
                                    const Icon(
                                      Icons.unfold_more_rounded,
                                      size: 20,
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ),
            items: [
              for (final option in options)
                GlassMenuItem(
                  title: localizations.text(option.$2),
                  height: itemHeight,
                  enabled: !savingLanguage,
                  isSelected: option.$1 == m.languageMode,
                  trailing: option.$1 == m.languageMode
                      ? Icon(
                          Icons.check_rounded,
                          color: leiAccent(context),
                          size: 20,
                        )
                      : null,
                  onTap: () => saveLanguage(option.$1),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget preference(IconData icon, String title, String subtitle, String key) {
    final saving = savingPreferences.contains(key);
    return LeiGlassTile(
      flat: true,
      leading:
          MediaQuery.sizeOf(context).width < 360 ||
              MediaQuery.textScalerOf(context).scale(14) > 20
          ? null
          : LeiMediaIcon(icon: icon),
      title: LText(title),
      subtitle: LText(
        saving ? '正在保存…' : subtitle,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      onTap: saving ? null : () => savePreference(key, m.state[key] == false),
      trailing: saving
          ? Semantics(
              label: AppLocalizations.of(context).text(
                '{title}正在保存',
                args: {'title': AppLocalizations.of(context).text(title)},
              ),
              child: const SizedBox(
                width: 52,
                child: Center(child: GlassProgressIndicator.circular(size: 22)),
              ),
            )
          : GlassSwitch(
              value: m.state[key] != false,
              onChanged: (value) => savePreference(key, value),
            ),
    );
  }

  Widget settingSection(
    String title,
    List<Widget> children, {
    String? footer,
    bool showTitle = true,
  }) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showTitle)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
            child: LText(title, style: Theme.of(context).textTheme.titleMedium),
          ),
        LeiSurface(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(children: children),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
            child: LText(
              footer,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    ),
  );

  Widget appearanceCard(String key, String label) {
    final selected = m.appearance == key;
    final dark = key == 'dark';
    return Semantics(
      selected: selected,
      button: true,
      label: AppLocalizations.of(context).text(
        '{label}外观',
        args: {'label': AppLocalizations.of(context).text(label)},
      ),
      child: GlassButton.custom(
        label: AppLocalizations.of(context).text(
          '{label}外观',
          args: {'label': AppLocalizations.of(context).text(label)},
        ),
        enabled: !savingAppearance,
        shape: leiRoundedControlShape,
        onTap: () => saveAppearance(key),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected
                  ? leiAccent(context)
                  : Theme.of(context).colorScheme.outline
                        .withValues(alpha: .16),
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            children: [
              Container(
                height: 54,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(9),
                  gradient: LinearGradient(
                    colors: key == 'system'
                        ? const [Color(0xfff5f2e9), Color(0xff25262e)]
                        : dark
                        ? const [Color(0xff25262e), Color(0xff17181d)]
                        : const [Color(0xfffffaf0), Color(0xffeef0f5)],
                  ),
                ),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Container(
                    height: 12,
                    width: 36,
                    decoration: BoxDecoration(
                      color: leiGold,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              LText(
                label,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelMedium,
              ),
              const SizedBox(height: 6),
              LeiMediaIcon(
                icon: selected
                    ? Icons.check_circle_rounded
                    : Icons.circle_outlined,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> showLegalDocument(
    String title,
    String asset, {
    String? onlineUrl,
  }) async {
    final code = AppLocalizations.of(context).code;
    final localizedAsset = code == 'zh-Hans'
        ? asset
        : asset
              .replaceFirst('.txt', '.$code.txt')
              .replaceFirst('assets/legal/', 'assets/legal/l10n/');
    final content = await rootBundle.loadString(localizedAsset);
    if (!mounted) return;
    await Navigator.of(context).push(
      legalDocumentRoute(
        title: title,
        content: content,
        onlineUrl: onlineUrl,
      ),
    );
  }

  void showOpenSourceLicenses() {
    // Registration itself is synchronous; LicensePage loads the asset text
    // lazily. Keep this transition immediate, like the other legal pages.
    ensureAppLicensesRegistered();
    Navigator.of(context).push(openSourceLicensesRoute(Theme.of(context)));
  }

  void startSettingsSwipe(PointerDownEvent event) {
    if (event.localPosition.dx > 32 || settingsSwipePointer != null) return;
    settingsSwipePointer = event.pointer;
    settingsSwipeStart = event.localPosition;
    settingsSwipePosition = event.localPosition;
  }

  void updateSettingsSwipe(PointerMoveEvent event) {
    if (event.pointer == settingsSwipePointer) {
      settingsSwipePosition = event.localPosition;
    }
  }

  void finishSettingsSwipe(PointerEvent event) {
    if (event.pointer != settingsSwipePointer) return;
    final start = settingsSwipeStart;
    final end = settingsSwipePosition ?? event.localPosition;
    settingsSwipePointer = null;
    settingsSwipeStart = null;
    settingsSwipePosition = null;
    if (start == null) return;
    final delta = end - start;
    final isRightEdgeSwipe = delta.dx >= 72 && delta.dx > delta.dy.abs() * 1.2;
    if (tab == 3 && isRightEdgeSwipe) {
      setState(() => tab = 0);
    }
  }

  void cancelSettingsSwipe(PointerCancelEvent event) {
    if (event.pointer != settingsSwipePointer) return;
    settingsSwipePointer = null;
    settingsSwipeStart = null;
    settingsSwipePosition = null;
  }

  Widget settings() {
    final sections = <Widget Function()>[
      () => const LeiSectionHeading(
        key: Key('settings-heading'),
        title: '设置',
        subtitle: '让播放器适合你的学习习惯。',
      ),
      () => settingSection(
        '语言',
        [languagePreference()],
        footer: '选择后全局生效并自动保存。跟随系统会使用系统首选语言，不支持时显示英语。',
        showTitle: false,
      ),
      () => settingSection('外观', [
        Padding(
          padding: const EdgeInsets.all(12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final stacked =
                  constraints.maxWidth < 280 ||
                  MediaQuery.textScalerOf(context).scale(14) > 20;
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final option in appearances.entries)
                    SizedBox(
                      width: stacked
                          ? constraints.maxWidth
                          : (constraints.maxWidth - 16) / 3,
                      child: appearanceCard(option.key, option.value),
                    ),
                ],
              );
            },
          ),
        ),
      ], footer: savingAppearance ? '正在保存外观…' : '选择后立即生效，自动保存。'),
      () => settingSection('播放', [
        preference(
          Icons.history_rounded,
          '记住播放进度',
          '下次打开，从上次停下的位置继续',
          'rememberProgress',
        ),
        preference(
          Icons.auto_awesome_outlined,
          '智能跳过空白片头',
          '仅跳过同时黑屏且静音的开头',
          'smartIntro',
        ),
        preference(
          Icons.playlist_play_rounded,
          '自动连续播放',
          '当前课程结束后，接着播放队列',
          'continuous',
        ),
        jumpSecondsPreference(Icons.replay_rounded, '后退秒数', 'rewindSeconds'),
        jumpSecondsPreference(Icons.forward_rounded, '前进秒数', 'forwardSeconds'),
      ], footer: '关闭进度记忆后从头播放，已有记录保留。断点续播优先于片头跳过；倍速与循环模式可在播放页调整。'),
      () => settingSection('后台与中断', [
        const LeiGlassTile(
          flat: true,
          leading: LeiMediaIcon(icon: Icons.headphones_rounded),
          title: LText('后台播放始终开启'),
          subtitle: LText('锁屏或切换应用时继续播放音频；不会自动进入画中画'),
        ),
        preference(
          Icons.play_circle_outline,
          '中断恢复',
          '通话结束后尝试恢复播放',
          'autoResume',
        ),
      ], footer: '仅在中断前正在播放、且 iOS 允许时恢复。'),
      () => settingSection('文件与记录', [
        LeiGlassTile(
          flat: true,
          leading: const LeiMediaIcon(icon: Icons.restore_from_trash_outlined),
          title: const LText('回收站'),
          subtitle: const LText('找回已移除的文件'),
          onTap: trash,
        ),
        LeiGlassTile(
          flat: true,
          leading: const LeiMediaIcon(icon: Icons.history_rounded),
          title: const LText('清除播放历史'),
          subtitle: const LText('保留收藏和媒体文件'),
          onTap: () async {
            if (await confirm('清除历史？', '收藏和视频文件保留；开启“记住播放进度”时会重新记录当前进度。')) {
              await m.command('clearHistory');
              await m.loadRecords();
            }
          },
        ),
      ]),
      () => settingSection('支持开发', [
        LeiGlassTile(
          flat: true,
          leading: const LeiMediaIcon(icon: Icons.volunteer_activism_outlined),
          title: const LText('打赏开发者'),
          subtitle: const LText('通过 App Store 自愿支持，不解锁任何功能'),
          onTap: showDeveloperTip,
        ),
      ], footer: '打赏为可重复购买的消耗型项目，完全自愿且不可恢复；雷player 始终免费、无广告。'),
      () => settingSection('关于雷player', [
        const LeiGlassTile(
          flat: true,
          leading: LeiMediaIcon(icon: Icons.bolt_rounded),
          title: LText('雷player'),
          subtitle: LText(
            '专注本地课程，陪你随时进入学习。\n'
            '爱学习的人最可爱。\n'
            '每天多学一点，未来就多一种可能。\n'
            '慢一点也没关系，坚持的每一步都算数。\n'
            '愿雷player陪你保持好奇，不断成长。',
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: LText(
            '文件存于 App 自有目录，可通过系统“文件”或 Finder 文件共享管理。卸载 App 会移除其数据，请保留课程原文件。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: LText(
            '使用 iOS 系统播放能力，实际格式兼容与流畅度取决于编码、系统版本和设备。支持外置 SRT / VTT；外置字幕不会显示在系统画中画中。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        LeiGlassTile(
          flat: true,
          leading: const LeiMediaIcon(icon: Icons.privacy_tip_outlined),
          title: const LText('隐私政策'),
          subtitle: const LText('本地数据处理、保留与联系信息'),
          onTap: () => showLegalDocument(
            '隐私政策',
            'assets/legal/PRIVACY_POLICY.txt',
            onlineUrl: _privacyPolicyUrl,
          ),
        ),
        LeiGlassTile(
          flat: true,
          leading: const LeiMediaIcon(icon: Icons.code_rounded),
          title: const LText('开源软件许可'),
          subtitle: const LText('Flutter、Dart 与原生播放器版权、源码及许可证'),
          onTap: showOpenSourceLicenses,
        ),
        LeiGlassTile(
          flat: true,
          leading: const LeiMediaIcon(icon: Icons.copyright_rounded),
          title: const LText('版权与用户内容'),
          subtitle: const LText('版权所有者、用户责任与合规联系'),
          onTap: () =>
              showLegalDocument('版权与用户内容', 'assets/legal/COPYRIGHT_NOTICE.txt'),
        ),
      ]),
    ];
    return ListView.builder(
      key: const Key('settings-list'),
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: sections.length,
      itemBuilder: (context, index) => sections[index](),
    );
  }

  Future<void> commonAction(String value) async {
    switch (value) {
      case 'new':
        if (m.importing || m.scanning) return;
        final name = await input('新建文件夹');
        if (name != null && name.isNotEmpty) {
          await m.command(
            'createFolder',
            args: {'parent': folder, 'name': name},
          );
          await m.refresh();
        }
        break;
      case 'import':
        if (!m.importing && !m.scanning) await add();
        break;
      case 'refresh':
        await m.refresh();
        break;
      case 'move':
        if (m.importing || m.scanning) return;
        final candidates = List<MediaEntry>.of(visible);
        final entry = await showLeiSheet<MediaEntry>(
          context: context,
          builder: (context) => SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .65,
              child: Column(
                children: [
                  const LeiSheetHeading(
                    title: '移动文件',
                    subtitle: '选择文件或文件夹，再选择目标目录',
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        if (candidates.isEmpty)
                          const LeiGlassTile(title: LText('当前目录没有可移动的内容')),
                        for (final e in candidates)
                          LeiGlassTile(
                            title: Text(e.name),
                            leading: LeiMediaIcon(
                              icon: e.isFolder
                                  ? Icons.folder_outlined
                                  : Icons.description_outlined,
                            ),
                            onTap: () => Navigator.pop(context, e),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        if (entry != null && mounted) await action(entry, 'move');
        break;
      case 'library':
        setState(() => tab = 0);
        break;
      case 'history':
        setState(() => tab = 1);
        break;
      case 'favorites':
        setState(() => tab = 2);
        break;
    }
  }

  Future<void> setLibraryLayout(String value) async {
    if (value == m.libraryLayout) return;
    await m.setLibraryPreferences(layout: value);
  }

  Future<void> setLibrarySort(String value) async {
    final ascending = value == m.librarySort ? !m.librarySortAscending : true;
    await m.setLibraryPreferences(sort: value, ascending: ascending);
  }

  Widget menuCheck(bool selected) => SizedBox(
    width: 20,
    child: selected ? const Icon(Icons.check_rounded) : null,
  );

  List<Widget> commonMenuItems() {
    final localizations = AppLocalizations.of(context);
    const layouts = {
      'list': ('列表', Icons.view_list_rounded),
      'grid': ('网格', Icons.grid_view_rounded),
    };
    const sorts = {'name': '名称', 'type': '类型', 'size': '大小', 'date': '日期'};
    Widget actionItem(String title, String value) => GlassMenuItem(
      title: localizations.text(title),
      height: 48,
      onTap: () => commonAction(value),
    );
    return [
      if (!m.importing && !m.scanning) ...[
        actionItem('新建文件夹', 'new'),
        actionItem('移动文件', 'move'),
        actionItem('导入文件 / 文件夹', 'import'),
        const GlassMenuDivider(),
      ],
      for (final option in layouts.entries)
        GlassMenuItem(
          title: localizations.text(option.value.$1),
          height: 48,
          icon: menuCheck(m.libraryLayout == option.key),
          trailing: Icon(option.value.$2),
          onTap: () => setLibraryLayout(option.key),
        ),
      const GlassMenuDivider(),
      for (final option in sorts.entries)
        GlassMenuItem(
          title: localizations.text(option.value),
          height: 48,
          icon: menuCheck(m.librarySort == option.key),
          trailing: m.librarySort == option.key
              ? Icon(
                  m.librarySortAscending
                      ? Icons.arrow_upward_rounded
                      : Icons.arrow_downward_rounded,
                )
              : null,
          onTap: () => setLibrarySort(option.key),
        ),
      const GlassMenuDivider(),
      if (!m.scanning && !m.importing) actionItem('刷新文件', 'refresh'),
      actionItem('课程库', 'library'),
      actionItem('最近播放', 'history'),
      actionItem('我的收藏', 'favorites'),
    ];
  }

  MediaEntry? get resumeEntry {
    final current = m.entry(m.path);
    if (current != null && current.isPlayable) return current;
    if (m.state['rememberProgress'] == false) return null;
    MediaEntry? latest;
    num lastPlayed = -1;
    for (final entry in m.entries) {
      if (!entry.isPlayable) continue;
      final record = m.record(entry.path);
      final position = (record['position'] as num?) ?? 0;
      final duration = (record['duration'] as num?) ?? 0;
      final played = (record['lastPlayed'] as num?) ?? 0;
      if (position <= 0 || (duration > 0 && position >= duration)) continue;
      if (played > lastPlayed) {
        latest = entry;
        lastPlayed = played;
      }
    }
    return latest;
  }

  Widget resumeCard(MediaEntry entry) {
    final current = entry.path == m.path;
    final record = m.record(entry.path);
    final position = current
        ? m.position
        : (record['position'] as num?)?.toDouble() ?? 0;
    final duration = current
        ? m.duration
        : (record['duration'] as num?)?.toDouble() ?? 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LText('继续学习', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          LeiSurface(
            accent: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LeiMediaIcon(
                      icon: entry.isAudio
                          ? Icons.headphones_rounded
                          : Icons.play_lesson_outlined,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          entry.parent.isEmpty
                              ? LText(
                                  '当前课程',
                                  style: Theme.of(context).textTheme.bodySmall,
                                )
                              : Text(
                                  entry.parent.split('/').last,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                          const SizedBox(height: 6),
                          Text(
                            entry.name,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                LText(
                  '{status} {position} / {duration}',
                  args: {
                    'status': AppLocalizations.of(context).text(
                      current && m.loading
                          ? '正在加载'
                          : current && m.playing
                          ? '正在播放'
                          : '已播',
                    ),
                    'position': timeLabel(position),
                    'duration': timeLabel(duration),
                  },
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                GlassProgressIndicator.linear(
                  minWidth: 0,
                  height: 3,
                  value: duration > 0
                      ? (position / duration).clamp(0, 1).toDouble()
                      : 0,
                  color: leiAccent(context),
                  semanticLabel: AppLocalizations.of(context).text('当前课程播放进度'),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: LeiGlassButton(
                        label: current && (m.playing || m.loading)
                            ? '返回播放'
                            : '继续播放',
                        icon: Icons.play_arrow_rounded,
                        onPressed: () async {
                          if (current) {
                            if (!m.playing && !m.loading) await m.toggle();
                            if (mounted) await showPlayer();
                          } else {
                            await open(entry);
                          }
                        },
                      ),
                    ),
                    if (current && (m.playing || m.loading)) ...[
                      const SizedBox(width: 10),
                      LeiGlassIconButton(
                        icon: const Icon(Icons.pause_rounded),
                        tooltip: m.loading ? '取消加载' : '暂停',
                        onPressed: m.toggle,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget libraryHeader() {
    final resume = resumeEntry;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (tab != 0 || folder.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Row(
              children: [
                LeiGlassIconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  tooltip: '返回',
                  onPressed: () => setState(() {
                    if (tab != 0) {
                      tab = 0;
                    } else {
                      folder = folder.contains('/')
                          ? folder.substring(0, folder.lastIndexOf('/'))
                          : '';
                    }
                  }),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: LText(
                    tab == 1
                        ? '最近播放'
                        : tab == 2
                        ? '我的收藏'
                        : folder.split('/').last,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
          ),
        if (tab == 0 && resume != null) resumeCard(resume),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget emptyLibrary() => Padding(
    padding: const EdgeInsets.all(24),
    child: LeiSurface(
      child: SizedBox(
        key: Key(
          m.initializing
              ? 'library-initializing-content'
              : 'library-empty-content',
        ),
        width: double.infinity,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            LeiMediaIcon(
              icon: tab == 1
                  ? Icons.history_rounded
                  : tab == 2
                  ? Icons.star_border_rounded
                  : Icons.folder_outlined,
            ),
            const SizedBox(height: 16),
            LText(
              m.initializing || m.scanning
                  ? '正在读取课程…'
                  : tab == 1
                  ? '还没有播放记录'
                  : tab == 2
                  ? '还没有收藏'
                  : '当前文件夹为空',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            LText(
              m.initializing
                  ? '正在加载偏好与课程索引。'
                  : tab == 0
                  ? '通过右上角菜单导入课程或新建文件夹。'
                  : tab == 1
                  ? '播放过的课程会出现在这里。'
                  : '在文件菜单或播放页中添加收藏。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    ),
  );

  IconData entryIcon(MediaEntry entry) => entry.isFolder
      ? Icons.folder_rounded
      : entry.isAudio
      ? Icons.headphones_rounded
      : entry.isVideo
      ? Icons.play_arrow_rounded
      : Icons.description_outlined;

  Widget entryMenu(MediaEntry entry, Map<String, dynamic> record) =>
      LeiGlassMenu(
        tooltip: '{name} · 更多操作',
        tooltipArgs: {'name': entry.name},
        onSelected: (value) => action(entry, value),
        choices: {
          if (entry.isPlayable)
            'favorite': record['favorite'] == true ? '取消收藏' : '收藏',
          if (entry.isPlayable) 'start': '从头播放',
          'rename': '重命名',
          'move': '移动',
          'info': '文件信息',
          'trash': '移入回收站',
        },
      );

  Widget fileRow(MediaEntry e) {
    final localizations = AppLocalizations.of(context);
    final r = m.record(e.path);
    final position = (r['position'] as num?)?.toDouble() ?? 0;
    final duration = (r['duration'] as num?)?.toDouble() ?? 0;
    final details = e.isFolder
        ? localizations.text('{count} 项 · 文件夹', args: {
            'count': folderCount(e.path),
          })
        : <String>[
            sizeLabel(e.size),
            if (e.isPlayable && position > 0)
              localizations.text('已播 {time}', args: {
                'time': timeLabel(position),
              }),
            if (r['favorite'] == true) localizations.text('已收藏'),
          ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: LeiGlassTile(
        leading: MediaQuery.textScalerOf(context).scale(14) > 20
            ? null
            : LeiMediaIcon(icon: entryIcon(e)),
        title: Text(
          e.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(
              details,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (tab != 0 && e.parent.isNotEmpty)
              Text(
                e.parent,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (e.isPlayable && duration > 0 && position > 0) ...[
              const SizedBox(height: 8),
              Semantics(
                label: AppLocalizations.of(context).text('播放进度'),
                value: '${(position / duration * 100).clamp(0, 100).round()}%',
                child: GlassProgressIndicator.linear(
                  value: (position / duration).clamp(0, 1).toDouble(),
                  height: 3,
                  minWidth: 0,
                  color: leiAccent(context),
                  backgroundColor: leiAccent(context).withValues(alpha: .1),
                ),
              ),
            ],
          ],
        ),
        onTap: () => open(e),
        trailing: entryMenu(e, r),
      ),
    );
  }

  Widget fileGridCard(MediaEntry entry) {
    final record = m.record(entry.path);
    return Stack(
      children: [
        Positioned.fill(
          child: Semantics(
            button: true,
            label: entry.name,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => open(entry),
              child: LeiSurface(
                padding: const EdgeInsets.fromLTRB(14, 18, 14, 14),
                child: SizedBox.expand(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      LeiMediaIcon(icon: entryIcon(entry)),
                      const SizedBox(height: 14),
                      Text(
                        entry.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (entry.isFolder) ...[
                        const SizedBox(height: 6),
                        LText(
                          '{count} 项',
                          args: {'count': folderCount(entry.path)},
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(top: 8, right: 8, child: entryMenu(entry, record)),
      ],
    );
  }

  Widget importStatus() {
    final done = (m.importProgress?['done'] as num?)?.toInt() ?? 0;
    final total = (m.importProgress?['total'] as num?)?.toInt() ?? 0;
    final progressName = m.importProgress?['name'] as String?;
    final progressCode = m.importProgress?['nameCode'] as String?;
    final title =
        progressName ??
        (progressCode == null
            ? AppLocalizations.of(context).text('请选择要导入的文件')
            : AppLocalizations.of(context).message(AppMessage(progressCode)));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: LeiSurface(
        accent: true,
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            LeiGlassTile(
              dense: true,
              title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: LText(
                total > 0
                    ? '${sizeLabel(done)} / ${sizeLabel(total)}'
                    : '等待选择或准备文件…',
              ),
              trailing: LeiGlassIconButton(
                icon: const Icon(Icons.close),
                tooltip: '取消导入',
                onPressed: () => m.command('cancelImport'),
              ),
            ),
            GlassProgressIndicator.linear(
              value: total > 0 ? (done / total).clamp(0, 1).toDouble() : null,
              height: 3,
              minWidth: 0,
              color: leiAccent(context),
              backgroundColor: leiAccent(context).withValues(alpha: .1),
              semanticLabel: AppLocalizations.of(context).text('课程导入进度'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = visible;
    return GlassScaffold(
      background: const LeiGlassBackground(),
      statusBarStyle: Theme.of(context).brightness == Brightness.dark
          ? GlassStatusBarStyle.light
          : GlassStatusBarStyle.dark,
      extendBody: false,
      appBar: GlassAppBar(
        centerTitle: false,
        toolbarHeight: 64,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        title: LText('雷 player', style: Theme.of(context).textTheme.titleLarge),
        actions: [
          if (tab == 0 && folder.isEmpty) ...[
            LeiGlassIconButton(
              tooltip: '打赏开发者',
              icon: const Icon(Icons.volunteer_activism_outlined),
              onPressed: showDeveloperTip,
            ),
            const SizedBox(width: 10),
          ],
          LeiGlassIconButton(
            tooltip: '综合设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => setState(() => tab = 3),
          ),
          const SizedBox(width: 10),
          LeiGlassMenu(
            tooltip: '常用操作',
            icon: Icons.more_horiz_rounded,
            onSelected: (_) {},
            items: commonMenuItems(),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: Listener(
            key: tab == 3 ? const Key('settings-swipe-area') : null,
            behavior: HitTestBehavior.translucent,
            onPointerDown: tab == 3 ? startSettingsSwipe : null,
            onPointerMove: tab == 3 ? updateSettingsSwipe : null,
            onPointerUp: tab == 3 ? finishSettingsSwipe : null,
            onPointerCancel: tab == 3 ? cancelSettingsSwipe : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Column(
                children: [
                  if (m.scanning)
                    GlassProgressIndicator.linear(color: leiAccent(context)),
                  if (m.importing) importStatus(),
                  if (tab == 3)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: LeiGlassButton(
                          label: '返回课程库',
                          icon: Icons.arrow_back_rounded,
                          onPressed: () => setState(() => tab = 0),
                        ),
                      ),
                    ),
                  Expanded(
                    child: tab == 3
                        ? settings()
                        : CustomScrollView(
                            key: PageStorageKey('library/$tab/$folder'),
                            slivers: [
                              SliverToBoxAdapter(child: libraryHeader()),
                              if (items.isEmpty)
                                SliverToBoxAdapter(child: emptyLibrary())
                              else if (m.libraryLayout == 'grid' && tab != 1)
                                SliverPadding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                  ),
                                  sliver: SliverGrid(
                                    delegate: SliverChildBuilderDelegate(
                                      (context, index) =>
                                          fileGridCard(items[index]),
                                      childCount: items.length,
                                    ),
                                    gridDelegate:
                                        const SliverGridDelegateWithMaxCrossAxisExtent(
                                          maxCrossAxisExtent: 220,
                                          mainAxisExtent: 190,
                                          crossAxisSpacing: 8,
                                          mainAxisSpacing: 8,
                                        ),
                                  ),
                                )
                              else
                                SliverList(
                                  delegate: SliverChildBuilderDelegate(
                                    (context, index) => fileRow(items[index]),
                                    childCount: items.length,
                                  ),
                                ),
                              const SliverToBoxAdapter(
                                child: SizedBox(height: 24),
                              ),
                            ],
                          ),
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
