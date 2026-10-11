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
