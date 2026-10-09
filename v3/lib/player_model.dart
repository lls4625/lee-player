import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'media_kit_playback.dart';
import 'app_localizations.dart';

class MediaEntry {
  MediaEntry(Map<dynamic, dynamic> data)
    : path = data['path'] as String,
      name = data['name'] as String,
      parent = data['parent'] as String,
      kind = data['kind'] as String,
      size = (data['size'] as num).toInt(),
      modified = (data['modified'] as num).toDouble();
  final String path, name, parent, kind;
  final int size;
  final double modified;
  bool get isFolder => kind == 'folder';
  bool get isVideo => kind == 'video';
  bool get isAudio => kind == 'audio';
  bool get isPlayable => isVideo || isAudio;
  String get extension {
    final dot = name.lastIndexOf('.');
    return dot > 0 && dot < name.length - 1
        ? name.substring(dot + 1).toLowerCase()
        : '';
  }
}

class PlayerModel extends ChangeNotifier {
  PlayerModel({Map<String, Duration>? commandTimeouts})
    : _commandTimeouts = commandTimeouts ?? const <String, Duration>{} {
    mediaKit.addListener(_notify);
  }
  final mediaKit = MediaKitPlayback();
  final Map<String, Duration> _commandTimeouts;
  static const _methods = MethodChannel('lei.player/methods');
  static const _events = EventChannel('lei.player/events');
  StreamSubscription<dynamic>? _subscription;
  Timer? _eventReconnectTimer;
  int _eventEpoch = 0, _eventReconnectAttempt = 0;
  int _nextCommandId = 0;
  final Map<String, int> _activeCommands = <String, int>{};
  final Map<String, String> _uncertainOperations = <String, String>{};
  int? _fileCommand;
  bool get fileBusy => _fileCommand != null || _uncertainOperations.isNotEmpty || importing;
  AppMessage? recordsIssue;
  int _recordsRevision = -1;
  AppMessage? importIssue;
  List<String> importSkippedPaths = [];
  int importSkippedCount = 0;
  void clearImportIssue() { importIssue = null; _notify(); }
  final Set<String> _loadedPreferences = {};
  final Map<String, int> _preferenceVersions = {};
  Future<void>? _preferenceRetry;
  Timer? _preferenceTimer;
  int _preferenceAttempts = 0;
  String _scanWarningIdentity = '';
  String? _controlFailureIdentity;
  Future<void>? _initialization;
  Completer<bool>? _refreshCompleter;
  bool _refreshQueued = false;
  bool _disposed = false;
  List<MediaEntry> entries = [];
  Map<String, Map<String, dynamic>> records = {};
  Map<String, dynamic> state = {};
  Map<String, dynamic>? importProgress;
  bool initializing = false, scanning = false, importing = false;
  int libraryRevision = 0;
  String appearance = 'system';
  AppLanguageMode languageMode = AppLanguageMode.system;
  String libraryLayout = 'list', librarySort = 'name';
  bool librarySortAscending = true;
  Future<bool> _loadPreference(String method, void Function(dynamic) apply) async {
    final version = _preferenceVersions[method] ?? 0;
    final success = await command(method, silent: true, onValue: (value) {
      if ((_preferenceVersions[method] ?? 0) == version) {
        apply(value);
        _loadedPreferences.add(method);
      }
    });
    return success;
  }
  Future<bool> loadAppearance() => _loadPreference('appearance', (value) {
    appearance = value as String;
  });
  Future<bool> setAppearance(String value) {
    _preferenceVersions.update('appearance', (n) => n + 1, ifAbsent: () => 1);
    return command(
      'setAppearance',
      args: {'value': value},
      onValue: (saved) {
        appearance = saved as String;
        _loadedPreferences.add('appearance');
      },
    );
  }
  Future<bool> loadLanguage() => _loadPreference('language', (value) {
    languageMode = AppLanguageModeValue.parse(value);
  });
  Future<bool> setLanguage(AppLanguageMode value) {
    _preferenceVersions.update('language', (n) => n + 1, ifAbsent: () => 1);
    return command(
      'setLanguage',
      args: {'value': value.value},
      onValue: (saved) {
        languageMode = AppLanguageModeValue.parse(saved);
        _loadedPreferences.add('language');
      },
    );
  }
  void applyLibraryPreferences(dynamic value) {
    final saved = Map<String, dynamic>.from(value as Map);
    final layout = saved['layout'] as String?;
    final sort = saved['sort'] as String?;
    libraryLayout = layout == 'grid' ? 'grid' : 'list';
    librarySort = const {'name', 'type', 'size', 'date'}.contains(sort)
        ? sort!
        : 'name';
    librarySortAscending = saved['ascending'] != false;
  }

  Future<bool> loadLibraryPreferences() =>
      _loadPreference('libraryPreferences', applyLibraryPreferences);
  Future<bool> setLibraryPreferences({
    String? layout,
    String? sort,
    bool? ascending,
  }) {
    _preferenceVersions.update('libraryPreferences', (n) => n + 1, ifAbsent: () => 1);
    return command(
      'setLibraryPreferences',
      args: {
        if (layout != null) 'layout': layout,
        if (sort != null) 'sort': sort,
        if (ascending != null) 'ascending': ascending,
      },
      onValue: (value) {
        applyLibraryPreferences(value);
        _loadedPreferences.add('libraryPreferences');
      },
    );
  }
  AppMessage? message;
  Future<void> Function(String? restoreToken)? onOpenPlayer;
  String get path => state['path'] as String? ?? '';
  bool get playing => state['playing'] == true;
  bool get loading => state['loading'] == true;
  double get position => number('position');
  double get duration => number('duration');
  double number(String key, [double fallback = 0]) =>
      (state[key] as num?)?.toDouble() ?? fallback;
  List<String> get queue => (state['queue'] as List?)?.cast<String>() ?? [];
  Map<String, dynamic> record(String path) => records[path] ?? {};
  MediaEntry? entry(String path) {
    for (final entry in entries) {
      if (entry.path == path) return entry;
    }
    return null;
  }

  void _connectEvents() {
    if (_disposed || _subscription != null) return;
    _eventReconnectTimer?.cancel();
    _eventReconnectTimer = null;
    final epoch = ++_eventEpoch;
    final subscription = _events.receiveBroadcastStream().listen(
      (dynamic event) {
        if (_disposed || epoch != _eventEpoch) return;
        _eventReconnectAttempt = 0;
        final data = Map<String, dynamic>.from(event as Map);
        switch (data['type']) {
          case 'player':
            _applyState(data['state']);
            if (path.isNotEmpty && duration > 0) {
              if (playing && record(path)['lastPlayed'] == null)
                libraryRevision++;
              records[path] = {
                ...record(path),
                if (state['rememberProgress'] != false) ...{
                  'position': position,
                  'duration': duration,
                },
                if (playing)
                  'lastPlayed': DateTime.now().millisecondsSinceEpoch / 1000,
              };
            }
            break;
          case 'records':
            _applyRecords(data);
            break;
          case 'import':
            importProgress = data;
            break;
          case 'importDone':
            importProgress = null;
            break;
          case 'openPlayer':
            final callback = onOpenPlayer;
            if (callback != null) {
              unawaited(callback(data['restoreToken'] as String?));
            }
            break;
          case 'scanWarning':
            final warnings = data['warnings'];
            final identity = warnings is List ? warnings.map((value) =>
              value is Map ? '${value['code']}:${value['path']}' : '').join('|') : '';
            if (identity == _scanWarningIdentity) break;
            _scanWarningIdentity = identity;
            if (warnings is List && warnings.isNotEmpty) {
              final symbolicLinks = warnings
                  .where(
                    (warning) =>
                        warning is Map &&
                        warning['code'] == 'symbolic_link_unsupported',
                  )
                  .length;
              message = AppMessage(
                symbolicLinks == warnings.length
                    ? 'symbolic_link_unsupported'
                    : 'library_item_unreadable',
                args: {'count': warnings.length},
              );
            }
            break;
          case 'operation':
            _applyOperation(data);
            break;
          case 'notice':
            message = AppMessage.fromMap(
              data,
              fallback: data['message'] as String?,
            );
            break;
        }
        _notify();
      },
      onError: (Object error) {
        if (_disposed || epoch != _eventEpoch) return;
        // Reconnect silently; a failed user command reports its own outcome.
        scheduleMicrotask(() => _disconnectEvents(epoch));
      },
      onDone: () {
        if (_disposed || epoch != _eventEpoch) return;
        scheduleMicrotask(() => _disconnectEvents(epoch));
      },
    );
    _subscription = subscription;
  }

  void _disconnectEvents(int epoch) {
    if (_disposed || epoch != _eventEpoch) return;
    final subscription = _subscription;
    if (subscription == null) return;
    _subscription = null;
    unawaited(subscription.cancel());
    final delays = [250, 750, 1500, 3000, 5000];
    final delayIndex = _eventReconnectAttempt < delays.length
        ? _eventReconnectAttempt
        : delays.length - 1;
    final delay = delays[delayIndex];
    _eventReconnectAttempt++;
    _eventReconnectTimer?.cancel();
    _eventReconnectTimer = Timer(Duration(milliseconds: delay), () async {
      if (_disposed || epoch != _eventEpoch || _subscription != null) return;
      _connectEvents();
      await command(
        'state',
        silent: true,
        onValue: _applyState,
      );
      unawaited(retryPreferences());
      unawaited(reconcileOperations());
    });
  }

  Future<void> initialize() {
    final existing = _initialization;
    if (existing != null) return existing;
    final future = _initialize();
    _initialization = future;
    return future;
  }

  void _applyState(dynamic value) {
    if (value is! Map) return;
    final incoming = Map<String, dynamic>.from(value);
    final generation = (incoming['generation'] as num?)?.toInt() ?? 0;
    if (generation < ((state['generation'] as num?)?.toInt() ?? 0)) return;
    if (generation == state['generation'] && incoming['revision'] is num && state['revision'] is num &&
        (incoming['revision'] as num) < (state['revision'] as num)) return;
    state = incoming;
  }

  void _applyRecords(dynamic value) {
    if (value is! Map) return;
    final revision = value['revision'];
    final wrapped = revision is num && value['records'] is Map;
    if (wrapped) {
      if (revision.toInt() < _recordsRevision) return;
      _recordsRevision = revision.toInt();
      final status = value['status'] as String?;
      recordsIssue = status == null || status == 'healthy' || status == 'library_records_loading'
          ? null : AppMessage(status);
    }
    final raw = wrapped ? value['records'] as Map : value;
    records = raw.map((key, item) => MapEntry(key as String, Map<String, dynamic>.from(item as Map)));
    libraryRevision++;
  }

  void _applyOperation(Map<dynamic, dynamic> data) {
    final id = data['operationId'] as String?;
    if (id == null || data['state'] != 'completed') return;
    final method = _uncertainOperations.remove(id);
    if (method == null) return;
    unawaited(refresh());
    if (data['success'] != true) {
      final failure = AppMessage(data['code'] as String? ?? 'operation_failed');
      if (failure.code.startsWith('library_records_')) { recordsIssue = failure; }
      else { message = failure; }
    }
  }

  Future<void> reconcileOperations() async {
    if (_uncertainOperations.isEmpty) return;
    await command('operationStatus', silent: true,
      args: {'ids': _uncertainOperations.keys.toList()},
      onValue: (value) { if (value is List) { for (final item in value.whereType<Map>()) { _applyOperation(item); } } });
  }

  Future<void> retryPreferences() {
    final existing = _preferenceRetry;
    if (existing != null) return existing;
    final future = _retryPreferences();
    _preferenceRetry = future;
    return future.whenComplete(() { if (identical(_preferenceRetry, future)) _preferenceRetry = null; });
  }

  Future<void> _retryPreferences() async {
    if (_disposed) return;
    await Future.wait([
      if (!_loadedPreferences.contains('appearance')) loadAppearance(),
      if (!_loadedPreferences.contains('language')) loadLanguage(),
      if (!_loadedPreferences.contains('libraryPreferences')) loadLibraryPreferences(),
    ]);
    if (_disposed || _loadedPreferences.length == 3) { _preferenceTimer?.cancel(); return; }
    if (_preferenceAttempts < 5) {
      _preferenceTimer?.cancel();
      _preferenceTimer = Timer(Duration(seconds: 1 << ++_preferenceAttempts), () { unawaited(retryPreferences()); });
    }
  }

  Future<void> _initialize() async {
    if (_disposed) return;
    initializing = true;
    _notify();
    _connectEvents();
    try {
      await command(
        'state',
        silent: true,
        onValue: _applyState,
      );
      await retryPreferences();
      await refresh();
    } finally {
      initializing = false;
      _notify();
    }
  }

  Duration? _timeoutFor(String method) {
    // A document picker may remain open for an arbitrary amount of time and a
    // selected folder may legitimately take minutes to copy. Native code owns
    // cancellation and terminal completion for this command.
    if (method == 'import') return null;
    final override = _commandTimeouts[method];
    if (override != null) return override;
    // Native library lanes report a terminal timeout at 30s (scan) or 45s
    // (mutations). These slightly longer Dart deadlines let that structured
    // result arrive instead of losing the operation id needed to reconcile a
    // late completion.
    if (_isolatedReadMethods.contains(method))
      return const Duration(seconds: 35);
    if (_mutationMethods.contains(method)) return const Duration(seconds: 50);
    if (method == 'open' || method == 'pip' || method == 'configure') return const Duration(seconds: 30);
    if (method == 'seek' || method == 'track')
      return const Duration(seconds: 12);
    return const Duration(seconds: 10);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Invalidates this isolate's reply handler. The native operation may still
  /// be running, so callers must reconcile native state before retrying a
  /// mutating command.
  void invalidateCommandResult(String method) {
    _activeCommands.remove(method);
  }

  Future<bool> command(
    String method, {
    Map<String, dynamic>? args,
    void Function(dynamic)? onValue,
    bool silent = false,
  }) async {
    if (_disposed) return false;
    final mutation = _mutationMethods.contains(method);
    if (mutation && fileBusy) return false;
    final commandId = ++_nextCommandId;
    if (mutation) { _fileCommand = commandId; _notify(); }
    _activeCommands[method] = commandId;
    final effectiveArgs = <String, dynamic>{...?args};
    if ((_mutationMethods.contains(method) ||
            _isolatedReadMethods.contains(method)) &&
        !effectiveArgs.containsKey('operationId')) {
      effectiveArgs['operationId'] =
          '${DateTime.now().microsecondsSinceEpoch}-$commandId';
    }
    bool isCurrent() => !_disposed && _activeCommands[method] == commandId;
    AppMessage? failureMessage;
    try {
      final pending = _methods.invokeMethod<dynamic>(
        method,
        effectiveArgs.isEmpty ? null : effectiveArgs,
      );
      final timeout = _timeoutFor(method);
      final dynamic value = timeout == null
          ? await pending
          : await pending.timeout(timeout);
      if (!isCurrent()) return false;
      _activeCommands.remove(method);
      onValue?.call(value);
      if (method == 'configure' || method == 'subtitle') _controlFailureIdentity = null;
      _notify();
      return true;
    } on TimeoutException catch (error) {
      if (!isCurrent()) return false;
      _activeCommands.remove(method);
      final operationId = effectiveArgs['operationId'] as String?;
      if (operationId != null) {
        if (_mutationMethods.contains(method)) {
          _uncertainOperations[operationId] = method;
        }
        failureMessage = AppMessage(
          'operation_timeout',
          args: {
            'operationId': operationId,
            'outcomeUnknown': _mutationMethods.contains(method),
          },
          technicalDetail: '$method: $error',
        );
      } else {
        failureMessage = AppMessage(
          'operation_failed',
          technicalDetail: '$method: $error',
        );
      }
    } on PlatformException catch (error) {
      if (!isCurrent()) return false;
      _activeCommands.remove(method);
      final details = error.details;
      if (error.code == 'operation_timeout' &&
          _mutationMethods.contains(method) &&
          details is Map) {
        final rawArgs = details['args'];
        final operationId = rawArgs is Map
            ? rawArgs['operationId'] as String?
            : null;
        if (operationId != null) _uncertainOperations[operationId] = method;
      }
      failureMessage = details is Map
          ? AppMessage.fromMap(<dynamic, dynamic>{
              ...details,
              'code': error.code,
            }, fallback: error.message)
          : AppMessage(
              error.code,
              fallback: error.message,
              technicalDetail: details == null ? null : '$details',
            );
    } on MissingPluginException {
      if (!isCurrent()) return false;
      _activeCommands.remove(method);
      failureMessage = const AppMessage('native_service_unavailable');
    } catch (error) {
      if (!isCurrent()) return false;
      _activeCommands.remove(method);
      failureMessage = AppMessage('operation_failed', technicalDetail: '$error');
    } finally {
      if (_fileCommand == commandId) { _fileCommand = null; _notify(); }
    }
    if (mutation && _uncertainOperations.isNotEmpty) unawaited(reconcileOperations());
    if (failureMessage.code == 'import_partial_failure' &&
        failureMessage.args['reasonCode'] == 'import_cancelled' &&
        failureMessage.args['completed'] == 0) failureMessage = null;
    if (failureMessage?.code.startsWith('library_records_') == true) {
      recordsIssue = failureMessage;
    } else if (!silent && failureMessage != null && !const {
      'file_operation_busy', 'purchase_busy', 'import_cancelled', 'control_superseded',
    }.contains(failureMessage.code)) {
      final identity = '${state['generation']}:${failureMessage.code}';
      if (method != 'configure' && method != 'subtitle' || identity != _controlFailureIdentity) {
        message = failureMessage;
      }
      if (method == 'configure' || method == 'subtitle') _controlFailureIdentity = identity;
    }
    _notify();
    return false;
  }

  Future<bool> refresh() {
    if (_disposed) return Future<bool>.value(false);
    _refreshQueued = true;
    final existing = _refreshCompleter;
    if (existing != null) return existing.future;
    if (importing) return Future<bool>.value(false);
    final completer = Completer<bool>();
    _refreshCompleter = completer;
    unawaited(_drainRefresh(completer));
    return completer.future;
  }

  Future<void> _drainRefresh(Completer<bool> completer) async {
    var attempted = false;
    var succeeded = true;
    try {
      while (_refreshQueued && !_disposed && !importing) {
        _refreshQueued = false;
        attempted = true;
        scanning = true;
        _notify();
        try {
          final scanned = await command(
            'scan',
            onValue: (value) {
              entries = (value as List)
                  .map((item) => MediaEntry(item as Map))
                  .toList();
              libraryRevision++;
            },
          );
          final recordsLoaded = scanned && await loadRecords();
          succeeded = succeeded && scanned && recordsLoaded;
        } finally {
          scanning = false;
          _notify();
        }
      }
    } finally {
      if (identical(_refreshCompleter, completer)) _refreshCompleter = null;
      if (!completer.isCompleted) completer.complete(attempted && succeeded);
    }
  }

  Future<bool> loadRecords() => command(
    'records',
    onValue: _applyRecords,
  );
  Future<void> importMedia({
    required bool folder,
    required String parent,
  }) async {
    if (fileBusy || scanning) return;
    importing = true;
    importIssue = null; importSkippedPaths = []; importSkippedCount = 0;
    _notify();
    var count = 0;
    var skippedCount = 0;
    List<String> importedPaths = [];
    var copied = false;
    try {
      copied = await command(
        'import',
        args: {'folder': folder, 'parent': parent},
        onValue: (value) {
          if (value is Map) {
            count = (value['count'] as num).toInt();
            importedPaths = (value['paths'] as List).cast<String>();
            skippedCount = (value['skippedCount'] as num?)?.toInt() ?? 0;
            importSkippedCount = skippedCount;
            importSkippedPaths = (value['warnings'] as List? ?? const [])
                .whereType<Map>().map((warning) => warning['path']).whereType<String>().toList();
          } else if (value is num) {
            // The picker returns zero on cancellation; tolerate an older native bridge.
            count = value.toInt();
          }
        },
      );
    } finally {
      importing = false;
      importProgress = null;
      _notify();
    }
    final refreshed = await refresh();
    if (copied && count > 0) {
      final indexed = entries
          .where((item) => item.parent == parent)
          .map((item) => item.path)
          .toSet();
      if (!refreshed) {
        message = AppMessage('import_refresh_failed', args: {'count': count});
      } else if (importedPaths.length != count ||
          !importedPaths.every(indexed.contains)) {
        message = AppMessage(
          'import_verification_failed',
          args: {'count': count},
        );
      } else if (skippedCount > 0) {
        importIssue = AppMessage('import_skipped_items', args: {'count': skippedCount});
      }
      _notify();
    }
  }

  Future<bool> open(
    List<MediaEntry> files,
    MediaEntry selected, {
    bool resume = true,
  }) => command(
    'open',
    args: {
      'paths': files.map((item) => item.path).toList(),
      'index': files.indexWhere((item) => item.path == selected.path),
      'resume': resume,
    },
    onValue: _applyState,
  );
  Future<void> favorite(MediaEntry item) async {
    final value = record(item.path)['favorite'] != true;
    if (await command('favorite', args: {'path': item.path, 'value': value})) {
      records[item.path] = {...record(item.path), 'favorite': value};
      libraryRevision++;
      _notify();
    }
  }

  Map<String, dynamic> _pendingConfiguration = {};
  final List<Completer<bool>> _configurationWaiters = [];
  bool _configuring = false;
  Object? _configurationGeneration;
  Future<bool> configure(Map<String, dynamic> values) {
    final completer = Completer<bool>();
    if (_configurationWaiters.isNotEmpty && _configurationGeneration != state['generation']) {
      for (final waiter in _configurationWaiters) { waiter.complete(false); }
      _configurationWaiters.clear(); _pendingConfiguration = {};
    }
    _configurationGeneration = state['generation'];
    _pendingConfiguration.addAll(values);
    _configurationWaiters.add(completer);
    if (!_configuring) unawaited(_drainConfiguration());
    return completer.future;
  }
  Future<void> _drainConfiguration() async {
    _configuring = true;
    try {
      while (_configurationWaiters.isNotEmpty) {
        final values = _pendingConfiguration;
        final generation = _configurationGeneration;
        final waiters = List<Completer<bool>>.of(_configurationWaiters);
        _pendingConfiguration = {}; _configurationWaiters.clear();
        final success = generation == state['generation'] && await command('configure',
          args: {...values, if (generation != null) 'generation': generation}, onValue: _applyState);
        for (final waiter in waiters) { waiter.complete(success); }
      }
    } finally { _configuring = false; }
  }
  Future<bool> seek(double value) async {
    var finished = false;
    final accepted = await command(
      'seek',
      args: {'seconds': value},
      onValue: (result) {
        finished = result == true;
      },
    );
    return accepted && finished;
  }

  Future<bool> previewSeek(double value) =>
      command('previewSeek', args: {'seconds': value});
  Future<bool> cancelScrub() => command('cancelScrub');
  bool? _desiredPlaying;
  Future<bool>? _toggleDrain;
  Future<bool> toggle() {
    _desiredPlaying = !(_desiredPlaying ?? (state['wantsPlayback'] as bool? ?? (playing || loading)));
    return _toggleDrain ??= _drainToggle().whenComplete(() {
      _toggleDrain = null; _desiredPlaying = null;
    });
  }
  Future<bool> _drainToggle() async {
    final generation = state['generation'];
    while (!_disposed && generation == state['generation']) {
      final desired = _desiredPlaying!;
      if (!await command(desired ? 'play' : 'pause', onValue: _applyState)) return false;
      if (_desiredPlaying == desired) return true;
    }
    return false;
  }
  void consumeMessage() {
    message = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _activeCommands.clear();
    _eventEpoch++;
    _eventReconnectTimer?.cancel();
    _preferenceTimer?.cancel();
    _subscription?.cancel();
    _subscription = null;
    mediaKit.removeListener(_notify);
    mediaKit.dispose();
    super.dispose();
  }

  static const Set<String> _mutationMethods = <String>{
    'favorite',
    'clearHistory',
    'createFolder',
    'move',
    'trash',
    'restore',
    'emptyTrash',
  };
  static const Set<String> _isolatedReadMethods = <String>{'scan', 'trashList'};
}

String timeLabel(double seconds) {
  final value = seconds.isFinite ? seconds.floor().clamp(0, 359999) : 0;
  final remainder = (value % 60).toString().padLeft(2, '0');
  if (value >= 3600)
    return '${value ~/ 3600}:${((value % 3600) ~/ 60).toString().padLeft(2, '0')}:$remainder';
  return '${(value ~/ 60).toString().padLeft(2, '0')}:$remainder';
}

String sizeLabel(int bytes) {
  if (bytes >= 1073741824)
    return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
  if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
}

int naturalCompare(String a, String b) {
  final pattern = RegExp(r'\d+|\D+');
  final left = pattern
      .allMatches(a.toLowerCase())
      .map((m) => m.group(0)!)
      .toList();
  final right = pattern
      .allMatches(b.toLowerCase())
      .map((m) => m.group(0)!)
      .toList();
  for (var i = 0; i < left.length && i < right.length; i++) {
    final x = BigInt.tryParse(left[i]), y = BigInt.tryParse(right[i]);
    final result = x != null && y != null
        ? x.compareTo(y)
        : left[i].compareTo(right[i]);
    if (result != 0) return result;
  }
  final result = left.length.compareTo(right.length);
  return result == 0 ? a.compareTo(b) : result;
}
