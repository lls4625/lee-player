// Compiled with the exact PlaybackEndGate and PlaybackSnapshotGate declarations
// extracted by run_replay_gate_review.py. This is not a duplicate model.
var checks = 0
var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
  checks += 1
  if !condition() { failures += 1; print("FAIL: \(name)") }
}

// A genuine EOF received during the final seek must survive if the final
// position confirms the endpoint, even when the requested target was not exact.
var actualEOF = PlaybackEndGate()
actualEOF.beginOperation()
actualEOF.offer()
actualEOF.settled(operation: 1, rawTarget: 119.999, position: 120, duration: 120)
check(actualEOF.consume(operation: 1, position: 120, duration: 120),
      "real EOF during seek is rechecked at the settled endpoint")
check(!actualEOF.consume(operation: 1, position: 120, duration: 120),
      "real EOF is consumed once")

var away = PlaybackEndGate()
away.offer()
away.beginOperation()
away.settled(operation: 2, rawTarget: 35, position: 35, duration: 120)
check(!away.consume(operation: 2, position: 35, duration: 120),
      "old EOF is discarded after seeking away")
check(!away.consume(operation: 2, position: 120, duration: 120),
      "discarded EOF cannot revive merely because time changes")

var near = PlaybackEndGate()
near.beginOperation()
near.settled(operation: 3, rawTarget: 119.95, position: 119.95, duration: 120)
check(!near.consume(operation: 3, position: 119.95, duration: 120),
      "the last 0.1 seconds alone are not EOF")
near.settled(operation: 3, rawTarget: 119.999, position: 119.999, duration: 120)
check(!near.consume(operation: 3, position: 119.999, duration: 120),
      "near-end position alone does not fabricate a native EOF")

var repeated = PlaybackEndGate()
repeated.offer()
check(repeated.consume(operation: 4, position: 120, duration: 120), "first native EOF")
repeated.offer()
check(!repeated.consume(operation: 4, position: 120, duration: 120), "duplicate native EOF")
repeated.beginOperation()
repeated.settled(operation: 5, rawTarget: 120, position: 119.999, duration: 120)
check(repeated.consume(operation: 5, position: 119.999, duration: 120),
      "new explicit end operation is independently consumable")
repeated.offer()
check(!repeated.consume(operation: 5, position: 119.999, duration: 120),
      "new explicit operation remains single-consumption")
repeated.beginOperation()
repeated.settled(operation: 6, rawTarget: 0, position: 0, duration: 120)
repeated.offer()
check(repeated.consume(operation: 6, position: 120, duration: 120),
      "successful return to zero rearms a later genuine EOF")

var failedPosition = PlaybackEndGate()
failedPosition.beginOperation()
failedPosition.settled(operation: 7, rawTarget: 120, position: 40, duration: 120)
check(!failedPosition.consume(operation: 7, position: 40, duration: 120),
      "raw endpoint intent does not bypass observed seek position")
check(!PlaybackEndGate.isAtEnd(0, duration: 0), "zero duration is not EOF")
check(!PlaybackEndGate.isAtEnd(.nan, duration: 120), "nonfinite position is not EOF")
check(!PlaybackEndGate.isAtEnd(120, duration: .infinity), "nonfinite duration is not EOF")
check(PlaybackEndGate.seekTarget(120, duration: 120) == 119.999, "existing seek clamp retained")
check(PlaybackEndGate.seekTarget(1, duration: 0.0005) == 0, "short duration seek stays nonnegative")

var snapshots = PlaybackSnapshotGate()
check(!snapshots.accepts([:]), "versionless state is rejected")
check(snapshots.accepts(["positionVersion": 0, "snapshotSequence": 10]), "first versioned state accepted")
check(!snapshots.accepts(["positionVersion": 0, "snapshotSequence": 10]), "duplicate state rejected")
check(!snapshots.accepts(["positionVersion": 0, "snapshotSequence": 9]), "out-of-order state rejected")
snapshots.advance()
check(!snapshots.accepts(["positionVersion": 0, "snapshotSequence": 9999]),
      "old seek state cannot poison sequence or state")
check(snapshots.accepts(["positionVersion": 1, "snapshotSequence": 11]),
      "current seek state remains accepted after high stale sequence")
check(!snapshots.accepts(["positionVersion": 2, "snapshotSequence": 12]), "future version rejected")
check(snapshots.accepts(["positionVersion": 1, "snapshotSequence": 12, "failure": "seek_failed"]),
      "current failure-only state follows the same version fence")
print("Replay gate review: \(checks - failures)/\(checks) checks passed")
if failures > 0 { exit(1) }
