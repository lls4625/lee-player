import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoThemeData;
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'player_model.dart';
import 'glass_ui.dart';

String _playbackRateLabel(double rate) {
  final ticks = (rate * 20).round();
  return (ticks / 20).toStringAsFixed(ticks.isEven ? 1 : 2);
}

class PlaybackPage extends StatefulWidget {
  const PlaybackPage({super.key, required this.model});
  final PlayerModel model;
  @override
  State<PlaybackPage> createState() => _PlaybackPageState();
}

class _SleepTimerDialog extends StatefulWidget {
  const _SleepTimerDialog({required this.initialMinutes,
    required this.remainingSeconds, required this.timerActive});
  final int initialMinutes;
  final double remainingSeconds;
  final bool timerActive;

  @override
  State<_SleepTimerDialog> createState() => _SleepTimerDialogState();
}

class _SleepTimerDialogState extends State<_SleepTimerDialog> {
  static const presets = [5, 15, 30, 45, 60, 90];
  late final TextEditingController controller;
  String? errorText;

  int? get enteredMinutes => int.tryParse(controller.text);

  @override
  void initState() {
    super.initState();
    controller = TextEditingController(text: '${widget.initialMinutes}');
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  String durationLabel(int minutes) {
    if (minutes < 60) return '$minutes 分钟';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return rest == 0 ? '$hours 小时' : '$hours 小时 $rest 分钟';
  }

  void selectPreset(int minutes) {
    setState(() {
      controller.text = '$minutes';
      controller.selection = TextSelection.collapsed(offset: controller.text.length);
      errorText = null;
    });
  }

  void submit() {
    final minutes = enteredMinutes;
    if (minutes == null || minutes < 1 || minutes > 1440) {
      setState(() => errorText = '请输入 1～1440 之间的整数');
      return;
    }
    Navigator.of(context, rootNavigator: true).pop(minutes.toDouble());
  }

  Widget presetButton(int minutes, double width) {
    final selected = enteredMinutes == minutes;
    return SizedBox(width: width, child: GlassButton.custom(
      onTap: () => selectPreset(minutes), label: '$minutes 分钟',
      height: 48, shape: leiRoundedControlShape,
      style: selected ? GlassButtonStyle.prominent : GlassButtonStyle.filled,
      glowColor: selected ? leiGold.withValues(alpha: .42) : null,
      platformViewBackdrop: true,
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Text('$minutes', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600,
          color: selected ? leiGold : Colors.white)),
        Text(' 分钟', style: TextStyle(fontSize: 13,
          color: selected ? leiGold.withValues(alpha: .82) : Colors.white70)),
      ]),
    ));
  }

  Widget actionButton({required String label, required VoidCallback onTap,
    bool primary = false}) => GlassButton.custom(
      onTap: onTap, label: label, height: 48,
      shape: const LiquidRoundedSuperellipse(borderRadius: 15),
      style: primary ? GlassButtonStyle.prominent : GlassButtonStyle.filled,
      glowColor: primary ? leiGold.withValues(alpha: .5) : null,
      platformViewBackdrop: true,
      child: Text(label, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600,
        color: primary ? leiGold : Colors.white)),
    );

  @override
  Widget build(BuildContext context) {
    final minutes = enteredMinutes;
    final valid = minutes != null && minutes >= 1 && minutes <= 1440;
    final subtitle = widget.timerActive
      ? '当前剩余 ${timeLabel(widget.remainingSeconds)}，可重新设置或关闭'
      : '播放将在设定时间后自动停止';
    return GlassContainer(
      useOwnLayer: true,
      quality: GlassQuality.minimal,
      platformViewBackdrop: true,
      padding: const EdgeInsets.all(22),
      shape: const LiquidRoundedSuperellipse(borderRadius: 26),
      child: AdaptiveLiquidGlassLayer(
        quality: GlassQuality.minimal,
        platformViewBackdrop: true,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Container(width: 46, height: 46,
                decoration: BoxDecoration(color: leiGold.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(color: leiGold.withValues(alpha: .22))),
                child: const Icon(Icons.timer_outlined, color: leiGold, size: 24)),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('定时停止', style: TextStyle(fontSize: 22,
                  fontWeight: FontWeight.w600, color: Colors.white)),
                const SizedBox(height: 3),
                Text(subtitle, maxLines: 2, style: const TextStyle(
                  fontSize: 13, height: 1.35, color: Colors.white60)),
              ])),
            ]),
            const SizedBox(height: 22),
            Row(children: [
              const Expanded(child: Text('快捷选择', style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white))),
              Text('分钟', style: TextStyle(fontSize: 12,
                color: Colors.white.withValues(alpha: .45))),
            ]),
            const SizedBox(height: 10),
            LayoutBuilder(builder: (context, constraints) {
              final buttonWidth = (constraints.maxWidth - 16) / 3;
              return Wrap(spacing: 8, runSpacing: 8, children: [
                for (final preset in presets) presetButton(preset, buttonWidth),
              ]);
            }),
            const SizedBox(height: 22),
            const Text('自定义分钟数', style: TextStyle(
              fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
            const SizedBox(height: 9),
            AnimatedContainer(duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .2),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: errorText == null
                  ? Colors.white.withValues(alpha: .15)
                  : Colors.redAccent.withValues(alpha: .8))),
              child: Row(children: [
                Expanded(child: TextField(
                  controller: controller,
                  autofocus: false,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(4),
                  ],
                  cursorColor: leiGold,
                  style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w500,
                    color: Colors.white),
                  decoration: const InputDecoration(border: InputBorder.none,
                    isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 15)),
                  onChanged: (_) => setState(() => errorText = null),
                  onSubmitted: (_) => submit(),
                )),
                const SizedBox(width: 12),
                const Text('分钟', style: TextStyle(fontSize: 16, color: Colors.white60)),
              ])),
            const SizedBox(height: 8),
            if (errorText != null)
              Text(errorText!, style: const TextStyle(fontSize: 12,
                color: Colors.redAccent))
            else
              Row(children: [
                const Expanded(child: Text('1～1440 分钟 · 最长 24 小时',
                  style: TextStyle(fontSize: 12, color: Colors.white54))),
                if (valid) Text(durationLabel(minutes), style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: leiGold)),
              ]),
            if (widget.timerActive) ...[
              const SizedBox(height: 12),
              GlassButton.custom(
                onTap: () => Navigator.of(context, rootNavigator: true).pop(0.0),
                label: '关闭当前定时', height: 42,
                shape: const LiquidRoundedSuperellipse(borderRadius: 14),
                style: GlassButtonStyle.transparent,
                glowColor: Colors.redAccent.withValues(alpha: .35),
                platformViewBackdrop: true,
                child: const Text('关闭当前定时', style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w500, color: Colors.redAccent))),
            ],
            const SizedBox(height: 22),
            Row(children: [
              Expanded(child: actionButton(label: '取消',
                onTap: () => Navigator.of(context, rootNavigator: true).pop())),
              const SizedBox(width: 10),
              Expanded(child: actionButton(label: '开始计时', onTap: submit, primary: true)),
            ]),
          ]),
      ),
    );
  }
}

class _PlaybackPageState extends State<PlaybackPage> {
  PlayerModel get m => widget.model;
  double? dragging;
  Timer? previewTimer;
  Timer? feedbackTimer;
  Timer? levelUpdateTimer;
  Timer? levelFeedbackTimer;
  String? seekFeedback;
  Object? feedbackGeneration;
  String? levelKind;
  double? levelValue;
  double levelStart = 0;
  double levelDragDistance = 0;
  bool jumping = false;
  int get rewindSeconds => m.number('rewindSeconds', 15).round().clamp(1, 300);
  int get forwardSeconds => m.number('forwardSeconds', 15).round().clamp(1, 300);

  Future<void> jump(double delta) async {
    if (!canSeek || jumping || dragging != null) return;
    final path = m.path;
    final generation = m.state['generation'];
    final target = (m.position + delta).clamp(0, m.duration).toDouble();
    setState(() => jumping = true);
    final success = await m.seek(target);
    if (!mounted) return;
    setState(() => jumping = false);
    if (!success || m.path != path || m.state['generation'] != generation) return;
    feedbackTimer?.cancel();
    feedbackGeneration = generation;
    setState(() => seekFeedback = '${delta < 0 ? '后退' : '前进'}至 ${timeLabel(target)}');
    feedbackTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => seekFeedback = null);
    });
  }
  double? lastPreview;
  String dragPath = '';
  int dragGeneration = 0;
  bool endingDrag = false;
  bool get canSeek => m.duration > 0 && m.state['seekable'] == true;
  void updateDrag(double value) {
    if (dragging == null || endingDrag) {
      dragGeneration++;
      endingDrag = false;
      dragPath = m.path;
      lastPreview = null;
    }
    setState(() => dragging = value);
    if (previewTimer == null) {
      // First preview pauses audio immediately. Subsequent targets are throttled.
      m.previewSeek(value);
      lastPreview = value;
      previewTimer = Timer(const Duration(milliseconds: 120), flushPreview);
    }
  }
  void flushPreview() {
    previewTimer = null;
    if (!mounted || dragging == null || endingDrag || dragPath != m.path) return;
    if (lastPreview != dragging) {
      m.previewSeek(dragging!);
      lastPreview = dragging;
    }
    previewTimer = Timer(const Duration(milliseconds: 120), flushPreview);
  }
  Future<void> endDrag(double value) async {
    previewTimer?.cancel(); previewTimer = null;
    endingDrag = true;
    final generation = dragGeneration;
    final path = m.path;
    await m.seek(value);
    if (mounted && generation == dragGeneration && path == m.path) {
      setState(() { dragging = null; endingDrag = false; });
    }
  }
  final videoKey = GlobalKey();
  bool landscape = false, locked = false, controlsVisible = true;
  bool pipCommandPending = false;
  static const modes = {'sequence': '顺序播放', 'folder': '文件夹循环', 'one': '单集循环', 'shuffle': '随机播放'};
  @override
  void initState() {
    super.initState();
    m.addListener(changed);
    // Entering the player applies the persisted playback brightness while the
    // native service keeps the current system brightness for restoration.
    if (m.state['isAudio'] != true) {
      unawaited(m.configure({'brightness': m.number('brightness', .5)}));
    }
  }
  void changed() {
    if (seekFeedback != null && feedbackGeneration != m.state['generation']) {
      feedbackTimer?.cancel(); seekFeedback = null;
    }
    if (dragging != null && (dragPath != m.path || (m.state['error'] as String? ?? '').isNotEmpty)) {
      previewTimer?.cancel(); previewTimer = null;
      dragGeneration++; dragging = null; endingDrag = false;
    }
    if (mounted) setState(() {});
  }
  @override
  void dispose() {
    feedbackTimer?.cancel();
    previewTimer?.cancel();
    levelUpdateTimer?.cancel();
    levelFeedbackTimer?.cancel();
    if (dragging != null && !endingDrag) m.cancelScrub();
    m.removeListener(changed);
    m.command('restoreBrightness');
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp, DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    super.dispose();
  }

  void startLevelDrag(String kind) {
    levelUpdateTimer?.cancel();
    levelUpdateTimer = null;
    levelFeedbackTimer?.cancel();
    final minimum = kind == 'brightness' ? .05 : 0.0;
    levelStart = m.number(kind, kind == 'volume' ? 1 : .5)
      .clamp(minimum, 1).toDouble();
    levelDragDistance = 0;
    setState(() {
      levelKind = kind;
      levelValue = levelStart;
    });
  }

  void updateLevelDrag(DragUpdateDetails details) {
    if (levelKind == null || levelValue == null) return;
    levelDragDistance += details.primaryDelta ?? 0;
    final height = context.size?.height ?? MediaQuery.sizeOf(context).height;
    final travel = height * .8 < 320 ? 320.0 : height * .8;
    final minimum = levelKind == 'brightness' ? .05 : 0.0;
    final next = (levelStart - levelDragDistance / travel)
      .clamp(minimum, 1).toDouble();
    if ((next - levelValue!).abs() < .002) return;
    setState(() => levelValue = next);
    if (levelUpdateTimer == null) {
      levelUpdateTimer = Timer(const Duration(milliseconds: 40), flushLevelUpdate);
    }
  }

  void flushLevelUpdate() {
    levelUpdateTimer?.cancel();
    levelUpdateTimer = null;
    final kind = levelKind;
    final value = levelValue;
    if (kind != null && value != null) unawaited(m.configure({kind: value}));
  }

  void finishLevelDrag() {
    if (levelKind == null) return;
    flushLevelUpdate();
    levelFeedbackTimer?.cancel();
    levelFeedbackTimer = Timer(const Duration(milliseconds: 800), () {
      if (mounted) setState(() { levelKind = null; levelValue = null; });
    });
  }

  Widget levelFeedback() {
    final kind = levelKind!;
    final value = levelValue!;
    final brightness = kind == 'brightness';
    final percent = (value * 100).round();
    return IgnorePointer(child: Center(child: Semantics(
      liveRegion: true,
      label: '${brightness ? '屏幕亮度' : '播放音量'} $percent%',
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
        width: 178,
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
        decoration: BoxDecoration(
          color: const Color(0xd918191d),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: .15)),
          boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 20)],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Icon(brightness ? Icons.brightness_6_rounded
              : value <= .001 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              color: leiGold, size: 24),
            const SizedBox(width: 10),
            Expanded(child: Text(brightness ? '亮度' : '音量',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600))),
            Text('$percent%', style: const TextStyle(color: Colors.white70,
              fontFeatures: [FontFeature.tabularFigures()])),
          ]),
          const SizedBox(height: 12),
          ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(
            value: value, minHeight: 6, color: leiGold,
            backgroundColor: Colors.white.withValues(alpha: .16))),
        ]),
      ),
    )));
  }
  Future<void> rotate() async {
    landscape = !landscape;
    await SystemChrome.setPreferredOrientations(landscape ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight] : [DeviceOrientation.portraitUp]);
    if (mounted) setState(() {});
  }
  Future<void> requestPiP() async {
    if (pipCommandPending || m.state['pipRequesting'] == true) return;
    final debounce = Stopwatch()..start();
    setState(() => pipCommandPending = true);
    try {
      await m.command('pip');
    } finally {
      final remaining = 700 - debounce.elapsedMilliseconds;
      if (remaining > 0) await Future<void>.delayed(Duration(milliseconds: remaining));
      if (mounted) setState(() => pipCommandPending = false);
    }
  }
  Future<T?> choose<T>(String title, Map<T, String> choices, {T? selected}) {
    final entries = choices.entries.toList();
    return showLeiSheet<T>(context: context, platformViewBackdrop: true,
      builder: (context) => SafeArea(child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .7,
        child: Column(children: [
          LeiSheetHeading(title: title, platformViewBackdrop: true),
          Expanded(child: ListView.builder(itemCount: entries.length, itemBuilder: (context, index) {
            final choice = entries[index];
            return LeiGlassTile(title: Text(choice.value,
              style: choice.key == selected ? TextStyle(color: leiAccent(context), fontWeight: FontWeight.w600) : null),
              trailing: choice.key == selected ? const LeiMediaIcon(icon: Icons.check) : null,
              onTap: () => Navigator.pop(context, choice.key));
          })),
        ]),
      )),
    );
  }
  Future<void> queue() async {
    final paths = List<String>.from(m.queue);
    final selectedIndex = m.number('index').toInt();
    final generation = m.state['generation'];
    final selected = await showLeiSheet<int>(context: context, platformViewBackdrop: true,
      builder: (context) => SafeArea(child: SizedBox(height: MediaQuery.sizeOf(context).height * .7,
        child: Column(children: [
          LeiSheetHeading(title: '播放队列', subtitle: '${paths.length} 个媒体 · 按课程顺序播放', platformViewBackdrop: true),
          if (paths.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('队列为空，请返回课程库选择媒体。')),
          Expanded(child: ListView.builder(itemCount: paths.length, itemBuilder: (context, index) {
            final current = index == selectedIndex;
            final record = m.record(paths[index]);
            final position = (record['position'] as num?)?.toDouble() ?? 0;
            return LeiGlassTile(
              leading: SizedBox(width: 48, child: current
                ? const LeiMediaIcon(icon: Icons.graphic_eq_rounded)
                : Text('${index + 1}', textAlign: TextAlign.center)),
              title: Text(paths[index].split('/').last, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: current ? const TextStyle(color: leiGold, fontWeight: FontWeight.w600) : null),
              subtitle: Text(current ? '当前课程' : position > 0 ? '上次播至 ${timeLabel(position)}' : '尚未记录进度'),
              onTap: () => Navigator.pop(context, index));
          })),
        ]))));
    if (selected == null || !mounted) return;
    if (generation != m.state['generation']) {
      showLeiToast(context, '课程已切换，请重新打开队列');
      return;
    }
    if (selected != selectedIndex) await m.command('open', args: {'paths': paths, 'index': selected, 'resume': true});
  }
  Future<void> speed() async {
    var ticks = (m.number('rate', 1) * 20).round().clamp(10, 60);
    final value = await showLeiDialog<double>(context: context, title: '播放速度',
      platformViewBackdrop: true,
      content: StatefulBuilder(builder: (context, setDialogState) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            LeiGlassIconButton(icon: const Icon(Icons.remove), tooltip: '减速 0.05 倍',
              platformViewBackdrop: true,
              onPressed: ticks > 10 ? () => setDialogState(() { ticks--; }) : null),
            Expanded(child: Semantics(liveRegion: true,
              child: Text(_playbackRateLabel(ticks / 20), textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium))),
            LeiGlassIconButton(icon: const Icon(Icons.add), tooltip: '加速 0.05 倍',
              platformViewBackdrop: true,
              onPressed: ticks < 60 ? () => setDialogState(() { ticks++; }) : null),
          ]),
          const SizedBox(height: 16),
          Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
            for (final preset in [20, 30, 40]) LeiGlassButton(
              label: _playbackRateLabel(preset / 20),
              onPressed: () => setDialogState(() => ticks = preset)),
          ]),
        ],
      )),
      actions: [
        GlassDialogAction(label: '取消', onPressed: () => Navigator.of(context, rootNavigator: true).pop()),
        GlassDialogAction(label: '确定',
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(ticks / 20)),
      ]);
    if (value != null) await m.configure({'rate': value});
  }
  Future<void> repeatMode() async {
    final value = await choose<String>('播放模式 · 选择后开启连续播放', modes, selected: m.state['mode'] as String?);
    if (value != null) await m.configure({'mode': value});
  }
  Future<void> sleep() async {
    final remainingSeconds = m.number('sleepRemaining');
    final timerActive = remainingSeconds > 0;
    final initialMinutes = timerActive
      ? (remainingSeconds / 60).ceil().clamp(1, 1440).toInt()
      : 30;
    final value = await showGeneralDialog<double>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: .62),
      transitionDuration: const Duration(milliseconds: 220),
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return FadeTransition(opacity: curved, child: ScaleTransition(
          scale: Tween<double>(begin: .96, end: 1).animate(curved), child: child));
      },
      pageBuilder: (dialogContext, animation, secondaryAnimation) => SafeArea(
        child: AnimatedPadding(duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: EdgeInsets.fromLTRB(18, 24, 18,
            MediaQuery.viewInsetsOf(dialogContext).bottom + 24),
          child: Center(child: SingleChildScrollView(
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 400),
              child: _SleepTimerDialog(initialMinutes: initialMinutes,
                remainingSeconds: remainingSeconds, timerActive: timerActive)),
          )),
        ),
      ),
    );
    if (value != null) await m.configure({'sleepMinutes': value});
  }
  Future<void> playbackInfo() async {
    String text = '';
    if (!await m.command('playbackInfo', onValue: (value) { text = value as String; }) || !mounted) return;
    await showLeiDialog<void>(context: context, title: null, platformViewBackdrop: true,
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          const SizedBox(width: 44),
          Expanded(child: Semantics(header: true, child: Text('播放信息',
            textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge))),
          GlassIconButton(icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
            platformViewBackdrop: true, semanticLabel: '关闭播放信息'),
        ]),
        const SizedBox(height: 8),
        SingleChildScrollView(child: SelectableText(text)),
      ]),
      actions: [
        GlassDialogAction(label: '复制信息', onPressed: () async {
          try {
            await Clipboard.setData(ClipboardData(text: text));
            if (mounted) showLeiToast(context, '已复制完整播放信息');
          } catch (_) {
            if (mounted) showLeiToast(context, '复制失败，请重试');
          }
        }),
        GlassDialogAction(label: '关闭', onPressed: () => Navigator.of(context, rootNavigator: true).pop()),
      ]);
  }
  Future<void> tracks() async {
    final kind = await choose<String>('音轨与字幕', {'audio': '选择内嵌音轨', 'subtitle': '选择内嵌字幕 / 关闭字幕', 'external': '选择已导入的外置字幕'});
    if (!mounted || kind == null) return;
    if (kind == 'external') {
      final subtitles = m.entries.where((e) => e.kind == 'subtitle').toList()..sort((a, b) => naturalCompare(a.path, b.path));
      if (subtitles.isEmpty) { showLeiToast(context, '请先回课程库，通过 + 导入字幕文件'); return; }
      final path = await choose<String>(m.state['engine'] == 'media_kit' ? '外置字幕' : '外置字幕 · 画中画内不显示', {for (final e in subtitles) e.path: e.path});
      if (path != null) await m.command('subtitle', args: {'path': path});
    } else {
      await chooseTrack(kind);
    }
  }
  Future<void> chooseTrack(String kind) async {
    final session = m.state['generation'];
    bool submitting = false;
    await showLeiSheet<void>(context: context, platformViewBackdrop: true,
      builder: (sheetContext) => StatefulBuilder(builder: (context, updateSheet) =>
        AnimatedBuilder(animation: m, builder: (context, child) {
          final sameMedia = session != null && m.state['generation'] == session;
          final options = sameMedia ? ((m.state['${kind}Tracks'] as List?) ?? []) : [];
          final rows = <Map<dynamic, dynamic>>[
            if (kind == 'subtitle') {'index': -1, 'name': '关闭字幕'},
            for (final option in options) Map<dynamic, dynamic>.from(option as Map),
          ];
          final busy = submitting || m.state['trackSelecting'] == true;
          final selected = m.number('${kind}Track', -1).toInt();
          return SafeArea(child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .7,
            child: Column(children: [
              LeiGlassTile(title: Text('${kind == 'audio' ? '音轨' : '字幕'} · ${options.length} 条'),
                subtitle: Text(!sameMedia ? '媒体已变化，请关闭后重新选择'
                  : busy ? '正在确认轨道切换…' : '列表随播放状态更新')),
              if (sameMedia && options.isEmpty) const LeiGlassTile(title: Text('暂未发现轨道')),
              Expanded(child: ListView.builder(itemCount: sameMedia ? rows.length : 0,
                itemBuilder: (context, rowIndex) {
                  final row = rows[rowIndex];
                  final index = (row['index'] as num).toInt();
                  final details = row['details'] as String? ?? '';
                  return LeiGlassTile(title: Text('${row['name']}'),
                    subtitle: details.isEmpty ? null : Text(details),
                    trailing: index == selected ? const LeiMediaIcon(icon: Icons.check) : null,
                    onTap: busy ? null : () async {
                      if (submitting || m.state['generation'] != session) return;
                      updateSheet(() { submitting = true; });
                      final route = ModalRoute.of(sheetContext);
                      final success = await m.command('track', args: {
                        'kind': kind, 'index': index, 'generation': session,
                        if (row['id'] != null) 'id': row['id'],
                      });
                      if (!sheetContext.mounted) return;
                      updateSheet(() { submitting = false; });
                      if (success && route?.isCurrent == true) Navigator.of(sheetContext).pop();
                    });
                })),
            ]),
          ));
        }),
      ),
    );
  }
  Future<void> moreOptions() async {
    final action = await choose<String>('播放选项', {
      'favorite': m.record(m.path)['favorite'] == true ? '取消收藏' : '收藏当前媒体',
      'previous': '上一节',
      'next': '下一节',
      'repeat': modes[m.state['mode']] ?? '循环模式',
      'sleep': m.number('sleepRemaining') > 0
        ? '定时停止 · ${timeLabel(m.number('sleepRemaining'))}' : '定时停止',
      'fit': '画面比例',
      'ab': 'A–B 片段复读',
      'levels': '音量与亮度',
      'tracks': '音轨与字幕 · 包含外置字幕',
      'status': '当前播放状态',
      'info': '播放信息',
    });
    if (!mounted || action == null) return;
    switch (action) {
      case 'favorite':
        final entry = m.entry(m.path);
        if (entry != null) await m.favorite(entry);
        break;
      case 'previous': await m.command('previous'); break;
      case 'next': await m.command('next'); break;
      case 'repeat': await repeatMode(); break;
      case 'sleep': await sleep(); break;
      case 'fit':
        final fit = await choose<String>('画面比例',
          {'fit': '适应画面', 'fill': '填满画面', 'stretch': '拉伸画面'},
          selected: m.state['fit'] as String?);
        if (fit != null) await m.configure({'fit': fit});
        break;
      case 'ab': await adjustmentSheet(true); break;
      case 'levels': await adjustmentSheet(false); break;
      case 'tracks': await tracks(); break;
      case 'status':
        await showLeiDialog<void>(context: context, title: '当前播放状态',
          platformViewBackdrop: true,
          message: [
            '${m.number('index').toInt() + 1} / ${m.queue.length} · ${m.state['continuous'] == false ? '播完当前停止' : modes[m.state['mode']] ?? '文件夹循环'}',
            if (m.number('introSkipped') > 0) '已跳过片头 ${timeLabel(m.number('introSkipped'))} · 可拖回开头查看',
            if ((m.state['engineNotice'] as String? ?? '').isNotEmpty) '${m.state['engineNotice']}',
            if ((m.state['subtitleName'] as String? ?? '').isNotEmpty) '字幕：${m.state['subtitleName']}',
          ].join('\n\n'),
          actions: [GlassDialogAction(label: '关闭',
            onPressed: () => Navigator.of(context, rootNavigator: true).pop())]);
        break;
      case 'info': await playbackInfo(); break;
    }
  }

  Future<void> adjustmentSheet(bool repeat) => showLeiSheet<void>(
    context: context, platformViewBackdrop: true,
    builder: (sheetContext) => SafeArea(child: SizedBox(
      height: MediaQuery.sizeOf(sheetContext).height * .65,
      child: AnimatedBuilder(animation: m, builder: (context, child) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          Row(children: [
            Expanded(child: Text(repeat ? 'A–B 片段复读' : '音量与亮度',
              style: Theme.of(context).textTheme.titleLarge)),
            GlassIconButton(icon: const Icon(Icons.close), semanticLabel: '关闭',
              platformViewBackdrop: true, onPressed: () => Navigator.pop(sheetContext)),
          ]),
          const SizedBox(height: 24),
          if (repeat) ...[
            Text('当前位置 ${timeLabel(m.position)}'),
            const SizedBox(height: 12),
            LeiGlassTile(
              title: Text(m.number('a', -1) < 0 ? '设置 A 点' : 'A 点 · ${timeLabel(m.number('a'))}'),
              leading: const LeiMediaIcon(icon: Icons.first_page),
              onTap: () => m.configure({'ab': 'a'})),
            const GlassDivider(),
            LeiGlassTile(
              title: Text(m.number('b', -1) < 0 ? '设置 B 点' : 'B 点 · ${timeLabel(m.number('b'))}'),
              leading: const LeiMediaIcon(icon: Icons.last_page),
              onTap: () => m.configure({'ab': 'b'})),
            const GlassDivider(),
            LeiGlassTile(title: const Text('清除复读区间'),
              leading: const LeiMediaIcon(icon: Icons.clear), onTap: () => m.configure({'ab': 'clear'})),
            const SizedBox(height: 16),
            const Text('在起点设置 A，播放到终点设置 B。也可先关闭面板，拖动进度后再设置。切换媒体会清除复读区间。'),
          ] else ...[
            const Text('播放音量'),
            GlassSlider(quality: GlassQuality.minimal,
              value: m.number('volume', 1).clamp(0, 1).toDouble(),
              onChanged: (value) => m.configure({'volume': value})),
            const SizedBox(height: 24),
            const Text('屏幕亮度'),
            GlassSlider(quality: GlassQuality.minimal, min: .05,
              value: m.number('brightness', .5).clamp(.05, 1).toDouble(),
              onChanged: (value) => m.configure({'brightness': value})),
            const SizedBox(height: 16),
            const Text('播放画面左侧上下滑动调音量，右侧上下滑动调亮度；数值会自动保存。退出播放页面后恢复原屏幕亮度，系统音量仍可用手机音量键调整。'),
          ],
        ],
      )),
    )),
  );

  Widget playbackButton(Widget icon, String label, VoidCallback? action) => Tooltip(
    message: label,
    child: GlassIconButton(icon: icon, semanticLabel: label,
      platformViewBackdrop: true, onPressed: action),
  );

  Widget seekButton({required bool rewind, required int seconds,
    required VoidCallback? action}) {
    final label = '${rewind ? '后退' : '前进'} $seconds 秒';
    final icon = Icon(rewind ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded,
      size: 22);
    final value = Text('$seconds', maxLines: 1, softWrap: false);
    return Tooltip(message: label, child: GlassButton.custom(
      onTap: action ?? () {}, enabled: action != null, label: label,
      width: 96, height: 44, shape: leiRoundedControlShape,
      platformViewBackdrop: true,
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: rewind
        ? [ExcludeSemantics(child: icon), const SizedBox(width: 6), value]
        : [value, const SizedBox(width: 6), ExcludeSemantics(child: icon)]),
    ));
  }

  Widget transportBar(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    final compact = MediaQuery.sizeOf(context).height < 500;
    final transport = <Widget>[
      seekButton(rewind: true, seconds: rewindSeconds,
        action: canSeek && !jumping && dragging == null
          ? () => jump(-rewindSeconds.toDouble()) : null),
      LeiGlassIconButton(
        icon: Icon(m.playing || m.loading ? Icons.pause_rounded : Icons.play_arrow_rounded),
        tooltip: m.loading ? '取消加载' : m.playing ? '暂停' : '播放', platformViewBackdrop: true, onPressed: m.toggle),
      seekButton(rewind: false, seconds: forwardSeconds,
        action: canSeek && !jumping && dragging == null
          ? () => jump(forwardSeconds.toDouble()) : null),
    ];
    final tools = <Widget>[
      playbackButton(Text(_playbackRateLabel(m.number('rate', 1))), '播放速度', speed),
      playbackButton(const Icon(Icons.repeat_rounded), 'A–B 片段复读', () => adjustmentSheet(true)),
      playbackButton(const Icon(Icons.subtitles_outlined), '音轨与字幕', tracks),
      playbackButton(const Icon(Icons.more_horiz), '更多播放选项', moreOptions),
    ];
    if (compact && constraints.maxWidth >= 560) {
      return Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [...transport, ...tools]);
    }
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: transport),
      const SizedBox(height: 12),
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: tools),
    ]);
  });

  Widget progressBar(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
    GlassSlider(
      quality: GlassQuality.minimal,
      value: (dragging ?? m.position).clamp(0, m.duration > 0 ? m.duration : 1).toDouble(),
      max: m.duration > 0 ? m.duration : 1,
      onChanged: canSeek && !jumping ? updateDrag : null,
      onChangeEnd: canSeek && !jumping ? endDrag : null,
    ),
    Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Row(children: [
      Text(timeLabel(dragging ?? m.position), style: Theme.of(context).textTheme.labelMedium),
      Expanded(child: Text(m.number('b', -1) >= 0 ? 'A–B 复读中'
        : m.number('a', -1) >= 0 ? '已设 A 点' : '', textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: leiGold))),
      Text(timeLabel(m.duration), style: Theme.of(context).textTheme.labelMedium),
    ])),
    const SizedBox(height: 12),
    transportBar(context),
  ]);

  Widget errorPanel(BuildContext context) => Positioned.fill(
    child: ColoredBox(color: const Color(0xee101114),
      child: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const LeiMediaIcon(icon: Icons.error_outline_rounded),
            const SizedBox(height: 16),
            Text('暂时无法播放', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            SelectableText('${m.state['error']}', textAlign: TextAlign.center),
            const SizedBox(height: 20),
            Wrap(spacing: 12, runSpacing: 12, alignment: WrapAlignment.center, children: [
              LeiGlassButton(label: '重试播放', icon: Icons.refresh,
                onPressed: m.loading ? null : () => m.command('play')),
              LeiGlassButton(label: '返回课程库', icon: Icons.arrow_back,
                onPressed: () => Navigator.of(context).pop()),
              LeiGlassButton(label: '播放信息', icon: Icons.info_outline, onPressed: playbackInfo),
            ]),
          ]))))));

  Widget videoContent(BuildContext context) => Stack(fit: StackFit.expand, children: [
    ColoredBox(color: Colors.black,
      child: m.state['engine'] == 'media_kit'
        ? m.mediaKit.controller != null && m.mediaKit.engineId == m.state['engineId']
          ? Video(key: ValueKey(m.mediaKit.engineId), controller: m.mediaKit.controller!, controls: NoVideoControls,
              pauseUponEnteringBackgroundMode: false,
              fit: m.state['fit'] == 'stretch' ? BoxFit.fill : m.state['fit'] == 'fill' ? BoxFit.cover : BoxFit.contain)
          : const SizedBox.expand()
        : UiKitView(key: videoKey, viewType: 'lei.player/video')),
    if (m.state['isAudio'] == true)
      Center(child: Container(width: 156, height: 156,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(40),
          gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Color(0xff51452a), Color(0xff22242c)]),
          border: Border.all(color: leiGold.withValues(alpha: .22))),
        child: const Center(child: LeiMediaIcon(icon: Icons.headphones_rounded)))),
    if (controlsVisible && !locked) const IgnorePointer(child: DecoratedBox(
      decoration: BoxDecoration(gradient: LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        stops: [0, .22, .5, .7, 1],
        colors: [Color(0xcc000000), Color(0x00000000), Color(0x00000000), Color(0x66000000), Color(0xee000000)],
      )),
    )),
    if (!locked) Row(children: [
      Expanded(child: GestureDetector(behavior: HitTestBehavior.translucent,
        onTap: () => setState(() => controlsVisible = !controlsVisible),
        onDoubleTap: canSeek && !jumping && dragging == null ? () => jump(-rewindSeconds.toDouble()) : null,
        onVerticalDragStart: m.state['isAudio'] != true ? (_) => startLevelDrag('volume') : null,
        onVerticalDragUpdate: m.state['isAudio'] != true ? updateLevelDrag : null,
        onVerticalDragEnd: m.state['isAudio'] != true ? (_) => finishLevelDrag() : null,
        onVerticalDragCancel: m.state['isAudio'] != true ? finishLevelDrag : null,
        child: const SizedBox.expand())),
      Expanded(child: GestureDetector(behavior: HitTestBehavior.translucent,
        onTap: () => setState(() => controlsVisible = !controlsVisible),
        onDoubleTap: canSeek && !jumping && dragging == null ? () => jump(forwardSeconds.toDouble()) : null,
        onVerticalDragStart: m.state['isAudio'] != true ? (_) => startLevelDrag('brightness') : null,
        onVerticalDragUpdate: m.state['isAudio'] != true ? updateLevelDrag : null,
        onVerticalDragEnd: m.state['isAudio'] != true ? (_) => finishLevelDrag() : null,
        onVerticalDragCancel: m.state['isAudio'] != true ? finishLevelDrag : null,
        child: const SizedBox.expand())),
    ]),
    if (levelKind != null && levelValue != null && !locked) levelFeedback(),
    if (seekFeedback != null && !locked) IgnorePointer(child: Center(
      child: Container(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(18)),
        child: Semantics(liveRegion: true, child: Text(seekFeedback!, style: const TextStyle(color: Colors.white))))
    )),
    if (m.loading && !locked)
      const IgnorePointer(child: Center(child: GlassProgressIndicator.circular())),
    if (controlsVisible && !locked) Positioned(top: 8, left: 12, right: 12,
      child: Row(children: [
        playbackButton(const Icon(Icons.arrow_back_ios_new), '返回课程库', () => Navigator.of(context).pop()),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(m.path.split('/').last, maxLines: 1,
            overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 3),
          Text('第 ${m.queue.isEmpty ? 0 : m.number('index').toInt() + 1} / ${m.queue.length} 节',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.white70)),
        ])),
        const SizedBox(width: 12),
        playbackButton(const Icon(Icons.queue_music), '播放队列', queue),
      ])),
    if (controlsVisible || locked) Align(alignment: Alignment.centerLeft,
      child: Padding(padding: const EdgeInsets.only(left: 12),
        child: playbackButton(Icon(locked ? Icons.lock : Icons.lock_open),
          locked ? '解锁控件' : '锁定控件',
          () => setState(() { locked = !locked; controlsVisible = true; })))),
    if (controlsVisible && !locked) Align(alignment: Alignment.centerRight,
      child: Padding(padding: const EdgeInsets.only(right: 12),
        child: Flex(direction: MediaQuery.sizeOf(context).height < 500 ? Axis.horizontal : Axis.vertical,
          mainAxisSize: MainAxisSize.min, children: [
          if (m.state['isAudio'] != true) ...[
            playbackButton(
              pipCommandPending || m.state['pipRequesting'] == true
                ? const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.picture_in_picture_alt),
              '画中画', pipCommandPending || m.state['pipRequesting'] == true ? null : requestPiP),
            const SizedBox(width: 12, height: 12),
          ],
          playbackButton(const Icon(Icons.screen_rotation), '横竖屏', rotate),
          const SizedBox(width: 12, height: 12),
          playbackButton(const Icon(Icons.fullscreen), '隐藏控件',
            () => setState(() => controlsVisible = false)),
        ]))),
    if (controlsVisible && !locked) Positioned(left: 16, right: 16, bottom: 12,
      child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (m.state['interrupted'] == true || m.state['detectingIntro'] == true)
          Padding(padding: const EdgeInsets.only(bottom: 8),
            child: Text(m.state['interrupted'] == true ? '音频中断中，等待通话结束…' : '正在识别空白片头…')),
        progressBar(context),
      ])))),
    if (!locked && (m.state['error'] as String? ?? '').isNotEmpty) errorPanel(context),
  ]);

  @override
  Widget build(BuildContext context) => Theme(
    data: ThemeData(brightness: Brightness.dark,
      cupertinoOverrideTheme: const CupertinoThemeData(brightness: Brightness.dark),
      colorScheme: ColorScheme.fromSeed(seedColor: leiGold, brightness: Brightness.dark)),
    child: Builder(builder: (context) => DefaultTextStyle(
      style: Theme.of(context).textTheme.bodyMedium!,
      child: IconTheme(data: const IconThemeData(color: Colors.white),
        child: PopScope(canPop: !locked, child: GlassScaffold(
          background: const ColoredBox(color: Colors.black),
          themeOverride: GlassThemeData.simple(quality: GlassQuality.minimal),
          enableBackgroundSampling: false,
          edgeFade: false, extendBody: false,
          statusBarStyle: GlassStatusBarStyle.light,
          body: SafeArea(child: videoContent(context)),
        )),
      ),
    )),
  );
}
