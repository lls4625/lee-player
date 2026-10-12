#!/usr/bin/env python3
"""Execute real Swift audio-recovery methods with deterministic collaborators.

This is app-decision coverage, not Apple SDK, AVKit, audio hardware or background
execution validation. The virtual scheduler does not emulate iOS suspension.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile
import sys
sys.dont_write_bytecode = True
from run_presentation_review import block

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swiftc', default='swiftc')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = (root / 'ios/Runner/PlaybackService.swift').read_text()
    anchors = [
        '  private func interruption(', '  private func routeChanged(',
        '  private func activateAudioSession(', '  private func mediaServicesWereReset(',
        '  private func attemptAudioRecovery(', '  private func deferAudioRecovery(',
        '  private func scheduleAudioRecoveryRetry(', '  private func cancelAudioRecovery(',
        '  func pause()', '  func play()', '  private func openMediaKit(',
        '  private func mediaKitChanged(',
    ]
    methods = '\n\n'.join(block(source, anchor).replace('  private func', '  func') for anchor in anchors)
    methods += '\n  func configureAutoResume(_ values: [String:Any]) {\n' + block(source, 'if let value = values["autoResume"] as? Bool') + '\n  }'
    active = block(source, 'notifications.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification')
    active = active[active.index('{ [weak self] _ in') + len('{ [weak self] _ in'):-1]
    active = active.replace('guard let self = self else { return }', '')
    template = (root / 'tool/audio_recovery_review.swift').read_text()
    code = template.replace('// PRODUCTION_METHODS', methods).replace('// PRODUCTION_FOREGROUND', active)
    code = code.replace('// PRODUCTION_POLICY', block(source, 'struct AudioRecoveryRetryPolicy'))
    code = code.replace('// PRODUCTION_TIMING', block(source, 'struct NativePlaybackTiming'))
    code = '\n'.join(block(source, anchor) for anchor in
        ('struct CurrentSessionCheckpoint', 'struct CurrentSessionPositionRestore')) + '\n' + code
    assert 'resetAttempts: true' not in active, 'foreground cannot reset retry budget or grant explicit play'
    activate = block(source, '  private func activateAudioSession(')
    assert 'interrupted = false' not in activate, 'activation helper cannot silently clear interruption authorization'
    assert 'self.play()' not in block(source, '  private func mediaKitChanged('), 'item-ready is not a user Play command'
    with tempfile.TemporaryDirectory(prefix='leeplayer-audio-recovery-review-') as work:
        work = Path(work)
        (work / 'main.swift').write_text(code)
        subprocess.run([args.swiftc, '-module-cache-path', str(work / 'cache'), str(work / 'main.swift'), '-o', str(work / 'review')], check=True)
        subprocess.run([str(work / 'review')], check=True)
    print('Audio-recovery source wiring: 3 assertions passed')

if __name__ == '__main__':
    main()
