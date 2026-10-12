var tests = 0, failures = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
  tests += 1
  if value() { print("PASS \(label)") } else { failures += 1; print("FAIL \(label)") }
}
for position in [119.958333, 119.96, 119.966667, 119.983333] {
  let s = EndReviewHost(); s.send(position)
  check(s.currentPath == "04.mp4" && s.loads == 1, "MK final-frame EOF advances to MP4 at \(position)")
}
do {
  let s = EndReviewHost(); s.index = 0; s.installEngine()
  s.avEOF(); check(s.currentPath == "02.mp4", "first MP4 advances")
  s.avEOF(); check(s.currentPath == "03.mkv" && s.mediaKit != nil, "second MP4 enters MKV")
  let oldID = s.mediaKit!.id
  s.send(119.967); check(s.currentPath == "04.mp4" && s.mediaKit == nil && s.loads == 3, "mixed queue advances MKV to MP4 once")
  s.receiveMediaKitState(["engineId":oldID,"positionVersion":0,"snapshotSequence":99,"ended":true,"position":120.0])
  check(s.currentPath == "04.mp4" && s.loads == 3, "old MK snapshot cannot skip next MP4")
}
do {
  let s = EndReviewHost(); s.queue = ["01.mkv","02.mkv"]; s.index = 0; s.installEngine()
  let oldID = s.mediaKit!.id; s.send(119.967)
  check(s.currentPath == "02.mkv" && s.mediaKit!.id != oldID && s.loads == 1, "MKV EOF opens next MKV session")
  s.send(120,engineID:oldID)
  check(s.loads == 1 && !s.sessionCompleted, "old session EOF cannot complete next MKV")
}
do {
  let s = EndReviewHost(); s.beginSeek(); s.send(10871.318,duration:10871.392,ended:false)
  s.settle(10871.392)
  check(s.currentPath == "04.mp4" && s.loads == 1, "r6 request145: confirmed 100% seek accepts 73ms final-frame gap")
}
do {
  let s = EndReviewHost(); s.beginSeek(); s.send(119.95,ended:false); s.settle(119.95)
  check(s.loads == 0 && !s.atPlaybackEnd, "ordinary near-end seek does not fabricate EOF")
}
do {
  let s = EndReviewHost(); s.beginSeek(); s.send(119.967)
  check(s.loads == 0, "EOF waits during in-flight seek")
  s.settle(119.98)
  check(s.loads == 1, "current confirmed EOF survives a settled near-end seek")
}
do {
  let s = EndReviewHost(); s.beginSeek(); s.send(120); s.send(35,ended:false); s.settle(35)
  check(s.loads == 0 && s.position == 35 && !s.endGate.candidate, "seek away discards earlier EOF")
  s.send(120,version:0,nextSequence:999)
  check(s.loads == 0 && s.position == 35, "old position version cannot revive EOF")
  s.send(120,nextSequence:1)
  check(s.loads == 0 && s.position == 35, "reversed snapshot cannot revive EOF")
}
do {
  let s = EndReviewHost(); s.wantsPlayback = false; s.send(119.967)
  check(s.loads == 0 && s.sessionCompleted && !s.pendingEndAction, "paused EOF records completion without autoplay")
}
do {
  let s = EndReviewHost(); s.continuous = false; s.send(119.967)
  check(s.loads == 0 && !s.wantsPlayback && s.pauses == 1, "continuous off stops")
}
do {
  let s = EndReviewHost(); s.mode = "one"; s.send(119.967); s.send(119.967)
  check(s.loads == 0 && s.restarts == 1, "single loop and duplicate EOF restart once")
  s.beginSeek(); s.send(119.967); s.settle(119.98)
  check(s.restarts == 2, "new confirmed EOF pass rearms after consumed prior pass")
  s.send(119.967); check(s.restarts == 2, "new pass duplicate remains single-consumption")
}
for mode in ["sequence", "folder", "shuffle"] {
  let s = EndReviewHost(); s.queue = ["01.mp4","02.mkv"]; s.index = 1; s.mode = mode; s.installEngine()
  s.send(119.967)
  check(mode == "sequence" ? s.loads == 0 && !s.wantsPlayback : s.currentPath == "01.mp4" && s.loads == 1,
        "last item follows \(mode) policy")
}
do {
  let s = EndReviewHost(); s.queue = ["01.mkv"]; s.index = 0; s.mode = "folder"; s.installEngine(); s.send(119.967)
  check(s.loads == 0 && s.restarts == 1, "single-entry folder repeats current player")
}
do {
  let s = EndReviewHost(); s.aPoint = 20; s.bPoint = 40; s.send(119.967)
  check(s.loads == 0 && !s.sessionCompleted && s.seekTargets == [20], "A-B repeats without episode completion")
}
for block in ["initial","loading","scrubbing","interruption","environment"] {
  let s = EndReviewHost()
  switch block {
  case "initial": s.initialPositionEstablished = false
  case "loading": s.loading = true
  case "scrubbing": s.scrubbing = true
  case "interruption": s.interrupted = true
  default: s.playbackEnvironmentAllowsPlayback = false
  }
  s.send(119.967)
  check(s.loads == 0, "EOF respects \(block) guard")
}
do {
  let s = EndReviewHost(); s.interrupted = true; s.send(119.967); s.pause(); s.interrupted = false; s.pending()
  check(s.loads == 0 && !s.wantsPlayback, "pause revokes deferred EOF after interruption")
}
do {
  let s = EndReviewHost(); s.index = 0; s.installEngine(); s.avEOF(119.967)
  check(s.loads == 0, "AVPlayer threshold remains unchanged")
}
print("EOF service review: \(tests-failures)/\(tests) passed; no Apple SDK or decoder exercised")
if failures > 0 { exit(1) }
