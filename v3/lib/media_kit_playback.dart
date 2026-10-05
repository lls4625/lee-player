import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'media_kit_recovery.dart';

class MediaKitPlayback extends ChangeNotifier {
  MediaKitPlayback() { _channel.setMethodCallHandler(_handle); }

  static const _channel = MethodChannel('lei.player/media_kit');
  static const _videoChannel = MethodChannel('com.alexmercerind/media_kit_video');
  Player? _player;
  VideoController? controller;
  String engineId = '';
  String? _requestedId;
  Future<void> _commands = Future<void>.value();
  int _commandEpoch = 0;
  final Set<MediaKitCommandPermit> _activePermits = {};
  int _refreshEpoch = 0;
  final MediaKitLatestIntent<bool> _playIntent = MediaKitLatestIntent<bool>();
  final MediaKitLatestIntent<double> _seekIntent = MediaKitLatestIntent<double>();
  final MediaKitCleanupCoordinator _cleanup = MediaKitCleanupCoordinator();
  final Map<Player, bool> _playRepairs = {};
  final Map<Player, bool> _seekRepairs = {};
  int _repairGeneration = 0;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final List<String> _errors = [];
  final Set<String> _timedOutProperties = {};
  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  bool _ready = false, _refreshing = false, _disposed = false, _releasing = false;
  int _releaseOperations = 0;
  String? _pipPreviousSwFast;
  String? _pipVideoTrack;
  String _failure = '';
  Map<String, dynamic> _diagnostics = {};

  Future<void> _createVideoOutput(Player player) async {
    final id = engineId;
    final videoController = controller;
    if (videoController == null) throw StateError('Flutter video controller was released');
    final handle = await player.handle;
    if (_requestedId != id || _player != player || _disposed) {
      throw StateError('Playback session changed');
    }
    final previousTextureId = videoController.id.value;
    await _videoChannel.invokeMethod<void>('VideoOutputManager.Create', {
      'handle': '$handle',
      'configuration': const {
        'width': 'null', 'height': 'null', 'enableHardwareAcceleration': true,
      },
    }).timeout(const Duration(seconds: 4));
    if (!await _waitForVideoTexture(videoController, id, previousTextureId)) {
      throw StateError('Flutter video output could not be recreated');
    }
    if (_requestedId != id || _player != player || _disposed) throw StateError('Playback session changed');
    await _restoreVideoTrack(player.platform as NativePlayer);
    final deadline = Stopwatch()..start();
    while (deadline.elapsed < const Duration(seconds: 12) && _requestedId == id && !_disposed) {
      final rect = videoController.rect.value;
      if (rect != null && rect.width > 0 && rect.height > 0) {
        _log('restored video output dimensions=${rect.width}x${rect.height}');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw StateError('Video output was registered without restored dimensions');
  }

  Future<void> _restoreVideoTrack(NativePlayer native) async {
    final track = _pipVideoTrack ?? 'auto';
    await native.setProperty('vid', track).timeout(const Duration(seconds: 2));
    _log('video track restored vid=$track');
  }

  Future<dynamic> _handle(MethodCall call) {
    final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
    final id = args['engineId'] as String?;
    if (call.method == 'open') _requestedId = id;
    if (call.method == 'release' || call.method == 'stop' && _requestedId == id) _requestedId = null;
    final barrier = call.method == 'open' || call.method == 'release' ||
      call.method == 'stop' && _requestedId == null;
    if (barrier) {
      _commandEpoch++;
      _repairGeneration++;
      _playRepairs.clear();
      _seekRepairs.clear();
      for (final active in _activePermits) { active.invalidate(); }
      // A new playback session must not wait behind a plugin Future which may
      // never complete. Late work is isolated by engineId and _requestedId.
      _commands = Future<void>.value();
    }
    final epoch = _commandEpoch;
    final permit = MediaKitCommandPermit();
    _activePermits.add(permit);
    if ((call.method == 'play' || call.method == 'pause') &&
        id != null && id == _requestedId) {
      args['_playIntent'] = _playIntent.record(call.method == 'play');
      final player = _player;
      if (player != null && _playRepairs.containsKey(player)) {
        _playRepairs[player] = true;
      }
    } else if (call.method == 'seek' && id != null && id == _requestedId) {
      final target = (args['seconds'] as num?)?.toDouble();
      if (target != null) {
        args['_seekIntent'] = _seekIntent.record(target);
        final player = _player;
        if (player != null && _seekRepairs.containsKey(player)) {
          _seekRepairs[player] = true;
        }
      }
    }
    final result = Completer<bool>();
    _commands = _commands.then((_) async {
      try {
        final value = await _execute(call.method, args, permit).timeout(_commandTimeout(call.method));
        if (!result.isCompleted) result.complete(value);
      } catch (error) {
        // Future.timeout cannot cancel its source.  Invalidate it so that any
        // late continuation cannot publish state or install a heartbeat.
        permit.invalidate();
        _log('${call.method}: $error');
        if (call.method == 'open' && _requestedId == id && epoch == _commandEpoch) {
          _failure = 'media_kit_open_failed';
          await _publishFailure();
        }
        if (!result.isCompleted) result.complete(false);
      } finally {
        _activePermits.remove(permit);
      }
    });
    return result.future;
  }

  Duration _commandTimeout(String method) => switch (method) {
    'open' => const Duration(seconds: 14),
    'pip' => const Duration(seconds: 18),
    'pipRestore' => const Duration(seconds: 22),
    'seek' => const Duration(seconds: 8),
    'release' || 'stop' => const Duration(seconds: 4),
    _ => const Duration(seconds: 6),
  };

  Future<bool> _execute(String method, Map<String, dynamic> args,
      MediaKitCommandPermit permit) async {
    if (_disposed || !permit.isValid) return false;
    if (method == 'release') return _release();
    final id = args['engineId'] as String? ?? '';
    if (method == 'open') {
      if (_requestedId != id || id.isEmpty) return false;
      final released = await _release();
      if (!released) return false;
      if (!_allows(permit, id)) return false;
      MediaKit.ensureInitialized();
      engineId = id;
      _clock.reset(); _clock.start();
      _errors.clear(); _timedOutProperties.clear(); _diagnostics = {}; _failure = ''; _ready = false;
      final player = Player(configuration: const PlayerConfiguration(libass: true, logLevel: MPVLogLevel.warn));
      _player = player;
      if (args['isAudio'] != true) {
        controller = VideoController(player,
          configuration: const VideoControllerConfiguration(enableHardwareAcceleration: true));
      }
      notifyListeners();
      _subscriptions.add(player.stream.error.listen((message) {
        unawaited(_handleRuntimeError(player, id, message));
      }));
      _subscriptions.add(player.stream.log.listen((entry) { _log('${entry.prefix}: ${entry.text}'); }));
      final native = player.platform as NativePlayer;
      await native.setProperty('audio-spdif', '');
      if (!_allows(permit, id, player)) {
        await _abandonOpen(player);
        return false;
      }
      await player.open(Media(args['url'] as String), play: false);
      if (!_allows(permit, id, player)) {
        await _abandonOpen(player);
        return false;
      }
      await player.setVolume(((args['volume'] as num?)?.toDouble() ?? 1) * 100);
      if (!_allows(permit, id, player)) {
        await _abandonOpen(player);
        return false;
      }
      await player.setRate((args['rate'] as num?)?.toDouble() ?? 1);
      if (!_allows(permit, id, player)) {
        await _abandonOpen(player);
        return false;
      }
      _ready = true;
      await _refresh(player, id);
      if (!_allows(permit, id, player)) {
        await _abandonOpen(player);
        return false;
      }
      _timer = Timer.periodic(const Duration(milliseconds: 250), (_) { unawaited(_heartbeat(player, id)); });
      return true;
    }
    final player = _player;
    if (player == null || engineId != id || _releasing) return false;
    if (method == 'stop') return _release();
    if (_requestedId != id) return false;
    final native = player.platform as NativePlayer;
    switch (method) {
      case 'play':
      case 'pause':
        final intent = args['_playIntent'] as int;
        if (method == 'play') { await player.play(); } else { await player.pause(); }
        if (!_allows(permit, id, player) || !_playIntent.isLatest(intent)) {
          _scheduleLatestPlayIntent(player, id);
          return false;
        }
        break;
      case 'rate': await player.setRate((args['value'] as num).toDouble()); break;
      case 'volume': await player.setVolume((args['value'] as num).toDouble() * 100); break;
      case 'seek':
        return _seek(player, id, (args['seconds'] as num).toDouble(),
            args['_seekIntent'] as int, permit);
      case 'track':
        final kind = args['kind'] as String;
        final trackId = args['trackId'] as String? ?? 'no';
        if (kind == 'audio') {
          final tracks = player.state.tracks.audio.where((track) => track.id == trackId);
          if (trackId != 'no' && tracks.isEmpty) return false;
          await player.setAudioTrack(trackId == 'no' ? AudioTrack.no() : tracks.first);
        } else if (kind == 'subtitle') {
          final tracks = player.state.tracks.subtitle.where((track) => track.id == trackId);
          if (trackId != 'no' && tracks.isEmpty) return false;
          await player.setSubtitleTrack(trackId == 'no' ? SubtitleTrack.no() : tracks.first);
        } else { return false; }
        break;
      case 'subtitle': await player.setSubtitleTrack(SubtitleTrack.uri(args['url'] as String)); break;
      case 'pip':
        final handle = await player.handle;
        if (!_allows(permit, id, player)) return false;
        final requestId = args['requestId'] as String? ?? '';
        if (requestId.isEmpty) return false;
        final wasPlaying = player.state.playing;
        final videoTrack = await _property(native, 'vid');
        if (!_allows(permit, id, player)) return false;
        final previousSwFast = await _property(native, 'sw-fast') ?? 'no';
        if (!_allows(permit, id, player)) return false;
        _pipVideoTrack = videoTrack == null || videoTrack == 'no' ? 'auto' : videoTrack;
        _pipPreviousSwFast = previousSwFast;
        var handoffBegan = false;
        var started = false;
        try {
          await player.pause();
          if (!_allows(permit, id, player)) return false;
          await native.setProperty('sw-fast', 'yes');
          if (!_allows(permit, id, player)) {
            await _restorePiPRenderingMode(native, player, id);
            return false;
          }
          await native.setProperty('vid', 'no');
          if (!_allows(permit, id, player)) {
            await _restoreVideoTrack(native);
            await _restorePiPRenderingMode(native, player, id);
            return false;
          }
          handoffBegan = true;
          await _videoChannel.invokeMethod<void>('VideoOutputManager.Dispose', {'handle': '$handle'});
          if (!_allows(permit, id, player)) {
            if (_sameSession(player, id)) {
              await _restorePiPVideoOutput(player, native, id);
            }
            return false;
          }
          started = await _channel.invokeMethod<bool>('pipReady', {
            'engineId': id, 'requestId': requestId, 'handle': handle,
          }) ?? false;
          if (!_allows(permit, id, player)) {
            if (started) {
              await _recoverStartedPiPFailure(player, native, id, requestId);
            } else if (handoffBegan && _sameSession(player, id)) {
              await _restorePiPVideoOutput(player, native, id);
            }
            return false;
          }
          if (started && _allows(permit, id, player)) {
            await _restoreVideoTrack(native);
            if (!_allows(permit, id, player)) {
              await _recoverStartedPiPFailure(
                  player, native, id, requestId);
              return false;
            }
          }
          if (!started && handoffBegan && _allows(permit, id, player)) {
            // The native request may have expired while this command was
            // queued. Roll back the output takeover without poisoning playback.
            await _restorePiPVideoOutput(player, native, id);
          }
          return started && _allows(permit, id, player);
        } catch (error, stackTrace) {
          if (started) {
            await _recoverStartedPiPFailure(player, native, id, requestId);
          } else if (handoffBegan && _sameSession(player, id)) {
            try { await _restorePiPVideoOutput(player, native, id); }
            catch (restoreError) {
              _log('pip output rollback failed: $restoreError');
              _failure = 'pip_restore_failed';
              await _publishFailure();
            }
          } else if (!handoffBegan && _sameSession(player, id)) {
            try { await _restoreVideoTrack(native); }
            catch (restoreError) { _log('pip video rollback failed: $restoreError'); }
            try { await _restorePiPRenderingMode(native, player, id); }
            catch (restoreError) { _log('pip mode rollback failed: $restoreError'); }
          }
          Error.throwWithStackTrace(error, stackTrace);
        } finally {
          if (wasPlaying && _playIntent.value != false && _failure.isEmpty &&
              _sameSession(player, id)) {
            if (_playIntent.value == null) _playIntent.record(true);
            _scheduleLatestPlayIntent(player, id);
          }
        }
      case 'pipRestore':
        await _restorePiPVideoOutput(player, native, id);
        break;
      case 'loop':
        final start = (args['from'] as num).toDouble(), end = (args['to'] as num).toDouble();
        await native.setProperty('ab-loop-b', 'no');
        await native.setProperty('ab-loop-a', start >= 0 && end > start ? '$start' : 'no');
        if (start >= 0 && end > start) await native.setProperty('ab-loop-b', '$end');
        break;
      default: return false;
    }
    if (!_allows(permit, id, player)) return false;
    await _refresh(player, id);
    return _allows(permit, id, player);
  }

  bool _allows(MediaKitCommandPermit permit, String id, [Player? player]) =>
      permit.isValid && !_disposed && _requestedId == id &&
      (player == null || _player == player);

  bool _sameSession(Player player, String id) =>
      !_disposed && _requestedId == id && _player == player;

  Future<bool> _abortNativePiP(String id, String requestId) async {
    try {
      return await _channel.invokeMethod<bool>('pipAbort', {
        'engineId': id,
        'requestId': requestId,
      }).timeout(const Duration(seconds: 2)) ?? false;
    } catch (error) {
      _log('native pip abort failed: $error');
      return false;
    }
  }

  Future<void> _recoverStartedPiPFailure(Player player, NativePlayer native,
      String id, String requestId) async {
    final aborted = await _abortNativePiP(id, requestId);
    if (aborted && _sameSession(player, id)) {
      try {
        await _restorePiPVideoOutput(player, native, id);
        return;
      } catch (error) {
        _log('inline output restore after pip abort failed: $error');
      }
    }
    if (_sameSession(player, id)) {
      _failure = 'pip_restore_failed';
      await _publishFailure(id);
      // An unverified native PiP owner and an inline output must never coexist.
      // Full release is the conservative fallback when the keyed abort fails.
      await _release();
    }
  }

  Future<void> _abandonOpen(Player player) async {
    if (_player == player) {
      await _release();
      return;
    }
    // A different current player is only possible after a release barrier,
    // which already transferred ownership of this stale player to _cleanup.
    final cleaned = await _cleanup.drain(const Duration(seconds: 3));
    if (!cleaned) _log('stale open remains quarantined behind cleanup gate');
  }

  Future<void> _restorePiPVideoOutput(
      Player player, NativePlayer native, String id) async {
    if (_disposed || _requestedId != id || _player != player) return;
    try {
      await _restorePiPRenderingMode(native, player, id);
    } catch (error) { _log('pip mode restore failed: $error'); }
    if (_disposed || _requestedId != id || _player != player) return;
    await _createVideoOutput(player);
    if (_pipPreviousSwFast != null && !_disposed && _requestedId == id && _player == player) {
      try { await _restorePiPRenderingMode(native, player, id); }
      catch (error) { _log('pip mode restore retry failed: $error'); }
    }
  }

  Future<void> _restorePiPRenderingMode(NativePlayer native,
      [Player? player, String? id]) async {
    if (player != null && (id == null || _disposed || _requestedId != id || _player != player)) return;
    final previousSwFast = _pipPreviousSwFast;
    if (previousSwFast != null) {
      await native.setProperty('sw-fast', previousSwFast)
          .timeout(const Duration(seconds: 2));
      if (player == null ||
          (!_disposed && _requestedId == id && _player == player &&
              _pipPreviousSwFast == previousSwFast)) {
        _pipPreviousSwFast = null;
      }
    }
  }

  Future<bool> _waitForVideoTexture(
      VideoController videoController, String id, int? previousTextureId) async {
    final elapsed = Stopwatch()..start();
    while (elapsed.elapsed < const Duration(seconds: 8) &&
        !_disposed && !_releasing && _requestedId == id) {
      final textureId = videoController.id.value;
      final rect = videoController.rect.value;
      if (textureId != null && textureId != previousTextureId) {
        final size = rect != null && rect.width > 0 && rect.height > 0
            ? '${rect.width.toInt()}x${rect.height.toInt()}' : 'pending-frame';
        _log('video texture ready id=$textureId size=$size '
            'after ${elapsed.elapsedMilliseconds}ms');
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    _log('video texture not confirmed after ${elapsed.elapsedMilliseconds}ms');
    return false;
  }

  Future<bool> _seek(Player player, String id, double target, int intent,
      MediaKitCommandPermit permit) async {
    if (!target.isFinite || target < 0) return false;
    final native = player.platform as NativePlayer;
    await player.pause();
    await native.command(['seek', target.toStringAsFixed(6), 'absolute+exact']);
    if (!_allows(permit, id, player) || !_seekIntent.isLatest(intent)) {
      _scheduleLatestSeekIntent(player, id);
      return false;
    }
    final elapsed = Stopwatch()..start();
    var settled = 0;
    while (elapsed.elapsedMilliseconds < 6000 && _allows(permit, id, player) &&
        _seekIntent.isLatest(intent)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      final seeking = await _property(native, 'seeking');
      final position = double.tryParse(await _property(native, 'time-pos') ?? '');
      final idle = seeking == 'no' || seeking == 'false';
      if (idle && position != null && position.isFinite && (position - target).abs() <= 0.35) {
        settled++;
        if (settled >= 2) {
          _log('seek settled target=${target.toStringAsFixed(3)} position=${position.toStringAsFixed(3)} elapsed=${elapsed.elapsedMilliseconds}ms');
          await _refresh(player, id);
          return _allows(permit, id, player) && _seekIntent.isLatest(intent);
        }
      } else { settled = 0; }
    }
    if (!_seekIntent.isLatest(intent) || !permit.isValid) {
      _scheduleLatestSeekIntent(player, id);
      return false;
    }
    _log('seek not confirmed target=${target.toStringAsFixed(3)}');
    await _refresh(player, id);
    return false;
  }

  void _scheduleLatestPlayIntent(Player player, String id) {
    if (!_sameSession(player, id)) return;
    if (_playRepairs.containsKey(player)) {
      _playRepairs[player] = true;
      return;
    }
    _playRepairs[player] = true;
    final generation = _repairGeneration;
    final budget = MediaKitRepairBudget();
    unawaited(() async {
      try {
        while (_playRepairs[player] == true && _sameSession(player, id) &&
            generation == _repairGeneration && budget.beginAttempt()) {
          _playRepairs[player] = false;
          final version = _playIntent.version;
          final operation = _playIntent.value == true ? player.play() : player.pause();
          final weakPlayer = WeakReference<Player>(player);
          unawaited(operation.then<void>((_) {
            final latePlayer = weakPlayer.target;
            if (latePlayer != null && generation == _repairGeneration &&
                _sameSession(latePlayer, id) &&
                !_playIntent.isLatest(version)) {
              _scheduleLatestPlayIntent(latePlayer, id);
            }
          }, onError: (_) {}));
          try {
            await operation.timeout(const Duration(seconds: 1));
          } on TimeoutException {
            _log('play intent recovery timed out; late completion is guarded');
            if (_playRepairs[player] == true) continue;
            break;
          }
          if (!_playIntent.isLatest(version)) _playRepairs[player] = true;
        }
      } catch (error) { _log('play intent recovery failed: $error'); }
      finally { _playRepairs.remove(player); }
    }());
  }

  void _scheduleLatestSeekIntent(Player player, String id) {
    if (!_sameSession(player, id)) return;
    if (_seekRepairs.containsKey(player)) {
      _seekRepairs[player] = true;
      return;
    }
    _seekRepairs[player] = true;
    final generation = _repairGeneration;
    final budget = MediaKitRepairBudget();
    unawaited(() async {
      try {
        final native = player.platform as NativePlayer;
        while (_seekRepairs[player] == true && _sameSession(player, id) &&
            generation == _repairGeneration && budget.beginAttempt()) {
          _seekRepairs[player] = false;
          final version = _seekIntent.version;
          final target = _seekIntent.value;
          if (target == null || !target.isFinite || target < 0) break;
          final operation = native.command([
            'seek', target.toStringAsFixed(6), 'absolute+exact',
          ]);
          final weakPlayer = WeakReference<Player>(player);
          unawaited(operation.then<void>((_) {
            final latePlayer = weakPlayer.target;
            if (latePlayer != null && generation == _repairGeneration &&
                _sameSession(latePlayer, id) &&
                !_seekIntent.isLatest(version)) {
              _scheduleLatestSeekIntent(latePlayer, id);
            }
          }, onError: (_) {}));
          try {
            await operation.timeout(const Duration(seconds: 1));
          } on TimeoutException {
            _log('seek intent recovery timed out; late completion is guarded');
            if (_seekRepairs[player] == true) continue;
            break;
          }
          if (!_seekIntent.isLatest(version)) _seekRepairs[player] = true;
        }
      } catch (error) { _log('seek intent recovery failed: $error'); }
      finally { _seekRepairs.remove(player); }
    }());
  }

  Future<void> _heartbeat(Player player, String id) async {
    if (_refreshing || _releasing || _disposed || _requestedId != id || _player != player) return;
    final epoch = _refreshEpoch;
    _refreshing = true;
    try { await _refresh(player, id); }
    catch (error) { _log('state: $error'); }
    finally {
      if (_refreshEpoch == epoch && _player == player && _requestedId == id) {
        _refreshing = false;
      }
    }
  }

  Future<void> _handleRuntimeError(Player player, String id, String message) async {
    if (_disposed || _player != player || _requestedId != id) return;
    _log('runtime: $message');
    if (classifyMediaKitRuntimeError(message) != MediaKitRuntimeErrorKind.fatal) return;
    _failure = 'media_kit_open_failed';
    _ready = false;
    _timer?.cancel();
    _timer = null;
    await _publishFailure(id);
  }

  Future<String?> _property(NativePlayer native, String name) async {
    try {
      final value = await native.getProperty(name).timeout(const Duration(milliseconds: 750));
      _timedOutProperties.remove(name);
      return value.isEmpty ? null : value;
    } on TimeoutException {
      if (_timedOutProperties.add(name)) _log('property timeout: $name');
      return null;
    } catch (_) { return null; }
  }

  Future<void> _refresh(Player player, String id) async {
    if (_disposed || _releasing || _player != player || _requestedId != id) return;
    final native = player.platform as NativePlayer;
    final values = await Future.wait([
      _property(native, 'time-pos'), _property(native, 'duration'),
      _property(native, 'seekable'), _property(native, 'aid'), _property(native, 'sid'),
      _property(native, 'pause'), _property(native, 'eof-reached'),
      _property(native, 'mpv-version'), _property(native, 'hwdec-current'),
      _property(native, 'current-vo'), _property(native, 'decoder-frame-drop-count'),
      _property(native, 'frame-drop-count'), _property(native, 'speed'),
    ]);
    if (_disposed || _releasing || _player != player || _requestedId != id) return;
    final state = player.state;
    final audio = state.tracks.audio.where((track) => track.id != 'auto' && track.id != 'no').toList();
    final subtitles = state.tracks.subtitle.where((track) => track.id != 'auto' && track.id != 'no').toList();
    final audioRows = [for (var index = 0; index < audio.length; index++) {
      'index': index, 'id': audio[index].id,
      'name': [audio[index].title ?? 'Audio ${index + 1}', audio[index].language,
        audio[index].codec, if (audio[index].channelscount != null) '${audio[index].channelscount} ch']
        .whereType<String>().where((text) => text.isNotEmpty).join(' · '),
      'selected': audio[index].id == values[3],
    }];
    final subtitleRows = [for (var index = 0; index < subtitles.length; index++) {
      'index': index, 'id': subtitles[index].id,
      'name': [subtitles[index].title ?? 'Subtitle ${index + 1}', subtitles[index].language, subtitles[index].codec]
        .whereType<String>().where((text) => text.isNotEmpty).join(' · '),
      'selected': subtitles[index].id == values[4],
    }];
    _diagnostics = {
      'decoderCode': 'automatic_hardware_decode',
      'version': values[7], 'hwdec': values[8], 'vo': values[9],
      'decoderDrops': values[10], 'outputDrops': values[11],
      'actualRate': values[12], 'errors': List<String>.from(_errors),
    };
    final position = double.tryParse(values[0] ?? '') ?? state.position.inMicroseconds / 1000000;
    final duration = double.tryParse(values[1] ?? '') ?? state.duration.inMicroseconds / 1000000;
    await _channel.invokeMethod<bool>('state', {
      'engineId': id, 'position': position.isFinite ? position : 0,
      'duration': duration.isFinite ? duration : 0, 'ready': _ready,
      'seekable': values[2] == 'yes' || values[2] == 'true',
      'playing': values[5] == null
        ? state.playing
        : (values[5] == 'no' || values[5] == 'false') && values[6] != 'yes' && values[6] != 'true',
      'buffering': state.buffering,
      'ended': values[6] == null ? state.completed : values[6] == 'yes' || values[6] == 'true',
      'failure': _failure, 'diagnostics': _diagnostics,
      'tracks': {'audioTracks': audioRows, 'subtitleTracks': subtitleRows,
        'audioTrack': audio.indexWhere((track) => track.id == values[3]),
        'subtitleTrack': subtitles.indexWhere((track) => track.id == values[4])},
    }).timeout(const Duration(seconds: 2));
  }

  Future<void> _publishFailure([String? sessionId]) async {
    final id = sessionId ?? engineId;
    try {
      await _channel.invokeMethod<bool>('state', {'engineId': id, 'failure': _failure})
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  void _log(String text) {
    final entry = text.length > 600 ? text.substring(0, 600) : text;
    _errors.add('[${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(1)}s] $entry');
    if (_errors.length > 40) _errors.removeAt(0);
  }

  Future<bool> _release() async {
    final player = _player;
    final subscriptions = List<StreamSubscription<dynamic>>.from(_subscriptions);
    final timer = _timer;
    _player = null;
    _subscriptions.clear();
    _timer = null;
    controller = null;
    engineId = '';
    _ready = false;
    _refreshing = false;
    _refreshEpoch++;
    _repairGeneration++;
    _playRepairs.clear();
    _seekRepairs.clear();
    _releaseOperations++;
    _releasing = true;
    _timedOutProperties.clear();
    _pipPreviousSwFast = null;
    _pipVideoTrack = null;
    timer?.cancel();
    if (!_disposed) notifyListeners();
    if (player != null || subscriptions.isNotEmpty) {
      _cleanup.add(() async {
        for (final subscription in subscriptions) { await subscription.cancel(); }
        await player?.dispose();
      });
    }
    final cleaned = await _cleanup.drain(const Duration(seconds: 3));
    if (!cleaned) {
      final error = _cleanup.lastError;
      _log(error == null
          ? 'release timed out; previous engine quarantined'
          : 'release failed; cleanup retained for retry: $error');
    }
    _releaseOperations--;
    _releasing = _releaseOperations > 0;
    return cleaned;
  }

  @override
  void dispose() {
    _disposed = true; _requestedId = null;
    _channel.setMethodCallHandler(null);
    _timer?.cancel();
    _commandEpoch++;
    for (final active in _activePermits) { active.invalidate(); }
    _commands = _release()
        .then<void>((_) {})
        .catchError((Object error) { _log('dispose: $error'); });
    super.dispose();
  }
}
