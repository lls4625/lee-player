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
