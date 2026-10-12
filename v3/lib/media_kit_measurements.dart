/// Bounded, per-session observations supplied by the playback adapter.
///
/// This class does not read a clock, schedule work, call the player, or log.
/// Durations and heartbeat timestamps must come from the caller's monotonic
/// clock. The adapter controls eligibility for foreground playing samples and
/// resets the heartbeat baseline whenever that eligibility changes.
class MediaKitPlaybackMeasurements {
  MediaKitPlaybackMeasurements({required String sessionId})
    : sessionId = _boundedString(sessionId, 160);

  final String sessionId;
  bool _active = true;
  int _refreshCurrent = 0;
  int _refreshPeak = 0;
  final _refresh = _MeasurementStats();
  final _phases = <String, _MeasurementStats>{
    'properties': _MeasurementStats(),
    'build': _MeasurementStats(),
    'bridge': _MeasurementStats(),
  };
  int _heartbeatCount = 0;
  int _heartbeatBusySkips = 0;
  int? _lastHeartbeatUs;
  final _heartbeatGapExcess = _MeasurementStats();
  final _receipts = <String, Map<String, int>>{
    'play': _emptyReceipts(),
    'pause': _emptyReceipts(),
  };
  Map<String, Object>? _lastSeek;

  bool get active => _active;

  /// Freezes this session. Late continuations holding it cannot write again.
  void close() => _active = false;

  void beginRefresh() {
    if (!_active) return;
    _refreshCurrent = _increment(_refreshCurrent);
    if (_refreshCurrent > _refreshPeak) _refreshPeak = _refreshCurrent;
  }

  /// Always balances an active refresh, but samples only eligible refreshes.
  /// An unmatched end is ignored rather than fabricating a timing sample.
  void endRefresh(int elapsedUs, {bool record = true}) {
    if (!_active || _refreshCurrent == 0) return;
    _refreshCurrent--;
    if (record) _refresh.record(elapsedUs);
  }

  /// Only these phases are retained: properties, build, and bridge.
  /// The caller is responsible for passing only eligible phase samples.
  void recordPhase(String phase, int elapsedUs) {
    if (!_active) return;
    _phases[phase]?.record(elapsedUs);
  }

  /// Clears only the baseline; accumulated eligible observations are retained.
  void resetHeartbeat() {
    if (!_active) return;
    _lastHeartbeatUs = null;
  }

  /// Records an existing eligible heartbeat, including refresh-busy skips.
  ///
  /// Gap statistics include zero excess for on-time/early invocations. The
  /// first invocation after a reset has no gap sample. A backwards clock also
  /// establishes a new baseline without treating it as elapsed time.
  void heartbeat(int nowUs, {required bool busy}) {
    if (!_active) return;
    _heartbeatCount = _increment(_heartbeatCount);
    if (busy) _heartbeatBusySkips = _increment(_heartbeatBusySkips);
    final now = nowUs.clamp(0, _maxSafeInteger);
    final previous = _lastHeartbeatUs;
    _lastHeartbeatUs = now;
    if (previous == null || now < previous) return;
    _heartbeatGapExcess.record(now - previous - 250000);
  }

  /// Unknown methods/reasons are ignored; they cannot grow the counter map.
  void recordReceipt(String method, String reason) {
    if (!_active) return;
    final receipts = _receipts[method];
    final count = receipts?[reason];
    if (receipts != null && count != null) {
      receipts[reason] = _increment(count);
    }
  }

  /// Replaces the last seek summary; never retains history or input maps.
  ///
  /// The fixed fields are requestId (80 characters), outcome (40 characters),
  /// target (finite numeric seconds), and pauseMs/commandMs/confirmMs/refreshMs/
  /// totalMs (finite nonnegative milliseconds, capped at 24 hours). Unsupported
  /// fields, types, and nonfinite numbers are omitted. Numeric targets are
  /// clamped to the exact-integer range supported by JSON consumers.
  void recordSeek(Map<String, Object> summary) {
    if (!_active) return;
    final result = <String, Object>{};
    final requestId = summary['requestId'];
    if (requestId is String) {
      result['requestId'] = _boundedString(requestId, 80);
    }
    final outcome = summary['outcome'];
    if (outcome is String) result['outcome'] = _boundedString(outcome, 40);
    final target = summary['target'];
    if (target is num && target.isFinite) {
      result['target'] = target
          .clamp(-_maxSafeInteger, _maxSafeInteger)
          .toDouble();
    }
    for (final field in const [
      'pauseMs',
      'commandMs',
      'confirmMs',
      'refreshMs',
      'totalMs',
    ]) {
      final value = summary[field];
      if (value is num && value.isFinite) {
        result[field] = value.clamp(0, _maxElapsedUs / 1000).toDouble();
      }
    }
    _lastSeek = result;
  }

  /// Returns a detached JSON-codec-friendly snapshot with fixed-size maps.
  /// Refresh current/peak cover calls the adapter chose to begin measuring
  /// (eligible at start), not every player refresh. Timing counts include only
  /// spans that remained eligible when the adapter ended them.
  Map<String, Object?> snapshot() => <String, Object?>{
    'version': 1,
    'sessionId': sessionId,
    'active': _active,
    'scope': 'foreground-playing-no-seek',
    'refresh': <String, Object>{
      ..._refresh.snapshot(),
      'current': _refreshCurrent,
      'peak': _refreshPeak,
    },
    'phases': <String, Object>{
      for (final entry in _phases.entries) entry.key: entry.value.snapshot(),
    },
    'heartbeat': <String, Object>{
      'count': _heartbeatCount,
      'busySkips': _heartbeatBusySkips,
      'gapCount': _heartbeatGapExcess.count,
      'meanGapExcessMs': _heartbeatGapExcess.meanUs / 1000,
      'maxGapExcessMs': _heartbeatGapExcess.maxUs / 1000,
    },
    'receipts': <String, Object>{
      for (final entry in _receipts.entries)
        entry.key: Map<String, int>.of(entry.value),
    },
    'lastSeek': _lastSeek == null ? null : Map<String, Object>.of(_lastSeek!),
  };
}

const _maxCount = 0x7fffffff;
const _maxSafeInteger = 0x1fffffffffffff;
const _maxElapsedUs = 24 * 60 * 60 * 1000000;

int _increment(int count) => count < _maxCount ? count + 1 : _maxCount;

String _boundedString(String value, int length) =>
    value.length <= length ? value : value.substring(0, length);

Map<String, int> _emptyReceipts() => <String, int>{
  'applied': 0,
  'superseded': 0,
  'stale': 0,
  'timeout': 0,
  'exception': 0,
};

/// Online mean avoids an ever-growing duration sum. Counts saturate, and
/// additional samples are ignored at saturation to keep the mean consistent.
class _MeasurementStats {
  int count = 0;
  double meanUs = 0;
  int maxUs = 0;
  int _over250 = 0;

  void record(int elapsedUs) {
    if (count == _maxCount) return;
    final elapsed = elapsedUs.clamp(0, _maxElapsedUs);
    count++;
    meanUs += (elapsed - meanUs) / count;
    if (elapsed > maxUs) maxUs = elapsed;
    if (elapsed > 250000) _over250++;
  }

  Map<String, Object> snapshot() => <String, Object>{
    'count': count,
    'meanMs': meanUs / 1000,
    'maxMs': maxUs / 1000,
    'over250': _over250,
  };
}
