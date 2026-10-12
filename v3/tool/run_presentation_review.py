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
    check('prepareAVPlayerPiP' not in source, 'ordinary playback must not prebuild PiP')
    check(source.count('AVPictureInPictureController(playerLayer:') == 1,
          'single explicit AV controller construction site')
    begin = block(source, '  private func beginAVPlayerPiP(')
    check('AVPictureInPictureController(playerLayer:' in begin, 'explicit request owns controller creation')
    check(source.count('try beginAVPlayerPiP(') == 1, 'only startPiP calls explicit creation')
    check('canStartPictureInPictureAutomaticallyFromInline = false' in begin, 'automatic inline mode stays disabled')
    check('options: [.initial, .new]' in begin and 'DispatchQueue.main.async' in begin,
          'request readiness uses queued initial and new KVO')
    issue = block(source, '  private func startAVPlayerPiPIfPossible(')
    check('applicationState == .active' not in issue.split('// Do not require')[0],
          'readiness does not cancel authorized immediate background handoff')
    check(issue.index('pipStartIssued = true') < issue.index('controller.startPictureInPicture()'),
          'record issued before AVKit can synchronously callback')
    terminal = block(source, '  func finishAVPlayerPiP(')
    check('pip = nil' in terminal and 'controller.delegate = nil' in terminal,
          'normal terminal releases controller without reprepare')
    reconcile = block(source, '  private func reconcileAVPlayerPresentation(')
    check('videoLayer.player = nil' not in reconcile and 'suspendAVPlayer' not in source,
          'ordinary background does not unbind healthy layer')
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
    for anchor in ('  private func load(', '  func stopForMutation('):
        check('avPlayerPiPOwnsPresentation ? pip : nil' in block(source, anchor),
              'media replacement honors observed-only start ownership')
    check('!avPlayerPiPOwnsPresentation' in block(source, '  private func fallbackToMediaKit('),
          'engine fallback cannot destroy observed-only AVKit output')
    check('decoderRecoveryAttempted = false' not in block(source, '  private func performLoad('),
          'automatic reload cannot reset task recovery budget')
    check('case "recoverDecoder": timeoutSeconds = 14' in bridge,
          'decoder repair acknowledgement has a bounded bridge timeout')
    discard = block(source, '  private func discardAVPlayerPiP(')
    check(discard.index('pip = nil') < discard.index('retirePiP(controller)'), 'clear AV ownership before possibly synchronous stop')
    finish = block(source, '  private func finishPendingReplacement(')
    check(finish.index('mediaKitPiP = nil') < finish.index('renderer?.stop()'), 'clear MK ownership before possibly synchronous stop')
    check('pendingReplacement = nil' in finish and 'performLoad' in finish,
          'matching terminal consumes latest replacement exactly once')
    retirement = block(source, '  private func retirePiP(')
    timeout = block(retirement, 'DispatchQueue.main.asyncAfter')
    check('removeValue(forKey: key)' not in timeout.replace('retiringPiPAbortCompletions.removeValue(forKey: key)', ''),
          'retirement timeout must retain controller identity')
    check('self.fail(' not in timeout and 'resumeDeferredPresentationLoadIfPossible' in timeout,
          'PiP timeout preserves media health and latest load intent')
    matches = block(source, '  private func matchesAVPlayerPiPRequest(')
    check('deadline' not in matches, 'identity and authorization cannot expire an already successful start')
    phase = block(source, '  private var avPlayerPiPPhaseAuthorizesBackground: Bool')
    check('mediaKit == nil' in phase and 'avPlayerPiPAuthorized' in phase
          and 'request.deadline != nil' in phase and 'matchesAVPlayerPiPRequest' in phase,
          'AV phase authorization requires the live complete request identity')
    for name in ('manualPiPAllowsBackground', 'playbackEnvironmentAllowsPlayback'):
        check('if avPlayerPiPPhaseAuthorizesBackground { return true }' in block(source, f'  private var {name}: Bool'),
              f'{name} must not let heartbeat preempt the AV phase watchdog')
    tick = block(source, '  private func tick()')
    check('discardAVPlayerPiP' not in tick and 'stopMediaKitPiPAndRestoreVideoOutput' in tick,
          'heartbeat leaves AV lifecycle expiry to its phase watchdog and preserves MK handling')
    for callback, result in (('pictureInPictureControllerDidStopPictureInPicture', 'didStop'),
                             ('pictureInPictureController', 'failedToStart')):
        anchor = f'  func {callback}('
        if result == 'failedToStart':
            anchor += '_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError'
        body = block(bridge, anchor)
        check(f'avTerminal: .{result}' in body and f'terminal: .{result}' in body,
              f'real Bridge {result} delivers typed terminal to retiring and current AV ownership')
    event = block(source, '  func recordAVPlayerPiPEvent(')
    check(event.index('guard pip === controller || ownsRetiredAV') < event.index('let layer = controller.playerLayer'),
          'AV-only diagnostic layer access requires live ownership, never historical address alone')
    check('isReadyForDisplay' not in begin and 'isReadyForDisplay' not in issue,
          'first-frame readiness remains a diagnostic, not a new PiP start gate')
    issue = block(source, '  private func startAVPlayerPiPIfPossible(')
    check('deadline.map' in issue, 'an unissued stale readiness still cannot start')
    isolate = block(source, '  private func isolateRetiringAVPlayerIfNeeded(')
    check(isolate.index('clearBoundary()') < isolate.index('player = AVPlayer()'),
          'remove old boundary observer on its actual player')
    check('output.player.isMuted = true' in isolate and 'owner.isMuted = true; owner.pause()' in isolate,
          'quarantined native controls cannot emit audio or pause the new player')
    check('replaceCurrentItem' not in isolate and 'layer.player = nil' not in isolate,
          'isolation preserves AVKit item and layer relationships until terminal')
    check('retiringPiP.isEmpty' in block(source, '  func startPiP(delegate:'),
          'one unconfirmed graph blocks more PiP graphs, bounding retained resources')
    check('case "playerDismissed":' in bridge and 'case "pipRestoreAllowed":' in bridge,
          'navigation cancellation and token validation bridge are wired')
    for callback in ('pictureInPictureControllerWillStartPictureInPicture', 'pictureInPictureControllerDidStartPictureInPicture'):
        body = block(bridge, f'  func {callback}(')
        check('rejectRetiringPiPStart' in body, 'both start callbacks observe and reject retired identities')
    check('@property (nonatomic, readonly) BOOL startIssued;' in header, 'renderer start exposure stays readonly')
    issue = block(renderer, '- (void)startIfPossible {')
    check(issue.index('self.startIssued = YES') < issue.index('[self.controller startPictureInPicture]'),
          'renderer records issued start before calling AVKit')
    check('notice?' not in source and '"type": "notice"' not in bridge,
          'recoverable native playback failures have no popup dispatch path')
    layer = block(source, '  func isolateVideoLayer(')
    check('backgroundColor = UIColor.black.cgColor' in layer and 'isOpaque = true' in layer
          and 'below: caption.layer' in layer, 'replacement layer covers old content below captions')
    check('player = nil' not in layer and 'removeFromSuperlayer' not in layer,
          'quarantine layer rotation does not detach the source from AVKit')
    check('guard retiringPiP.isEmpty' in begin,
          'native AV preparation retains the unchanged system PiP safety gate')
    capture = block(source, '  private func captureRememberedProgress(')
    check(capture.index('currentSessionCheckpoint =') < capture.index('guard rememberProgress'),
          'volatile position capture is independent of persisted history preference')
    for anchor in ('  func open(paths:', '  func stopForMutation('):
        check('resetCurrentSessionCheckpoint()' in block(source, anchor),
              'new explicit selection and clear invalidate volatile recovery identity')
    check('resetCurrentSessionCheckpoint()' in block(source, '  func skip('),
          'different queue item cannot inherit a current-session checkpoint')
    for body in (source[source.index('  func seek(_ seconds:'):source.index('  func previewSeek(')],
                 block(source, '  func previewSeek(')):
        check('currentSessionPositionRestore = nil' in body,
              'newer manual positioning cancels the old internal restore')
    ready = block(source, '  private func mediaKitChanged(')
    check(ready.index('restoreCurrentSessionPositionIfNeeded') < ready.index('readPlaybackRecord'),
          'internal recovery never falls back to a historical record before its own seek')
    recovery = block(source, '  private func recoverMediaKitVideoOutput(')
    check('checkpoint.engineID == engine.id' in recovery and 'checkpoint.generation == generation' in recovery,
          'reload requires a confirmed checkpoint from this exact source engine/generation')
    check('load(resume: false, autoplay: shouldResume)' in recovery and 'load(resume: true' not in recovery,
          'automatic output recovery cannot borrow disk history')
    prepared = block(source, '  private func loadPrepared(')
    check('$0.targetGeneration == token' in prepared and
          '$0.checkpoint.sessionID == currentSessionID' in prepared and
          '$0.checkpoint.path == path' in prepared and
          'Self.prefersMediaKit(url) || restoringCurrentMKPosition' in prepared,
          'explicit current-session MK rebuild remains MK even for an AV-fallback MP4')
    check('guard currentSessionPositionRestore == nil || restoringCurrentMKPosition else' in prepared and
          'inline output recovery load identity no longer matches' in prepared,
          'a mismatched recovery request cannot fall through to an ordinary zero-position open')
    restore = block(source, '  private func restoreCurrentSessionPositionIfNeeded(')
    check('engine.seekable' in restore and 'currentSessionPositionRestore?.id == restore.id' in restore,
          'position restore requires seek support and its exact one-shot request')
    check('self.playbackOperation == operation' in restore and 'self.wantsPlayback =' not in restore,
          'restoration cannot overwrite a newer seek or replay stale autoplay intent')
    check('duration - 2' not in restore, 'recovery positions near EOF are not history-filtered to zero')
    restart = block(source, '  private func restartCurrentItem(')
    check(restart.index('currentSessionPositionRestore = nil') < restart.index('playbackOperation += 1'),
          'same-item replay cancels a restore before invalidating its completion operation')
    check('if next == index' in block(source, '  func skip(') and
          'restartCurrentItem()' in block(source, '  func skip('),
          'single-item next routes through the replay cancellation path')
    print(f'Presentation source wiring: {count} assertions passed', flush=True)


def main(default_case_group='all'):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swiftc', default='swiftc')
    parser.add_argument('--case-group', choices=('all', 'position-recovery'), default=default_case_group)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = (root / 'ios/Runner/PlaybackService.swift').read_text()
    source_checks(source, (root / 'ios/Runner/PlayerBridge.swift').read_text(),
                  (root / 'ios/Runner/MediaKitPiPRenderer.m').read_text(),
                  (root / 'ios/Runner/MediaKitPiPRenderer.h').read_text())
    methods = [
        '  private var blockingRetiringPiP: Bool', '  private var presentationWaiting: Bool',
        '  private var playbackEnvironmentAllowsPlayback: Bool',
        '  private var avPlayerPiPPhaseAuthorizesBackground: Bool',
        '  private var manualPiPAllowsBackground: Bool',
        '  private func revokeManualPiP(', '  private func enforcePlaybackEnvironment(',
        '  private var hasValidAVPlayerPresentationItem: Bool',
        '  private var pipRequesting: Bool', '  private var avPlayerPiPOwnsPresentation: Bool',
        '  private func discardAVPlayerPiP(', '  private func beginAVPlayerPiP(',
        '  private func matchesAVPlayerPiPRequest(', '  private func startAVPlayerPiPIfPossible(',
        '  private func armAVPlayerPiPTimeout(', '  func startPiP(delegate:',
        '  func requestMediaKitDecoderRecovery(',
        '  private func attachAVPlayerPresentationIfAllowed(',
        '  private func ensureAVPlayerPresentation(', '  func attachSurface(',
        '  private func reconcileAVPlayerPresentation(', '  private func retirePiP(',
        '  func finishRetiringPiP(', '  func rejectRetiringPiPStart(',
        '  private func replaceFailedPlayerIfNeeded(',
        '  private func isolateRetiringAVPlayerIfNeeded(',
        '  private func resumeDeferredPresentationLoadIfPossible(',
        '  private func resumeHealthyPlaybackAfterPiPStop(',
        '  private func load(', '  private func deferPresentationLoad(',
        '  private func awaitPresentationStop(',
        '  func playerDismissed(', '  func play()', '  func pause()',
        '  private func finishPendingReplacement(', '  func finishAVPlayerPiP(',
        '  func didStartAVPlayerPiP(', '  func rejectUnauthorizedAVPlayerPiPStart(',
        '  func recordPiPFailure(', '  func allowsPiPRestore(',
        '  func recordAVPlayerPiPEvent(',
        '  private func cancelPendingAVPlayerPiP(', '  func finishMediaKitPiP(',
        '  private func restoreMediaKitVideoOutput(', '  private func recoverMediaKitVideoOutput(',
        '  private func captureRememberedProgress(', '  private func resetCurrentSessionCheckpoint(',
        '  private func restoreCurrentSessionPositionIfNeeded(',
        '  private var healthyForReplay: Bool', '  private func restartCurrentItem(',
        '  private func discardMediaKitPiP(', '  private func stopMediaKitPiPAndRestoreVideoOutput(',
        '  func abortMediaKitPiP(',
        '  static func matchesPiPAbort(', '  private func fail(', '  private func recordLifecycle(',
    ]
    extracted = '\n\n'.join(block(source, anchor) for anchor in methods)
    harness = (root / 'tool/presentation_review.swift').read_text()
    if args.case_group == 'position-recovery':
        # Share the exact production-method adapter; run only the new
        # position/ownership scenarios, without copying their implementation.
        harness = (harness[:harness.index('// Exhaustive input matrices')]
                   + harness[harness.index('// An isolated old AV graph'):])
    harness = harness.replace('// PRODUCTION_POLICY', declaration(source, 'AVPlayerPresentationPolicy') + '\n' + declaration(source, 'BackgroundPlaybackPolicy') + '\n' + declaration(source, 'MediaKitDecoderRecoveryPolicy'))
    harness = block(source, 'enum AVPlayerPiPTerminal') + '\n' + harness
    harness = block(source, 'struct NativePlaybackTiming') + '\n' + harness
    harness = '\n'.join(block(source, anchor) for anchor in
        ('struct CurrentSessionCheckpoint', 'struct CurrentSessionPositionRestore', 'struct PlaybackEndGate')) + '\n' + harness
    harness = harness.replace('  // PRODUCTION_METHODS', extracted)
    route_start = source.index('      let restoringCurrentMKPosition =')
    route_end = source.index('      guard currentSessionPositionRestore == nil || restoringCurrentMKPosition', route_start)
    harness = harness.replace('    // PRODUCTION_MK_RECOVERY_ROUTE',
                              source[route_start:route_end] + '\n    return restoringCurrentMKPosition')
    expiry = block(block(source, '  private func tick()'), '    if manualPiPSession != nil')
    harness = harness.replace('// PRODUCTION_AV_PIP_HEARTBEAT', expiry)
    # Apple's controller.playerLayer is AVPlayerLayer, not AVPlayerLayer?.
    # Compile the exact former misuse against the same non-optional collaborator
    # as a negative control, so an accidentally optional mock cannot hide it.
    # https://developer.apple.com/documentation/avkit/avpictureinpicturecontroller/playerlayer
    controller = block(harness, 'final class AVPictureInPictureController')
    assert 'let playerLayer: VideoLayer\n' in controller, 'controller layer must match the non-optional SDK declaration'
    fixed_binding = ('if renderer == nil, let owner = controller.playerLayer.player {\n'
                     '      let layer = controller.playerLayer')
    assert fixed_binding in harness, 'production retirement binding must be extracted unchanged'
    negative = harness.replace(fixed_binding,
        'if renderer == nil, let layer = controller.playerLayer, let owner = layer.player {', 1)
    with tempfile.TemporaryDirectory(prefix='leeplayer-presentation-review-') as work:
        work = Path(work)
        bad = work / 'former_optional_binding.swift'
        bad.write_text(negative)
        rejected = subprocess.run([args.swiftc, '-typecheck', '-module-cache-path', str(work / 'cache'), str(bad)],
                                  capture_output=True, text=True)
        assert rejected.returncode != 0, 'negative control unexpectedly accepted non-optional conditional binding'
        assert 'initializer for conditional binding must have Optional type' in rejected.stderr, rejected.stderr
        print('PiP SDK nullability contract: former binding rejected by Swift typecheck', flush=True)
        main = work / 'main.swift'
        main.write_text(harness)
        binary = work / 'review'
        subprocess.run([args.swiftc, '-module-cache-path', str(work / 'cache'), str(main), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    main()
