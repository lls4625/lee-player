#!/usr/bin/env python3
"""Execute unchanged production subtitle request/commit methods with Foundation stubs.
This covers application cancellation/ordering, not UIKit or actual AV selection.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile


def block(source, anchor):
    start = source.index(anchor)
    begin = source.index('{', start)
    depth = 0
    for i in range(begin, len(source)):
        depth += (source[i] == '{') - (source[i] == '}')
        if depth == 0:
            return source[start:i + 1]
    raise AssertionError(anchor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swiftc', default='swiftc')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = (root / 'ios/Runner/PlaybackService.swift').read_text()
    types = '\n'.join(block(source, name) for name in (
        'struct SubtitleCue', 'final class SubtitleParseRequest',
        'struct SubtitleTimeline', 'enum ExternalSubtitleParser'))
    methods = '\n'.join(block(source, name) for name in (
        '  private func cancelSubtitleLoad()', '  private func loadSubtitle(path:'))
    for anchor in ('  private func deferPresentationLoad(', '  private func awaitPresentationStop(',
                   '  private func performLoad(', '  private func fail(', '  func stopForMutation(', '  deinit {\n    cancelSubtitleLoad()'):
        assert 'cancelSubtitleLoad()' in block(source, anchor), anchor
    assert 'if kind == "subtitle" { cancelSubtitleLoad() }' in block(source, '  func requestTrack(')
    assert 'loadSubtitle(path: path, completion: completion)' in block(source, '  func requestSubtitle(')
    assert 'subtitleTimeline.text(at: subtitlePosition)' in block(source, '  private func tick(')
    harness = r'''
import Foundation

enum LibraryFailure: Error { case app(String); var code: String { switch self { case .app(let code): return code } } }
__TYPES__
final class Library {
  func url(_ path: String) throws -> URL { URL(fileURLWithPath: path) }
  func scheduleProtectionNormalization(paths: [String]) {}
}
final class Service {
  let library = Library()
  let subtitleQueue = DispatchQueue(label: "test.subtitle", qos: .userInitiated)
  var subtitleLoad: (request: SubtitleParseRequest, done: (String?) -> Void)?
  var generation = 0
  var mediaKit: NSObject?
  var timelineReady = true, seekFault = false, detectingIntro = false
  var currentPath: String? = "movie.mp4"
  var trackSelection: Int?
  var position = 0.0
  var subtitleTimeline = SubtitleTimeline()
  var subtitleName = ""
  var publishes = 0, selections = 0
  func seek(_ position: Double) {}
  func selectTrack(kind: String, index: Int) throws { selections += 1 }
  func publish() { publishes += 1 }
  func load(_ path: String, done: @escaping (String?) -> Void) { loadSubtitle(path: path, completion: done) }
  func cancel() { cancelSubtitleLoad() }
  deinit { cancelSubtitleLoad() }
__METHODS__
}
var count = 0
func check(_ ok: @autoclosure () -> Bool, _ message: String) {
  precondition(ok(), message); count += 1
}
func drain(until condition: () -> Bool) {
  let deadline = Date().addingTimeInterval(4)
  while !condition() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
  check(condition(), "async subtitle completion was bounded")
}
let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let a = folder.appendingPathComponent("a.srt")
let b = folder.appendingPathComponent("b.vtt")
try "1\n00:00:00,000 --> 00:00:03,000\nOLD_A".write(to: a, atomically: true, encoding: .utf8)
try "WEBVTT\n\n00:00.000 --> 00:03.000\nNEW_B".write(to: b, atomically: true, encoding: .utf8)
// A pending file can be superseded without waiting for its read or parse.
do {
  let s = Service(); var first: [String?] = [], second: [String?] = []
  s.subtitleQueue.suspend()
  s.load(a.path) { first.append($0) }
  s.load(b.path) { second.append($0) }
  check(first.count == 1 && first[0] == "control_superseded", "newest request cancels older receipt once")
  check(second.isEmpty && s.subtitleName.isEmpty, "no success before actual apply")
  s.subtitleQueue.resume(); drain { !second.isEmpty }
  check(second.count == 1 && second[0] == nil, "newest request committed successfully")
  check(s.subtitleName == "b.vtt" && s.subtitleTimeline.text(at: 1) == "NEW_B", "only newest caption applied")
  check(s.selections == 1 && first.count == 1, "late old work cannot select/complete again")
}
for mode in ["off", "embedded", "new generation", "failed", "engine changed", "file removed"] {
  let s = Service(); var replies: [String?] = []
  s.subtitleQueue.suspend(); s.load(a.path) { replies.append($0) }
  switch mode {
    case "off", "embedded": s.cancel()
    case "new generation": s.generation += 1; s.cancel()
    case "failed": s.seekFault = true; s.timelineReady = false
    case "engine changed": s.mediaKit = NSObject()
    default: try FileManager.default.removeItem(at: a)
  }
  s.subtitleQueue.resume(); drain { !replies.isEmpty }
  check(replies.count == 1 && replies[0] != nil, "cancel/failure returns exactly one error: \(mode)")
  check(s.subtitleName.isEmpty && s.selections == 0, "stale parse cannot change selected track: \(mode)")
}
// Completion identity, rather than only playback generation, protects a newer request.
do {
  let s = Service(); var errors: [String?] = []
  s.trackSelection = 1
  s.load(b.path) { errors.append($0) }
  check(errors.count == 1 && errors[0] == "subtitle_switch_busy", "busy selection rejects without async work")
  s.trackSelection = nil
  s.load(b.path) { errors.append($0) }
  drain { errors.count == 2 }
  check(errors[1] == nil && s.subtitleName == "b.vtt", "busy failure does not wedge later request")
}

// A rejected oversized cue leaves the current file, timeline and selection intact.
do {
  let s = Service(); var errors: [String?] = []
  s.subtitleName = "already-selected.srt"
  s.subtitleTimeline = SubtitleTimeline([SubtitleCue(start: 0, end: 10, text: "KEEP_CURRENT")])
  let large = folder.appendingPathComponent("large.srt")
  try ("1\n00:00:00,000 --> 00:00:03,000\n" + String(repeating: "<", count: 49 * 1024))
    .write(to: large, atomically: true, encoding: .utf8)
  s.load(large.path) { errors.append($0) }
  drain { !errors.isEmpty }
  check(errors.count == 1 && errors[0] == "subtitle_load_failed", "oversized cue rejected with existing generic message")
  check(s.subtitleName == "already-selected.srt", "rejected parse keeps selected filename")
  check(s.subtitleTimeline.text(at: 1) == "KEEP_CURRENT" && s.selections == 0, "rejected parse preserves caption and embedded selection")
}
// Destroyed service cancels its accepted result once; queued parsing cannot retain it.
do {
  var s: Service? = Service(); weak var weakService = s
  let queue = s!.subtitleQueue
  var replies: [String?] = []
  queue.suspend(); s!.load(b.path) { replies.append($0) }
  s = nil
  check(weakService == nil, "parse queue does not retain service")
  check(replies.count == 1 && replies[0] == "control_superseded", "deinit silently completes cancellation once")
  queue.resume()
  queue.sync {} // All cancelled worker closures have now returned.
  RunLoop.current.run(until: Date().addingTimeInterval(0.01))
  check(replies.count == 1, "dead service cannot publish late parse receipt")
}
print("Subtitle production request lifecycle: \(count) assertions passed")
'''.replace('__TYPES__', types).replace('__METHODS__', methods)
    with tempfile.TemporaryDirectory(prefix='lee-subtitle-lifecycle-') as temp:
        swift = Path(temp) / 'main.swift'
        binary = Path(temp) / 'review'
        swift.write_text(harness)
        subprocess.run([args.swiftc, '-module-cache-path', str(Path(temp) / 'module-cache'), '-swift-version', '5', str(swift), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)

if __name__ == '__main__': main()
