import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leeplayer/player_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MediaEntry', () {
    test('parses native metadata and identifies playable media', () {
      final entry = MediaEntry(<String, Object>{
        'path': '课程/第02课.MP4',
        'name': '第02课.MP4',
        'parent': '课程',
        'kind': 'video',
        'size': 2048,
        'modified': 123.5,
      });

      expect(entry.isPlayable, isTrue);
      expect(entry.isVideo, isTrue);
      expect(entry.extension, 'mp4');
      expect(entry.size, 2048);
    });
  });

  group('display helpers', () {
    test('formats playback positions at minute and hour boundaries', () {
      expect(timeLabel(0), '00:00');
      expect(timeLabel(65.9), '01:05');
      expect(timeLabel(3661), '1:01:01');
      expect(timeLabel(double.infinity), '00:00');
    });

    test('formats media sizes with binary units', () {
      expect(sizeLabel(1024), '1 KB');
      expect(sizeLabel(1572864), '1.5 MB');
      expect(sizeLabel(1610612736), '1.5 GB');
    });
  });

  group('naturalCompare', () {
    test('sorts numbered lessons in human order', () {
      final names = <String>['第10课.mp4', '第2课.mp4', '第1课.mp4'];
      names.sort(naturalCompare);
      expect(names, <String>['第1课.mp4', '第2课.mp4', '第10课.mp4']);
    });

    test('handles integers larger than the platform integer range', () {
      expect(
        naturalCompare(
          'lesson99999999999999999999',
          'lesson100000000000000000000',
        ),
        lessThan(0),
      );
    });
  });

  group('PlayerModel platform commands', () {
    const methods = MethodChannel('lei.player/methods');

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methods, null);
    });

    test('new file selection does not wait for a pending PiP command', () async {
      final pip = Completer<Object?>();
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(methods, (call) async {
        if (call.method == 'pip') return pip.future;
        if (call.method == 'open') return {
          'path': 'next.mp4', 'generation': 2, 'loading': true,
          'playing': false, 'error': '',
        };
        return null;
      });
      final model = PlayerModel()..state = {
        'path': 'broken.mp4', 'generation': 1, 'error': 'media_playback_failed',
      };
      addTearDown(model.dispose);
      final requesting = model.command('pip');
      expect(await model.openPaths(['next.mp4'], 0), isTrue);
      expect(pip.isCompleted, isFalse);
      expect(model.path, 'next.mp4');
      // Accepted selection is not proof that cleanup/opening/decoding finished.
      expect(model.loading, isTrue);
      expect(model.playing, isFalse);
      expect(model.state['error'], isEmpty);
      pip.complete(null);
      expect(await requesting, isTrue);
    });

    test('latest selected file wins over an earlier delayed open failure state', () async {
      final earlier = Completer<Object?>();
      var opens = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methods, (call) async {
        if (call.method != 'open') return null;
        if (++opens == 1) return earlier.future;
        return {'path': 'next.mp4', 'generation': 2, 'error': '', 'playing': true};
      });
      final model = PlayerModel();
      addTearDown(model.dispose);
      final first = model.openPaths(['broken.mp4'], 0);
      expect(await model.openPaths(['next.mp4'], 0), isTrue);
      earlier.complete({'path': 'broken.mp4', 'generation': 1,
        'error': 'media_playback_failed', 'playing': false});
      expect(await first, isFalse);
      expect(model.path, 'next.mp4');
      expect(model.playing, isTrue);
      expect(model.state['error'], isEmpty);
    });

    test('a declined PiP transaction does not replace media state with a prompt', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methods, (_) async => false);
      final model = PlayerModel()..state = {
        'path': 'test.mp4', 'generation': 1, 'playing': true, 'error': '',
      };
      addTearDown(model.dispose);
      await model.command('pip');
      expect(model.message, isNull);
      expect(model.playing, isTrue);
      expect(model.state['error'], isEmpty);
    });

    test('terminal and unrecognized playback failures remain visible state', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methods, (_) async {
        throw PlatformException(code: 'media_playback_failed');
      });
      final model = PlayerModel()..state = {
        'path': 'test.mp4', 'error': 'media_playback_failed', 'playing': false,
      };
      addTearDown(model.dispose);
      expect(await model.command('open'), isFalse);
      expect(model.message?.code, 'media_playback_failed');
      expect(model.playbackIssue?.code, 'media_playback_failed');
      expect(model.playing, isFalse);
      model.state = {'error': 'new_unrecognized_failure'};
      expect(model.playbackIssue?.code, 'new_unrecognized_failure');
    });

    for (final loading in [false, true]) {
      test('${loading ? 'loading' : 'pending automatic recovery'} keeps a cancel action', () async {
        final calls = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methods, (call) async {
          calls.add(call.method);
          return {'generation': 1, 'playing': false, 'loading': false,
            'wantsPlayback': false, 'audioRecovery': 'idle'};
        });
        final model = PlayerModel()..state = {
          'generation': 1, 'playing': false, 'loading': loading,
          // A loading button still cancels even if native intent has changed.
          'wantsPlayback': !loading, 'audioRecovery': loading ? 'idle' : 'pending',
        };
        addTearDown(model.dispose);
        expect(model.transportShowsPause, isTrue);
        expect(await model.toggle(), isTrue);
        expect(calls, ['pause']);
        expect(model.transportShowsPause, isFalse);
      });
    }

    for (final wantsPlayback in [false, true]) {
      test('presentation wait cancels with pause when native intent is $wantsPlayback', () async {
        final calls = <String>[];
        final model = PlayerModel()..state = {
          'generation': 1, 'revision': 1, 'presentationWaiting': true,
          'playing': false, 'loading': false, 'wantsPlayback': wantsPlayback,
        };
        addTearDown(model.dispose);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methods, (call) async {
          calls.add(call.method);
          return {...model.state, 'revision': calls.length + 1,
            'playing': false, 'wantsPlayback': false};
        });
        for (var tap = 0; tap < 3; tap++) {
          expect(model.transportShowsPause, isTrue);
          expect(await model.toggle(), isTrue);
        }
        expect(calls, ['pause', 'pause', 'pause']);
        expect(model.state['wantsPlayback'], isFalse);
        // A later native ownership release does not create a new Play intent.
        model.state = {...model.state, 'presentationWaiting': false};
        expect(model.transportShowsPause, isFalse);
        expect(calls.where((call) => call == 'play'), isEmpty);
      });
    }

    for (final lateFailure in [false, true]) {
      test('waiting cancellation bypasses pending play and rejects its late ${lateFailure ? 'error' : 'state'}', () async {
        final playReply = Completer<Object?>();
        final calls = <String>[];
        final model = PlayerModel()..state = {
          'generation': 1, 'revision': 1, 'path': 'current.mp4',
          'playing': false, 'wantsPlayback': false,
        };
        addTearDown(model.dispose);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methods, (call) async {
          calls.add(call.method);
          if (call.method == 'play') return playReply.future;
          return {...model.state, 'revision': 3,
            'playing': false, 'wantsPlayback': false};
        });
        final oldPlay = model.toggle();
        await Future<void>.delayed(Duration.zero);
        model.state = {...model.state, 'revision': 2,
          'presentationWaiting': true, 'wantsPlayback': true};
        final cancel = model.toggle();
        await Future<void>.delayed(Duration.zero);
        // Pause must be sent while the old Play reply is still unresolved.
        expect(calls, ['play', 'pause']);
        expect(await cancel, isTrue);
        expect(playReply.isCompleted, isFalse);
        if (lateFailure) {
          playReply.completeError(PlatformException(code: 'media_playback_failed'));
        } else {
          playReply.complete({'generation': 1, 'revision': 99,
            'path': 'current.mp4', 'presentationWaiting': false,
            'playing': true, 'wantsPlayback': true});
        }
        expect(await oldPlay, isFalse);
        expect(model.state['revision'], 3);
        expect(model.presentationWaiting, isTrue);
        expect(model.playing, isFalse);
        expect(model.state['wantsPlayback'], isFalse);
        expect(model.message, isNull);
      });
    }

    test('waiting cancellation makes a pending play timeout stale', () async {
      final playReply = Completer<Object?>();
      final model = PlayerModel(commandTimeouts: {
        'play': const Duration(milliseconds: 30),
      })..state = {'generation': 1, 'revision': 1,
        'playing': false, 'wantsPlayback': false};
      addTearDown(model.dispose);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methods, (call) async {
        if (call.method == 'play') return playReply.future;
        return {...model.state, 'revision': 3,
          'playing': false, 'wantsPlayback': false};
      });
      final oldPlay = model.toggle();
      model.state = {...model.state, 'presentationWaiting': true};
      expect(await model.toggle(), isTrue);
      expect(await oldPlay, isFalse);
      expect(model.message, isNull);
      expect(model.state['wantsPlayback'], isFalse);
      playReply.complete(null);
    });

    test('late wait-cancellation reply cannot roll back a newer session', () async {
      final pauseReply = Completer<Object?>();
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methods, (call) async {
        calls.add(call.method);
        if (call.method == 'pause') return pauseReply.future;
        return {'generation': 2, 'revision': 1, 'path': 'new.mkv',
          'playing': true, 'wantsPlayback': true, 'presentationWaiting': false};
      });
      final model = PlayerModel()..state = {
        'generation': 1, 'revision': 1, 'path': 'old.mp4',
        'presentationWaiting': true, 'playing': false, 'wantsPlayback': true,
      };
      addTearDown(model.dispose);
      final cancelled = model.toggle();
      expect(await model.openPaths(['new.mkv'], 0), isTrue);
      pauseReply.complete({'generation': 1, 'revision': 99, 'path': 'old.mp4',
        'presentationWaiting': true, 'playing': false, 'wantsPlayback': false});
      await cancelled;
      expect(calls, ['pause', 'open']);
      expect(model.path, 'new.mkv');
      expect(model.state['generation'], 2);
      expect(model.state['revision'], 1);
      expect(model.playing, isTrue);
      expect(model.presentationWaiting, isFalse);
    });

    for (final taps in [2, 3]) {
      test('$taps rapid toggles preserve the latest requested intent', () async {
        final firstReply = Completer<Object?>();
        final calls = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methods, (call) async {
          calls.add(call.method);
          if (calls.length == 1) return firstReply.future;
          return {'generation': 1, 'playing': call.method == 'play',
            'wantsPlayback': call.method == 'play', 'loading': false};
        });
        final model = PlayerModel()..state = {
          'generation': 1, 'playing': false, 'loading': false, 'wantsPlayback': false,
        };
        addTearDown(model.dispose);
        final pending = [for (var i = 0; i < taps; i++) model.toggle()];
        expect(model.transportShowsPause, taps.isOdd);
        firstReply.complete({'generation': 1, 'playing': true,
          'wantsPlayback': true, 'loading': false});
        expect(await Future.wait(pending), everyElement(isTrue));
        expect(calls, taps.isEven ? ['play', 'pause'] : ['play']);
        expect(model.playing, taps.isOdd);
        expect(model.transportShowsPause, taps.isOdd);
      });
    }

    test('an old pending toggle cannot control the newly selected session', () async {
      final oldReply = Completer<Object?>();
      var calls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methods, (call) async {
        if (++calls == 1) return oldReply.future;
        return {'generation': 2, 'path': 'new.mp4', 'playing': true,
          'wantsPlayback': true, 'loading': false};
      });
      final model = PlayerModel()..state = {
        'generation': 1, 'path': 'old.mp4', 'playing': false, 'wantsPlayback': false,
      };
      addTearDown(model.dispose);
      final old = model.toggle();
      model.state = {'generation': 2, 'path': 'new.mp4', 'playing': false,
        'wantsPlayback': false, 'loading': false};
      expect(model.transportShowsPause, isFalse);
      expect(await model.toggle(), isTrue);
      oldReply.complete({'generation': 1, 'path': 'old.mp4', 'playing': true});
      expect(await old, isFalse);
      expect(calls, 2);
      expect(model.path, 'new.mp4');
      expect(model.transportShowsPause, isTrue);
    });

    test(
      'sends the natural-order queue and selected index when opening',
      () async {
        MethodCall? received;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methods, (call) async {
              received = call;
              return null;
            });
        final first = MediaEntry(<String, Object>{
          'path': '课程/第1课.mp4',
          'name': '第1课.mp4',
          'parent': '课程',
          'kind': 'video',
          'size': 1,
          'modified': 1.0,
        });
        final second = MediaEntry(<String, Object>{
          'path': '课程/第2课.mp4',
          'name': '第2课.mp4',
          'parent': '课程',
          'kind': 'video',
          'size': 1,
          'modified': 1.0,
        });

        final accepted = await PlayerModel().open(<MediaEntry>[
          first,
          second,
        ], second);

        expect(accepted, isTrue);
        expect(received?.method, 'open');
        expect(received?.arguments, <String, Object>{
          'paths': <String>['课程/第1课.mp4', '课程/第2课.mp4'],
          'index': 1,
          'resume': true,
        });
      },
    );

    test(
      'only reports a seek as complete when native code confirms it',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methods, (call) async => false);

        expect(await PlayerModel().seek(42), isFalse);
      },
    );

    test(
      'scan timeout releases busy state and ignores a late result',
      () async {
        final scan = Completer<Object?>();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methods, (call) async {
              if (call.method == 'scan') return scan.future;
              if (call.method == 'records') return <String, Object>{};
              return null;
            });
        final model = PlayerModel(
          commandTimeouts: {'scan': const Duration(milliseconds: 10)},
        );
        addTearDown(model.dispose);

        final refreshing = model.refresh();
        await Future<void>.delayed(Duration.zero);
        expect(model.scanning, isTrue);
        expect(await refreshing, isFalse);
        expect(model.scanning, isFalse);
        expect(model.message?.code, 'operation_timeout');

        scan.complete(<Object>[
          <String, Object>{
            'path': '迟到.mp4',
            'name': '迟到.mp4',
            'parent': '',
            'kind': 'video',
            'size': 1,
            'modified': 1.0,
          },
        ]);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(model.entries, isEmpty);
      },
    );

    test(
      'refresh during a scan is coalesced into one supplemental scan',
      () async {
        final scans = <Completer<Object?>>[];
        var scanCalls = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methods, (call) async {
              if (call.method == 'scan') {
                scanCalls++;
                final completer = Completer<Object?>();
                scans.add(completer);
                return completer.future;
              }
              if (call.method == 'records') return <String, Object>{};
              return null;
            });
        final model = PlayerModel();
        addTearDown(model.dispose);

        final first = model.refresh();
        await Future<void>.delayed(Duration.zero);
        final second = model.refresh();
        expect(scanCalls, 1);
        scans.first.complete(<Object>[]);
        while (scanCalls < 2) {
          await Future<void>.delayed(Duration.zero);
        }
        scans[1].complete(<Object>[]);

        expect(await first, isTrue);
        expect(await second, isTrue);
        expect(scanCalls, 2);
        expect(model.scanning, isFalse);
      },
    );

    test(
      'a picker wait is not cut off by ordinary command deadlines',
      () async {
        final picker = Completer<Object?>();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methods, (call) async {
              return switch (call.method) {
                'import' => picker.future,
                'scan' => <Object>[],
                'records' => <String, Object>{},
                _ => null,
              };
            });
        final model = PlayerModel(
          commandTimeouts: {'import': const Duration(milliseconds: 5)},
        );
        addTearDown(model.dispose);

        final importing = model.importMedia(folder: false, parent: '');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(model.importing, isTrue);
        picker.complete(0);
        await importing;
        expect(model.importing, isFalse);
      },
    );

    test(
      'a reply arriving after dispose cannot notify or mutate state',
      () async {
        final reply = Completer<Object?>();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methods, (_) async => reply.future);
        final model = PlayerModel();
        var notifications = 0;
        model.addListener(() => notifications++);

        final pending = model.command(
          'state',
          onValue: (value) {
            model.state = Map<String, dynamic>.from(value as Map);
          },
        );
        model.dispose();
        reply.complete(<String, Object>{'path': '不应写入'});

        expect(await pending, isFalse);
        expect(notifications, 0);
        expect(model.state, isEmpty);
      },
    );
  });
}
