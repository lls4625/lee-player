import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'media_kit_recovery.dart';
import 'media_kit_measurements.dart';
import 'media_kit_subtitle_fonts.dart';

class MediaKitPlayback extends ChangeNotifier with WidgetsBindingObserver {
  MediaKitPlayback() {
    _channel.setMethodCallHandler(_handle);
    WidgetsBinding.instance.addObserver(this);
  }

  static const _channel = MethodChannel('lei.player/media_kit');
  static const _videoChannel = MethodChannel('com.alexmercerind/media_kit_video');
  Player? _player;
  VideoController? controller;
  int? _videoAttachFrame;
  Completer<void>? _videoAttachReady;
  String engineId = '';
  String? _requestedId;
  Future<void> _commands = Future<void>.value();
  int _commandEpoch = 0;
  final Set<MediaKitCommandPermit> _activePermits = {};
  int _refreshEpoch = 0;
  final MediaKitSnapshotFence _snapshots = MediaKitSnapshotFence();
  final MediaKitLatestIntent<bool> _playIntent = MediaKitLatestIntent<bool>();
  final MediaKitLatestIntent<double> _seekIntent = MediaKitLatestIntent<double>();
  final MediaKitCleanupCoordinator _cleanup = MediaKitCleanupCoordinator();
  final Map<Player, bool> _playRepairs = {};
  final Map<Player, bool> _seekRepairs = {};
  int _repairGeneration = 0;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final List<String> _errors = [];
  final Set<String> _timedOutProperties = {};
  final MediaKitSubtitleFonts _subtitleFonts = MediaKitSubtitleFonts();
  MediaKitDecoderRecoveryMonitor _decoderMonitor = MediaKitDecoderRecoveryMonitor();
  bool _decoderRecoveryRunning = false;
  bool _isAudio = false;
  int _activeSeeks = 0;
  String _decoderRecoveryStatus = 'idle';
  final Map<String, String> _propertyStatus = {};
  String _subtitleFontStatus = 'unavailable';
  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  bool _ready = false, _refreshing = false, _disposed = false, _releasing = false;
  int _releaseOperations = 0;
  String? _pipPreviousSwFast;
  String? _pipVideoTrack;
  String? _deferredPiPRestoreId;
  bool _pipInlineOutputDetached = false;
  bool _pipRestoreCreateIssued = false;
  int? _pipRestorePreviousTextureId;
  String _failure = '';
  Map<String, dynamic> _diagnostics = {};
  MediaKitPlaybackMeasurements? _measurements;
  int _measurementWindow = 0;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Never count time spent suspended as event-loop delay.
    _resetMeasurementWindow();
    if (state == AppLifecycleState.resumed) {
      final player = _player;
      if (player != null) _scheduleVideoAttachment(player, engineId);
      _notifyPiPRestoreForeground();
    } else {
      // A foreground open waiting for its first frame can still become an
      // audio-only background open. Do not leave it waiting on a hidden UI.
      _cancelVideoAttachment();
    }
  }

  void _scheduleVideoAttachment(Player player, String id) {
    if (!_sameSession(player, id) || _isAudio || controller != null ||
        _failure.isNotEmpty || _videoAttachFrame != null ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
    // media_kit_video 2.0.1 marks the player as video-attached immediately,
    // then waits for a post-frame callback. NativePlayer.open, controls and
    // dispose all wait for that attachment. A background/locked app has no
    // frames, so keep the default vid=no audio path independent of Flutter.
    // Construct at frame START: the plugin's post-frame callback can complete
    // in this same frame, including when open races with going to background.
    final ready = _videoAttachReady = Completer<void>();
    _videoAttachFrame = WidgetsBinding.instance.scheduleFrameCallback((_) {
      _videoAttachFrame = null;
      _videoAttachReady = null;
      try {
        if (!_sameSession(player, id) || _isAudio || controller != null ||
            _failure.isNotEmpty ||
            WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
        controller = VideoController(player,
          configuration: const VideoControllerConfiguration(enableHardwareAcceleration: true));
        _log('inline video attached on foreground frame');
        // Attach the existing player only. Never reopen, seek or change play
        // intent here: pause, background-off and newer sessions must still win.
        notifyListeners();
      } finally {
        ready.complete();
      }
    });
  }

  void _cancelVideoAttachment() {
    final frame = _videoAttachFrame;
    _videoAttachFrame = null;
    if (frame != null) WidgetsBinding.instance.cancelFrameCallbackWithId(frame);
    _videoAttachReady?.complete();
    _videoAttachReady = null;
  }

  void _resetMeasurementWindow() {
    _measurementWindow++;
    _measurements?.resetHeartbeat();
  }

  bool _steadyMeasurementEligible(Player player, String id) =>
      _sameSession(player, id) && !_releasing && _ready &&
      !_decoderRecoveryRunning && _activeSeeks == 0 && _activePermits.isEmpty &&
      _failure.isEmpty &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
      player.state.playing && !player.state.buffering;

  Map<String, Object?> _measurementSnapshot() => {
    ...?_measurements?.snapshot(),
    'buildMode': kDebugMode ? 'debug' : kProfileMode ? 'profile' : 'release',
  };


  bool get _foregroundVideoAllowed =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  void _notifyPiPRestoreForeground() {
    final id = _deferredPiPRestoreId;
    if (id == null || id != _requestedId || !_foregroundVideoAllowed || _disposed) return;
    unawaited(_channel.invokeMethod<void>('pipRestoreForeground', {'engineId': id})
        .catchError((Object error) { _log('pip foreground notification failed: $error'); }));
  }

  Future<void> _deferPiPVideoOutput(Player player, String id, String? requestId) async {
    if (!_sameSession(player, id)) return;
    final accepted = await _channel.invokeMethod<bool>('pipRestoreDeferred', {
      'engineId': id, if (requestId != null) 'requestId': requestId,
    }).timeout(const Duration(seconds: 2)) ?? false;
    if (!_sameSession(player, id)) return;
    if (!accepted) throw StateError('PiP output deferral was superseded');
    _deferredPiPRestoreId = id;
    _log('inline PiP output deferred until foreground');
    // Native and Flutter lifecycle notifications can arrive in either order.
    // A resumed event that happened while this receipt was in flight is enough.
    _notifyPiPRestoreForeground();
  }

  Future<bool> _createVideoOutput(Player player, String id,
      MediaKitCommandPermit? permit) async {
    bool current() => _sameSession(player, id) && (permit?.isValid ?? true);
    final videoController = controller;
    if (videoController == null) throw StateError('Flutter video controller was released');
    if (!current()) throw StateError('Playback session changed');
    if (!_foregroundVideoAllowed) return false;
    final handle = await player.handle;
    if (!current()) throw StateError('Playback session changed');
    if (!_foregroundVideoAllowed) return false;
    if (!_pipRestoreCreateIssued) {
      _pipRestorePreviousTextureId = videoController.id.value;
      _pipRestoreCreateIssued = true;
      try {
        await _videoChannel.invokeMethod<void>('VideoOutputManager.Create', {
          'handle': '$handle',
          // Opt-in: leave the established headless-open attachment path alone.
          'requireForeground': true,
          'configuration': const {
            'width': 'null', 'height': 'null', 'enableHardwareAcceleration': true,
          },
        }).timeout(const Duration(seconds: 4));
      } on PlatformException catch (error) {
        if (!current()) throw StateError('Playback session changed');
        if (error.code != 'video_output_background') rethrow;
        _pipRestoreCreateIssued = false;
        return false;
      }
    }
    if (!await _waitForVideoTexture(videoController, id, _pipRestorePreviousTextureId)) {
      if (current() && !_foregroundVideoAllowed) return false;
      throw StateError('Flutter video output could not be recreated');
    }
    if (!current()) throw StateError('Playback session changed');
    if (!_foregroundVideoAllowed) return false;
    await _restoreVideoTrack(player.platform as NativePlayer);
    final deadline = Stopwatch()..start();
    while (deadline.elapsed < const Duration(seconds: 12) && current()) {
      if (!_foregroundVideoAllowed) return false;
      final rect = videoController.rect.value;
      if (rect != null && rect.width > 0 && rect.height > 0) {
        _log('restored video output dimensions=${rect.width}x${rect.height}');
        _pipInlineOutputDetached = false;
        _pipRestoreCreateIssued = false;
        _deferredPiPRestoreId = null;
        return true;
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

  final Map<String, MediaKitCommandPermit> _controlPermits = {};
  Future<dynamic> _handle(MethodCall call) {
    final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
    final id = args['engineId'] as String?;
    final requestId = args['requestId'] as String?;
    // Fence existing reads immediately, not when this command eventually runs.
    if (call.method == 'open' || call.method == 'seek') {
      final positionVersion = args['positionVersion'];
      if (positionVersion is! int || positionVersion < 0) {
        return Future<bool>.value(false);
      }
      if (call.method == 'open') {
        if (id == null || id.isEmpty) return Future<bool>.value(false);
        _snapshots.beginSession(positionVersion);
      } else if (id != null && id == _requestedId) {
        if (!_snapshots.recordPositionVersion(positionVersion)) {
          return Future<bool>.value(false);
        }
      }
    }
    if (call.method == 'recoverDecoder' &&
        (id != _requestedId || args['positionVersion'] != _snapshots.positionVersion)) {
      return Future<bool>.value(false);
    }
    if (call.method == 'seek' || call.method == 'pause' ||
        call.method == 'pip' || call.method == 'pipRestore') _decoderMonitor.suspend();
    if (call.method == 'invalidateControl') {
      if (id != null && id == _requestedId && requestId != null) {
        _controlPermits[requestId]?.invalidate();
        unawaited(_publishFailure('playback_control_failed', id: id));
      }
      return Future<bool>.value(true);
    }
    if (call.method == 'open') _requestedId = id;
    if (call.method == 'release' || call.method == 'stop' && _requestedId == id) {
      _requestedId = null;
      _snapshots.invalidateSession();
    }
    final barrier = call.method == 'open' || call.method == 'release' ||
      call.method == 'stop' && _requestedId == null;
    if (barrier) {
      _measurements?.close();
      _measurements = null;
      _resetMeasurementWindow();
      _commandEpoch++;
      _playIntent.clear();
      _seekIntent.clear();
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
    if (requestId != null && const {'rate', 'volume', 'loop', 'subtitle'}.contains(call.method)) {
      _controlPermits[requestId] = permit;
    }
    _activePermits.add(permit);
    _resetMeasurementWindow();
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
    Future<void> runCommand() async {
      final measurements = _measurements;
      final measuresReceipt = (call.method == 'play' || call.method == 'pause') &&
          measurements?.sessionId == id;
      String receiptReason = 'stale';
      try {
        final value = await _execute(call.method, args, permit).timeout(_commandTimeout(call.method));
        if (measuresReceipt) {
          final intent = args['_playIntent'];
          receiptReason = intent is int && !_playIntent.isLatest(intent)
              ? 'superseded' : value ? 'applied' : 'stale';
          if (!value && identical(measurements, _measurements) && measurements!.active) {
            _log('${call.method} receipt=$receiptReason request=${requestId ?? ""} (not an audio-output result)');
          }
        }
        if (!result.isCompleted) result.complete(value);
      } catch (error) {
        receiptReason = error is TimeoutException ? 'timeout' : 'exception';
        // Future.timeout cannot cancel its source.  Invalidate it so that any
        // late continuation cannot publish state or install a heartbeat.
        permit.invalidate();
        _log('${call.method}: $error');
        if (call.method == 'open' && id != null && _requestedId == id && epoch == _commandEpoch) {
          await _publishFailure('media_kit_open_failed', id: id);
        }
        if (error is TimeoutException && const {'rate', 'volume', 'loop', 'subtitle'}.contains(call.method) &&
            id != null && _requestedId == id && epoch == _commandEpoch) {
          // A timed-out plugin write is not cancelled. Quarantine this session
          // instead of allowing a late write to overwrite subsequent controls.
          await _publishFailure('playback_control_failed', id: id);
        }
        if (!result.isCompleted) result.complete(false);
      } finally {
        if (measuresReceipt) measurements?.recordReceipt(call.method, receiptReason);
        _activePermits.remove(permit);
        if (requestId != null && identical(_controlPermits[requestId], permit)) _controlPermits.remove(requestId);
      }
    }
    // Pause is a safety command: do not let a pending PiP/seek/plugin Future
    // postpone it. Intent was recorded synchronously above, so queued play
    // commands are already obsolete before this operation reaches the player.
    _commands = dispatchMediaKitCommand(
      _commands, runCommand, priority: call.method == 'pause',
    );
    return result.future;
  }

  Duration _commandTimeout(String method) => switch (method) {
    'open' || 'recoverDecoder' => const Duration(seconds: 14),
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
      _measurements = MediaKitPlaybackMeasurements(sessionId: id);
      _resetMeasurementWindow();
      _clock.reset(); _clock.start();
      _errors.clear(); _timedOutProperties.clear(); _propertyStatus.clear();
      _diagnostics = {}; _failure = ''; _ready = false;
      _decoderMonitor = MediaKitDecoderRecoveryMonitor();
      _decoderRecoveryRunning = false; _activeSeeks = 0;
      _isAudio = args['isAudio'] == true;
      _decoderRecoveryStatus = 'idle'; _subtitleFontStatus = 'unavailable';
      final player = Player(configuration: const PlayerConfiguration(libass: true, logLevel: MPVLogLevel.warn));
      _player = player;
      _scheduleVideoAttachment(player, id);
      notifyListeners();
      _subscriptions.add(player.stream.error.listen((message) {
        final origin = _snapshots.capture();
        unawaited(_handleRuntimeError(player, id, message, origin));
      }));
      _subscriptions.add(player.stream.log.listen((entry) {
        if (!_sameSession(player, id)) return;
        _log('${entry.prefix}: ${entry.text}');
        _decoderMonitor.record(entry.prefix, entry.text, _clock.elapsedMilliseconds);
      }));
      // Visible opens retain video-before-load ordering, including videos
      // with no audio track. Leaving the foreground releases this wait.
      while (_videoAttachReady != null && _allows(permit, id, player)) {
        await _videoAttachReady!.future;
      }
      if (!_allows(permit, id, player)) {
        await _abandonOpen(player);
        return false;
      }
      final native = player.platform as NativePlayer;
      await native.setProperty('audio-spdif', '');
      if (!_allows(permit, id, player)) {
        await _abandonOpen(player);
        return false;
      }
      await _configureSubtitleFonts(native, player, id, permit);
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
    if (_failure.isNotEmpty && method != 'pause') {
      // The native side may have advanced its seek version before our earlier
      // failure message arrived. A confirmed failure remains current until the
      // session ends, even when its original envelope was superseded.
      await _publishFailure(_failure, id: id, player: player);
      return false;
    }
    final native = player.platform as NativePlayer;
    switch (method) {
      case 'play':
      case 'pause':
        final intent = args['_playIntent'] as int;
        final applied = await _playIntent.applyIfLatest(
          intent,
          isAllowed: () => _allows(permit, id, player),
          apply: () => method == 'play' ? player.play() : player.pause(),
          onSuperseded: () => _scheduleLatestPlayIntent(player, id),
        );
        if (!applied) return false;
        break;
      case 'rate':
        final previousRate = player.state.rate;
        await _applyControl(player, id, permit,
          () => player.setRate((args['value'] as num).toDouble()), () => player.setRate(previousRate));
        break;
      case 'volume':
        final previousVolume = player.state.volume;
        await _applyControl(player, id, permit,
          () => player.setVolume((args['value'] as num).toDouble() * 100), () => player.setVolume(previousVolume));
        break;
      case 'recoverDecoder':
        return _recoverDecoder(player, id, permit);
      case 'seek':
        _activeSeeks++;
        try {
          return await _seek(player, id, (args['seconds'] as num).toDouble(),
              args['_seekIntent'] as int, permit, requestId: args['requestId'] as String? ?? '');
        } finally {
          if (_sameSession(player, id)) {
            _activeSeeks--;
            _decoderMonitor.suspend();
          }
        }
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
      case 'subtitle':
        final previousSubtitle = player.state.track.subtitle;
        await _applyControl(player, id, permit,
          () => player.setSubtitleTrack(SubtitleTrack.uri(args['url'] as String)),
          () => player.setSubtitleTrack(previousSubtitle));
        break;
      case 'pip':
        // A background-opened item has no inline output to hand over yet.
        // Reject a late request without pausing audio or creating a renderer.
        if (controller == null) return false;
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
          _pipInlineOutputDetached = true;
          _pipRestoreCreateIssued = false;
          _deferredPiPRestoreId = null;
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
              await _publishFailure('media_playback_failed', id: id, player: player,
                  diagnosticCode: 'pip_restore_failed');
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
              _deferredPiPRestoreId != id && _sameSession(player, id)) {
            if (_playIntent.value == null) _playIntent.record(true);
            _scheduleLatestPlayIntent(player, id);
          }
        }
      case 'pipRestore':
        await _restorePiPVideoOutput(player, native, id,
            requestId: args['requestId'] as String?, permit: permit);
        break;
      case 'loop':
        final start = (args['from'] as num).toDouble(), end = (args['to'] as num).toDouble();
        final previousA = await _property(native, 'ab-loop-a');
        final previousB = await _property(native, 'ab-loop-b');
        if (!_allows(permit, id, player) || previousA == null || previousB == null) return false;
        await _applyControl(player, id, permit, () async {
          await native.setProperty('ab-loop-b', 'no');
          if (!_allows(permit, id, player)) throw StateError('Loop command expired');
          await native.setProperty('ab-loop-a', start >= 0 && end > start ? '$start' : 'no');
          if (!_allows(permit, id, player)) throw StateError('Loop command expired');
          if (start >= 0 && end > start) await native.setProperty('ab-loop-b', '$end');
        }, () async {
          await native.setProperty('ab-loop-b', 'no');
          await native.setProperty('ab-loop-a', previousA);
          await native.setProperty('ab-loop-b', previousB);
        });
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

  Future<void> _applyControl(Player player, String id, MediaKitCommandPermit permit,
      Future<void> Function() apply, Future<void> Function() restore) async {
    try {
      await apply();
      if (!_allows(permit, id, player)) throw StateError('Control command expired');
    } catch (_) {
      if (_sameSession(player, id)) {
        try { await restore(); }
        catch (_) {
          await _publishFailure('playback_control_failed', id: id, player: player);
        }
      }
      rethrow;
    }
  }

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
      await _publishFailure('media_playback_failed', id: id, player: player,
          diagnosticCode: 'pip_restore_failed');
      // An unverified native PiP owner and an inline output must never coexist.
      // Full release is the conservative fallback when the keyed abort fails.
      if (_sameSession(player, id)) await _release();
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
      Player player, NativePlayer native, String id,
      {String? requestId, MediaKitCommandPermit? permit}) async {
    bool current() => _sameSession(player, id) && (permit?.isValid ?? true);
    if (!current() || !_pipInlineOutputDetached) return;
    if (!_foregroundVideoAllowed) {
      await _deferPiPVideoOutput(player, id, requestId);
      return;
    }
    try {
      await _restorePiPRenderingMode(native, player, id);
    } catch (error) { _log('pip mode restore failed: $error'); }
    if (!current()) return;
    if (!await _createVideoOutput(player, id, permit)) {
      await _deferPiPVideoOutput(player, id, requestId);
      return;
    }
    if (_pipPreviousSwFast != null && current()) {
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
        !_disposed && !_releasing && _requestedId == id && _foregroundVideoAllowed) {
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
      MediaKitCommandPermit permit, {String requestId = ''}) async {
    final measurements = _measurements;
    var origin = _snapshots.capture();
    final total = Stopwatch()..start();
    var pauseUs = -1, commandUs = -1, confirmUs = -1, refreshUs = -1;
    var phaseStart = 0, confirmStart = -1;
    var outcome = 'superseded-or-stale';
    _resetMeasurementWindow();
    try {
      if (!target.isFinite || target < 0) { outcome = 'invalid-target'; return false; }
      final native = player.platform as NativePlayer;
      try { await player.pause(); }
      finally { pauseUs = total.elapsedMicroseconds; }
      phaseStart = total.elapsedMicroseconds;
      if (!_allows(permit, id, player) || !_seekIntent.isLatest(intent)) return false;
      // media_kit pins hr-seek=yes: its public absolute seek remains precise
      // and also clears completed, so a later play does not jump back to zero.
      // Our intent queue owns serialization; do not hold the plugin-wide lock
      // across a delayed seek receipt and block priority pause/disposal.
      try { await native.seek(Duration(microseconds: (target * 1000000).round()), synchronized: false); }
      finally { commandUs = total.elapsedMicroseconds - phaseStart; }
      if (!_allows(permit, id, player) || !_seekIntent.isLatest(intent)) {
        _scheduleLatestSeekIntent(player, id);
        return false;
      }
      confirmStart = total.elapsedMicroseconds;
      final elapsed = Stopwatch()..start();
      var settled = 0;
      while (elapsed.elapsedMilliseconds < 6000 && _allows(permit, id, player) &&
          _seekIntent.isLatest(intent)) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        final seeking = await _property(native, 'seeking', controlRead: true);
        final position = double.tryParse(await _property(native, 'time-pos', controlRead: true) ?? '');
        final idle = seeking == 'no' || seeking == 'false';
        if (idle && position != null && position.isFinite && (position - target).abs() <= 0.35) {
          settled++;
          if (settled >= 2) {
            if (!_allows(permit, id, player) || !_seekIntent.isLatest(intent)) return false;
            if (!_snapshots.settlePosition(origin)) {
              // A same-version late repair is another native mutation. Require
              // two new observations after it, rather than trusting old reads.
              origin = _snapshots.capture();
              settled = 0;
              continue;
            }
            _log('seek settled target=${target.toStringAsFixed(3)} position=${position.toStringAsFixed(3)} elapsed=${elapsed.elapsedMilliseconds}ms');
            confirmUs = elapsed.elapsedMicroseconds;
            phaseStart = total.elapsedMicroseconds;
            try { await _refresh(player, id); }
            finally { refreshUs = total.elapsedMicroseconds - phaseStart; }
            final accepted = _allows(permit, id, player) && _seekIntent.isLatest(intent);
            outcome = accepted ? 'confirmed' : 'superseded-or-stale';
            return accepted;
          }
        } else { settled = 0; }
      }
      confirmUs = elapsed.elapsedMicroseconds;
      if (!_seekIntent.isLatest(intent) || !permit.isValid) {
        _scheduleLatestSeekIntent(player, id);
        return false;
      }
      outcome = 'not-confirmed';
      _log('seek not confirmed target=${target.toStringAsFixed(3)}');
      phaseStart = total.elapsedMicroseconds;
      try { await _refresh(player, id); }
      finally { refreshUs = total.elapsedMicroseconds - phaseStart; }
      return false;
    } catch (_) {
      outcome = 'exception';
      rethrow;
    } finally {
      if (confirmStart >= 0 && confirmUs < 0) {
        confirmUs = total.elapsedMicroseconds - confirmStart;
      }
      // Phase durations are awaited wall-clock time, not FFI or output timing.
      if (measurements?.sessionId == id) {
        measurements?.recordSeek({
          'requestId': requestId, 'target': target, 'outcome': outcome,
          if (pauseUs >= 0) 'pauseMs': pauseUs / 1000,
          if (commandUs >= 0) 'commandMs': commandUs / 1000,
          if (confirmUs >= 0) 'confirmMs': confirmUs / 1000,
          if (refreshUs >= 0) 'refreshMs': refreshUs / 1000,
          'totalMs': total.elapsedMicroseconds / 1000,
        });
      }
      if (identical(measurements, _measurements)) _resetMeasurementWindow();
    }
  }

  void _scheduleLatestPlayIntent(Player player, String id) {
    if (!_sameSession(player, id) || _decoderRecoveryRunning) return;
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
            generation == _repairGeneration && !_decoderRecoveryRunning && budget.beginAttempt()) {
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
          _snapshots.invalidateEndEvidence();
          final origin = _snapshots.capture();
          final permit = MediaKitCommandPermit();
          bool current() => permit.isValid && _sameSession(player, id) &&
              generation == _repairGeneration && _seekIntent.isLatest(version);
          final operation = () async {
            await native.seek(Duration(microseconds: (target * 1000000).round()), synchronized: false);
            final elapsed = Stopwatch()..start();
            var stable = 0;
            while (current() && elapsed.elapsed < const Duration(seconds: 1)) {
              await Future<void>.delayed(const Duration(milliseconds: 25));
              if (!current()) return;
              final seeking = await _property(native, 'seeking', controlRead: true);
              final position = double.tryParse(await _property(native, 'time-pos', controlRead: true) ?? '');
              if (!current()) return;
              if ((seeking == 'no' || seeking == 'false') && position != null &&
                  position.isFinite && (position - target).abs() <= 0.35) {
                if (++stable >= 2) {
                  _snapshots.settlePosition(origin);
                  return;
                }
              } else { stable = 0; }
            }
          }();
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
            permit.invalidate();
            _log('seek intent recovery timed out; EOF remains fenced until a confirmed seek');
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
    if (_sameSession(player, id)) {
      if (_steadyMeasurementEligible(player, id)) {
        _measurements?.heartbeat(_clock.elapsedMicroseconds, busy: _refreshing);
      } else {
        _resetMeasurementWindow();
      }
    }
    if (_refreshing || _releasing || _decoderRecoveryRunning || _disposed || _requestedId != id || _player != player) return;
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

  Future<void> _handleRuntimeError(Player player, String id, String message,
      MediaKitSnapshotStamp origin) async {
    if (!_sameSession(player, id) || !_snapshots.isCurrent(origin)) return;
    _log('runtime: $message');
    if (classifyMediaKitRuntimeError(message) != MediaKitRuntimeErrorKind.fatal) return;
    _ready = false;
    _timer?.cancel();
    _timer = null;
    await _publishFailure('media_kit_open_failed',
        id: id, player: player, origin: origin);
  }

  Future<MediaKitPropertyRead> _readProperty(NativePlayer native, String name,
      {bool controlRead = false}) async {
    final result = await MediaKitPropertyRead.read(() async {
      try {
        return await native.getPropertyAsync(name, controlRead: controlRead);
      } on MpvPropertyReadException catch (error) {
        // Keep a currently unavailable value unknown. Unsupported properties
        // and other errors retain the existing explicit error status.
        if (!error.submission && error.errorCode == -10) return '';
        rethrow;
      }
    });
    if (_player?.platform != native || _disposed) return result;
    _propertyStatus[name] = result.status.name;
    if (result.status == MediaKitPropertyStatus.timeout) {
      if (_timedOutProperties.add(name)) _log('property timeout: $name');
    } else {
      _timedOutProperties.remove(name);
    }
    return result;
  }

  Future<String?> _property(NativePlayer native, String name,
      {bool controlRead = false}) async =>
      (await _readProperty(native, name, controlRead: controlRead)).value;

  Future<void> _configureSubtitleFonts(NativePlayer native, Player player,
      String id, MediaKitCommandPermit permit) async {
    try {
      final directory = await _subtitleFonts.prepare();
      if (!_allows(permit, id, player)) return;
      await native.setProperty('sub-fonts-dir', directory.path);
      if (!_allows(permit, id, player)) return;
      await native.setProperty('sub-font', MediaKitSubtitleFonts.family);
      if (!_allows(permit, id, player)) return;
      final values = await Future.wait([
        _property(native, 'sub-fonts-dir'), _property(native, 'sub-font'),
      ]);
      if (!_allows(permit, id, player)) return;
      _subtitleFontStatus = values[0] == directory.path &&
          values[1] == MediaKitSubtitleFonts.family ? 'configured' : 'unconfirmed';
      _log('subtitle fallback font $_subtitleFontStatus');
    } catch (error) {
      if (_sameSession(player, id)) {
        _subtitleFontStatus = 'unavailable';
        _log('subtitle fallback font unavailable: $error');
      }
    }
  }

  Future<bool> _recoverDecoder(Player player, String id,
      MediaKitCommandPermit permit) async {
    if (_decoderRecoveryRunning || _isAudio || _playIntent.value != true) return false;
    final native = player.platform as NativePlayer;
    final positionVersion = _seekIntent.version;
    final playVersion = _playIntent.version;
    // Fence reads begun before reinitialization, retaining native position
    // identity and the user's playback task.
    _snapshots.beginSession(_snapshots.positionVersion);
    final snapshot = _snapshots.capture();
    final monitor = _decoderMonitor;
    _decoderRecoveryRunning = true;
    _decoderRecoveryStatus = 'reinitializing';
    monitor.beginRepair(_clock.elapsedMilliseconds);
    bool current() => _allows(permit, id, player);
    bool samePosition() => _seekIntent.isLatest(positionVersion);
    bool sameIntent() => samePosition() && _playIntent.isLatest(playVersion);
    try {
      final values = await Future.wait([
        _property(native, 'hwdec'), _property(native, 'time-pos'),
      ]);
      if (!current() || !sameIntent()) return true;
      final policy = values[0];
      final target = double.tryParse(values[1] ?? '');
      if (policy == null || target == null || !target.isFinite || target < 0) {
        throw StateError('Decoder policy or current position is unavailable');
      }
      _log('decoder repair start policy=$policy position=${target.toStringAsFixed(3)}');
      final result = await reinitializeMediaKitDecoder(
        hardwarePolicy: policy,
        sameSession: () => _sameSession(player, id),
        samePositionIntent: () => current() && sameIntent(),
        wantsPlayback: () => _playIntent.value == true && _failure.isEmpty,
        pause: player.pause,
        writeHardwarePolicy: (value) async {
          if (!_sameSession(player, id)) return;
          // Initialization is already complete. Do not queue a late property
          // write behind an initialization Future after a command timeout.
          await native.setProperty('hwdec', value, waitForInitialization: false);
          if (!_sameSession(player, id)) return;
          final actual = await _property(native, 'hwdec');
          if (actual != value) throw StateError('hwdec=$value was not confirmed');
          _log('decoder repair configured hwdec=$actual');
        },
        restorePosition: () async {
          if (!current() || !sameIntent()) return;
          if (!await _seek(player, id, target, positionVersion, permit)) {
            if (current() && sameIntent()) throw StateError('Decoder repair seek unconfirmed');
          }
        },
        resume: () async {
          if (!current() || !sameIntent() || _playIntent.value != true) return;
          final version = _playIntent.version;
          await _playIntent.applyIfLatest(version,
            isAllowed: () => current() && sameIntent(),
            apply: player.play,
            onSuperseded: () {
              // A priority pause can overtake a plugin play Future.
              if (_sameSession(player, id) && _playIntent.value == false) {
                unawaited(player.pause());
              }
            },
          );
        },
      );
      if (!current()) return false;
      _decoderRecoveryStatus = result == MediaKitDecoderRepairResult.restored
          ? 'reinitialized_output_unmeasured' : 'superseded';
      _log('decoder repair $_decoderRecoveryStatus; actual hwdec=${await _property(native, 'hwdec-current') ?? 'unknown'}');
      return true;
    } catch (error) {
      if (_sameSession(player, id) && (!sameIntent() || !_snapshots.isCurrent(snapshot))) {
        _decoderRecoveryStatus = 'superseded';
        _log('decoder repair error after newer intent: $error');
        return true;
      }
      if (_sameSession(player, id)) {
        _decoderRecoveryStatus = 'failed';
        _log('decoder repair failed: $error');
        try { await player.pause().timeout(const Duration(seconds: 1)); } catch (_) {}
        if (!_sameSession(player, id)) return false;
        if (!sameIntent() || !_snapshots.isCurrent(snapshot)) {
          _decoderRecoveryStatus = 'superseded';
          return true;
        }
        await _publishFailure('media_playback_failed',
            id: id, player: player, origin: snapshot,
            diagnosticCode: 'media_decoder_recovery_failed');
      }
      return false;
    } finally {
      if (_sameSession(player, id)) _decoderRecoveryRunning = false;
    }
  }

  void _checkDecoderSymptoms(Player player, String id, {required bool eligible}) {
    final monitor = _decoderMonitor;
    final action = monitor.evaluate(_clock.elapsedMilliseconds,
      eligible: eligible && !_decoderRecoveryRunning && _activeSeeks == 0 &&
          !_isAudio && _playIntent.value == true && _failure.isEmpty &&
          _pipPreviousSwFast == null,
    );
    if (action == MediaKitDecoderAction.none) return;
    if (action == MediaKitDecoderAction.stop) {
      final origin = _snapshots.capture();
      final playVersion = _playIntent.version;
      bool current() => _sameSession(player, id) && _snapshots.isCurrent(origin) &&
          _playIntent.isLatest(playVersion);
      _decoderRecoveryStatus = 'failed_persistent_underrun';
      unawaited(() async {
        if (!current()) return;
        try { await player.pause().timeout(const Duration(seconds: 1)); } catch (_) {}
        if (current()) {
          await _publishFailure('media_playback_failed',
              id: id, player: player, origin: origin,
              diagnosticCode: 'media_decoder_recovery_failed');
        }
      }());
      return;
    }
    _decoderRecoveryStatus = 'requested';
    final snapshot = _snapshots.capture();
    _log('decoder recovery requested: VT session failed, both methods failed, sustained underrun');
    unawaited(() async {
      try {
        final accepted = await _channel.invokeMethod<bool>('decoderRecoveryNeeded', {
          'engineId': id, 'positionVersion': snapshot.positionVersion,
          'reason': 'vt_session_failed_with_persistent_underrun',
        }).timeout(const Duration(seconds: 18)) ?? false;
        if (_sameSession(player, id) && !accepted && !monitor.attempted) {
          _decoderRecoveryStatus = 'deferred_by_native';
          monitor.requestDeclined();
        }
      } catch (error) {
        if (_sameSession(player, id)) {
          // An uncertain request may already have consumed the native budget.
          // Do not send it again or build another player.
          _decoderRecoveryStatus = 'request_unconfirmed';
          _log('decoder recovery request unconfirmed: $error');
        }
      }
    }());
  }

  Future<void> _refresh(Player player, String id) async {
    if (_disposed || _releasing || _decoderRecoveryRunning || _player != player || _requestedId != id) return;
    final measurements = _measurements;
    final window = _measurementWindow;
    final measured = _steadyMeasurementEligible(player, id) && measurements != null;
    final total = Stopwatch()..start();
    var propertiesUs = -1, buildUs = -1, bridgeUs = -1;
    var buildStart = 0, bridgeStart = 0;
    if (measured) measurements.beginRefresh();
    try {
      final snapshot = _snapshots.capture();
      final endEligible = !_seekRepairs.containsKey(player);
      final native = player.platform as NativePlayer;
      final values = await Future.wait([
        _property(native, 'time-pos'), _property(native, 'duration'),
        _property(native, 'seekable'), _property(native, 'aid'), _property(native, 'sid'),
        _property(native, 'pause'), _property(native, 'eof-reached'),
        _property(native, 'mpv-version'), _property(native, 'hwdec-current'),
        _property(native, 'current-vo'), _property(native, 'decoder-frame-drop-count'),
        _property(native, 'frame-drop-count'), _property(native, 'speed'),
        _property(native, 'hwdec'), _property(native, 'seeking'),
        _property(native, 'paused-for-cache'), _property(native, 'avsync'),
      ]);
      propertiesUs = total.elapsedMicroseconds;
      buildStart = total.elapsedMicroseconds;
      if (_disposed || _releasing || _decoderRecoveryRunning || _player != player || _requestedId != id) return;
      if (!_snapshots.accept(snapshot)) return;
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
        'hwdecReadStatus': _propertyStatus['hwdec-current'],
        'configuredHwdec': values[13], 'decoderRecovery': _decoderRecoveryStatus,
        'engineAvsync': values[16], 'subtitleFontStatus': _subtitleFontStatus,
        'subtitleFontFamily': MediaKitSubtitleFonts.family,
        'decoderDrops': values[10], 'outputDrops': values[11],
        'actualRate': values[12], 'errors': List<String>.from(_errors),
        'playbackTiming': _measurementSnapshot(),
      };
      _checkDecoderSymptoms(player, id, eligible: _ready &&
          !state.buffering && values[5] == 'no' && values[6] == 'no' &&
          values[14] == 'no' && values[15] == 'no');
      final position = double.tryParse(values[0] ?? '') ?? state.position.inMicroseconds / 1000000;
      final duration = double.tryParse(values[1] ?? '') ?? state.duration.inMicroseconds / 1000000;
      buildUs = total.elapsedMicroseconds - buildStart;
      bridgeStart = total.elapsedMicroseconds;
      await _channel.invokeMethod<bool>('state', {
        'engineId': id,
        'positionVersion': snapshot.positionVersion,
        'snapshotSequence': snapshot.snapshotSequence,
        'position': position.isFinite ? position : 0,
        'duration': duration.isFinite ? duration : 0, 'ready': _ready,
        'seekable': mediaKitSeekability(values[2]),
        'playing': values[5] == null
          ? state.playing
          : (values[5] == 'no' || values[5] == 'false') && values[6] != 'yes' && values[6] != 'true',
        'buffering': state.buffering,
        'ended': endEligible && !_seekRepairs.containsKey(player) &&
            _snapshots.confirmsEnd(snapshot, eof: values[6], seeking: values[14]),
        'failure': _failure, 'diagnostics': _diagnostics,
        'tracks': {'audioTracks': audioRows, 'subtitleTracks': subtitleRows,
          'audioTrack': audio.indexWhere((track) => track.id == values[3]),
          'subtitleTrack': subtitles.indexWhere((track) => track.id == values[4])},
      }).timeout(const Duration(seconds: 2));
      bridgeUs = total.elapsedMicroseconds - bridgeStart;
    } finally {
      // Include a failed/timeout await instead of excluding the slowest sample.
      if (bridgeStart > 0 && bridgeUs < 0) bridgeUs = total.elapsedMicroseconds - bridgeStart;
      if (propertiesUs < 0) propertiesUs = total.elapsedMicroseconds;
      if (measured) {
        final eligible = window == _measurementWindow &&
            identical(measurements, _measurements) &&
            _steadyMeasurementEligible(player, id);
        measurements.endRefresh(total.elapsedMicroseconds, record: eligible);
        if (eligible) {
          if (propertiesUs >= 0) measurements.recordPhase('properties', propertiesUs);
          if (buildUs >= 0) measurements.recordPhase('build', buildUs);
          if (bridgeUs >= 0) measurements.recordPhase('bridge', bridgeUs);
        }
      }
    }
  }

  Future<void> _publishFailure(String failure, {
    required String id,
    Player? player,
    MediaKitSnapshotStamp? origin,
    String? diagnosticCode,
  }) async {
    if (_disposed || _requestedId != id ||
        (player != null && _player != player)) return;
    final snapshot = origin == null
        ? _snapshots.capture() : _snapshots.captureFailure(origin);
    if (snapshot == null || !_snapshots.accept(snapshot)) return;
    // Gate mutation as well as publication: a stale error must not leak into a
    // later, otherwise-current heartbeat through the shared failure field.
    _failure = failure;
    if (diagnosticCode != null) _log(diagnosticCode);
    _diagnostics = {..._diagnostics, 'errors': List<String>.from(_errors)};
    try {
      await _channel.invokeMethod<bool>('state', {
        'engineId': id,
        'positionVersion': snapshot.positionVersion,
        'snapshotSequence': snapshot.snapshotSequence,
        'failure': failure,
        'diagnostics': _diagnostics,
      }).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  void _log(String text) {
    final entry = text.length > 600 ? text.substring(0, 600) : text;
    _errors.add('[${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(1)}s] $entry');
    if (_errors.length > 40) _errors.removeAt(0);
  }

  Future<bool> _release() async {
    _cancelVideoAttachment();
    _measurements?.close();
    _resetMeasurementWindow();
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
    _deferredPiPRestoreId = null;
    _pipInlineOutputDetached = false;
    _pipRestoreCreateIssued = false;
    _pipRestorePreviousTextureId = null;
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
    WidgetsBinding.instance.removeObserver(this);
    _measurements?.close();
    _disposed = true; _requestedId = null;
    _snapshots.invalidateSession();
    _playIntent.clear();
    _seekIntent.clear();
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
