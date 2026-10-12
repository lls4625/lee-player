import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:leeplayer/media_kit_measurements.dart';

Map<String, Object?> section(Map<String, Object?> snapshot, String key) =>
    snapshot[key] as Map<String, Object?>;

void main() {
  group('MediaKitPlaybackMeasurements', () {
    test('starts with bounded empty JSON-friendly observations', () {
      final measurements = MediaKitPlaybackMeasurements(sessionId: 'one');
      final snapshot = measurements.snapshot();

      expect(measurements.active, isTrue);
      expect(snapshot['version'], 1);
      expect(snapshot['sessionId'], 'one');
      expect(snapshot['scope'], 'foreground-playing-no-seek');
      expect(section(snapshot, 'refresh'), {
        'count': 0,
        'meanMs': 0.0,
        'maxMs': 0.0,
        'over250': 0,
        'current': 0,
        'peak': 0,
      });
      expect(section(snapshot, 'phases').keys, [
        'properties',
        'build',
        'bridge',
      ]);
      expect(snapshot['lastSeek'], isNull);
      expect(jsonDecode(jsonEncode(snapshot)), snapshot);
    });

    test('tracks overlapping refreshes and strictly over-250 ms samples', () {
      final measurements = MediaKitPlaybackMeasurements(sessionId: 'one');
      measurements.beginRefresh();
      measurements.beginRefresh();
      expect(section(measurements.snapshot(), 'refresh')['current'], 2);
      measurements.endRefresh(250000);
      expect(section(measurements.snapshot(), 'refresh')['current'], 1);
      measurements.endRefresh(350000);
      measurements.endRefresh(999999); // No matching begin.

      expect(section(measurements.snapshot(), 'refresh'), {
        'count': 2,
        'meanMs': 300.0,
        'maxMs': 350.0,
        'over250': 1,
        'current': 0,
        'peak': 2,
      });
    });

    test('ineligible refreshes balance overlap without timing samples', () {
      final measurements = MediaKitPlaybackMeasurements(sessionId: 'one');
      measurements.beginRefresh();
      measurements.beginRefresh();
      measurements.endRefresh(8000000, record: false);
      measurements.endRefresh(40000);

      expect(section(measurements.snapshot(), 'refresh'), {
        'count': 1,
        'meanMs': 40.0,
        'maxMs': 40.0,
        'over250': 0,
        'current': 0,
        'peak': 2,
      });
    });

    test('phase allowlist never grows and means use supplied elapsed time', () {
      final measurements = MediaKitPlaybackMeasurements(sessionId: 'one');
      measurements.recordPhase('properties', 100000);
      measurements.recordPhase('properties', 500000);
      measurements.recordPhase('build', 3000);
      measurements.recordPhase('bridge', 7000);
      for (var i = 0; i < 1000; i++) {
        measurements.recordPhase('unknown-$i', 999999);
      }

      final phases = section(measurements.snapshot(), 'phases');
      expect(phases.length, 3);
      expect(phases['properties'], {
        'count': 2,
        'meanMs': 300.0,
        'maxMs': 500.0,
        'over250': 1,
      });
      expect(section(phases, 'build')['meanMs'], 3.0);
      expect(section(phases, 'bridge')['meanMs'], 7.0);
    });

    test('heartbeat measures excess above 250 ms including busy skips', () {
      final measurements = MediaKitPlaybackMeasurements(sessionId: 'one');
      measurements.heartbeat(1000000, busy: false);
      measurements.heartbeat(1250000, busy: true);
      measurements.heartbeat(1700000, busy: true);
      measurements.heartbeat(1800000, busy: false);

      final heartbeat = section(measurements.snapshot(), 'heartbeat');
      expect(heartbeat['count'], 4);
      expect(heartbeat['busySkips'], 2);
      expect(heartbeat['gapCount'], 3);
      expect(heartbeat['meanGapExcessMs'], closeTo(200 / 3, 0.000001));
      expect(heartbeat['maxGapExcessMs'], 200.0);
    });

    test('heartbeat reset excludes paused or background gaps', () {
      final measurements = MediaKitPlaybackMeasurements(sessionId: 'one');
      measurements.heartbeat(0, busy: false);
      measurements.heartbeat(350000, busy: false);
      measurements.resetHeartbeat();
      measurements.heartbeat(60000000, busy: false);
      measurements.heartbeat(60250000, busy: false);

      expect(section(measurements.snapshot(), 'heartbeat'), {
        'count': 4,
        'busySkips': 0,
        'gapCount': 2,
        'meanGapExcessMs': 50.0,
        'maxGapExcessMs': 100.0,
      });
    });

    test('backwards heartbeat clock establishes a fresh baseline', () {
      final measurements = MediaKitPlaybackMeasurements(sessionId: 'one');
      measurements.heartbeat(1000000, busy: false);
      measurements.heartbeat(-1, busy: true);
      measurements.heartbeat(250000, busy: false);

      expect(section(measurements.snapshot(), 'heartbeat'), {
        'count': 3,
        'busySkips': 1,
        'gapCount': 1,
        'meanGapExcessMs': 0.0,
        'maxGapExcessMs': 0.0,
      });
    });

    test('receipt method and reason counters are fixed and independent', () {
      final measurements = MediaKitPlaybackMeasurements(sessionId: 'one');
      for (final method in ['play', 'pause']) {
        for (final reason in [
          'applied',
          'superseded',
          'stale',
          'timeout',
          'exception',
        ]) {
          measurements.recordReceipt(method, reason);
        }
      }
      measurements.recordReceipt('play', 'applied');
      for (var i = 0; i < 1000; i++) {
        measurements.recordReceipt('method-$i', 'applied');
        measurements.recordReceipt('play', 'reason-$i');
      }

      final receipts = section(measurements.snapshot(), 'receipts');
      expect(receipts.keys, ['play', 'pause']);
      expect(section(receipts, 'play'), {
        'applied': 2,
        'superseded': 1,
        'stale': 1,
        'timeout': 1,
        'exception': 1,
      });
      expect(section(receipts, 'pause').values, everyElement(1));
    });

    test('seek summary is copied, allowlisted, and replaces prior details', () {
      final measurements = MediaKitPlaybackMeasurements(sessionId: 'one');
      final input = <String, Object>{
        'requestId': 'request-1',
        'target': 12.5,
        'outcome': 'applied',
        'pauseMs': 1,
        'commandMs': 2,
        'confirmMs': 3,
        'refreshMs': 4,
        'totalMs': 10,
        'unknown': {'unbounded': List.filled(1000, 1)},
      };
      measurements.recordSeek(input);
      input['target'] = 999;
      final first = section(measurements.snapshot(), 'lastSeek');
      expect(first.length, 8);
      expect(first['target'], 12.5);
      expect(first.containsKey('unknown'), isFalse);

      measurements.recordSeek({'requestId': 'request-2', 'outcome': 'stale'});
      expect(section(measurements.snapshot(), 'lastSeek'), {
        'requestId': 'request-2',
        'outcome': 'stale',
      });
      expect(first['requestId'], 'request-1');
    });

    test('seek values are finite, clamped, and type checked', () {
      final measurements = MediaKitPlaybackMeasurements(sessionId: 's' * 1000);
      measurements.recordSeek({
        'requestId': 'r' * 1000,
        'outcome': 'o' * 1000,
        'target': 1e300,
        'pauseMs': -100,
        'commandMs': 1e300,
        'confirmMs': double.nan,
        'refreshMs': double.infinity,
        'totalMs': 'not a number',
      });

      final snapshot = measurements.snapshot();
      final seek = section(snapshot, 'lastSeek');
      expect((snapshot['sessionId'] as String).length, 160);
      expect((seek['requestId'] as String).length, 80);
      expect((seek['outcome'] as String).length, 40);
      expect(seek['target'], 9007199254740991.0);
      expect(seek['pauseMs'], 0.0);
      expect(seek['commandMs'], 86400000.0);
      expect(seek.containsKey('confirmMs'), isFalse);
      expect(seek.containsKey('refreshMs'), isFalse);
      expect(seek.containsKey('totalMs'), isFalse);
      expect(jsonDecode(jsonEncode(snapshot)), snapshot);

      measurements.recordSeek({
        'requestId': 12,
        'outcome': false,
        'target': double.negativeInfinity,
        'totalMs': Object(),
      });
      expect(section(measurements.snapshot(), 'lastSeek'), isEmpty);
    });

    test('elapsed durations clamp negatives and huge values', () {
      final measurements = MediaKitPlaybackMeasurements(sessionId: 'one');
      measurements.beginRefresh();
      measurements.endRefresh(-1);
      measurements.beginRefresh();
      measurements.endRefresh(0x7fffffffffffffff);
      measurements.recordPhase('build', -1);
      measurements.recordPhase('bridge', 0x7fffffffffffffff);
      measurements.heartbeat(0, busy: false);
      measurements.heartbeat(0x7fffffffffffffff, busy: false);

      final snapshot = measurements.snapshot();
      expect(section(snapshot, 'refresh')['meanMs'], 43200000.0);
      expect(section(snapshot, 'refresh')['maxMs'], 86400000.0);
      final phases = section(snapshot, 'phases');
      expect(section(phases, 'build')['maxMs'], 0.0);
      expect(section(phases, 'bridge')['maxMs'], 86400000.0);
      expect(section(snapshot, 'heartbeat')['maxGapExcessMs'], 86400000.0);
      expect(jsonDecode(jsonEncode(snapshot)), snapshot);
    });

    test('closed instances ignore every write and remain frozen', () {
      final measurements = MediaKitPlaybackMeasurements(sessionId: 'one');
      measurements.beginRefresh();
      measurements.heartbeat(1000000, busy: false);
      measurements.recordSeek({'requestId': 'before'});
      measurements.close();
      final frozen = measurements.snapshot();

      measurements.beginRefresh();
      measurements.endRefresh(9000000);
      measurements.endRefresh(9000000, record: false);
      measurements.recordPhase('properties', 9000000);
      measurements.heartbeat(9000000, busy: true);
      measurements.resetHeartbeat();
      measurements.recordReceipt('play', 'applied');
      measurements.recordSeek({'requestId': 'after'});
      measurements.close();

      expect(measurements.active, isFalse);
      expect(measurements.snapshot(), frozen);
    });

    test('late captured old session cannot pollute a replacement', () {
      var current = MediaKitPlaybackMeasurements(sessionId: 'old');
      final captured = current;
      captured.beginRefresh();
      captured.close();
      current = MediaKitPlaybackMeasurements(sessionId: 'new');
      current.beginRefresh();
      current.endRefresh(1000);
      current.heartbeat(50000000, busy: false);
      captured.endRefresh(7000000);
      captured.recordReceipt('pause', 'applied');
      captured.recordSeek({'requestId': 'old-seek'});
      captured.heartbeat(90000000, busy: true);

      final snapshot = current.snapshot();
      expect(snapshot['sessionId'], 'new');
      expect(section(snapshot, 'refresh')['count'], 1);
      expect(section(snapshot, 'refresh')['meanMs'], 1.0);
      expect(section(snapshot, 'heartbeat')['count'], 1);
      expect(section(snapshot, 'heartbeat')['gapCount'], 0);
      expect(snapshot['lastSeek'], isNull);
      expect(
        section(section(snapshot, 'receipts'), 'pause').values,
        everyElement(0),
      );
      expect(section(captured.snapshot(), 'refresh')['count'], 0);
    });

    test('returned nested maps cannot mutate measurements', () {
      final measurements = MediaKitPlaybackMeasurements(sessionId: 'one');
      measurements.recordSeek({'requestId': 'one'});
      final snapshot = measurements.snapshot();
      final expected = measurements.snapshot();
      section(snapshot, 'refresh')['count'] = 99;
      section(section(snapshot, 'phases'), 'properties')['count'] = 99;
      section(section(snapshot, 'receipts'), 'play')['applied'] = 99;
      section(snapshot, 'lastSeek')['requestId'] = 'mutated';
      section(snapshot, 'heartbeat')['count'] = 99;

      expect(measurements.snapshot(), expected);
    });

    test('many samples retain fixed-size summaries and no histories', () {
      final measurements = MediaKitPlaybackMeasurements(sessionId: 'one');
      for (var i = 0; i < 10000; i++) {
        measurements.beginRefresh();
        measurements.endRefresh(i);
        measurements.recordPhase('properties', i);
        measurements.heartbeat(i * 250000, busy: i.isEven);
        measurements.recordReceipt('play', 'applied');
        measurements.recordSeek({'requestId': '$i', 'target': i});
      }

      final snapshot = measurements.snapshot();
      expect(snapshot.length, 9);
      expect(section(snapshot, 'refresh').length, 6);
      expect(section(snapshot, 'phases').length, 3);
      expect(section(snapshot, 'heartbeat').length, 5);
      expect(section(snapshot, 'receipts').length, 2);
      expect(section(snapshot, 'lastSeek'), {
        'requestId': '9999',
        'target': 9999.0,
      });
      expect(section(snapshot, 'refresh')['count'], 10000);
      expect(section(snapshot, 'refresh')['meanMs'], closeTo(4.9995, 0.000001));
      expect(jsonEncode(snapshot).length, lessThan(1500));
    });

    test('recording and snapshotting schedule no timers or microtasks', () {
      runZoned(
        () {
          final measurements = MediaKitPlaybackMeasurements(sessionId: 'one');
          measurements.beginRefresh();
          measurements.endRefresh(1000);
          measurements.recordPhase('properties', 1000);
          measurements.heartbeat(1000, busy: false);
          measurements.heartbeat(251000, busy: true);
          measurements.resetHeartbeat();
          measurements.recordReceipt('play', 'applied');
          measurements.recordSeek({'requestId': 'one'});
          measurements.snapshot();
          measurements.close();
          measurements.snapshot();
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) =>
              throw StateError('Unexpected timer'),
          createPeriodicTimer: (self, parent, zone, duration, callback) =>
              throw StateError('Unexpected periodic timer'),
          scheduleMicrotask: (self, parent, zone, callback) =>
              throw StateError('Unexpected microtask'),
        ),
      );
    });
  });
}
