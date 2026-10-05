import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:leeplayer/media_kit_recovery.dart';

void main() {
  group('MediaKitCommandPermit', () {
    test('invalidates a timed-out source continuation', () async {
      final permit = MediaKitCommandPermit();
      final gate = Completer<void>();
      var published = false;

      final source = () async {
        await gate.future;
        if (permit.isValid) published = true;
      }();

      permit.invalidate();
      gate.complete();
      await source;

      expect(permit.isValid, isFalse);
      expect(published, isFalse);
    });
  });

  group('classifyMediaKitRuntimeError', () {
    test('accepts only the complete media source-open error envelope', () {
      expect(classifyMediaKitRuntimeError(
              '[MediaKitError]\nFailed to open file:///missing.mp4.'),
          MediaKitRuntimeErrorKind.fatal);
      expect(classifyMediaKitRuntimeError('Failed to open https://bad.invalid/a.'),
          MediaKitRuntimeErrorKind.recoverable);
    });

    test('does not infer fatality from diagnostic prose', () {
      expect(classifyMediaKitRuntimeError(
              'decoder recovered after loading failed for one track'),
          MediaKitRuntimeErrorKind.recoverable);
      expect(classifyMediaKitRuntimeError('Loading failed.'),
          MediaKitRuntimeErrorKind.recoverable);
      expect(classifyMediaKitRuntimeError('decoder: Failed to open hw device.'),
          MediaKitRuntimeErrorKind.recoverable);
      expect(classifyMediaKitRuntimeError('network timeout'),
          MediaKitRuntimeErrorKind.recoverable);
      expect(classifyMediaKitRuntimeError(''),
          MediaKitRuntimeErrorKind.recoverable);
    });
  });

  test('a late operation observes the newest intent', () async {
    final intents = MediaKitLatestIntent<String>();
    final oldVersion = intents.record('play');
    final lateOperation = Completer<void>();

    final completion = () async {
      await lateOperation.future;
      return intents.isLatest(oldVersion);
    }();

    final newVersion = intents.record('pause');
    lateOperation.complete();

    expect(await completion, isFalse);
    expect(intents.isLatest(newVersion), isTrue);
    expect(intents.value, 'pause');
  });

  test('timed-out cleanup remains a gate until it actually finishes', () async {
    final coordinator = MediaKitCleanupCoordinator();
    final gate = Completer<void>();
    var cleanups = 0;
    coordinator.add(() async {
      cleanups++;
      await gate.future;
    });

    expect(await coordinator.drain(Duration.zero), isFalse);
    expect(coordinator.hasPending, isTrue);
    expect(await coordinator.drain(Duration.zero), isFalse);
    expect(cleanups, 1, reason: 'a second drain must share the old cleanup');
    gate.complete();
    expect(await coordinator.drain(const Duration(seconds: 1)), isTrue);
    expect(coordinator.hasPending, isFalse);
    expect(cleanups, 1);
  });

  test('failed cleanup is retained and retried', () async {
    final coordinator = MediaKitCleanupCoordinator();
    var attempts = 0;
    coordinator.add(() async {
      attempts++;
      if (attempts == 1) throw StateError('injected dispose failure');
    });

    expect(await coordinator.drain(const Duration(seconds: 1)), isFalse);
    expect(coordinator.hasPending, isTrue);
    // Allow the completed in-flight attempt to clear before retrying.
    await Future<void>.delayed(Duration.zero);
    expect(await coordinator.drain(const Duration(seconds: 1)), isTrue);
    expect(attempts, 2);
  });

  test('repair budget stops retries by attempt count and invalidation', () {
    var now = 1000;
    final budget = MediaKitRepairBudget(
      maxAttempts: 2,
      maxElapsed: const Duration(seconds: 5),
      nowMilliseconds: () => now,
    );

    expect(budget.beginAttempt(), isTrue);
    expect(budget.beginAttempt(), isTrue);
    expect(budget.beginAttempt(), isFalse);
    expect(budget.attempts, 2);

    final invalidated = MediaKitRepairBudget(nowMilliseconds: () => now);
    invalidated.invalidate();
    expect(invalidated.beginAttempt(), isFalse);
  });

  test('repair budget expires even with attempts remaining', () {
    var now = 0;
    final budget = MediaKitRepairBudget(
      maxAttempts: 5,
      maxElapsed: const Duration(milliseconds: 50),
      nowMilliseconds: () => now,
    );
    expect(budget.beginAttempt(), isTrue);
    now = 50;
    expect(budget.beginAttempt(), isFalse);
  });
}
