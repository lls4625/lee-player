import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leeplayer/app_localizations.dart';
import 'package:leeplayer/media_kit_measurements.dart';

void main() {
  Map<String, dynamic> info(MediaKitPlaybackMeasurements timing) => {
    'engine': 'media_kit / libmpv',
    'decoderCode': 'automatic_hardware_decode',
    'playbackTiming': {...timing.snapshot(), 'buildMode': 'profile'},
    'nativePlaybackTiming': {
      'tickCount': 2,
      'gapCount': 1,
      'maxGapExcessMs': 23.5,
      'audioActivateCount': 2,
      'audioDeactivateCount': 1,
      'audioLastReason': 'activate:media-open',
    },
  };

  test(
    'four locales export four bounded timing lines and label their limits',
    () {
      final timing = MediaKitPlaybackMeasurements(sessionId: 'test-session');
      timing.beginRefresh();
      timing.endRefresh(300000);
      timing.recordPhase('properties', 275000);
      timing.recordPhase('build', 5000);
      timing.recordPhase('bridge', 20000);
      timing.heartbeat(0, busy: false);
      timing.heartbeat(350000, busy: true);
      timing.recordReceipt('pause', 'superseded');
      timing.recordSeek({
        'requestId': 'seek-test',
        'target': 2184.724,
        'outcome': 'confirmed',
        'pauseMs': 2.0,
        'commandMs': 3.0,
        'confirmMs': 500.0,
        'refreshMs': 10.0,
        'totalMs': 515.0,
      });
      for (final locale in AppLocalizations.supportedLocales) {
        final strings = AppLocalizations(locale);
        final data = info(timing);
        final measured = strings.playbackInfo(data);
        final baseline = strings.playbackInfo(
          {...data}..remove('playbackTiming'),
        );
        expect(measured.split('\n').length - baseline.split('\n').length, 4);
        expect(measured, contains('profile'));
        expect(measured, contains('FFI'));
        expect(measured, contains('300.0/300.0 (n=1)'));
        expect(measured, contains('275.0/275.0 (n=1)'));
        expect(measured, contains('100.0 (n=1'));
        expect(measured, contains('23.5 (n=1)'));
        expect(measured, contains('2/1 activate:media-open'));
        expect(measured, contains('2.0/3.0/500.0/10.0/515.0'));
        expect(measured, contains('id=seek-test'));
        expect(measured, contains('pause=1/0/0/0'));
        expect(measured, isNot(contains('Instance of')));
      }
    },
  );

  test('no completed samples and no actual gap never imply measured zero', () {
    final timing = MediaKitPlaybackMeasurements(sessionId: 'no-samples');
    timing.heartbeat(0, busy: false);
    timing.resetHeartbeat();
    timing.heartbeat(8000000, busy: false);
    final data = info(timing);
    data['nativePlaybackTiming'] = {
      'tickCount': 2,
      'gapCount': 0,
      'maxGapExcessMs': 0,
    };
    final expected = ['尚无样本', '尚無樣本', 'サンプルなし', 'no samples'];
    for (
      var index = 0;
      index < AppLocalizations.supportedLocales.length;
      index++
    ) {
      final locale = AppLocalizations.supportedLocales[index];
      final text = AppLocalizations(locale).playbackInfo(data);
      // Select by language rather than assuming the supported locale order.
      expect(expected.any((label) => text.contains(label)), isTrue);
      expect(text, isNot(contains('0.0/0.0 (n=0)')));
      expect(text, isNot(contains('Dart 0.0')));
      expect(text, isNot(contains('Native 0.0')));
    }
  });

  test('missing failed-seek phases are displayed as unknown, not zero', () {
    final timing = MediaKitPlaybackMeasurements(sessionId: 'failed');
    timing.recordSeek({
      'requestId': 'failed-pause',
      'target': 2.0,
      'outcome': 'exception',
      'pauseMs': 250.0,
      'totalMs': 250.0,
    });
    final text = AppLocalizations(const Locale('en'))
        .playbackInfo(info(timing));
    expect(text, contains('250.0/Unknown/Unknown/Unknown/250.0'));
    expect(text, contains('exception'));
  });
}
