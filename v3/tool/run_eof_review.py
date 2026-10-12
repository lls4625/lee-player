#!/usr/bin/env python3
"""Run real EOF/queue/engine Swift methods with controlled transport snapshots.

This is application decision testing, not an Apple SDK, decoder, or device test.
Use --source with an unmodified baseline for the expected failing negative control.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile
import sys
sys.dont_write_bytecode = True
from run_presentation_review import block

def build(source, scenarios):
    parts = [block(source, name) for name in
             ('struct PlaybackEndGate', 'struct PlaybackSnapshotGate', 'final class LeeMediaKitEngine')]
    methods = [block(source, name) for name in (
        '  private func offerEndCandidate(', '  private func resolveEndCandidate(',
        '  private func performPendingEndAction(', '  func receiveMediaKitState(', '  func skip(')]
    host = r'''
final class EndReviewHost {
  var currentPath: String? { queue.indices.contains(index) ? queue[index] : nil }
  var timelineReady = true, seekFault = false, initialPositionEstablished = true
  var loading = false, isSeeking = false, scrubbing = false
  var replayOperation: Int? = nil
  var playbackOperation = 1, generation = 1
  var endGate = PlaybackEndGate()
  var atPlaybackEnd = false, sessionCompleted = false, pendingEndAction = false
  var wantsPlayback = true, playbackEnvironmentAllowsPlayback = true, interrupted = false
  var aPoint: Double? = nil, bPoint: Double? = nil
  var continuous = true, mode = "sequence", index = 2
  var queue = ["01.mp4", "02.mp4", "03.mkv", "04.mp4"]
  var mediaKit: LeeMediaKitEngine?
  var avPosition = 0.0, duration = 120.0
  var position: Double { mediaKit?.position ?? avPosition }
  var decoderRecoveryAttempted = false
  var loads = 0, restarts = 0, pauses = 0, saves = 0, publishes = 0
  var seekTargets: [Double] = [], events: [String] = []
  var sequence = 0
  init() { installEngine() }
  func installEngine() {
    mediaKit?.stopPlayback(); mediaKit = nil
    if currentPath?.hasSuffix(".mkv") != true { return }
    let engine = LeeMediaKitEngine(transport: { _,_,done in done(true) })
    mediaKit = engine
    let token = generation
    engine.changed = { [weak self, weak engine] in
      guard let self = self, let engine = engine, self.generation == token, self.mediaKit === engine else { return }
      // The real terminal branch in mediaKitChanged, after ready positioning.
      if engine.ended { self.offerEndCandidate(source: "media_kit snapshot"); return }
    }
  }
  func recordLifecycle(_ text: String) { events.append(text) }
  func persist() { saves += 1 }
  func publish() { publishes += 1 }
  func pauseEngine() { pauses += 1 }
  func pause() { wantsPlayback = false; pendingEndAction = false; pauseEngine() }
  func restartCurrentItem() { restarts += 1 }
  func seek(_ seconds: Double) { seekTargets.append(seconds) }
  func resetCurrentSessionCheckpoint() {}
  func load(resume: Bool) {
    loads += 1; generation += 1; playbackOperation += 1
    endGate = PlaybackEndGate(); sessionCompleted = false; atPlaybackEnd = false
    pendingEndAction = false; sequence = 0; installEngine()
  }
  func enforcePlaybackEnvironment() {}
  func deactivateAudioSessionIfIdle() {}
  func send(_ position: Double, duration: Double = 120, ended: Bool = true,
            version: Int? = nil, nextSequence: Int? = nil, engineID: String? = nil) {
    sequence += 1; self.duration = duration
    receiveMediaKitState(["engineId": engineID ?? mediaKit!.id,
      "positionVersion": version ?? mediaKit!.positionVersion,
      "snapshotSequence": nextSequence ?? sequence,
      "position": position, "duration": duration, "ended": ended,
      "ready": true, "playing": false, "seekable": true])
  }
  func avEOF(_ position: Double = 120) {
    avPosition = position; offerEndCandidate(source: "AVPlayerItemDidPlayToEndTime")
  }
  func beginSeek() {
    isSeeking = true; playbackOperation += 1; endGate.beginOperation()
    mediaKit!.seek(seconds: 0) { _ in }
  }
  func settle(_ target: Double) {
    isSeeking = false
    // SETTLED
    resolveEndCandidate()
  }
  func resolve() { resolveEndCandidate() }
  func pending() { performPendingEndAction() }
'''
    settled = 'endGate.settled(operation: playbackOperation, rawTarget: target, position: position, duration: duration'
    if 'endpointSeekTolerance:' in source:
        settled += ', confirmedEngineEnd: mediaKit?.ended == true, endpointSeekTolerance: mediaKit == nil ? nil : 0.35'
    host = host.replace('// SETTLED', settled + ')')
    return 'import Foundation\n' + '\n'.join(parts) + host + '\n'.join(methods) + '\n}\n' + scenarios

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swiftc', default='swiftc')
    parser.add_argument('--source', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = (args.source or root/'ios/Runner/PlaybackService.swift').read_text()
    code = build(source, (root/'tool/eof_review.swift').read_text())
    with tempfile.TemporaryDirectory(prefix='leeplayer-eof-review-') as folder:
        work = Path(folder); (work/'main.swift').write_text(code)
        subprocess.run([args.swiftc,'-module-cache-path',str(work/'cache'),str(work/'main.swift'),'-o',str(work/'review')],check=True)
        subprocess.run([str(work/'review')],check=True)
if __name__ == '__main__': main()
