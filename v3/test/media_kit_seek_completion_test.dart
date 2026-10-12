import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/src/player/native/core/native_library.dart';
import 'package:media_kit/src/player/native/player/real.dart';
import 'package:media_kit/src/player/platform_player.dart';

/// Executes the real vendored NativePlayer against a receipt/EOF-only C ABI.
/// This measures submitted targets and Dart state, not decoded-frame accuracy,
/// hardware behavior, keyframe landing, seek performance, or iOS playback.
void main() {
  late Directory temporary;
  late void Function(Pointer<Void>, int) holdSeek;
  late void Function(Pointer<Void>, int) releaseSeek;
  late int Function(Pointer<Void>) lastSeekId, seekCount, commandCount;
  late int Function(Pointer<Void>) pauseValue, pauseSets, hasCallback;
  late Pointer<Utf8> Function(Pointer<Void>, int, int) argument;
  late void Function(Pointer<Void>) emitEof;
  final players = <NativePlayer>[];

  Future<void> waitUntil(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Expected NativePlayer event or command was not observed');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<NativePlayer> createPlayer() async {
    final player = NativePlayer(
      configuration: const PlayerConfiguration(async: true),
    );
    players.add(player);
    await player.future!.timeout(const Duration(seconds: 2));
    // The fake has no decoder/idle state machine. Initialization is complete.
    player.completer.complete();
    return player;
  }

  List<List<String>> commands(NativePlayer player) {
    final ctx = player.ctx.cast<Void>();
    return [
      for (var i = 0; i < commandCount(ctx); i++)
        [for (var j = 0; j < 3; j++) argument(ctx, i, j).toDartString()],
    ];
  }

  Future<void> completeAtEof(NativePlayer player) async {
    await player.play();
    emitEof(player.ctx.cast());
    await waitUntil(() => player.state.completed);
    expect(player.state.playing, isFalse);
  }

  setUpAll(() {
    temporary = Directory.systemTemp.createTempSync('leeplayer-seek-ffi-');
    final extension = Platform.isMacOS ? 'dylib' : 'so';
    final path = '${temporary.path}/fake_mpv_seek.$extension';
    final compile = Process.runSync('cc', [
      if (Platform.isMacOS) '-dynamiclib' else '-shared',
      '-fPIC',
      '-std=c11',
      '-Wall',
      '-Wextra',
      '-Werror',
      'tool/ffi/fake_mpv_seek.c',
      '-o',
      path,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    final lib = DynamicLibrary.open(path);
    NativeLibrary.ensureInitialized(libmpv: path);
    holdSeek = lib
        .lookupFunction<
          Void Function(Pointer<Void>, Int32),
          void Function(Pointer<Void>, int)
        >('fake_seek_hold');
    releaseSeek = lib
        .lookupFunction<
          Void Function(Pointer<Void>, Uint64),
          void Function(Pointer<Void>, int)
        >('fake_seek_release');
    lastSeekId = lib
        .lookupFunction<
          Uint64 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('fake_seek_last_id');
    seekCount = lib
        .lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('fake_seek_count');
    commandCount = lib
        .lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('fake_command_count');
    pauseValue = lib
        .lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('fake_pause_value');
    pauseSets = lib
        .lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('fake_pause_sets');
    hasCallback = lib
        .lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('fake_has_callback');
    argument = lib
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>, Int32, Int32),
          Pointer<Utf8> Function(Pointer<Void>, int, int)
        >('fake_command_argument');
    emitEof = lib
        .lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('fake_seek_eof');
  });

  tearDown(() async {
    for (final player in players) {
      if (!player.disposed) {
        holdSeek(player.ctx.cast(), 0);
        await player.dispose().timeout(const Duration(seconds: 2));
      }
    }
    players.clear();
  });
  tearDownAll(() => temporary.deleteSync(recursive: true));

  test('control reproduces raw seek retaining completed and play rewinding to zero', () async {
    final player = await createPlayer();
    await completeAtEof(player);
    await player.command(['seek', '35.000000', 'absolute+exact']);
    expect(player.state.completed, isTrue);
    await player.play();
    final seeks = commands(player).where((c) => c.first == 'seek').toList();
    expect(seeks, [
      ['seek', '35.000000', 'absolute+exact'],
      ['seek', '0.0000', 'absolute'],
    ]);
  });

  test('official seek clears completed and subsequent play does not rewind to zero', () async {
    final player = await createPlayer();
    await completeAtEof(player);
    final events = <bool>[];
    final subscription = player.stream.completed.listen(events.add);
    addTearDown(subscription.cancel);
    await player.seek(const Duration(seconds: 35), synchronized: false);
    expect(player.state.completed, isFalse);
    await player.play();
    await Future<void>.delayed(Duration.zero);
    expect(events, contains(false));
    expect(player.state.playing, isTrue);
    expect(commands(player).where((c) => c.first == 'seek').toList(), [
      ['seek', '35.0000', 'absolute'],
    ]);
  });

  for (final microseconds in [35123987, 10870999000, 10871000000, 123456]) {
    test(
      'absolute target $microseconds microseconds is quantized below one millisecond',
      () async {
        final player = await createPlayer();
        await player.seek(
          Duration(microseconds: microseconds),
          synchronized: false,
        );
        final seek = commands(player).singleWhere((c) => c.first == 'seek');
        final submitted = double.parse(seek[1]);
        expect(seek[2], 'absolute');
        expect((submitted - microseconds / 1000000).abs(), lessThan(0.001));
        expect(submitted, microseconds ~/ 1000 / 1000);
      },
    );
  }

  test('repeated A-B style absolute seeks keep targets and never add an EOF rewind', () async {
    final player = await createPlayer();
    final targets = [12345, 45678, 12345, 45678, 12345];
    for (final target in targets) {
      await completeAtEof(player);
      await player.seek(Duration(milliseconds: target), synchronized: false);
      await player.play();
      expect(player.state.completed, isFalse);
    }
    final seeks = commands(player).where((c) => c.first == 'seek').toList();
    expect(seeks.length, targets.length);
    expect(
      seeks.map((c) => double.parse(c[1])).toList(),
      targets.map((target) => target / 1000).toList(),
    );
  });

  test('lock control proves default synchronized seek holds pause until its receipt', () async {
    final player = await createPlayer();
    await player.play();
    final ctx = player.ctx.cast<Void>();
    holdSeek(ctx, 1);
    final seek = player.seek(const Duration(seconds: 35));
    await waitUntil(() => seekCount(ctx) == 1);
    final id = lastSeekId(ctx);
    var paused = false;
    final pause = player.pause()..then((_) => paused = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(paused, isFalse);
    expect(player.state.playing, isTrue);
    releaseSeek(ctx, id);
    await Future.wait([seek, pause]).timeout(const Duration(seconds: 1));
    expect(paused, isTrue);
    expect(player.state.playing, isFalse);
  });

  test('delayed unsynchronized seek receipt does not block priority pause or resume later', () async {
    final player = await createPlayer();
    await completeAtEof(player);
    final ctx = player.ctx.cast<Void>();
    holdSeek(ctx, 1);
    var settled = false;
    final seek = player.seek(const Duration(seconds: 35), synchronized: false)
      ..then((_) => settled = true);
    await waitUntil(() => seekCount(ctx) == 1);
    final id = lastSeekId(ctx);
    final before = pauseSets(ctx);
    await player.pause().timeout(const Duration(seconds: 1));
    expect(settled, isFalse);
    expect(pauseSets(ctx), greaterThan(before));
    expect(pauseValue(ctx), 1);
    expect(player.state.playing, isFalse);
    releaseSeek(ctx, id);
    await seek.timeout(const Duration(seconds: 1));
    expect(player.state.playing, isFalse);
    expect(pauseValue(ctx), 1);
    expect(seekCount(ctx), 1);
  });

  test('delayed unsynchronized seek receipt does not block stop or restart after it', () async {
    final player = await createPlayer();
    await player.play();
    final ctx = player.ctx.cast<Void>();
    holdSeek(ctx, 1);
    var settled = false;
    final seek = player.seek(const Duration(seconds: 35), synchronized: false)
      ..then((_) => settled = true);
    await waitUntil(() => seekCount(ctx) == 1);
    final id = lastSeekId(ctx);
    await player.stop().timeout(const Duration(seconds: 1));
    expect(settled, isFalse);
    expect(player.state.playing, isFalse);
    expect(
      commands(player).map((c) => c.first),
      containsAllInOrder([
        'seek',
        'stop',
        'playlist-clear',
        'playlist-play-index',
      ]),
    );
    releaseSeek(ctx, id);
    await seek.timeout(const Duration(seconds: 1));
    expect(player.state.playing, isFalse);
    expect(player.state.position, Duration.zero);
    expect(seekCount(ctx), 1);
  });

  test('dispose bypasses delayed seek and its detached late receipt cannot touch successor', () async {
    final player = await createPlayer();
    final ctx = player.ctx.cast<Void>();
    holdSeek(ctx, 1);
    var settled = false;
    // Upstream does not cancel pending command futures on dispose. Do not await
    // this old future: the assertion is detached-pump isolation and fast close.
    unawaited(
      player
          .seek(const Duration(seconds: 35), synchronized: false)
          .then((_) => settled = true),
    );
    await waitUntil(() => seekCount(ctx) == 1);
    final id = lastSeekId(ctx);
    await player.dispose().timeout(const Duration(seconds: 1));
    expect(player.disposed, isTrue);
    expect(settled, isFalse);
    expect(hasCallback(ctx), 0);
    final successor = await createPlayer();
    expect(successor.ctx.address, isNot(player.ctx.address));
    await completeAtEof(successor);
    releaseSeek(ctx, id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(settled, isFalse);
    expect(successor.state.completed, isTrue);
    expect(successor.state.playing, isFalse);
    expect(seekCount(successor.ctx.cast()), 0);
  });
}
