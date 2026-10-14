#!/usr/bin/env python3
"""Compile and execute the production Foundation subtitle parser and timeline.

Uses exact production declarations with a LibraryFailure stub. These are real
parser/file-I/O tests, not AVPlayer, UIKit, file-provider or device tests. Large
malformed cases deliberately avoid running the former quadratic regex oracle.
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from run_presentation_review import block


SCENARIOS = r'''
enum LibraryFailure: Error { case app(String) }
// The adapter forwards to real Foundation file I/O. A one-shot hook controls
// delay/cancellation or file growth at the read boundary without changing any
// production parser method, relying on file-provider timing, or blocking a FIFO.
final class FileHandle {
  static var beforeRead: (() throws -> Void)?
  private let file: Foundation.FileHandle
  init(forReadingFrom url: URL) throws { file = try Foundation.FileHandle(forReadingFrom: url) }
  func close() throws { try file.close() }
  func read(upToCount count: Int) throws -> Data? {
    let hook = Self.beforeRead; Self.beforeRead = nil
    try hook?()
    return try file.read(upToCount: count)
  }
}
var checks = 0
func check(_ value: Bool, _ message: String) {
  guard value else { fatalError(message) }
  checks += 1
}
func expectError(_ expected: String, _ message: String, _ action: () throws -> Void) {
  do { try action(); fatalError("Expected \(expected): \(message)") }
  catch LibraryFailure.app(let actual) { check(actual == expected, message + ": " + actual) }
  catch { fatalError("Unexpected error \(error): \(message)") }
}
func parse(_ body: String) throws -> SubtitleTimeline {
  try ExternalSubtitleParser.parse(body, request: SubtitleParseRequest())
}
func srt(_ caption: String, newline: String = "\n") -> String {
  ["1", "00:00:01,250 --> 00:00:03,500", caption].joined(separator: newline)
}
struct RNG {
  var state: UInt64 = 0x123456789abcdef
  mutating func next(_ bound: Int) -> Int {
    state = state &* 6364136223846793005 &+ 1442695040888963407
    return Int((state >> 32) % UInt64(bound))
  }
}
var random = RNG()
let regex = try NSRegularExpression(pattern: "<[^>]+>")
func oldTags(_ text: String) -> String {
  regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
}
for text in ["", "<>中文", "<<>", "<a\nb>text", "left<b>bold</b>right",
             "<", "<<", "abc<unclosed", "<a><><b>", "🎬<i>日本語</i>繁體"] {
  check(ExternalSubtitleParser.removingTags(text) == oldTags(text), "tag edge equivalence: \(text)")
}
let alphabet = ["<", ">", "a", "b", "\n", "\r", " ", "中", "繁", "日", "🎬"]
for _ in 0..<3000 {
  let text = (0..<random.next(180)).map { _ in alphabet[random.next(alphabet.count)] }.joined()
  check(ExternalSubtitleParser.removingTags(text) == oldTags(text), "random bounded tag equivalence")
}
for caption in ["简体中文字幕", "繁體中文字幕", "日本語の字幕", "English subtitle 🎬"] {
  for newline in ["\n", "\r\n", "\r"] {
    let timeline = try parse(srt("<b>" + caption + "</b>", newline: newline))
    check(timeline.cues.count == 1 && timeline.cues[0].text == caption, "four-language SRT and line ending")
    check(timeline.text(at: 1.25) == caption && timeline.text(at: 3.5).isEmpty,
          "start inclusive, end exclusive")
  }
  let vtt = try parse("WEBVTT\n\ncue-id\n00:01.250 --> 00:03.500 align:start position:0%\n" + caption)
  check(vtt.cues.count == 1 && vtt.text(at: 2) == caption, "four-language VTT and cue settings")
}
check(try parse(srt("a\nb")).cues[0].text == "a\nb", "multiline caption")
check(try parse(srt("a\n")).cues[0].text == "a\n", "legacy single trailing newline retained")
check(try parse(srt("a\n\n")).cues[0].text == "a", "block separator not caption newline")
check(try parse(srt("<a\nb>visible")).cues[0].text == "visible", "tag can span caption lines")
check(try parse(srt("<>literal<unclosed")).cues[0].text == "<>literal<unclosed", "empty and unclosed tags remain literal")
for invalid in ["", "WEBVTT", "no timing", "00:00:03 --> 00:00:01\nbackward",
                "00:00:01 --> 00:00:01\nzero", "NaN:00 --> 00:05\nbad",
                "-1:00 --> 00:05\nbad", "1e308:00:00 --> 1e309:00:00\noverflow",
                "xx:00:00 --> 00:05\nbad"] {
  expectError("subtitle_timeline_invalid", "invalid timing rejected") { _ = try parse(invalid) }
}
let unsorted = try parse("00:03 --> 00:05\nlate\n\n00:01 --> 00:04\nearly")
check(unsorted.cues.map(\.text) == ["early", "late"], "cues sorted before indexing")
check(unsorted.text(at: 3.5) == "early" && unsorted.text(at: 4) == "late", "overlap keeps original first-active rule")
for size in [64 * 1024, ExternalSubtitleParser.maximumBytes] {
  let body = String(repeating: "<", count: size)
  let start = ProcessInfo.processInfo.systemUptime
  let cleaned = ExternalSubtitleParser.removingTags(body)
  let elapsed = ProcessInfo.processInfo.systemUptime - start
  check(cleaned.utf8.count == size, "large unmatched tag bytes preserved by linear cleaner")
  check(elapsed < 5, "linear cleaner completes without quadratic regex cost")
  print(String(format: "Tag cleaner only: %d unmatched bytes, %.3f seconds", body.utf8.count, elapsed))
}
for size in [49 * 1024, ExternalSubtitleParser.maximumCueBytes,
             ExternalSubtitleParser.maximumBytes - srt("").utf8.count] {
  expectError("subtitle_load_failed", "oversized visible or raw cue rejected") {
    _ = try parse(srt(String(repeating: "<", count: size)))
  }
}
let rawLimit = ExternalSubtitleParser.maximumCueBytes
let visibleLimit = ExternalSubtitleParser.maximumCaptionBytes
let rawBoundary = "<" + String(repeating: "a", count: rawLimit - 3) + ">x"
check(try parse(srt(rawBoundary)).cues[0].text == "x", "64KiB raw cue with short cleaned caption accepted")
expectError("subtitle_load_failed", "raw line one byte over limit") { _ = try parse(srt(rawBoundary + "x")) }
let multilineBoundary = "<" + String(repeating: "a", count: rawLimit / 2 - 2)
  + "\n" + String(repeating: "b", count: rawLimit / 2 - 2) + ">x"
check(multilineBoundary.utf8.count == rawLimit, "multiline raw fixture includes newline bytes")
check(try parse(srt(multilineBoundary)).cues[0].text == "x", "multiline raw exact limit accepted")
expectError("subtitle_load_failed", "multiline total raw one byte over limit") { _ = try parse(srt(multilineBoundary + "x")) }
expectError("subtitle_load_failed", "trailing caption newline counts toward raw limit") { _ = try parse(srt(rawBoundary + "\n")) }
let visibleBoundary = String(repeating: "🎬", count: visibleLimit / 4)
check(try parse(srt(visibleBoundary)).cues[0].text == visibleBoundary, "Unicode visible byte boundary accepted")
expectError("subtitle_load_failed", "visible caption one byte over limit") { _ = try parse(srt(visibleBoundary + "x")) }
let visibleMultiline = String(repeating: "x", count: visibleLimit / 2)
  + "\n" + String(repeating: "y", count: visibleLimit / 2 - 1)
check(try parse(srt(visibleMultiline)).cues[0].text == visibleMultiline, "multiline visible limit includes newline")
expectError("subtitle_load_failed", "visible multiline one byte over limit") { _ = try parse(srt(visibleMultiline + "x")) }
do {
  let fullBlock = srt(rawBoundary) + "\n\n"
  let count = ExternalSubtitleParser.maximumBytes / fullBlock.utf8.count
  let remaining = ExternalSubtitleParser.maximumBytes - count * fullBlock.utf8.count
  let tailSize = remaining - srt("").utf8.count
  check(tailSize > 3 && tailSize <= rawLimit, "10MiB fixture remainder fits cue limit")
  let tail = "<" + String(repeating: "a", count: tailSize - 3) + ">x"
  let body = String(repeating: fullBlock, count: count) + srt(tail)
  check(body.utf8.count == ExternalSubtitleParser.maximumBytes, "multi-cue file exactly 10MiB")
  let timeline = try parse(body)
  check(timeline.cues.count == count + 1 && timeline.cues.allSatisfy { $0.text == "x" },
        "10MiB total file accepted when every cue satisfies both limits")
}
let smallCue = "00:00 --> 00:01\nx\n\n"
let maximum = try parse(String(repeating: smallCue, count: ExternalSubtitleParser.maximumCues))
check(maximum.cues.count == ExternalSubtitleParser.maximumCues, "100,000 cues accepted")
expectError("subtitle_load_failed", "100,001 cues rejected") {
  _ = try parse(String(repeating: smallCue, count: ExternalSubtitleParser.maximumCues + 1))
}
expectError("subtitle_too_large", "byte limit enforced before parsing") {
  _ = try parse(String(repeating: "x", count: ExternalSubtitleParser.maximumBytes + 1))
}
for _ in 0..<120 {
  var cues: [SubtitleCue] = []
  for i in 0..<random.next(500) {
    let start = Double(random.next(500)) / 10
    cues.append(SubtitleCue(start: start, end: start + Double(random.next(500) + 1) / 10, text: "cue-\(i)"))
  }
  cues.sort { $0.start < $1.start }
  let timeline = SubtitleTimeline(cues)
  for _ in 0..<250 {
    let position = Double(random.next(1200) - 100) / 10
    let expected = cues.first { $0.start <= position && position < $0.end }?.text ?? ""
    check(timeline.text(at: position) == expected, "random indexed lookup equals linear first-match oracle")
  }
}
let work = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let file = work.appendingPathComponent("captions.srt")
try srt("从文件读取 🎬").write(to: file, atomically: true, encoding: .utf8)
let loaded = try ExternalSubtitleParser.read(file, request: SubtitleParseRequest())
check(loaded.cues[0].text == "从文件读取 🎬", "actual UTF-8 file read")
let cancelled = SubtitleParseRequest(); cancelled.cancel()
expectError("track_selection_stale", "cancelled parse rejected") { _ = try ExternalSubtitleParser.parse(srt("stale"), request: cancelled) }
expectError("track_selection_stale", "cancelled read rejected") { _ = try ExternalSubtitleParser.read(file, request: cancelled) }
try Data([0xff, 0xfe, 0xf8]).write(to: file)
expectError("subtitle_load_failed", "invalid UTF-8 rejected") { _ = try ExternalSubtitleParser.read(file, request: SubtitleParseRequest()) }
try Data(repeating: 60, count: ExternalSubtitleParser.maximumBytes + 1).write(to: file)
expectError("subtitle_too_large", "actual read cannot exceed byte cap") { _ = try ExternalSubtitleParser.read(file, request: SubtitleParseRequest()) }
try srt("small preflight").write(to: file, atomically: true, encoding: .utf8)
FileHandle.beforeRead = {
  let writer = try Foundation.FileHandle(forWritingTo: file)
  try writer.seekToEnd()
  try writer.write(contentsOf: Data(repeating: 60, count: ExternalSubtitleParser.maximumBytes))
  try writer.close()
}
expectError("subtitle_too_large", "actual read cap rejects growth after preflight") {
  _ = try ExternalSubtitleParser.read(file, request: SubtitleParseRequest())
}
try srt("expired").write(to: file, atomically: true, encoding: .utf8)
let expired = SubtitleParseRequest()
let delayed = work.appendingPathComponent("delayed.srt")
expectError("subtitle_load_failed", "FIFO rejected before opening") {
  _ = try ExternalSubtitleParser.read(delayed, request: SubtitleParseRequest())
}
expectError("subtitle_load_failed", "directory rejected before opening") {
  _ = try ExternalSubtitleParser.read(work, request: SubtitleParseRequest())
}
let slowRequest = SubtitleParseRequest()
FileHandle.beforeRead = { Thread.sleep(forTimeInterval: 5.1) }
expectError("subtitle_load_failed", "controlled read delay rejects expired result") {
  _ = try ExternalSubtitleParser.read(file, request: slowRequest)
}
expectError("subtitle_load_failed", "deadline checked before read") { _ = try ExternalSubtitleParser.read(file, request: expired) }
expectError("subtitle_load_failed", "deadline checked during parse") { _ = try ExternalSubtitleParser.parse(srt("expired"), request: expired) }
let cancelledRead = SubtitleParseRequest()
FileHandle.beforeRead = { cancelledRead.cancel() }
expectError("track_selection_stale", "controlled read cancellation rejects result") {
  _ = try ExternalSubtitleParser.read(file, request: cancelledRead)
}
print("Subtitle production parser/timeline: \(checks) assertions passed")
print("Scope: exact Foundation declarations, actual file I/O with controlled read-boundary hooks and deterministic oracles; UIKit/AVPlayer, file providers and device UI responsiveness not exercised.")
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swiftc', default='swiftc')
    parser.add_argument('--source', type=Path)
    parser.add_argument('--debug', action='store_true', help='Compile without optimization')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = (args.source or root / 'ios/Runner/PlaybackService.swift').read_text()
    declarations = '\n\n'.join(block(source, anchor) for anchor in (
        'struct SubtitleCue', 'final class SubtitleParseRequest',
        'struct SubtitleTimeline', 'enum ExternalSubtitleParser'))
    with tempfile.TemporaryDirectory(prefix='leeplayer-subtitle-review-') as folder:
        work = Path(folder)
        os.mkfifo(work / 'delayed.srt')
        (work / 'main.swift').write_text('import Foundation\nimport Dispatch\n' + declarations + '\n' + SCENARIOS)
        subprocess.run([args.swiftc, *([] if args.debug else ['-O']), '-module-cache-path', str(work / 'cache'),
                        str(work / 'main.swift'), '-o', str(work / 'review')], check=True)
        subprocess.run([str(work / 'review'), str(work)], check=True, timeout=45)


if __name__ == '__main__':
    main()
