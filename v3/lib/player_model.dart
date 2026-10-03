import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'media_kit_playback.dart';

class MediaEntry {
  MediaEntry(Map<dynamic, dynamic> data)
      : path = data['path'] as String, name = data['name'] as String,
        parent = data['parent'] as String, kind = data['kind'] as String,
        size = (data['size'] as num).toInt(), modified = (data['modified'] as num).toDouble();
  final String path, name, parent, kind;
  final int size;
  final double modified;
  bool get isFolder => kind == 'folder';
  bool get isVideo => kind == 'video';
  bool get isAudio => kind == 'audio';
  bool get isPlayable => isVideo || isAudio;
  String get extension {
    final dot = name.lastIndexOf('.');
    return dot > 0 && dot < name.length - 1 ? name.substring(dot + 1).toLowerCase() : '';
  }
}

class PlayerModel extends ChangeNotifier {
  PlayerModel() { mediaKit.addListener(notifyListeners); }
  final mediaKit = MediaKitPlayback();
  static const _methods = MethodChannel('lei.player/methods');
  static const _events = EventChannel('lei.player/events');
  StreamSubscription<dynamic>? _subscription;
  List<MediaEntry> entries = [];
  Map<String, Map<String, dynamic>> records = {};
  Map<String, dynamic> state = {};
  Map<String, dynamic>? importProgress;
  bool scanning = false, importing = false;
  int libraryRevision = 0;
  String appearance = 'dark';
  String libraryLayout = 'list', librarySort = 'name';
  bool librarySortAscending = true;
  Future<bool> loadAppearance() => command('appearance', onValue: (value) { appearance = value as String; });
  Future<bool> setAppearance(String value) => command('setAppearance', args: {'value': value},
    onValue: (saved) { appearance = saved as String; });
  void applyLibraryPreferences(dynamic value) {
    final saved = Map<String, dynamic>.from(value as Map);
    final layout = saved['layout'] as String?;
    final sort = saved['sort'] as String?;
    libraryLayout = layout == 'grid' ? 'grid' : 'list';
    librarySort = const {'name', 'type', 'size', 'date'}.contains(sort) ? sort! : 'name';
    librarySortAscending = saved['ascending'] != false;
  }
  Future<bool> loadLibraryPreferences() => command('libraryPreferences', onValue: applyLibraryPreferences);
  Future<bool> setLibraryPreferences({String? layout, String? sort, bool? ascending}) =>
    command('setLibraryPreferences', args: {
      if (layout != null) 'layout': layout,
      if (sort != null) 'sort': sort,
      if (ascending != null) 'ascending': ascending,
    }, onValue: applyLibraryPreferences);
  String? message;
  VoidCallback? onOpenPlayer;
  String get path => state['path'] as String? ?? '';
  bool get playing => state['playing'] == true;
  bool get loading => state['loading'] == true;
  double get position => number('position');
  double get duration => number('duration');
  double number(String key, [double fallback = 0]) => (state[key] as num?)?.toDouble() ?? fallback;
  List<String> get queue => (state['queue'] as List?)?.cast<String>() ?? [];
  Map<String, dynamic> record(String path) => records[path] ?? {};
  MediaEntry? entry(String path) {
    for (final entry in entries) { if (entry.path == path) return entry; }
    return null;
  }
  Future<void> initialize() async {
    _subscription ??= _events.receiveBroadcastStream().listen((dynamic event) {
      final data = Map<String, dynamic>.from(event as Map);
      switch (data['type']) {
        case 'player':
          state = Map<String, dynamic>.from(data['state'] as Map);
          if (path.isNotEmpty && duration > 0) {
            if (playing && record(path)['lastPlayed'] == null) libraryRevision++;
            records[path] = {...record(path), if (state['rememberProgress'] != false) ...{'position': position, 'duration': duration}, if (playing) 'lastPlayed': DateTime.now().millisecondsSinceEpoch / 1000};
          }
          break;
        case 'import': importProgress = data; break;
        case 'importDone': importProgress = null; break;
        case 'openPlayer': onOpenPlayer?.call(); break;
        case 'notice': message = data['message'] as String?; break;
      }
      notifyListeners();
    }, onError: (Object error) { message = '无法连接 iOS 播放服务：$error'; notifyListeners(); });
    await command('state', onValue: (value) { state = Map<String, dynamic>.from(value as Map); });
    await loadLibraryPreferences();
    await refresh();
  }
  Future<bool> command(String method, {Map<String, dynamic>? args, void Function(dynamic)? onValue}) async {
    try {
      final dynamic value = await _methods.invokeMethod<dynamic>(method, args);
      onValue?.call(value); notifyListeners(); return true;
    } on PlatformException catch (error) { message = error.message ?? '操作失败';
    } on MissingPluginException { message = 'iOS 服务尚未加载，请在 iOS 设备中完整启动应用';
    } catch (error) { message = '操作失败：$error'; }
    notifyListeners(); return false;
  }
  Future<bool> refresh() async {
    if (scanning || importing) return false;
    scanning = true; notifyListeners();
    try {
      final scanned = await command('scan', onValue: (value) {
        entries = (value as List).map((item) => MediaEntry(item as Map)).toList();
        libraryRevision++;
      });
      await loadRecords();
      return scanned;
    } finally {
      scanning = false; notifyListeners();
    }
  }
  Future<void> loadRecords() async {
    await command('records', onValue: (value) { records = (value as Map).map((key, value) => MapEntry(key as String, Map<String, dynamic>.from(value as Map))); libraryRevision++; });
  }
  Future<void> importMedia({required bool folder, required String parent}) async {
    if (importing || scanning) return;
    importing = true; notifyListeners();
    var count = 0;
    List<String> importedPaths = [];
    final copied = await command('import', args: {'folder': folder, 'parent': parent}, onValue: (value) {
      if (value is Map) {
        count = (value['count'] as num).toInt();
        importedPaths = (value['paths'] as List).cast<String>();
      } else if (value is num) {
        // The picker returns zero on cancellation; tolerate an older native bridge.
        count = value.toInt();
      }
    });
    importing = false; importProgress = null;
    final refreshed = await refresh();
    if (copied && count > 0) {
      final indexed = entries.where((item) => item.parent == parent).map((item) => item.path).toSet();
      if (!refreshed) {
        message = '已复制 $count 项，但课程库刷新失败，请点击刷新重试，无需重复导入';
      } else if (importedPaths.length != count || !importedPaths.every(indexed.contains)) {
        message = '已复制 $count 项，但未能在目标目录核对文件，请完整重启应用后刷新，无需重复导入';
      } else {
        message = '已导入 $count 项';
      }
      notifyListeners();
    }
  }
  Future<bool> open(List<MediaEntry> files, MediaEntry selected, {bool resume = true}) => command('open', args: {'paths': files.map((item) => item.path).toList(), 'index': files.indexWhere((item) => item.path == selected.path), 'resume': resume});
  Future<void> favorite(MediaEntry item) async {
    final value = record(item.path)['favorite'] != true;
    if (await command('favorite', args: {'path': item.path, 'value': value})) { records[item.path] = {...record(item.path), 'favorite': value}; libraryRevision++; notifyListeners(); }
  }
  Future<bool> configure(Map<String, dynamic> values) => command('configure', args: values);
  Future<bool> seek(double value) async {
    var finished = false;
    final accepted = await command('seek', args: {'seconds': value}, onValue: (result) { finished = result == true; });
    return accepted && finished;
  }
  Future<bool> previewSeek(double value) => command('previewSeek', args: {'seconds': value});
  Future<bool> cancelScrub() => command('cancelScrub');
  Future<bool> toggle() => command(playing || loading ? 'pause' : 'play');
  void consumeMessage() { message = null; }
  @override
  void dispose() {
    _subscription?.cancel();
    mediaKit.removeListener(notifyListeners);
    mediaKit.dispose();
    super.dispose();
  }
}

String timeLabel(double seconds) {
  final value = seconds.isFinite ? seconds.floor().clamp(0, 359999) : 0;
  final remainder = (value % 60).toString().padLeft(2, '0');
  if (value >= 3600) return '${value ~/ 3600}:${((value % 3600) ~/ 60).toString().padLeft(2, '0')}:$remainder';
  return '${(value ~/ 60).toString().padLeft(2, '0')}:$remainder';
}
String sizeLabel(int bytes) {
  if (bytes >= 1073741824) return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
  if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
}
int naturalCompare(String a, String b) {
  final pattern = RegExp(r'\d+|\D+');
  final left = pattern.allMatches(a.toLowerCase()).map((m) => m.group(0)!).toList();
  final right = pattern.allMatches(b.toLowerCase()).map((m) => m.group(0)!).toList();
  for (var i = 0; i < left.length && i < right.length; i++) {
    final x = BigInt.tryParse(left[i]), y = BigInt.tryParse(right[i]);
    final result = x != null && y != null ? x.compareTo(y) : left[i].compareTo(right[i]);
    if (result != 0) return result;
  }
  final result = left.length.compareTo(right.length);
  return result == 0 ? a.compareTo(b) : result;
}
