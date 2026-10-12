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

    resign = block(source, 'notifications.append(center.addObserver(forName: UIApplication.willResignActiveNotification')
    check('discardUnrequestedAVPlayerPiP()' in resign and 'videoLayer.player' not in resign,
          'willResign revokes only unrequested preparation without touching video')
    background = block(source, 'notifications.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification')
    check('videoLayer.player' not in background and 'discardAVPlayerPiP' not in background,
          'background transition keeps healthy presentation bound')
    idle = block(source, '  private func discardUnrequestedAVPlayerPiP(')
    check('!avPlayerPiPAuthorized' in idle and 'avPlayerPiPRequest == nil' in idle
          and '!avPlayerPiPOwnsPresentation' in idle and 'discardAVPlayerPiP()' in idle,
          'idle revocation protects all authorized or issued/observed/active presentations')
    check('player = nil' not in idle and 'stopPictureInPicture' not in idle,
          'idle revocation neither detaches nor treats an idle controller as started')
    for gate in ('Thread.isMainThread', 'let controller = pip', 'pendingReplacement == nil', 'retiringPiP.isEmpty'):
        check(gate in idle, f'idle source release requires {gate}')
    check(idle.index('discardAVPlayerPiP()') < idle.index('controller.contentSource = nil'),
          'original KVO/ownership/delegate cleanup precedes source clearing')
    post_discard = idle[idle.index('discardAVPlayerPiP()'):idle.index('controller.contentSource = nil')]
    check('retiringPiP[ObjectIdentifier(controller)] == nil' in post_discard
          and '!controller.isPictureInPictureActive' in post_discard,
          'source setter rechecks non-retired and inactive ownership after generic cleanup')
    after_clear = idle[idle.index('controller.contentSource = nil') + len('controller.contentSource = nil'):]
    code_after_clear = '\n'.join(line for line in after_clear.splitlines() if not line.strip().startswith('//'))
    check('.playerLayer' not in code_after_clear and 'recordAVPlayerPiPEvent(' not in code_after_clear,
          'source-cleared controller cannot be queried through playerLayer or detailed AV diagnostics')
    check(source.count('controller.contentSource = nil') == 1,
          'source clearing is limited to the single idle teardown site')
    check('sourceMatchedCurrentLayerBefore=' in idle and '.map { $0 === surface?.videoLayer } ?? false' in idle,
          'source matching is a non-nil pre-clear Boolean reused only as captured evidence')
    active = block(source, 'notifications.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification')
    check('ensureAVPlayerPresentation' in active, 'active notification repairs and reprepares')
    attach = block(source, '  private func attachAVPlayerPresentationIfAllowed(')
    check('videoLayer.player = nil' not in attach, 'rejected attach cannot detach')
    check('if videoLayer.player !== player' in attach, 'attachment is idempotent')
    check('prepareAVPlayerPiP()' in attach, 'foreground attachment supplies preparation')
    check(source.count('AVPictureInPictureController(playerLayer:') == 1,
          'single AV controller construction site')
    prepare = block(source, '  private func prepareAVPlayerPiP(')
    begin = block(source, '  private func beginAVPlayerPiP(')
    check('AVPictureInPictureController(playerLayer:' in prepare, 'preparation owns construction')
    check('canStartPictureInPictureAutomaticallyFromInline = false' in prepare, 'automatic inline mode stays disabled')
    check('options: [.initial, .new]' in prepare and 'DispatchQueue.main.async' in prepare,
          'preparation readiness uses queued initial and new KVO')
    for forbidden in ('authorizeManualPiP(', 'avPlayerPiPAuthorized = true', 'avPlayerPiPRequest = (',
                      'startAVPlayerPiPIfPossible(', 'startPictureInPicture()', 'armAVPlayerPiPTimeout('):
        check(forbidden not in prepare, f'preparation cannot perform {forbidden}')
    check('!avPlayerPiPOwnsPresentation' in prepare and 'retiringPiP.isEmpty' in prepare,
          'preparation cannot replace in-flight or quarantined graphs')
    check('controller.isPictureInPicturePossible else { publish(); return }' in begin,
          'unready tap has no delayed authorization or error popup')
    check(source.count('try beginAVPlayerPiP(') == 1 and source.count('startAVPlayerPiPIfPossible(controller,') == 1,
          'only a button request can issue AVKit start')
    issue = block(source, '  private func startAVPlayerPiPIfPossible(')
    check('applicationState == .active' not in issue.split('// Do not require')[0],
          'authorized immediate background handoff is preserved')
    check(issue.index('pipStartIssued = true') < issue.index('controller.startPictureInPicture()'),
          'record issued before AVKit can synchronously callback')
    check(issue.index('pipPossibleObservation?.invalidate()') < issue.index('controller.startPictureInPicture()'),
          'r2 observer-lifetime experiment is removed; manual start consumes preparation')
    terminal = block(source, '  func finishAVPlayerPiP(')
    check('pip = nil' in terminal and 'controller.delegate = nil' in terminal,
          'normal terminal releases the completed controller')
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
    check('guard retiringPiP.isEmpty' in prepare,
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
    observer = block(source, '  private func observePiPTransport(')
    check('sessionID: sessionID, generation: token' in observer and
          'weak observed, weak item' in observer and 'weak controller' not in observer and 'queue: .main' in observer,
          'transport observation captures immutable presentation and item identity and serializes on main')
    check('guard reason == .setRateCalled' in observer, 'background/interruption/failure reasons never drive the passive mirror')
    check('DispatchQueue.main.async' not in observer,
          'transport observations add no extra deferred intent mutation')
    transport = block(source, '  private func mirrorPiPTransport(')
    for gate in ('item === player.currentItem', 'session.id == sessionID', 'token == generation',
                 'avPlayerTransportMutationDepth == 0',
                 'session.inline || pip.map', '!isSeeking', '!interrupted', '!audioRecoveryPending'):
        check(gate in transport, f'transport preserves identity and technical-pause gate: {gate}')
    check('play()' not in transport.split('let playing =')[1] and
          'pause()' not in transport.split('let playing =')[1] and
          'attemptAudioRecovery(' not in transport,
          'actual-transport mirror cannot feed control commands back into AVKit')
    for anchor in ('  private func pauseEngine(', '  private func resumeEngine('):
        body = block(source, anchor)
        check('avPlayerTransportMutationDepth += 1' in body and
              'defer { avPlayerTransportMutationDepth -= 1 }' in body,
              'synchronous service transport mutation is explicitly excluded')
    restore_bridge = block(bridge, '  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterface')
    check(restore_bridge.index('guard playback.allowsPiPRestore') < restore_bridge.index('completePiPRestore(false)'),
          'late old-controller restore cannot cancel a current restore completion')
    check('self?.completePiPRestore(false)' in restore_bridge,
          'restore timeout clears its matching service restore disposition')
    check('completePiPRestore(false)' in block(bridge, '  func handle(') if '  func handle(' in bridge else
          'case "playerDismissed":\n        pendingMediaKitPiPToken = nil; pendingMediaKitPiPSourceView = nil\n        completePiPRestore(false)' in bridge,
          'navigation cancellation completes and clears restoration')
    check('"pipActive": pipActive' in block(source, '  func snapshot('),
          'Flutter receives actual PiP activity separately from preparation/request readiness')
    print(f'Presentation source wiring: {count} assertions passed', flush=True)


def main(default_case_group='all'):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swiftc', default='swiftc')
    parser.add_argument('--case-group', choices=('all', 'position-recovery', 'pip-diagnostics', 'pip-prepared', 'pip-close', 'pip-idle-source'), default=default_case_group)
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
        '  private var pipRequesting: Bool', '  private var pipAvailable: Bool', '  private var avPlayerPiPOwnsPresentation: Bool',
        '  private func prepareAVPlayerPiP(', '  private func discardUnrequestedAVPlayerPiP(',
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
        '  func recordPiPFailure(', '  func allowsPiPRestore(', '  func ownsMediaKitPiP(',
        '  private func acceptPiPPlaybackSession(', '  func didStartMediaKitPiP(',
        '  private func clearPiPPlaybackSession(', '  func willStopPiP(',
        '  func beginPiPRestore(', '  func completePiPRestore(',
        '  private func clearPiPTransportObservation(', '  private func endInlinePiPTransportFollow(', '  private func observePiPTransport(',
        '  private func finishPiPPlaybackSession(', '  private func mirrorPiPTransport(',
        '  func recordAVPlayerPiPEvent(', '  func recordPiPDelegateEntry(',
        '  private func recordPiPDelegateEntryOnMain(',
        '  private static func pipDiagnosticIdentity(', '  private static func pipDiagnosticRect(',
        '  private func avPlayerPiPSourceSnapshot(',
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
    if args.case_group == 'pip-idle-source':
        harness = (harness[:harness.index('// Exhaustive input matrices')]
                   + harness[harness.index('// Idle PiP source-release regression scenarios'):
                             harness.index('// Prepared manual PiP regression scenarios')]
                   + harness[harness.index('print("Presentation production policy/method harness:'):])
    if args.case_group == 'pip-prepared':
        harness = (harness[:harness.index('// Exhaustive input matrices')]
                   + harness[harness.index('// Prepared manual PiP regression scenarios'):
                             harness.index('// PiP diagnostics regression scenarios')]
                   + harness[harness.index('print("Presentation production policy/method harness:'):])
    if args.case_group == 'pip-close':
        harness = (harness[:harness.index('// Exhaustive input matrices')]
                   + harness[harness.index('// PiP close and restore regression scenarios'):
                             harness.index('// PiP diagnostics regression scenarios')]
                   + harness[harness.index('print("Presentation production policy/method harness:'):])
    if args.case_group == 'pip-diagnostics':
        harness = (harness[:harness.index('// Exhaustive input matrices')]
                   + harness[harness.index('// PiP diagnostics regression scenarios'):])
    harness = harness.replace('// PRODUCTION_POLICY', declaration(source, 'AVPlayerPresentationPolicy') + '\n' + declaration(source, 'BackgroundPlaybackPolicy') + '\n' + declaration(source, 'MediaKitDecoderRecoveryPolicy'))
    harness = block(source, 'enum AVPlayerPiPTerminal') + '\n' + harness
    harness = block(source, 'struct NativePlaybackTiming') + '\n' + harness
    harness = '\n'.join(block(source, anchor) for anchor in
        ('struct CurrentSessionCheckpoint', 'struct CurrentSessionPositionRestore', 'struct PlaybackEndGate')) + '\n' + harness
    harness = harness.replace('  // PRODUCTION_METHODS', extracted)
    bridge_source = (root / 'ios/Runner/PlayerBridge.swift').read_text()
    bridge_methods = [
        '  private func completePiPRestore(',
        '  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterface',
        '  func pictureInPictureControllerWillStopPictureInPicture(',
        '  func pictureInPictureControllerDidStopPictureInPicture(',
        '  func pictureInPictureControllerDidStartPictureInPicture(',
        '  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError',
    ]
    harness = harness.replace('  // PRODUCTION_BRIDGE_METHODS', '\n\n'.join(
        block(bridge_source, anchor) for anchor in bridge_methods))
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
    assert 'var playerLayer: VideoLayer {' in controller, 'controller layer must match the non-optional SDK declaration'
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
