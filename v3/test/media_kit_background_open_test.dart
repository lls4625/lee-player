import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:leeplayer/media_kit_playback.dart';
import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/media_kit.dart';

// Production Dart bridge + actual NativePlayer/VideoController + a C ABI
// receipt fixture. These verify lifecycle gating and transport, not decoding,
// physical audio, GPU rendering, AVKit or iOS background execution entitlement.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const bridge = MethodChannel('lei.player/media_kit');
  const video = MethodChannel('com.alexmercerind/media_kit_video');
  const codec = StandardMethodCodec();
  late Directory temporary;
  late int Function() created;
  late Pointer<Void> Function() lastContext;
  late int Function(Pointer<Void>) pauseValue, commandCount;
  late int Function(Pointer<Void>) videoSelected, earlyVideoEnables;
  late void Function(Pointer<Void>, int) renderReady;
  var delayRenderReady = false;
  var restoreDimensions = false;
  var rejectRestoreCreate = false;
  var backgroundAfterRestoreCreate = false;
  var failPiPReadyInBackground = false;
  late Pointer<Utf8> Function(Pointer<Void>, int, int) argument;
  late Pointer<Utf8> Function(Pointer<Void>) videoTrack;
  late MediaKitPlayback playback;
  final states = <Map<dynamic, dynamic>>[];
  final nativeCalls = <String>[];
  final outputs = <int>[];
  var nextTexture = 10;

  Future<dynamic> incoming(
    MethodChannel channel,
    String method, [
    Map<String, dynamic>? args,
  ]) {
    final result = Completer<dynamic>();
    binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall(method, args)),
      (reply) {
        try {
          result.complete(reply == null ? null : codec.decodeEnvelope(reply));
        } catch (error, stack) {
          result.completeError(error, stack);
        }
      },
    );
    return result.future.timeout(const Duration(seconds: 3));
  }

  Future<dynamic> open(String id, {bool audio = false}) =>
      incoming(bridge, 'open', {
        'engineId': id,
        'positionVersion': 0,
        'url': 'file:///fixture/$id.mkv',
        'isAudio': audio,
        'rate': 1.25,
        'volume': 0.6,
      });

  Future<void> acknowledgeRenderContext(int handle) async {
    renderReady(Pointer<Void>.fromAddress(handle), 1);
    await incoming(video, 'VideoOutput.Resize', {
      'handle': handle, 'id': nextTexture++,
      'rect': {'left': 0, 'top': 0, 'width': restoreDimensions ? 640 : 0, 'height': restoreDimensions ? 360 : 0},
    });
  }

  List<String> commands(Pointer<Void> ctx) => [
    for (var i = 0; i < commandCount(ctx); i++)
      argument(ctx, i, 0).toDartString(),
  ];

  Future<void> waitFor(bool Function() ready) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!ready()) {
      if (DateTime.now().isAfter(deadline))
        fail('Expected event did not arrive');
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  setUpAll(() {
    temporary = Directory.systemTemp.createTempSync(
      'leeplayer-background-ffi-',
    );
    final path =
        '${temporary.path}/fake_mpv.${Platform.isMacOS ? 'dylib' : 'so'}';
    final compile = Process.runSync('cc', [
      if (Platform.isMacOS) '-dynamiclib' else '-shared',
      '-fPIC',
      '-std=c11',
      '-Wall',
      '-Wextra',
      '-Werror',
      'tool/ffi/fake_mpv_background.c',
      '-o',
      path,
    ]);
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    final lib = DynamicLibrary.open(path);
    // media_kit's debug cache stores raw addresses keyed by pid. Keep this
    // suite's initialization in a fresh directory even when executors reuse pid.
    IOOverrides.runZoned(
      () => MediaKit.ensureInitialized(libmpv: path),
      getSystemTempDirectory: () => temporary,
    );
    created = lib.lookupFunction<Int32 Function(), int Function()>(
      'fake_created_count',
    );
    lastContext = lib
        .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
          'fake_last_context',
        );
    pauseValue = lib
        .lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('fake_pause_value');
    commandCount = lib
        .lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('fake_command_count');
    argument = lib
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>, Int32, Int32),
          Pointer<Utf8> Function(Pointer<Void>, int, int)
        >('fake_command_argument');
    renderReady = lib.lookupFunction<Void Function(Pointer<Void>, Int32), void Function(Pointer<Void>, int)>('fake_render_context_ready');
    videoSelected = lib.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('fake_video_selected');
    earlyVideoEnables = lib.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('fake_early_video_enables');
    videoTrack = lib
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>),
          Pointer<Utf8> Function(Pointer<Void>)
        >('fake_video_track');
  });
  tearDownAll(() {
    temporary.deleteSync(recursive: true);
  });

  setUp(() {
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    states.clear();
    nativeCalls.clear();
    outputs.clear();
    delayRenderReady = false;
    restoreDimensions = false;
    rejectRestoreCreate = false;
    backgroundAfterRestoreCreate = false;
    failPiPReadyInBackground = false;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(bridge, (
      call,
    ) async {
      nativeCalls.add(call.method);
      if (call.method == 'pipReady') {
        if (failPiPReadyInBackground) {
          binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
          return false;
        }
        renderReady(Pointer<Void>.fromAddress((call.arguments as Map)['handle'] as int), 1);
      }
      if (call.method == 'state')
        states.add(Map<dynamic, dynamic>.from(call.arguments as Map));
      return true;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(video, (
      call,
    ) async {
      nativeCalls.add(call.method);
      if (call.method == 'VideoOutputManager.Create') {
        final restoring = (call.arguments as Map)['requireForeground'] == true;
        if (restoring && rejectRestoreCreate) {
          binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
          throw PlatformException(code: 'video_output_background');
        }
        final handle = int.parse((call.arguments as Map)['handle'] as String);
        outputs.add(handle);
        if (!delayRenderReady) await acknowledgeRenderContext(handle);
        if (restoring && backgroundAfterRestoreCreate) {
          binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        }
      }
      if (call.method == 'VideoOutputManager.Dispose') {
        final handle = int.parse((call.arguments as Map)['handle'] as String);
        renderReady(Pointer<Void>.fromAddress(handle), 0);
      }
      return null;
    });
    playback = MediaKitPlayback();
  });

  Future<void> frame(WidgetTester tester) async {
    // Run the real plugin continuations in the same real-async zone as FFI.
    // No frame is driven while testing the paused/locked open path.
    await tester.runAsync(() async {
      binding.handleBeginFrame(null);
      binding.handleDrawFrame();
      await Future<void>.delayed(Duration.zero);
    });
  }

  Future<void> cleanup(WidgetTester tester) async {
    await tester.runAsync(() async {
      expect(await incoming(bridge, 'release'), isTrue);
      playback.dispose();
      await Future<void>.delayed(Duration.zero);
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(bridge, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(video, null);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await frame(tester);
  }

  testWidgets(
    'paused video opens, plays and releases without a Flutter frame',
    (tester) async {
      await tester.runAsync(() async {
        expect(binding.lifecycleState, AppLifecycleState.paused);
        final before = created();
        expect(await open('background-next'), isTrue);
        expect(created(), before + 1);
        expect(playback.controller, isNull);
        expect(outputs, isEmpty);
        final ctx = lastContext();
        expect(commands(ctx), contains('loadlist'));
        expect(states.last['ready'], isTrue);
        expect(states.last['duration'], 120.0);
        expect(
          await incoming(bridge, 'play', {'engineId': 'background-next'}),
          isTrue,
        );
        expect(pauseValue(ctx), 0);
        expect(states.last['playing'], isTrue);
        expect(await open('background-next-again'), isTrue);
        expect(created(), before + 2);
        expect(playback.controller, isNull);
        expect(
          await incoming(bridge, 'play', {'engineId': 'background-next-again'}),
          isTrue,
        );
        expect(pauseValue(lastContext()), 0);
        expect(outputs, isEmpty);
      });
      await cleanup(tester);
    },
  );

  testWidgets(
    'resume attaches the same paused player on its first frame without reopen or seek',
    (tester) async {
      late Pointer<Void> ctx;
      late int before, commandBefore;
      await tester.runAsync(() async {
        expect(await open('resume-paused'), isTrue);
        ctx = lastContext();
        before = created();
        commandBefore = commandCount(ctx);
        expect(
          await incoming(bridge, 'pause', {'engineId': 'resume-paused'}),
          isTrue,
        );
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        expect(playback.controller, isNull);
        expect(outputs, isEmpty);
      });
      await frame(tester);
      await tester.runAsync(() async {
        await playback.controller!.platform.future.timeout(
          const Duration(seconds: 2),
        );
        expect(outputs, [ctx.address]);
        expect(playback.controller!.id.value, isNotNull);
        expect(created(), before);
        expect(commandCount(ctx), commandBefore);
        expect(pauseValue(ctx), 1);
        expect(videoTrack(ctx).toDartString(), 'auto');
        expect(videoSelected(ctx), 1);
        expect(earlyVideoEnables(ctx), 0);
        expect(nativeCalls, isNot(contains('pipReady')));
      });
      await frame(tester);
      expect(outputs, [ctx.address]);
      await cleanup(tester);
    },
  );

  testWidgets('foreground load waits for video attachment before loadlist', (
    tester,
  ) async {
    late Future<dynamic> pending;
    await tester.runAsync(() async {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      pending = open('foreground-video-only');
      await waitFor(() => playback.engineId == 'foreground-video-only');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(commands(lastContext()), isNot(contains('loadlist')));
      expect(playback.controller, isNull);
    });
    await frame(tester);
    await tester.runAsync(() async {
      expect(await pending, isTrue);
      expect(videoTrack(lastContext()).toDartString(), 'auto');
      expect(outputs, [lastContext().address]);
    });
    await cleanup(tester);
  });

  testWidgets(
    'foreground open followed by background before first frame remains controllable',
    (tester) async {
      await tester.runAsync(() async {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        final pending = open('race-to-background');
        await waitFor(() => playback.engineId == 'race-to-background');
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        expect(await pending, isTrue);
        expect(playback.controller, isNull);
        expect(
          await incoming(bridge, 'play', {'engineId': 'race-to-background'}),
          isTrue,
        );
        expect(outputs, isEmpty);
        expect(await incoming(bridge, 'release'), isTrue);
      });
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await frame(tester);
      expect(playback.controller, isNull);
      expect(outputs, isEmpty);
      await cleanup(tester);
    },
  );

  testWidgets('a newer item fences an earlier pending foreground attachment', (
    tester,
  ) async {
    late Pointer<Void> current;
    late Future<dynamic> pending;
    await tester.runAsync(() async {
      expect(await open('old'), isTrue);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      pending = open('new');
      await waitFor(() => playback.engineId == 'new');
      current = lastContext();
    });
    await frame(tester);
    await tester.runAsync(() async {
      await playback.controller!.platform.future.timeout(
        const Duration(seconds: 2),
      );
      expect(outputs, [current.address]);
      expect(playback.engineId, 'new');
      expect(await pending, isTrue);
    });
    await cleanup(tester);
  });

  testWidgets('pure audio never attaches a video controller after resume', (
    tester,
  ) async {
    await tester.runAsync(() async {
      expect(await open('audio', audio: true), isTrue);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    await frame(tester);
    expect(playback.controller, isNull);
    expect(outputs, isEmpty);
    await cleanup(tester);
  });

  testWidgets(
    'PiP before inline attachment is rejected without disrupting background audio',
    (tester) async {
      await tester.runAsync(() async {
        expect(await open('pip-before-frame'), isTrue);
        expect(
          await incoming(bridge, 'play', {'engineId': 'pip-before-frame'}),
          isTrue,
        );
        final before = List<String>.from(nativeCalls);
        expect(
          await incoming(bridge, 'pip', {
            'engineId': 'pip-before-frame',
            'requestId': 'late-pip',
          }),
          isFalse,
        );
        expect(pauseValue(lastContext()), 0);
        expect(nativeCalls, before);
        expect(playback.controller, isNull);
      });
      await cleanup(tester);
    },
  );

  testWidgets('background seek and controls do not depend on a video surface', (
    tester,
  ) async {
    await tester.runAsync(() async {
      expect(await open('background-controls'), isTrue);
      const id = 'background-controls';
      expect(
        await incoming(bridge, 'seek', {
          'engineId': id,
          'positionVersion': 1,
          'seconds': 35.0,
          'requestId': 'seek1',
        }),
        isTrue,
      );
      expect(commands(lastContext()), contains('seek'));
      for (final method in ['rate', 'volume']) {
        expect(
          await incoming(bridge, method, {
            'engineId': id,
            'requestId': method,
            'value': method == 'rate' ? 1.5 : 0.7,
          }),
          isTrue,
        );
      }
      for (final kind in ['audio', 'subtitle']) {
        expect(
          await incoming(bridge, 'track', {
            'engineId': id,
            'kind': kind,
            'trackId': 'no',
          }),
          isTrue,
        );
      }
      expect(await incoming(bridge, 'play', {'engineId': id}), isTrue);
      expect(await incoming(bridge, 'pause', {'engineId': id}), isTrue);
      expect(pauseValue(lastContext()), 1);
      expect(playback.controller, isNull);
      expect(outputs, isEmpty);
    });
    await cleanup(tester);
  });

  testWidgets(
    'release after resume but before its first frame cannot revive the old output',
    (tester) async {
      await tester.runAsync(() async {
        expect(await open('release-before-frame'), isTrue);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        expect(await incoming(bridge, 'release'), isTrue);
      });
      await frame(tester);
      expect(playback.controller, isNull);
      expect(playback.engineId, isEmpty);
      expect(outputs, isEmpty);
      await cleanup(tester);
    },
  );

  testWidgets('resume preserves an already playing headless session', (
    tester,
  ) async {
    late Pointer<Void> ctx;
    late int commandBefore;
    await tester.runAsync(() async {
      expect(await open('resume-playing'), isTrue);
      expect(
        await incoming(bridge, 'play', {'engineId': 'resume-playing'}),
        isTrue,
      );
      ctx = lastContext();
      commandBefore = commandCount(ctx);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    await frame(tester);
    await tester.runAsync(() async {
      await playback.controller!.platform.future.timeout(
        const Duration(seconds: 2),
      );
      expect(outputs, [ctx.address]);
      expect(commandCount(ctx), commandBefore);
      expect(pauseValue(ctx), 0);
    });
    await cleanup(tester);
  });

  testWidgets(
    'inactive then resumed in one turn reinstalls the foreground load gate',
    (tester) async {
      late Future<dynamic> pending;
      await tester.runAsync(() async {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        pending = open('rapid-resume-video-only');
        await waitFor(() => playback.engineId == 'rapid-resume-video-only');
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(commands(lastContext()), isNot(contains('loadlist')));
      });
      await frame(tester);
      await tester.runAsync(() async {
        expect(await pending, isTrue);
        expect(videoTrack(lastContext()).toDartString(), 'auto');
      });
      await cleanup(tester);
    },
  );

  testWidgets(
    'paused open reaches loadlist before any frame (negative control)',
    (tester) async {
      late Future<dynamic> pending;
      var openedBeforeFrame = false;
      var loadedBeforeFrame = false;
      await tester.runAsync(() async {
        pending = open('frame-independent');
        await Future.any([
          pending.then((_) {
            if (binding.lifecycleState == AppLifecycleState.paused) {
              openedBeforeFrame = true;
            }
          }),
          Future<void>.delayed(const Duration(milliseconds: 500)),
        ]);
        loadedBeforeFrame = commands(lastContext()).contains('loadlist');
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      });
      // Also unblock the old implementation so the negative control cleans up
      // normally before asserting; no late plugin errors contaminate its result.
      await frame(tester);
      await tester.runAsync(() async {
        expect(await pending, isTrue);
      });
      await cleanup(tester);
      expect(
        openedBeforeFrame,
        isTrue,
        reason: 'open must not wait for foreground',
      );
      expect(
        loadedBeforeFrame,
        isTrue,
        reason: 'libmpv must load while no frame exists',
      );
    },
  );

  testWidgets('late attachment waits for render context rather than Create reply', (tester) async {
    late Pointer<Void> ctx;
    late int earlyBefore, selectedBefore, pauseBefore, earlyAfter, selectedAfter, pauseAfter;
    late String trackBefore;
    late Rect? textureRect;
    var rendered = false;
    await tester.runAsync(() async {
      expect(await open('late-render'), isTrue);
      expect(await incoming(bridge, 'play', {'engineId': 'late-render'}), isTrue);
      ctx = lastContext();
      delayRenderReady = true;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    await frame(tester);
    await tester.runAsync(() async {
      await waitFor(() => outputs.contains(ctx.address));
      // Capture before releasing the native-ready receipt. Always allow normal
      // cleanup, including on the original ordering used as a negative control.
      earlyBefore = earlyVideoEnables(ctx);
      selectedBefore = videoSelected(ctx);
      trackBefore = videoTrack(ctx).toDartString();
      pauseBefore = pauseValue(ctx);
      await acknowledgeRenderContext(ctx.address);
      await playback.controller!.platform.future.timeout(const Duration(seconds: 2));
      earlyAfter = earlyVideoEnables(ctx);
      selectedAfter = videoSelected(ctx);
      pauseAfter = pauseValue(ctx);
      textureRect = playback.controller!.rect.value;
      unawaited(playback.controller!.waitUntilFirstFrameRendered.then((_) { rendered = true; }));
      await Future<void>.delayed(Duration.zero);
    });
    await cleanup(tester);
    expect(earlyBefore, 0, reason: 'video must not be enabled before render-context readiness');
    expect(selectedBefore, 0);
    expect(trackBefore, isNot('auto'));
    expect(pauseBefore, 0);
    expect(earlyAfter, 0);
    expect(selectedAfter, 1);
    expect(pauseAfter, 0);
    expect(textureRect, Rect.zero);
    expect(rendered, isFalse, reason: 'context-ready is not proof of displayed video');
  });

  testWidgets('release continues after delayed initialization without reviving the old session', (tester) async {
    late Pointer<Void> ctx;
    late Future<dynamic> release;
    await tester.runAsync(() async {
      expect(await open('release-during-render'), isTrue);
      ctx = lastContext(); delayRenderReady = true;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    await frame(tester);
    await tester.runAsync(() async {
      await waitFor(() => outputs.contains(ctx.address));
      release = incoming(bridge, 'release');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(playback.controller, isNull);
      expect(earlyVideoEnables(ctx), 0);
      await acknowledgeRenderContext(ctx.address);
      expect(await release, isTrue);
      expect(videoSelected(ctx), 0);
      expect(playback.controller, isNull);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(await open('new-after-release'), isTrue);
      expect(lastContext(), isNot(ctx));
      expect(playback.engineId, 'new-after-release');
    });
    await cleanup(tester);
  });

  Future<void> prepareInlinePiP(WidgetTester tester, String id) async {
    await tester.runAsync(() async {
      expect(await open(id), isTrue);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    await frame(tester);
    await tester.runAsync(() async {
      await playback.controller!.platform.future.timeout(const Duration(seconds: 2));
      expect(await incoming(bridge, 'pip', {
        'engineId': id, 'requestId': 'pip-$id',
      }), isTrue);
      restoreDimensions = true;
    });
  }

  testWidgets('background PiP close defers output and foreground restores the same paused player once', (tester) async {
    const id = 'pip-background-close';
    await prepareInlinePiP(tester, id);
    await tester.runAsync(() async {
      final ctx = lastContext();
      final count = created();
      final loaded = commands(ctx).where((x) => x == 'loadlist').length;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(await incoming(bridge, 'pause', {'engineId': id}), isTrue);
      for (var i = 0; i < 2; i++) {
        expect(await incoming(bridge, 'pipRestore', {
          'engineId': id, 'requestId': 'background-$i',
        }), isTrue);
      }
      expect(outputs, [ctx.address]);
      expect(nativeCalls.where((x) => x == 'pipRestoreDeferred').length, 2);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(await incoming(bridge, 'pipRestore', {
        'engineId': id, 'requestId': 'foreground',
      }), isTrue);
      expect(await incoming(bridge, 'pipRestore', {
        'engineId': id, 'requestId': 'duplicate-foreground',
      }), isTrue);
      expect(outputs, [ctx.address, ctx.address]);
      expect(created(), count);
      expect(commands(ctx).where((x) => x == 'loadlist').length, loaded);
      expect(commands(ctx), isNot(contains('seek')));
      expect(pauseValue(ctx), 1);
      expect(nativeCalls, contains('pipRestoreForeground'));
    });
    await cleanup(tester);
  });

  testWidgets('background native Create rejection is deferred and retry does not poison playback', (tester) async {
    const id = 'pip-native-admission';
    await prepareInlinePiP(tester, id);
    await tester.runAsync(() async {
      rejectRestoreCreate = true;
      expect(await incoming(bridge, 'pipRestore', {
        'engineId': id, 'requestId': 'native-background',
      }), isTrue);
      expect(outputs.length, 1);
      expect(states.last['failure'], isEmpty);
      expect(nativeCalls, contains('pipRestoreDeferred'));
      rejectRestoreCreate = false;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(await incoming(bridge, 'pipRestore', {
        'engineId': id, 'requestId': 'native-foreground',
      }), isTrue);
      expect(outputs.length, 2);
      expect(pauseValue(lastContext()), 1);
    });
    await cleanup(tester);
  });

  testWidgets('accepted Create followed by background reuses its texture on foreground', (tester) async {
    const id = 'pip-create-lifecycle-race';
    await prepareInlinePiP(tester, id);
    await tester.runAsync(() async {
      backgroundAfterRestoreCreate = true;
      expect(await incoming(bridge, 'pipRestore', {
        'engineId': id, 'requestId': 'race-before-background',
      }), isTrue);
      expect(outputs.length, 2);
      expect(nativeCalls, contains('pipRestoreDeferred'));
      backgroundAfterRestoreCreate = false;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(await incoming(bridge, 'pipRestore', {
        'engineId': id, 'requestId': 'race-after-foreground',
      }), isTrue);
      expect(outputs.length, 2, reason: 'accepted native Create cannot be repeated for the same handoff');
    });
    await cleanup(tester);
  });

  testWidgets('new background item discards deferred old PiP restoration', (tester) async {
    const old = 'pip-old-deferred';
    await prepareInlinePiP(tester, old);
    await tester.runAsync(() async {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(await incoming(bridge, 'pipRestore', {
        'engineId': old, 'requestId': 'old-background',
      }), isTrue);
      expect(await open('new-after-pip'), isTrue);
      expect(await incoming(bridge, 'pipRestore', {
        'engineId': old, 'requestId': 'late-old',
      }), isFalse);
      expect(outputs.length, 1);
      expect(playback.controller, isNull);
      expect(playback.engineId, 'new-after-pip');
      expect(await incoming(bridge, 'play', {'engineId': 'new-after-pip'}), isTrue);
      expect(pauseValue(lastContext()), 0);
    });
    await cleanup(tester);
  });

  testWidgets('failed PiP rollback in background defers without finally resuming stale play intent', (tester) async {
    const id = 'pip-rollback-background';
    await tester.runAsync(() async {
      expect(await open(id), isTrue);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    await frame(tester);
    await tester.runAsync(() async {
      await playback.controller!.platform.future.timeout(const Duration(seconds: 2));
      expect(await incoming(bridge, 'play', {'engineId': id}), isTrue);
      expect(pauseValue(lastContext()), 0);
      failPiPReadyInBackground = true;
      expect(await incoming(bridge, 'pip', {
        'engineId': id, 'requestId': 'rollback-background',
      }), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(outputs.length, 1);
      expect(pauseValue(lastContext()), 1);
      expect(nativeCalls, contains('pipRestoreDeferred'));
      expect(states.last['failure'], isEmpty);
      restoreDimensions = true;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(await incoming(bridge, 'pipRestore', {
        'engineId': id, 'requestId': 'rollback-foreground',
      }), isTrue);
      expect(outputs.length, 2);
      expect(pauseValue(lastContext()), 1, reason: 'only latest native intent may resume playback');
    });
    await cleanup(tester);
  });

}
