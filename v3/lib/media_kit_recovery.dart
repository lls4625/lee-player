import 'dart:async';

/// Small, plugin-independent recovery primitives used by MediaKitPlayback.
///
/// Keeping these separate makes the rules around timed-out work and native
/// error classification testable without constructing a media_kit player.
enum MediaKitRuntimeErrorKind { recoverable, fatal }

/// A missing/timed-out property is unknown, not proof of a non-seekable stream.
bool? mediaKitSeekability(String? value) => switch (value?.trim().toLowerCase()) {
  'yes' || 'true' => true,
  'no' || 'false' => false,
  _ => null,
};


MediaKitRuntimeErrorKind classifyMediaKitRuntimeError(String message) {
  // media_kit exposes this stream as text, so recognize only its top-level
  // source-open error envelope.  In particular, generic decoder/render log
  // phrases such as "loading failed" are recoverable and must not tear down a
  // healthy session.
  var error = message.trim().split('\n').map((line) => line.trim())
      .join(' ').trim().toLowerCase();
  const envelope = '[mediakiterror]';
  final isMediaKitEnvelope = error.startsWith(envelope);
  if (isMediaKitEnvelope) error = error.substring(envelope.length).trim();
  return isMediaKitEnvelope && error.startsWith('failed to open ') && error.endsWith('.')
      ? MediaKitRuntimeErrorKind.fatal
      : MediaKitRuntimeErrorKind.recoverable;
}

/// Priority pause bypasses slow PiP/seek work without unblocking that queue.
/// The caller handles errors and uses intent/session guards for late work.
Future<void> dispatchMediaKitCommand(Future<void> queued,
    Future<void> Function() command, {bool priority = false}) {
  if (priority) {
    unawaited(command());
    return queued;
  }
  return queued.then((_) => command());
}

class MediaKitCommandPermit {
  bool _valid = true;

  bool get isValid => _valid;

  void invalidate() => _valid = false;
}

class MediaKitLatestIntent<T> {
  int _version = 0;
  T? _value;

  int get version => _version;
  T? get value => _value;

  int record(T value) {
    _value = value;
    return ++_version;
  }

  bool isLatest(int version) => version == _version;

  /// Invalidates captured intent when its playback session ends.
  void clear() {
    _value = null;
    _version++;
  }

  /// A queued operation must still be wanted before touching the player.
  /// Recheck on completion too: a plugin Future cannot be cancelled when a
  /// priority pause or session barrier overtakes it.
  Future<bool> applyIfLatest(int version, {
    required bool Function() isAllowed,
    required Future<void> Function() apply,
    required void Function() onSuperseded,
  }) async {
    if (!isLatest(version) || !isAllowed()) return false;
    try {
      await apply();
      return isLatest(version) && isAllowed();
    } finally {
      if (!isLatest(version) || !isAllowed()) onSuperseded();
    }
  }
}

/// Serializes disposal attempts and keeps failed/timed-out cleanup as a gate.
/// A later drain retries a failed callback instead of forgetting the resource.
class MediaKitCleanupCoordinator {
  final List<Future<void> Function()> _pending = [];
  Future<bool>? _inFlight;
  Object? lastError;

  bool get hasPending => _pending.isNotEmpty;

  void add(Future<void> Function() cleanup) => _pending.add(cleanup);

  Future<bool> drain(Duration timeout) async {
    var active = _inFlight;
    if (active == null) {
      active = _drainPending();
      _inFlight = active;
      unawaited(active.whenComplete(() {
        if (identical(_inFlight, active)) _inFlight = null;
      }));
    }
    try {
      return await active.timeout(timeout);
    } on TimeoutException {
      return false;
    }
  }

  Future<bool> _drainPending() async {
    lastError = null;
    while (_pending.isNotEmpty) {
      try {
        await _pending.first();
        _pending.removeAt(0);
      } catch (error) {
        lastError = error;
        return false;
      }
    }
    return true;
  }
}

/// Bounds intent reconciliation without retrying the same native operation
/// forever. A new user intent may consume another attempt within the deadline.
class MediaKitRepairBudget {
  MediaKitRepairBudget({
    this.maxAttempts = 3,
    this.maxElapsed = const Duration(seconds: 4),
    int Function()? nowMilliseconds,
  }) : _nowMilliseconds = nowMilliseconds ??
            (() => DateTime.now().millisecondsSinceEpoch) {
    _startedAt = _nowMilliseconds();
  }

  final int maxAttempts;
  final Duration maxElapsed;
  final int Function() _nowMilliseconds;
  late final int _startedAt;
  int _attempts = 0;
  bool _valid = true;

  int get attempts => _attempts;
  bool get isValid => _valid;

  bool beginAttempt() {
    if (!_valid || _attempts >= maxAttempts ||
        _nowMilliseconds() - _startedAt >= maxElapsed.inMilliseconds) {
      return false;
    }
    _attempts++;
    return true;
  }

  void invalidate() => _valid = false;
}

/// Identifies when a state read began, before any asynchronous plugin reads.
class MediaKitSnapshotStamp {
  const MediaKitSnapshotStamp._(
    this._session,
    this.positionVersion,
    this.snapshotSequence,
    this.positionSettled,
    this._endEpoch,
  );

  final int _session;
  final int positionVersion;
  final int snapshotSequence;
  final bool positionSettled;
  final int _endEpoch;
}

/// Fences the whole state payload, including EOF and failure, across seeks.
///
/// Sequence numbers are allocated at capture time, so a slower property read
/// cannot overwrite a newer published snapshot from the same position version.
/// Session changes also invalidate work even if the position version is reused.
class MediaKitSnapshotFence {
  int _session = 0;
  int _positionVersion = 0;
  int _snapshotSequence = 0;
  int _lastPublishedSequence = 0;
  bool _positionSettled = true;
  int _endEpoch = 0;

  int get positionVersion => _positionVersion;

  void beginSession(int positionVersion) {
    if (positionVersion < 0) throw ArgumentError.value(positionVersion);
    _session++;
    _positionVersion = positionVersion;
    _positionSettled = true;
  }

  void invalidateSession() => _session++;

  /// Called synchronously when a seek arrives, before it waits in the queue.
  bool recordPositionVersion(int positionVersion) {
    if (positionVersion < _positionVersion) return false;
    _positionVersion = positionVersion;
    _positionSettled = false;
    return true;
  }

  MediaKitSnapshotStamp capture() => MediaKitSnapshotStamp._(
    _session,
    _positionVersion,
    ++_snapshotSequence,
    _positionSettled,
    _endEpoch,
  );

  bool isCurrent(MediaKitSnapshotStamp stamp) =>
      stamp._session == _session && stamp.positionVersion == _positionVersion;

  /// A seek is pending from receipt, including its time waiting in the command
  /// queue. Only the latest, observed settled seek can restore EOF authority.
  bool settlePosition(MediaKitSnapshotStamp origin) {
    if (!isCurrent(origin) || origin._endEpoch != _endEpoch) return false;
    _positionSettled = true;
    return true;
  }

  /// A late intent repair may issue another native seek in the same version.
  /// Invalidate reads begun before that repair without falsely acknowledging
  /// an unconfirmed primary seek or changing its receipt identity.
  void invalidateEndEvidence() {
    _endEpoch++;
    _positionSettled = false;
  }

  /// Completion must come from libmpv in this settled playback pass. Cached
  /// PlayerState.completed can outlive a seek and is never terminal evidence.
  bool confirmsEnd(MediaKitSnapshotStamp stamp, {
    required String? eof,
    required String? seeking,
  }) => isCurrent(stamp) && stamp._endEpoch == _endEpoch &&
      stamp.positionSettled && _positionSettled &&
      (eof == 'yes' || eof == 'true') &&
      (seeking == 'no' || seeking == 'false');

  /// A current error is a new state transition, rather than a delayed property
  /// snapshot. Give it a fresh sequence even if newer reads already published.
  /// An old session/position error must not poison the current failure state.
  MediaKitSnapshotStamp? captureFailure(MediaKitSnapshotStamp origin) =>
      isCurrent(origin) ? capture() : null;

  bool accept(MediaKitSnapshotStamp stamp) {
    if (!isCurrent(stamp) ||
        stamp.snapshotSequence <= _lastPublishedSequence) {
      return false;
    }
    _lastPublishedSequence = stamp.snapshotSequence;
    return true;
  }
}

/// An empty result is not software decoding. media_kit 1.2.6 collapses libmpv
/// property-unavailable/error into an empty string; retain that uncertainty.
enum MediaKitPropertyStatus { value, unavailable, error, timeout }

class MediaKitPropertyRead {
  const MediaKitPropertyRead(this.status, [this.value]);
  final MediaKitPropertyStatus status;
  final String? value;

  static Future<MediaKitPropertyRead> read(Future<String> Function() read, {
    Duration timeout = const Duration(milliseconds: 750),
  }) async {
    try {
      final value = (await read().timeout(timeout)).trim();
      return value.isEmpty
          ? const MediaKitPropertyRead(MediaKitPropertyStatus.unavailable)
          : MediaKitPropertyRead(MediaKitPropertyStatus.value, value);
    } on TimeoutException {
      return const MediaKitPropertyRead(MediaKitPropertyStatus.timeout);
    } catch (_) {
      return const MediaKitPropertyRead(MediaKitPropertyStatus.error);
    }
  }
}

enum MediaKitDecoderAction { none, requestRepair, stop }

/// A conservative symptom detector, not a video-frame health measurement.
/// Requires the specific VT session failure and both failed VT methods before
/// considering later sustained audio starvation. Ordinary warnings, a lone
/// underrun, buffering, and timeline advancement cannot establish this case.
class MediaKitDecoderRecoveryMonitor {
  static const fallbackGrace = Duration(seconds: 4);
  static const evidenceLifetime = Duration(seconds: 30);
  static const underrunWindow = Duration(seconds: 3);
  int? _invalidAt, _directFailedAt, _copyFailedAt, _observationStart;
  final List<int> _underruns = [];
  bool _requestOutstanding = false;
  bool _attempted = false;
  bool _stopped = false;

  bool get attempted => _attempted;
  bool get hasEvidence => _invalidAt != null;

  void record(String prefix, String message, int now) {
    if (_invalidAt != null && now - _invalidAt! > evidenceLifetime.inMilliseconds) {
      _invalidAt = _directFailedAt = _copyFailedAt = null;
      _underruns.clear();
    }
    final source = prefix.toLowerCase();
    final text = message.trim().toLowerCase();
    if (source.startsWith('ffmpeg/video') &&
        text.contains('failed to decode frame (invalid session, -12903)')) {
      _invalidAt ??= now;
    }
    if (source == 'vd') {
      if (text == 'attempting next decoding method after failure of h264-videotoolbox.') {
        _directFailedAt ??= now;
      } else if (text == 'attempting next decoding method after failure of h264-videotoolbox-copy.') {
        _copyFailedAt ??= now;
      }
    }
    if (source == 'cplayer' && text == 'audio device underrun detected.') {
      _underruns.add(now);
      _prune(now);
    }
  }

  void _prune(int now) => _underruns.removeWhere(
      (time) => now - time > underrunWindow.inMilliseconds);

  /// Preserve recent decoder evidence through a seek/pause, but start a fresh
  /// continuous observation after it. A user operation is never a failure.
  void suspend() { _underruns.clear(); _observationStart = null; }

  void beginRepair(int now) {
    _attempted = true;
    _requestOutstanding = false;
    _underruns.clear();
    _observationStart = now;
  }

  void requestDeclined() { _requestOutstanding = false; suspend(); }

  MediaKitDecoderAction evaluate(int now, {required bool eligible}) {
    if (_stopped || _requestOutstanding) return MediaKitDecoderAction.none;
    if (!eligible) { suspend(); return MediaKitDecoderAction.none; }
    _observationStart ??= now;
    final evidence = [_invalidAt, _directFailedAt, _copyFailedAt];
    if (evidence.any((time) => time == null || now - time > evidenceLifetime.inMilliseconds)) {
      return MediaKitDecoderAction.none;
    }
    final latestFailure = evidence.whereType<int>().reduce((a, b) => a > b ? a : b);
    if (now - latestFailure < fallbackGrace.inMilliseconds ||
        now - _observationStart! < fallbackGrace.inMilliseconds) {
      return MediaKitDecoderAction.none;
    }
    _prune(now);
    if (_underruns.length < 5 || _underruns.last - _underruns.first < 1000) {
      return MediaKitDecoderAction.none;
    }
    if (_attempted) { _stopped = true; return MediaKitDecoderAction.stop; }
    _requestOutstanding = true;
    return MediaKitDecoderAction.requestRepair;
  }
}

enum MediaKitDecoderRepairResult { restored, superseded }

/// Runs libmpv's documented hwdec reinitialization in the existing player.
/// No file, tracks, subtitle state, render context or playback rate is replaced.
/// The adapter verifies writes by reading back the configured hwdec property.
Future<MediaKitDecoderRepairResult> reinitializeMediaKitDecoder({
  required String hardwarePolicy,
  required bool Function() sameSession,
  required bool Function() samePositionIntent,
  required bool Function() wantsPlayback,
  required Future<void> Function() pause,
  required Future<void> Function(String) writeHardwarePolicy,
  required Future<void> Function() restorePosition,
  required Future<void> Function() resume,
  Duration stepTimeout = const Duration(seconds: 2),
}) async {
  if (hardwarePolicy.isEmpty || hardwarePolicy == 'no') {
    throw StateError('No enabled hardware decode policy to reinitialize');
  }
  bool current() => sameSession() && samePositionIntent();
  if (!current() || !wantsPlayback()) return MediaKitDecoderRepairResult.superseded;
  await pause().timeout(stepTimeout);
  if (!current() || !wantsPlayback()) return MediaKitDecoderRepairResult.superseded;
  try {
    try {
      await writeHardwarePolicy('no').timeout(stepTimeout);
    } finally {
      // Even a failed disable/readback must restore the old policy. A new player
      // must never receive this old session's setting. The production adapter
      // issues synchronous initialized writes, with no delayed initialization.
      if (sameSession()) {
        await writeHardwarePolicy(hardwarePolicy).timeout(stepTimeout);
      }
    }
  } catch (_) {
    // Cleanup still ran. A late readback failure is not a failure of a newer
    // user seek/session and must not pause or fail that new operation.
    if (!current()) return MediaKitDecoderRepairResult.superseded;
    rethrow;
  }
  if (!current()) return MediaKitDecoderRepairResult.superseded;
  // mpv automatically seeks to its last video PTS after hwdec changes. In this
  // failure that frame may be stale; preserve the latest pre-repair time-pos.
  await restorePosition();
  if (!current()) return MediaKitDecoderRepairResult.superseded;
  if (wantsPlayback()) await resume().timeout(stepTimeout);
  return current()
      ? MediaKitDecoderRepairResult.restored
      : MediaKitDecoderRepairResult.superseded;
}
