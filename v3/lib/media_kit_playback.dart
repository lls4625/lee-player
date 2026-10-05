import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

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
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final List<String> _errors = [];
  final Set<String> _timedOutProperties = {};
  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  bool _ready = false, _refreshing = false, _disposed = false, _releasing = false;
  String? _pipPreviousSwFast;
  String? _pipVideoTrack;
  String _failure = '';
  Map<String, dynamic> _diagnostics = {};

  Future<void> _createVideoOutput(Player player) async {
    final id = engineId;
    final videoController = controller;
    if (videoController == null) throw StateError('Flutter video controller was released');
    final handle = await player.handle;
    final previousTextureId = videoController.id.value;
    await _videoChannel.invokeMethod<void>('VideoOutputManager.Create', {
      'handle': '$handle',
      'configuration': const {
        'width': 'null', 'height': 'null', 'enableHardwareAcceleration': true,
      },
    });
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
    await native.setProperty('vid', track);
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
      // A new playback session must not wait behind a plugin Future which may
      // never complete. Late work is isolated by engineId and _requestedId.
      _commands = Future<void>.value();
    }
    final epoch = _commandEpoch;
    final result = Completer<bool>();
    _commands = _commands.then((_) async {
      try {
        final value = await _execute(call.method, args).timeout(_commandTimeout(call.method));
        if (!result.isCompleted) result.complete(value);
      } catch (error) {
        _log('${call.method}: $error');
        if (call.method == 'open' && _requestedId == id && epoch == _commandEpoch) {
          _failure = 'media_kit_open_failed';
          await _publishFailure();
        }
        if (!result.isCompleted) result.complete(false);
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

  Future<bool> _execute(String method, Map<String, dynamic> args) async {
    if (_disposed) return false;
    if (method == 'release') { await _release(); return true; }
    final id = args['engineId'] as String? ?? '';
    if (method == 'open') {
      if (_requestedId != id || id.isEmpty) return false;
      await _release();
      if (_requestedId != id) return false;
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
      _subscriptions.add(player.stream.error.listen((message) { _log(message); }));
      _subscriptions.add(player.stream.log.listen((entry) { _log('${entry.prefix}: ${entry.text}'); }));
      final native = player.platform as NativePlayer;
      await native.setProperty('audio-spdif', '');
      if (_requestedId != id) return false;
      await player.open(Media(args['url'] as String), play: false);
      if (_requestedId != id) return false;
      await player.setVolume(((args['volume'] as num?)?.toDouble() ?? 1) * 100);
      await player.setRate((args['rate'] as num?)?.toDouble() ?? 1);
      _ready = true;
      await _refresh(player, id);
      _timer = Timer.periodic(const Duration(milliseconds: 250), (_) { unawaited(_heartbeat(player, id)); });
      return true;
    }
    final player = _player;
    if (player == null || engineId != id || _releasing) return false;
    if (method == 'stop') { await _release(); return true; }
    if (_requestedId != id) return false;
    final native = player.platform as NativePlayer;
    switch (method) {
      case 'play': await player.play(); break;
      case 'pause': await player.pause(); break;
      case 'rate': await player.setRate((args['value'] as num).toDouble()); break;
      case 'volume': await player.setVolume((args['value'] as num).toDouble() * 100); break;
      case 'seek': return _seek(player, id, (args['seconds'] as num).toDouble());
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
        final requestId = args['requestId'] as String? ?? '';
        if (requestId.isEmpty) return false;
        final wasPlaying = player.state.playing;
        final videoTrack = await _property(native, 'vid');
        _pipVideoTrack = videoTrack == null || videoTrack == 'no' ? 'auto' : videoTrack;
        _pipPreviousSwFast = await _property(native, 'sw-fast') ?? 'no';
        var handoffBegan = false;
        var started = false;
        try {
          await player.pause();
          await native.setProperty('sw-fast', 'yes');
          await native.setProperty('vid', 'no');
          handoffBegan = true;
          await _videoChannel.invokeMethod<void>('VideoOutputManager.Dispose', {'handle': '$handle'});
          started = await _channel.invokeMethod<bool>('pipReady', {
            'engineId': id, 'requestId': requestId, 'handle': handle,
          }) ?? false;
          if (started && _requestedId == id) {
            await _restoreVideoTrack(native);
          }
          if (!started && handoffBegan && _requestedId == id && _player == player) {
            // The native request may have expired while this command was
            // queued. Roll back the output takeover without poisoning playback.
            await _restorePiPVideoOutput(player, native);
          }
          return started;
        } catch (error, stackTrace) {
          if (handoffBegan && _requestedId == id) {
            try { await _restorePiPVideoOutput(player, native); }
            catch (restoreError) {
              _log('pip output rollback failed: $restoreError');
              _failure = 'pip_restore_failed';
              await _publishFailure();
            }
          } else if (!handoffBegan) {
            try { await _restoreVideoTrack(native); }
            catch (restoreError) { _log('pip video rollback failed: $restoreError'); }
            try { await _restorePiPRenderingMode(native); }
            catch (restoreError) { _log('pip mode rollback failed: $restoreError'); }
          }
          Error.throwWithStackTrace(error, stackTrace);
        } finally {
          if (wasPlaying && _failure.isEmpty && _player == player && _requestedId == id) {
            try { await player.play(); }
            catch (error) { _log('pip resume failed: $error'); }
          }
        }
      case 'pipRestore':
        await _restorePiPVideoOutput(player, native);
        break;
      case 'loop':
        final start = (args['from'] as num).toDouble(), end = (args['to'] as num).toDouble();
        await native.setProperty('ab-loop-b', 'no');
        await native.setProperty('ab-loop-a', start >= 0 && end > start ? '$start' : 'no');
        if (start >= 0 && end > start) await native.setProperty('ab-loop-b', '$end');
        break;
      default: return false;
    }
    await _refresh(player, id);
    return _requestedId == id;
  }

  Future<void> _restorePiPVideoOutput(Player player, NativePlayer native) async {
    try {
      await _restorePiPRenderingMode(native);
    } catch (error) { _log('pip mode restore failed: $error'); }
    await _createVideoOutput(player);
    if (_pipPreviousSwFast != null) {
      try { await _restorePiPRenderingMode(native); }
      catch (error) { _log('pip mode restore retry failed: $error'); }
    }
  }

  Future<void> _restorePiPRenderingMode(NativePlayer native) async {
    final previousSwFast = _pipPreviousSwFast;
    if (previousSwFast != null) {
      await native.setProperty('sw-fast', previousSwFast);
      _pipPreviousSwFast = null;
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

  Future<bool> _seek(Player player, String id, double target) async {
    if (!target.isFinite || target < 0) return false;
    final native = player.platform as NativePlayer;
    await player.pause();
    await native.command(['seek', target.toStringAsFixed(6), 'absolute+exact']);
    final elapsed = Stopwatch()..start();
    var settled = 0;
    while (elapsed.elapsedMilliseconds < 6000 && _requestedId == id && !_disposed) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      final seeking = await native.getProperty('seeking');
      final position = double.tryParse(await native.getProperty('time-pos'));
      final idle = seeking == 'no' || seeking == 'false';
      if (idle && position != null && position.isFinite && (position - target).abs() <= 0.35) {
        settled++;
        if (settled >= 2) {
          _log('seek settled target=${target.toStringAsFixed(3)} position=${position.toStringAsFixed(3)} elapsed=${elapsed.elapsedMilliseconds}ms');
          await _refresh(player, id);
          return _requestedId == id;
        }
      } else { settled = 0; }
    }
    _log('seek not confirmed target=${target.toStringAsFixed(3)}');
    await _refresh(player, id);
    return false;
  }

  Future<void> _heartbeat(Player player, String id) async {
    if (_refreshing || _releasing || _disposed || _requestedId != id) return;
    _refreshing = true;
    try { await _refresh(player, id); }
    catch (error) { _log('state: $error'); }
    finally { _refreshing = false; }
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
    });
  }

  Future<void> _publishFailure() async {
    try {
      await _channel.invokeMethod<bool>('state', {'engineId': engineId, 'failure': _failure});
    } catch (_) {}
  }

  void _log(String text) {
    final entry = text.length > 600 ? text.substring(0, 600) : text;
    _errors.add('[${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(1)}s] $entry');
    if (_errors.length > 40) _errors.removeAt(0);
  }

  Future<void> _release() async {
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
    _releasing = true;
    _timedOutProperties.clear();
    _pipPreviousSwFast = null;
    _pipVideoTrack = null;
    timer?.cancel();
    if (!_disposed) notifyListeners();
    try {
      await (() async {
        for (final subscription in subscriptions) { await subscription.cancel(); }
        await player?.dispose();
      })().timeout(const Duration(seconds: 3));
    } on TimeoutException {
      _log('release timed out; previous engine quarantined');
    } catch (error) {
      _log('release failed: $error');
    } finally { _releasing = false; }
  }

  @override
  void dispose() {
    _disposed = true; _requestedId = null;
    _channel.setMethodCallHandler(null);
    _timer?.cancel();
    _commandEpoch++;
    _commands = _release().catchError((Object error) { _log('dispose: $error'); });
    super.dispose();
  }
}
