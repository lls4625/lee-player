import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leeplayer/playback_page.dart';

void main() {
  test('rotation targets follow the orientation currently on screen', () {
    expect(
      playbackOrientationTargets(Orientation.portrait),
      const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
    );
    expect(
      playbackOrientationTargets(Orientation.landscape),
      const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown],
    );
  });

  test('leaving playback restores every supported app orientation', () {
    expect(
      playbackExitOrientations,
      const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ],
    );
  });
}
