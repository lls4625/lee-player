#!/usr/bin/env python3
"""Run the production Swift gate declarations on hosts without AVKit/Xcode.

This verifies the real gates, not PlaybackService/AVPlayer integration. The
service XCTest suite and iOS device regression remain separate checks.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile


def declaration(source: str, name: str) -> str:
    start = source.index(f"struct {name} {{")
    begin = source.index("{", start)
    depth = 0
    for index in range(begin, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[start:index + 1]
    raise ValueError(f"Unterminated declaration: {name}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swiftc", default="swiftc")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = (root / "ios/Runner/PlaybackService.swift").read_text()
    gates = "\n\n".join(declaration(source, name) for name in
                        ("PlaybackEndGate", "PlaybackSnapshotGate"))
    checks = (root / "tool/replay_gate_review.swift").read_text()
    with tempfile.TemporaryDirectory(prefix="leeplayer-replay-review-") as work:
        work = Path(work)
        main = work / "main.swift"
        binary = work / "review"
        main.write_text("import Foundation\n\n" + gates + "\n\n" + checks)
        subprocess.run([args.swiftc, "-module-cache-path", str(work / "cache"),
                        str(main), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
