#!/usr/bin/env python3
"""Exercise real Swift transport/seek/recovery methods with delayed receipts.

The shared collaborators provide fake platform APIs and a virtual main queue.
These are application-decision tests, not Apple SDK or decoder validation.
"""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from run_presentation_review import block as simple_block


def block(source, anchor):
    # The public seek declaration has a default closure before its method body.
    if anchor != '  func seek(_ seconds:':
        return simple_block(source, anchor)
    start = source.index(anchor)
    begin = source.index(') {', start) + 2
    depth = 0
    for i in range(begin, len(source)):
        depth += (source[i] == '{') - (source[i] == '}')
        if depth == 0:
            return source[start:i + 1]
    raise AssertionError(anchor)


def build(source, template):
    code = template.split('// AUDIO_RECOVERY_SCENARIOS')[0]
    code = code.replace(block(code, 'final class LeeMediaKitEngine'),
                        block(source, 'struct PlaybackSnapshotGate') + '\n' +
                        block(source, 'final class LeeMediaKitEngine'))
    code = code.replace(block(code, 'final class Item'),
                        'final class Item { var status=Status.ready; func cancelPendingSeeks() {} }')
    code = code.replace(block(code, 'final class ReviewPlayer'), '''final class ReviewPlayer {
      var status=Status.ready; var currentItem: Item?=Item()
      func pause() {}; func playImmediately(atRate: Float) {}
      func replaceCurrentItem(with: Item?) { currentItem=with }
      func seek(to:CMTime,toleranceBefore:CMTime,toleranceAfter:CMTime,
                completion:@escaping (Bool)->Void) { completion(true) }
    }''')
    code = code.replace('import Foundation', '''import Foundation
struct CMTime {
  init(seconds:Double,preferredTimescale:Int) {}
  static let zero=Self(seconds:0,preferredTimescale:600)
}
''' + block(source, 'struct PlaybackEndGate'))
    for anchor in (' func pauseEngine(', ' func resumeEngine(',
                   ' func seek(_ n:', 'func cancelSeeks('):
        stub = block(code, anchor)
        code = code.replace(stub + ';', '') if stub + ';' in code else code.replace(stub, '')
    code = code.replace('isSeeking=false, ', '')
    code = code.replace('final class Service {', '''final class Service {
      var isSeeking:Bool { activeSeek != nil || pendingSeek != nil }
      var activeSeek:Int?, activeSeekCompletion:((Bool)->Void)?
      var pendingSeek:(id:Int, seconds:Double, precise:Bool, done:(Bool)->Void)?
      var seekSequence=0, seekTimeout:DispatchWorkItem?, cancellingSeeks=false
      var introSkipped=0.0, endGate=PlaybackEndGate()
      var position:Double { mediaKit?.position ?? 0 }
      func deactivateAudioSessionIfIdle() {}
    ''')
    anchors = [
        '  private func interruption(', '  private func routeChanged(',
        '  private func activateAudioSession(', '  private func mediaServicesWereReset(',
        '  private func attemptAudioRecovery(', '  private func deferAudioRecovery(',
        '  private func scheduleAudioRecoveryRetry(', '  private func cancelAudioRecovery(',
        '  func pause()', '  func play()', '  private func openMediaKit(',
        '  private func mediaKitChanged(', '  private func pauseEngine(',
        '  private func resumeEngine(', '  func seek(_ seconds:',
        '  private func enqueueSeek(', '  private func runNextSeek(',
        '  private func cancelSeeks(',
    ]
    methods = '\n'.join(block(source, a).replace('  private func', '  func') for a in anchors)
    methods += '\n func configureAutoResume(_ values:[String:Any]) {\n' + block(source, 'if let value = values["autoResume"] as? Bool') + '\n }'
    active = block(source, 'notifications.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification')
    active = active[active.index('{ [weak self] _ in') + len('{ [weak self] _ in'):-1]
    active = active.replace('guard let self = self else { return }', '')
    position_types = '\n'.join(
        block(source, 'struct ' + name) if 'struct ' + name + ' {' in source else 'struct ' + name + ' {}'
        for name in ('CurrentSessionCheckpoint', 'CurrentSessionPositionRestore'))
    return position_types + '\n' + (code.replace('// PRODUCTION_POLICY', block(source, 'struct AudioRecoveryRetryPolicy'))
            .replace('// PRODUCTION_TIMING', block(source, 'struct NativePlaybackTiming'))
            .replace('// PRODUCTION_FOREGROUND', active).replace('// PRODUCTION_METHODS', methods))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swiftc', default='swiftc')
    parser.add_argument('--source', type=Path, help='optional frozen source for negative control')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = (args.source or root / 'ios/Runner/PlaybackService.swift').read_text()
    code = build(source, (root / 'tool/audio_recovery_review.swift').read_text())
    code += (root / 'tool/command_race_review.swift').read_text()
    with tempfile.TemporaryDirectory(prefix='leeplayer-command-race-review-') as folder:
        work = Path(folder)
        (work / 'main.swift').write_text(code)
        subprocess.run([args.swiftc, '-module-cache-path', str(work / 'cache'),
                        str(work / 'main.swift'), '-o', str(work / 'review')], check=True)
        subprocess.run([str(work / 'review')], check=True)


if __name__ == '__main__':
    main()
