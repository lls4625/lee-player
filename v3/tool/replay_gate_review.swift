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
// Confirmed libmpv EOF is distinct from a position-only or AVPlayer hint.
for finalPosition in [119.958333, 119.96, 119.966667, 119.983333] {
  var gate = PlaybackEndGate()
  gate.offer()
  check(gate.consume(operation: 1, position: finalPosition, duration: 120, confirmedEngineEnd: true),
        "current libmpv EOF accepts final-frame timestamp")
  gate.offer()
  check(!gate.consume(operation: 1, position: finalPosition, duration: 120, confirmedEngineEnd: true),
        "confirmed EOF still consumes only once")
}
var actualR6 = PlaybackEndGate()
actualR6.beginOperation()
actualR6.settled(operation: 192, rawTarget: 10871.392, position: 10871.318, duration: 10871.392,
  endpointSeekTolerance: 0.35)
check(actualR6.consume(operation: 192, position: 10871.318, duration: 10871.392),
      "r6 log endpoint seek is acknowledged at its real final frame")
var nearMK = PlaybackEndGate()
nearMK.beginOperation()
nearMK.settled(operation: 2, rawTarget: 119.95, position: 119.95, duration: 120,
  endpointSeekTolerance: 0.35)
check(!nearMK.consume(operation: 2, position: 119.95, duration: 120),
      "MK seek tolerance does not fabricate EOF for ordinary near-end intent")
var seekEOF = PlaybackEndGate()
seekEOF.beginOperation(); seekEOF.offer()
seekEOF.settled(operation: 3, rawTarget: 119.98, position: 119.967, duration: 120,
  confirmedEngineEnd: true, endpointSeekTolerance: 0.35)
check(seekEOF.consume(operation: 3, position: 119.967, duration: 120, confirmedEngineEnd: true),
      "current settled actual EOF survives a final-frame seek")
var failedEnd = PlaybackEndGate()
failedEnd.beginOperation()
failedEnd.settled(operation: 4, rawTarget: 120, position: 115, duration: 120,
  endpointSeekTolerance: 0.35)
check(!failedEnd.consume(operation: 4, position: 115, duration: 120),
      "endpoint intent still requires confirmed positioning")
var staleMK = PlaybackEndGate()
staleMK.beginOperation(); staleMK.offer()
staleMK.settled(operation: 5, rawTarget: 35, position: 35, duration: 120,
  confirmedEngineEnd: false, endpointSeekTolerance: 0.35)
check(!staleMK.consume(operation: 5, position: 35, duration: 120),
      "seek away clears earlier MK EOF")
var avHint = PlaybackEndGate()
avHint.offer()
check(!avHint.consume(operation: 6, position: 119.967, duration: 120),
      "AVPlayer and unconfirmed EOF retain the original 5ms threshold")
var nextPassEOF = PlaybackEndGate()
nextPassEOF.offer()
check(nextPassEOF.consume(operation: 10, position: 119.967, duration: 120, confirmedEngineEnd: true),
      "first playback pass consumes genuine MK EOF")
nextPassEOF.beginOperation(); nextPassEOF.offer()
nextPassEOF.settled(operation: 11, rawTarget: 119.98, position: 119.967, duration: 120,
  confirmedEngineEnd: true, endpointSeekTolerance: 0.35)
check(nextPassEOF.consume(operation: 11, position: 119.967, duration: 120, confirmedEngineEnd: true),
      "new confirmed playback pass at EOF is independently consumable")
nextPassEOF.offer()
check(!nextPassEOF.consume(operation: 11, position: 119.967, duration: 120, confirmedEngineEnd: true),
      "same new playback pass still consumes only once")
var nearAfterEOF = PlaybackEndGate()
nearAfterEOF.offer()
check(nearAfterEOF.consume(operation: 20, position: 120, duration: 120, confirmedEngineEnd: true),
      "consume preceding pass before near-end seek")
nearAfterEOF.beginOperation()
nearAfterEOF.settled(operation: 21, rawTarget: 119.999, position: 119.999, duration: 120,
  confirmedEngineEnd: false, endpointSeekTolerance: 0.35)
check(!nearAfterEOF.consume(operation: 21, position: 119.999, duration: 120),
      "successful MK near-end seek rearms but does not invent EOF")
nearAfterEOF.offer()
check(nearAfterEOF.consume(operation: 21, position: 119.999, duration: 120, confirmedEngineEnd: true),
      "subsequent real EOF is accepted after new near-end seek")
print("Replay gate review: \(checks - failures)/\(checks) checks passed")
if failures > 0 { exit(1) }
