#!/usr/bin/env python3
"""Check PiP diagnostic wiring; optionally execute extracted Swift regressions.

Use --source-only for Python assertions without Swift. Otherwise --swiftc can
select a compiler. These checks do not validate Apple's SDK or device behavior.
"""
import argparse
from pathlib import Path
import sys

sys.dont_write_bytecode = True
from run_presentation_review import block, main as run_review


def source_checks(source, bridge, localizations):
    count = 0

    def check(condition, label):
        nonlocal count
        assert condition, label
        count += 1

    issue = block(source, '  private func startAVPlayerPiPIfPossible(')
    positions = [issue.index(token) for token in (
        'pipStartIssued = true', 'recordAVPlayerPiPEvent("start issued"',
        'AVPiP start call before', 'let callBegan =',
        'controller.startPictureInPicture()', 'let elapsedMs =', 'AVPiP start call returned')]
    check(positions == sorted(positions), 'issued/entry/clock/start/duration/return ordering')
    check(issue.count('controller.startPictureInPicture()') == 1, 'exactly one AVKit start call')
    check('weak var callSourceLayer = ' in issue, 'post-call source must not retain a platform object')
    check(issue.count('\\(callTrace)') == 4, 'both call logs and snapshots use the same captured trace')
    returned = issue[issue.index('let elapsedMs ='):]
    check('guard ' not in returned and 'recordAVPlayerPiPEvent(' not in returned,
          'synchronous delegate cleanup cannot filter the call return')
    check('main=\\(Thread.isMainThread)' in returned and 'elapsedMs=' in returned,
          'returned log carries thread and call duration')
    entry = block(source, '  func recordPiPDelegateEntry(')
    check('guard ' not in entry and '.playerLayer' not in entry, 'raw entry has no filtering or playerLayer access')
    classification = block(source, '  private func recordPiPDelegateEntryOnMain(')
    for owner in ('current', 'retiring', 'unknown'):
        check(f'owner = "{owner}"' in classification, f'explicit {owner} ownership')
    for forbidden in ('retiringPiP[', 'pip ===', 'mediaKitPiP', 'avPlayerPiPTraceRequests', 'recordLifecycle(', 'surface', 'UIApplication'):
        check(forbidden not in entry, f'cross-thread entry excludes {forbidden}')
    check('if originMain {' in entry and 'DispatchQueue.main.async { [weak self, weak controller]' in entry,
          'off-main raw diagnostics only queue weak references for main-thread recording')
    check('let entryUptime = ProcessInfo.processInfo.systemUptime' in entry and 'let key = ObjectIdentifier(controller)' in entry,
          'arrival timestamp and controller identity are captured before deferral')
    check('ownershipSample=' in classification and 'originMain=' in classification and 'entryUptime=' in classification,
          'deferred ownership cannot be mistaken for callback-time ownership')
    check('if let controller {' in classification, 'released weak controller cannot match a nil current owner')
    check('owner != "unknown" && kind == "AVPlayer"' in classification,
          'historical identity alone does not attribute AV request ownership')
    callbacks = {
        'willStart': 'pictureInPictureControllerWillStartPictureInPicture(',
        'didStart': 'pictureInPictureControllerDidStartPictureInPicture(',
        'failedToStart': 'pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError',
        'willStop': 'pictureInPictureControllerWillStopPictureInPicture(',
        'didStop': 'pictureInPictureControllerDidStopPictureInPicture(',
        'restore': 'pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler',
    }
    for event, signature in callbacks.items():
        method = block(bridge, '  func ' + signature)
        body = method[method.index('{') + 1:].lstrip()
        check(body.startswith(f'playback.recordPiPDelegateEntry("{event}"'),
              f'{event} records raw identity before original callback logic')
    detailed = block(source, '  func recordAVPlayerPiPEvent(')
    check(detailed.index('guard Thread.isMainThread') < detailed.index('let key = ObjectIdentifier(controller)'),
          'detailed AV diagnostics return before ownership, UI or arrays are read off-main')
    check(detailed.index('guard pip === controller || ownsRetiredAV') < detailed.index('controller.playerLayer'),
          'detailed snapshot requires known live AV ownership')
    snapshot = block(source, '  private func avPlayerPiPSourceSnapshot(')
    for forbidden in ('portName', '.uid', 'currentPath', 'localizedDescription', 'DispatchQueue', '.observe(',
                      'setActive(', 'setCategory(', 'layoutIfNeeded(', 'setNeedsLayout(', 'controller.playerLayer'):
        check(forbidden not in snapshot, f'source snapshot excludes {forbidden}')
    check('ancestors.count < 8' in snapshot and '.prefix(2800)' in snapshot,
          'ancestry work and source text are bounded')
    check(snapshot.count('.prefix(4)') == 2, 'input/output route lists are bounded')
    check('guard Thread.isMainThread else' in snapshot, 'off-main snapshots avoid UIKit traversal')
    check('layer === $0.layer || layer.superlayer === $0.layer' in snapshot,
          'surface geometry requires actual source layer relationship')
    check('ancestorsTruncated=' in snapshot and 'visibility=geometryAndAncestorsOnly' in snapshot,
          'incomplete hierarchy and non-occlusion visibility are explicit')
    check(source.count('includeSource: true') == 2,
          'only creation and existing watchdog add detailed AV event snapshots')
    for anchor, event in (('  private func beginAVPlayerPiP(', 'requested'),
                          ('  private func armAVPlayerPiPTimeout(', 'phase watchdog fired')):
        check(f'recordAVPlayerPiPEvent("{event}", controller: controller, includeSource: true)' in block(source, anchor),
              f'{event} captures a detailed snapshot')
    check('canStopPictureInPicture' not in source, 'no unverified canStop API dependency')
    check('private static let pipDiagnosticBuild = "pip-idle-source-20261012-r6"' in source,
          'diagnostic build has a stable local marker')
    info = block(source, '  func playbackInfo()')
    check('result["lifecycleEvents"] = ["PiP diagnostics build=\\(Self.pipDiagnosticBuild)"] + lifecycleEvents' in info,
          'build marker remains in existing playback info after log rollover')
    check("info['lifecycleEvents']" in localizations and 'lines.addAll(lifecycle.map' in localizations,
          'existing localization path renders diagnostic lines without new UI text')
    print(f'PiP diagnostics source wiring: {count} assertions passed', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-only', action='store_true')
    parser.add_argument('--swiftc', default='swiftc')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source_checks((root / 'ios/Runner/PlaybackService.swift').read_text(),
                  (root / 'ios/Runner/PlayerBridge.swift').read_text(),
                  (root / 'lib/app_localizations.dart').read_text())
    if args.source_only:
        print('Swift execution intentionally skipped (--source-only).')
    else:
        run_review(default_case_group='pip-diagnostics')


if __name__ == '__main__':
    main()
