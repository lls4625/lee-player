#!/usr/bin/env python3
"""Execute production presentation rules/methods with deterministic collaborators.

No AVKit class is subclassed or imported by this Linux harness. Its lightweight
collaborators exercise the extracted service decisions and callback ordering;
they cannot validate Apple's SDK contracts, rendering, or device PiP behavior.
Source assertions also check lifecycle/install and bridge wiring that the harness
does not execute. Run Xcode and real-device regressions separately.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile
import sys

# Keep generated Python cache files out of source/delivery copies.
sys.dont_write_bytecode = True
from run_replay_gate_review import declaration


def block(source, anchor):
    start = source.index(anchor)
    begin = source.index('{', start)
    depth = 0
    for i in range(begin, len(source)):
        depth += (source[i] == '{') - (source[i] == '}')
        if depth == 0:
            return source[start:i + 1]
    raise AssertionError(f'Unclosed block: {anchor}')


def source_checks(source, bridge, renderer, header):
    count = 0

    def check(ok, label):
        nonlocal count
        assert ok, label
        count += 1

    for notification in ('willResignActiveNotification', 'didEnterBackgroundNotification'):
        body = block(source, f'notifications.append(center.addObserver(forName: UIApplication.{notification}')
        check('suspendAVPlayerPresentation' not in body and 'discardAVPlayerPiP' not in body
              and 'videoLayer.player' not in body, f'{notification} must preserve ordinary presentation')
    active = block(source, 'notifications.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification')
    check('ensureAVPlayerPresentation' in active, 'active notification must repair without a detached flag')
    attach = block(source, '  private func attachAVPlayerPresentationIfAllowed(')
    check('videoLayer.player = nil' not in attach, 'rejected attach cannot detach')
    check('if videoLayer.player !== player' in attach, 'attachment is idempotent')
    load = block(source, '  private func loadPrepared(')
    check(load.index('attachAVPlayerPresentationIfAllowed(reason: "initial load")') < load.index('Task.detached'),
          'first-load attachment remains before asynchronous item installation')
    check('hasValidAVPlayerPresentationItem' not in load, 'initial load must not require an installed item')
    install = block(source, '  private func install(')
    check('self.player.currentItem === item' in install and 'self.currentPath == path' in install,
          'ready callback must match actual item and media')
    check(install.index('player.replaceCurrentItem(with: item)') < install.index('ensureAVPlayerPresentation(reason: "item installed")'),
          'installation repairs after item assignment')
    check('self.ensureAVPlayerPresentation(reason: "item ready")' in install,
          'ready provides a separate repair exit')
    surface = block(source, '  func attachSurface(')
    check('ensureAVPlayerPresentation(reason: "surface attached")' in surface,
          'new surfaces enter the ordinary guarded repair')
    check('hasValidAVPlayerPresentationItem && (avPlayerPiPAuthorized || pipActive)' in surface
          and 'attachAVPlayerPresentationIfAllowed(reason: "authorized PiP surface attached")' in surface,
          'authorized PiP surfaces preserve the separate handoff attachment')
    check('avPlayerPresentationDetachedForBackground' not in source, 'repair must not depend on stale detached bookkeeping')
    discard = block(source, '  private func discardAVPlayerPiP(')
    check(discard.index('pip = nil') < discard.index('retirePiP(controller)'), 'clear AV ownership before possibly synchronous stop')
    finish = block(source, '  private func finishPendingReplacement(')
    check(finish.index('mediaKitPiP = nil') < finish.index('renderer?.stop()'), 'clear MK ownership before possibly synchronous stop')
    aborted = block(finish, 'if request.aborted')
    check('performLoad' not in aborted and 'return true' in aborted, 'late terminal cannot revive an aborted load')
    retirement = block(source, '  private func retirePiP(')
    timeout = block(retirement, 'DispatchQueue.main.asyncAfter')
    check('removeValue(forKey: key)' not in timeout.replace('retiringPiPAbortCompletions.removeValue(forKey: key)', ''),
          'retirement timeout must retain controller identity')
    check('self.fail("media_engine_cleanup_failed")' in timeout, 'unconfirmed stop ends loading as failure')
    for callback in ('pictureInPictureControllerWillStartPictureInPicture', 'pictureInPictureControllerDidStartPictureInPicture'):
        body = block(bridge, f'  func {callback}(')
        check('rejectRetiringPiPStart' in body, 'both start callbacks observe and reject retired identities')
    check('@property (nonatomic, readonly) BOOL startIssued;' in header, 'renderer start exposure stays readonly')
    issue = block(renderer, '- (void)startIfPossible {')
    check(issue.index('self.startIssued = YES') < issue.index('[self.controller startPictureInPicture]'),
          'renderer records issued start before calling AVKit')
    print(f'Presentation source wiring: {count} assertions passed', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swiftc', default='swiftc')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = (root / 'ios/Runner/PlaybackService.swift').read_text()
    source_checks(source, (root / 'ios/Runner/PlayerBridge.swift').read_text(),
                  (root / 'ios/Runner/MediaKitPiPRenderer.m').read_text(),
                  (root / 'ios/Runner/MediaKitPiPRenderer.h').read_text())
    methods = [
        '  private var hasValidAVPlayerPresentationItem: Bool',
        '  private func discardAVPlayerPiP(', '  private func prepareAVPlayerPiP(',
        '  private func attachAVPlayerPresentationIfAllowed(',
        '  private func ensureAVPlayerPresentation(', '  func attachSurface(',
        '  private func suspendAVPlayerPresentationForBackground(',
        '  private func reconcileAVPlayerPresentation(', '  private func retirePiP(',
        '  func finishRetiringPiP(', '  func rejectRetiringPiPStart(',
        '  private func finishPendingReplacement(', '  func finishAVPlayerPiP(',
        '  func didStartAVPlayerPiP(', '  func rejectUnauthorizedAVPlayerPiPStart(',
        '  private func cancelPendingAVPlayerPiP(', '  func finishMediaKitPiP(',
        '  private func discardMediaKitPiP(', '  func abortMediaKitPiP(',
        '  static func matchesPiPAbort(', '  private func fail(', '  private func recordLifecycle(',
    ]
    extracted = '\n\n'.join(block(source, anchor) for anchor in methods)
    harness = (root / 'tool/presentation_review.swift').read_text()
    harness = harness.replace('// PRODUCTION_POLICY', declaration(source, 'AVPlayerPresentationPolicy'))
    harness = harness.replace('  // PRODUCTION_METHODS', extracted)
    with tempfile.TemporaryDirectory(prefix='leeplayer-presentation-review-') as work:
        work = Path(work)
        main = work / 'main.swift'
        main.write_text(harness)
        binary = work / 'review'
        subprocess.run([args.swiftc, '-module-cache-path', str(work / 'cache'), str(main), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    main()
