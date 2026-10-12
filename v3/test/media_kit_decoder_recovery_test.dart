import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:leeplayer/media_kit_recovery.dart';

void evidence(MediaKitDecoderRecoveryMonitor monitor, int at) {
  monitor.record(
    'ffmpeg/video/h264',
    'Failed to decode frame (invalid session, -12903)',
    at,
  );
  monitor.record(
    'vd',
    'Attempting next decoding method after failure of h264-videotoolbox.',
    at,
  );
  monitor.record(
    'vd',
    'Attempting next decoding method after failure of h264-videotoolbox-copy.',
    at,
  );
}

void underruns(MediaKitDecoderRecoveryMonitor monitor, int at) {
  for (var i = 0; i < 5; i++) {
    monitor.record('cplayer', 'Audio device underrun detected.', at + i * 300);
  }
}

void main() {
  group('property diagnostics', () {
    test(
      'no is a value, empty is unavailable, errors and timeouts differ',
      () async {
        final software = await MediaKitPropertyRead.read(() async => 'no');
        expect(software.status, MediaKitPropertyStatus.value);
        expect(software.value, 'no');
        expect(
          (await MediaKitPropertyRead.read(() async => '')).status,
          MediaKitPropertyStatus.unavailable,
        );
        expect(
          (await MediaKitPropertyRead.read(
            () async => throw StateError('read'),
          )).status,
          MediaKitPropertyStatus.error,
        );
        expect(
          (await MediaKitPropertyRead.read(
            () => Completer<String>().future,
            timeout: Duration.zero,
          )).status,
          MediaKitPropertyStatus.timeout,
        );
      },
    );
  });

  group('VT symptom monitor', () {
    test('exact field sequence survives user seek and waits after it', () {
      final monitor = MediaKitDecoderRecoveryMonitor();
      monitor.evaluate(190000, eligible: true);
      evidence(monitor, 190500);
      monitor.suspend(); // user seek at 194.4; do not lose decoder evidence
      monitor.evaluate(194800, eligible: true);
      underruns(monitor, 195300);
      expect(
        monitor.evaluate(196500, eligible: true),
        MediaKitDecoderAction.none,
      );
      underruns(monitor, 197800);
      expect(
        monitor.evaluate(199000, eligible: true),
        MediaKitDecoderAction.requestRepair,
      );
      expect(
        monitor.evaluate(199100, eligible: true),
        MediaKitDecoderAction.none,
      );
    });

    test(
      'generic errors or underruns without both VT methods never trigger',
      () {
        final monitor = MediaKitDecoderRecoveryMonitor();
        monitor.evaluate(0, eligible: true);
        monitor.record(
          'ffmpeg/video/h264',
          'hardware accelerator failed to decode picture',
          0,
        );
        underruns(monitor, 5000);
        expect(
          monitor.evaluate(6200, eligible: true),
          MediaKitDecoderAction.none,
        );
        monitor.record(
          'ffmpeg/video/h264',
          'Failed to decode frame (invalid session, -12903)',
          6200,
        );
        underruns(monitor, 11000);
        expect(
          monitor.evaluate(12200, eligible: true),
          MediaKitDecoderAction.none,
        );
      },
    );

    test('single burst and recovered fallback do not trigger', () {
      final monitor = MediaKitDecoderRecoveryMonitor();
      monitor.evaluate(0, eligible: true);
      evidence(monitor, 0);
      underruns(monitor, 200);
      expect(
        monitor.evaluate(2000, eligible: true),
        MediaKitDecoderAction.none,
      );
      expect(
        monitor.evaluate(5000, eligible: true),
        MediaKitDecoderAction.none,
      );
    });

    test('repeated VT logs cannot perpetually extend the fallback grace', () {
      final monitor = MediaKitDecoderRecoveryMonitor();
      monitor.evaluate(0, eligible: true);
      evidence(monitor, 0);
      evidence(monitor, 4500);
      underruns(monitor, 5000);
      expect(
        monitor.evaluate(6200, eligible: true),
        MediaKitDecoderAction.requestRepair,
      );
    });

    test('pause, seek, PiP, background and buffering gates require fresh observation', () {
      final monitor = MediaKitDecoderRecoveryMonitor();
      monitor.evaluate(0, eligible: true);
      evidence(monitor, 0);
      underruns(monitor, 5000);
      expect(
        monitor.evaluate(6200, eligible: false),
        MediaKitDecoderAction.none,
      );
      expect(
        monitor.evaluate(7000, eligible: true),
        MediaKitDecoderAction.none,
      );
      underruns(monitor, 8000);
      expect(
        monitor.evaluate(9200, eligible: true),
        MediaKitDecoderAction.none,
      );
    });

    test('expired VT evidence cannot accuse a later unrelated underrun', () {
      final monitor = MediaKitDecoderRecoveryMonitor();
      monitor.evaluate(0, eligible: true);
      evidence(monitor, 0);
      underruns(monitor, 31000);
      expect(
        monitor.evaluate(32200, eligible: true),
        MediaKitDecoderAction.none,
      );
    });

    test('continued symptoms after one repair stop instead of looping', () {
      final monitor = MediaKitDecoderRecoveryMonitor();
      monitor.evaluate(0, eligible: true);
      evidence(monitor, 0);
      underruns(monitor, 5000);
      expect(
        monitor.evaluate(6200, eligible: true),
        MediaKitDecoderAction.requestRepair,
      );
      monitor.beginRepair(6300);
      underruns(monitor, 11000);
      expect(
        monitor.evaluate(12200, eligible: true),
        MediaKitDecoderAction.stop,
      );
      underruns(monitor, 13000);
      expect(
        monitor.evaluate(14200, eligible: true),
        MediaKitDecoderAction.none,
      );
    });

    test('new monitor has no evidence from previous engine', () {
      final old = MediaKitDecoderRecoveryMonitor();
      evidence(old, 0);
      final current = MediaKitDecoderRecoveryMonitor();
      current.evaluate(0, eligible: true);
      underruns(current, 5000);
      expect(
        current.evaluate(6200, eligible: true),
        MediaKitDecoderAction.none,
      );
    });
  });

  group('official same-player decoder reinitialization', () {
    Future<MediaKitDecoderRepairResult> repair({
      required List<String> calls,
      bool Function()? sameSession,
      bool Function()? samePosition,
      bool Function()? wantsPlayback,
      Future<void> Function(String)? write,
      Future<void> Function()? pause,
      Future<void> Function()? seek,
      Future<void> Function()? play,
      Duration timeout = const Duration(seconds: 1),
    }) => reinitializeMediaKitDecoder(
      hardwarePolicy: 'auto-safe',
      sameSession: sameSession ?? () => true,
      samePositionIntent: samePosition ?? () => true,
      wantsPlayback: wantsPlayback ?? () => true,
      pause:
          pause ??
          () async {
            calls.add('pause');
          },
      writeHardwarePolicy:
          write ??
          (value) async {
            calls.add('hwdec=$value');
          },
      restorePosition:
          seek ??
          () async {
            calls.add('seek-latest-position');
          },
      resume:
          play ??
          () async {
            calls.add('play');
          },
      stepTimeout: timeout,
    );

    test('only decoder policy and position/playback are touched', () async {
      final calls = <String>[];
      expect(await repair(calls: calls), MediaKitDecoderRepairResult.restored);
      expect(calls, [
        'pause',
        'hwdec=no',
        'hwdec=auto-safe',
        'seek-latest-position',
        'play',
      ]);
    });

    test('priority pause between no and restore never resumes', () async {
      final calls = <String>[];
      var playing = true;
      await repair(
        calls: calls,
        wantsPlayback: () => playing,
        write: (value) async {
          calls.add('hwdec=$value');
          if (value == 'no') playing = false;
        },
      );
      expect(calls, [
        'pause',
        'hwdec=no',
        'hwdec=auto-safe',
        'seek-latest-position',
      ]);
    });

    test(
      'new seek restores policy but skips stale positioning and play',
      () async {
        final calls = <String>[];
        var samePosition = true;
        expect(
          await repair(
            calls: calls,
            samePosition: () => samePosition,
            write: (value) async {
              calls.add('hwdec=$value');
              if (value == 'no') samePosition = false;
            },
          ),
          MediaKitDecoderRepairResult.superseded,
        );
        expect(calls, ['pause', 'hwdec=no', 'hwdec=auto-safe']);
      },
    );

    test('new seek wins even if the old disable readback throws', () async {
      final calls = <String>[];
      var samePosition = true;
      expect(
        await repair(
          calls: calls,
          samePosition: () => samePosition,
          write: (value) async {
            calls.add('hwdec=$value');
            if (value == 'no') {
              samePosition = false;
              throw StateError('late readback failure');
            }
          },
        ),
        MediaKitDecoderRepairResult.superseded,
      );
      expect(calls, ['pause', 'hwdec=no', 'hwdec=auto-safe']);
    });

    test('pause then play supersedes an old recovery readback failure', () async {
      final calls = <String>[];
      var intentVersion = 1;
      const captured = 1;
      expect(await repair(calls: calls,
          samePosition: () => intentVersion == captured,
          write: (value) async {
            calls.add('hwdec=$value');
            if (value == 'no') {
              intentVersion += 2;
              throw StateError('old readback failed after pause and play');
            }
          }), MediaKitDecoderRepairResult.superseded);
      expect(calls, ['pause', 'hwdec=no', 'hwdec=auto-safe']);
    });

    test('new media prevents all old-session continuation', () async {
      final calls = <String>[];
      var sameSession = true;
      expect(
        await repair(
          calls: calls,
          sameSession: () => sameSession,
          write: (value) async {
            calls.add('hwdec=$value');
            if (value == 'no') sameSession = false;
          },
        ),
        MediaKitDecoderRepairResult.superseded,
      );
      expect(calls, ['pause', 'hwdec=no']);
    });

    test(
      'failed disable readback still restores original policy and stops',
      () async {
        final calls = <String>[];
        await expectLater(
          repair(
            calls: calls,
            write: (value) async {
              calls.add('hwdec=$value');
              if (value == 'no') throw StateError('readback mismatch');
            },
          ),
          throwsStateError,
        );
        expect(calls, ['pause', 'hwdec=no', 'hwdec=auto-safe']);
      },
    );

    test(
      'disable readback timeout still restores original policy once',
      () async {
        final calls = <String>[];
        await expectLater(
          repair(
            calls: calls,
            timeout: Duration.zero,
            write: (value) {
              calls.add('hwdec=$value');
              return value == 'no' ? Completer<void>().future : Future.value();
            },
          ),
          throwsA(isA<TimeoutException>()),
        );
        expect(calls, ['pause', 'hwdec=no', 'hwdec=auto-safe']);
      },
    );

    test('failed policy restoration never seeks or resumes', () async {
      final calls = <String>[];
      await expectLater(
        repair(
          calls: calls,
          write: (value) async {
            calls.add('hwdec=$value');
            if (value == 'auto-safe') throw StateError('restore denied');
          },
        ),
        throwsStateError,
      );
      expect(calls, ['pause', 'hwdec=no', 'hwdec=auto-safe']);
    });

    test('seek failure does not resume and retains hardware policy', () async {
      final calls = <String>[];
      await expectLater(
        repair(
          calls: calls,
          seek: () async {
            calls.add('seek-failed');
            throw StateError('seek');
          },
        ),
        throwsStateError,
      );
      expect(calls, ['pause', 'hwdec=no', 'hwdec=auto-safe', 'seek-failed']);
    });

    test('pause before reset does not alter decoder', () async {
      final calls = <String>[];
      expect(
        await repair(calls: calls, wantsPlayback: () => false),
        MediaKitDecoderRepairResult.superseded,
      );
      expect(calls, isEmpty);
    });
  });
}
