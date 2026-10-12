import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'package:media_kit/src/player/native/core/native_library.dart';
import 'package:media_kit/src/player/native/player/real.dart';
import 'package:media_kit/src/player/platform_player.dart';
import 'package:media_kit/src/player/native/utils/async_property_requests.dart';
import 'package:leeplayer/media_kit_recovery.dart';

void main() {
  late Directory temporary;
  late generated.MPV mpv;
  late String libraryPath;
  late void Function() wake;
  late int Function() syncGets;
  late void Function() reset;
  late void Function(int) submissionError;
  late int Function() submissions, frees, lastFormat, lastId;
  late Pointer<Utf8> Function() lastName;
  late void Function(int, Pointer<Utf8>, int, int, int) prepareReply;
  late AsyncPropertyRequests reader;
  var nextId = 1000;
  final ctx = Pointer<generated.mpv_handle>.fromAddress(1);

  void reply(
    int id,
    String text, {
    int error = 0,
    int format = 1,
    int nullMode = 0,
  }) {
    final bytes = text.toNativeUtf8();
    try {
      prepareReply(id, bytes, error, format, nullMode);
    } finally {
      calloc.free(bytes);
    }
    expect(reader.handleEvent(mpv.mpv_wait_event(ctx, 0)), isTrue);
  }

  setUpAll(() {
    temporary = Directory.systemTemp.createTempSync('leeplayer-property-ffi-');
    final extension = Platform.isMacOS ? 'dylib' : 'so';
    final library = '${temporary.path}/fake_mpv.$extension';
    libraryPath = library;
    final compile = Process.runSync('cc', [
      if (Platform.isMacOS) '-dynamiclib' else '-shared',
      '-fPIC',
      '-std=c11',
      '-Wall',
      '-Wextra',
      '-Werror',
      'tool/ffi/fake_mpv_property.c',
      '-o',
      library,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    final dylib = DynamicLibrary.open(library);
    mpv = generated.MPV(dylib);
    wake = dylib.lookupFunction<Void Function(), void Function()>('fake_wake');
    syncGets = dylib.lookupFunction<Int32 Function(), int Function()>(
      'fake_sync_gets',
    );
    reset = dylib.lookupFunction<Void Function(), void Function()>(
      'fake_reset',
    );
    submissionError = dylib
        .lookupFunction<Void Function(Int32), void Function(int)>(
          'fake_submit_error',
        );
    submissions = dylib.lookupFunction<Int32 Function(), int Function()>(
      'fake_submissions',
    );
    frees = dylib.lookupFunction<Int32 Function(), int Function()>(
      'fake_frees',
    );
    lastFormat = dylib.lookupFunction<Int32 Function(), int Function()>(
      'fake_last_format',
    );
    lastId = dylib.lookupFunction<Uint64 Function(), int Function()>(
      'fake_last_id',
    );
    lastName = dylib
        .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
          'fake_last_name',
        );
    prepareReply = dylib
        .lookupFunction<
          Void Function(Uint64, Pointer<Utf8>, Int32, Int32, Int32),
          void Function(int, Pointer<Utf8>, int, int, int)
        >('fake_reply');
  });

  tearDownAll(() => temporary.deleteSync(recursive: true));
  setUp(() {
    reset();
    nextId = 1000;
    reader = AsyncPropertyRequests(
      mpv: mpv,
      handle: () => ctx,
      nextRequestId: () => nextId++,
    );
  });

  test('FFI submits STRING asynchronously and copies borrowed char** before next event', () async {
    var completed = false;
    final future = reader.read('hwdec-current')..then((_) => completed = true);
    final id = lastId();
    expect(submissions(), 1);
    expect(lastFormat(), generated.mpv_format.MPV_FORMAT_STRING);
    expect(lastName().toDartString(), 'hwdec-current');
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    reply(id, 'videotoolbox · 中文');
    // Invalidate the C payload before the Future continuation runs.
    mpv.mpv_wait_event(ctx, 0);
    expect(await future, 'videotoolbox · 中文');
    expect(reader.pendingCount, 0);
    expect(frees(), 0);
  });

  test('out-of-order replies use independent IDs and never substitute a stale read', () async {
    final beforeSeek = reader.read('time-pos');
    final beforeId = lastId();
    nextId++; // Shared allocator also services commands and sets.
    final afterSeek = reader.read('time-pos', controlRead: true);
    final afterId = lastId();
    expect(afterId, beforeId + 2);
    reply(afterId, '200.0');
    expect(await afterSeek, '200.0');
    expect(reader.pendingCount, 1);
    reply(beforeId, '100.0');
    expect(await beforeSeek, '100.0');
    expect(reader.pendingCount, 0);
  });

  test(
    'null native handle is rejected before allocation or FFI submission',
    () async {
      reader = AsyncPropertyRequests(
        mpv: mpv,
        handle: () => nullptr,
        nextRequestId: () => nextId++,
      );
      await expectLater(reader.read('duration'), throwsStateError);
      expect(submissions(), 0);
      expect(reader.pendingCount, 0);
      expect(nextId, 1000);
    },
  );

  test(
    'immediate submission failure releases slot without an orphan error Future',
    () async {
      submissionError(-1);
      await expectLater(
        reader.read('duration'),
        throwsA(
          isA<MpvPropertyReadException>()
              .having((e) => e.errorCode, 'error', -1)
              .having((e) => e.submission, 'submission', true),
        ),
      );
      expect(reader.pendingCount, 0);
      submissionError(0);
      final future = reader.read('duration');
      reply(lastId(), '10');
      expect(await future, '10');
    },
  );

  for (final code in [-8, -9, -10, -11]) {
    test(
      'native reply error $code is preserved and invalid payload is not dereferenced',
      () async {
        final future = reader.read('hwdec-current');
        final assertion = expectLater(
          future,
          throwsA(
            isA<MpvPropertyReadException>()
                .having((e) => e.errorCode, 'code', code)
                .having((e) => e.submission, 'submission', false),
          ),
        );
        reply(lastId(), '', error: code, format: 0, nullMode: 1);
        await assertion;
        expect(reader.pendingCount, 0);
        expect(frees(), 0);
      },
    );
  }

  for (final nullMode in [1, 2, 3]) {
    test('successful malformed null payload $nullMode fails safely', () async {
      final future = reader.read('duration');
      final assertion = expectLater(future, throwsFormatException);
      reply(lastId(), '', nullMode: nullMode);
      await assertion;
      expect(reader.pendingCount, 0);
    });
  }

  test('unexpected payload format fails safely', () async {
    final future = reader.read('duration');
    final assertion = expectLater(future, throwsFormatException);
    reply(lastId(), '3', format: generated.mpv_format.MPV_FORMAT_NONE);
    await assertion;
    expect(reader.pendingCount, 0);
  });

  test('caller timeout retains native slot until late reply', () async {
    final future = reader.read('duration');
    final id = lastId();
    await expectLater(
      future.timeout(const Duration(milliseconds: 1)),
      throwsA(isA<TimeoutException>()),
    );
    expect(reader.pendingCount, 1);
    reply(id, '30');
    expect(reader.pendingCount, 0);
    expect(await future, '30');
    reply(id, 'duplicate');
    expect(reader.pendingCount, 0);
  });

  test(
    '56 diagnostic requests cannot consume eight reserved control slots',
    () async {
      final ordinary = <Future<String>>[];
      final ids = <int>[];
      for (var n = 0; n < 56; n++) {
        ordinary.add(reader.read('diagnostic-$n'));
        ids.add(lastId());
      }
      await expectLater(
        reader.read('one-too-many'),
        throwsA(isA<MpvPropertyReadBusy>()),
      );
      expect(submissions(), 56);
      final control = <Future<String>>[];
      for (var n = 0; n < 8; n++) {
        control.add(
          reader.read(n.isEven ? 'seeking' : 'time-pos', controlRead: true),
        );
        ids.add(lastId());
      }
      expect(reader.pendingCount, 64);
      expect(reader.controlPendingCount, 8);
      await expectLater(
        reader.read('seeking', controlRead: true),
        throwsA(isA<MpvPropertyReadBusy>()),
      );
      expect(submissions(), 64);
      for (final id in ids) {
        reply(id, 'ok');
      }
      expect(await Future.wait([...ordinary, ...control]), everyElement('ok'));
      expect(reader.pendingCount, 0);
    },
  );

  test(
    'control saturation remains bounded and does not consume diagnostic budget',
    () async {
      final waiting = <Future<String>>[];
      final ids = <int>[];
      for (var n = 0; n < 8; n++) {
        waiting.add(reader.read('seeking', controlRead: true));
        ids.add(lastId());
      }
      await expectLater(
        reader.read('seeking', controlRead: true),
        throwsA(isA<MpvPropertyReadBusy>()),
      );
      waiting.add(reader.read('mpv-version'));
      ids.add(lastId());
      expect(submissions(), 9);
      for (final id in ids) {
        reply(id, 'ok');
      }
      await Future.wait(waiting);
    },
  );

  test('timed-out native requests still count toward the hard limit', () async {
    reader = AsyncPropertyRequests(
      mpv: mpv,
      handle: () => ctx,
      nextRequestId: () => nextId++,
      maxPending: 4,
      reservedControl: 1,
    );
    final futures = [for (var n = 0; n < 3; n++) reader.read('duration')];
    for (final future in futures) {
      await expectLater(
        future.timeout(const Duration(milliseconds: 1)),
        throwsA(isA<TimeoutException>()),
      );
    }
    expect(reader.pendingCount, 3);
    await expectLater(
      reader.read('duration'),
      throwsA(isA<MpvPropertyReadBusy>()),
    );
    final control = reader.read('seeking', controlRead: true);
    final assertions = [
      for (final future in [...futures, control])
        expectLater(future, throwsStateError),
    ];
    reader.close();
    await Future.wait(assertions);
    expect(reader.pendingCount, 0);
  });

  test('dispose closes pending once, rejects future reads, and ignores late replies', () async {
    final future = reader.read('time-pos', controlRead: true);
    final id = lastId();
    final assertion = expectLater(future, throwsStateError);
    reader.close();
    reader.close();
    await assertion;
    expect(reader.pendingCount, 0);
    expect(reader.controlPendingCount, 0);
    await expectLater(reader.read('duration'), throwsStateError);
    expect(submissions(), 1);
    reply(id, '10');
    expect(reader.pendingCount, 0);
    expect(frees(), 0);
  });

  test(
    'other events and null pointers are not consumed by the GET handler',
    () {
      expect(reader.handleEvent(nullptr), isFalse);
      expect(reader.handleEvent(mpv.mpv_wait_event(ctx, 0)), isFalse);
    },
  );

  test('real NativePlayer handles GET reply through its sole pump before initialization gate', () async {
    NativeLibrary.ensureInitialized(libmpv: libraryPath);
    final player = NativePlayer(
      configuration: const PlayerConfiguration(async: false),
    );
    await player.future;
    expect(player.completer.isCompleted, isFalse);
    final future = player.getPropertyAsync(
      'hwdec-current',
      waitForInitialization: false,
    );
    final bytes = 'videotoolbox'.toNativeUtf8();
    try {
      prepareReply(lastId(), bytes, 0, 1, 0);
    } finally {
      calloc.free(bytes);
    }
    wake();
    expect(await future.timeout(const Duration(seconds: 1)), 'videotoolbox');
    expect(syncGets(), 0);
    expect(frees(), 0);
    // The old public getter remains exactly the synchronous API.
    expect(
      await player.getProperty('duration', waitForInitialization: false),
      'legacy-sync',
    );
    expect(syncGets(), 1);
    player.completer.complete();
    await player.dispose();
  });

  test(
    'real NativePlayer rechecks disposal after player initialization await',
    () async {
      NativeLibrary.ensureInitialized(libmpv: libraryPath);
      final player = NativePlayer(
        configuration: const PlayerConfiguration(async: false),
      );
      await player.future;
      final read = player.getPropertyAsync('duration');
      final assertion = expectLater(read, throwsStateError);
      final disposal = player.dispose();
      await expectLater(
        player.getPropertyAsync('duration', waitForInitialization: false),
        throwsStateError,
      );
      expect(submissions(), 0);
      player.completer.complete();
      await assertion;
      await disposal;
      expect(submissions(), 0);
    },
  );

  test('real NativePlayer rejects reads waiting on video initialization during disposal', () async {
    NativeLibrary.ensureInitialized(libmpv: libraryPath);
    final player = NativePlayer(
      configuration: const PlayerConfiguration(async: false),
    );
    await player.future;
    player.completer.complete();
    player.isVideoControllerAttached = true;
    final read = player.getPropertyAsync('duration');
    final assertion = expectLater(read, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    final disposal = player.dispose();
    player.videoControllerCompleter.complete();
    await assertion;
    await disposal;
    expect(submissions(), 0);
  });

  test('real NativePlayer disposal terminates pending read without freeing borrowed event memory', () async {
    NativeLibrary.ensureInitialized(libmpv: libraryPath);
    final player = NativePlayer(
      configuration: const PlayerConfiguration(async: false),
    );
    await player.future;
    player.completer.complete();
    final read = player.getPropertyAsync('time-pos', controlRead: true);
    final assertion = expectLater(read, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    expect(submissions(), 1);
    await player.dispose();
    await assertion;
    expect(frees(), 0);
  });

  test('existing app property wrapper keeps unsupported and full-budget reads unknown/error', () async {
    for (final error in [
      const MpvPropertyReadException('x', -8),
      const MpvPropertyReadBusy(false),
    ]) {
      final result = await MediaKitPropertyRead.read(() async => throw error);
      expect(result.status, MediaKitPropertyStatus.error);
      expect(result.value, isNull);
    }
    final unavailable = await MediaKitPropertyRead.read(() async => '');
    expect(unavailable.status, MediaKitPropertyStatus.unavailable);
    expect(unavailable.value, isNull);
  });

  test('integration gates preserve one event consumer, disposal checks and seek-only reserve', () {
    final source = File(
      'third_party/media_kit/lib/src/player/native/player/real.dart',
    ).readAsStringSync();
    final handler = source.substring(source.indexOf('Future<void> _handler('));
    expect(
      handler.indexOf('_asyncPropertyRequests.handleEvent(event)'),
      lessThan(handler.indexOf('if (!completer.isCompleted)')),
    );
    final dispose = source.substring(
      source.indexOf('Future<void> dispose('),
      source.indexOf('/// Opens a [Media]'),
    );
    expect(
      dispose.indexOf('_asyncPropertyDisposing = true'),
      lessThan(dispose.indexOf('Future<void> function()')),
    );
    final read = source.substring(
      source.indexOf('Future<String> getPropertyAsync('),
      source.indexOf('/// Observes property'),
    );
    expect('disposed || _asyncPropertyDisposing'.allMatches(read).length, 2);
    expect(
      read,
      contains('await waitForVideoControllerInitializationIfAttached'),
    );
    expect(read, isNot(contains('mpv_wait_event')));
    final app = File('lib/media_kit_playback.dart').readAsStringSync();
    final seek = app.substring(app.indexOf('Future<bool> _seek('),
        app.indexOf('void _scheduleLatestPlayIntent('));
    final repair = app.substring(app.indexOf('void _scheduleLatestSeekIntent('),
        app.indexOf('Future<void> _heartbeat('));
    for (final positioningPath in [seek, repair]) {
      expect('controlRead: true'.allMatches(positioningPath).length, 2);
      expect("_property(native, 'seeking', controlRead: true)".allMatches(positioningPath).length, 1);
      expect("_property(native, 'time-pos', controlRead: true)".allMatches(positioningPath).length, 1);
    }
    expect('controlRead: true'.allMatches(app).length, 4,
        reason: 'only primary and late-repair seek confirmation use the reserve');
    expect(app, isNot(contains('.observeProperty(')));
    // The app catches only actual UNAVAILABLE (-10), not unsupported/busy.
    expect(
      app,
      contains("if (!error.submission && error.errorCode == -10) return '';"),
    );
  });
}
