import 'package:flutter_test/flutter_test.dart';
import 'package:leeplayer/media_kit_recovery.dart';

void main() {
  group('current settled libmpv EOF evidence', () {
    late MediaKitSnapshotFence fence;
    setUp(() { fence = MediaKitSnapshotFence()..beginSession(0); });

    test('new open can end without a seek, including nonseekable media', () {
      final state = fence.capture();
      expect(fence.confirmsEnd(state, eof: 'yes', seeking: 'no'), isTrue);
      expect(fence.confirmsEnd(state, eof: 'true', seeking: 'false'), isTrue);
    });

    test('missing or false raw EOF never inherits cached completed', () {
      final state = fence.capture();
      for (final eof in [null, '', 'no', 'false']) {
        expect(fence.confirmsEnd(state, eof: eof, seeking: 'no'), isFalse);
      }
      for (final seeking in [null, '', 'yes', 'true']) {
        expect(fence.confirmsEnd(state, eof: 'yes', seeking: seeking), isFalse);
      }
    });

    test('seek receipt fences old EOF before command leaves its queue', () {
      final before = fence.capture();
      expect(fence.recordPositionVersion(1), isTrue);
      final queued = fence.capture();
      expect(fence.confirmsEnd(before, eof: 'yes', seeking: 'no'), isFalse);
      expect(fence.confirmsEnd(queued, eof: 'yes', seeking: 'no'), isFalse);
    });

    test('a read begun unsettled cannot gain authority when published later', () {
      fence.recordPositionVersion(1);
      final queuedRead = fence.capture();
      final operation = fence.capture();
      expect(fence.settlePosition(operation), isTrue);
      expect(fence.accept(queuedRead), isTrue);
      expect(fence.confirmsEnd(queuedRead, eof: 'yes', seeking: 'no'), isFalse);
      expect(fence.confirmsEnd(fence.capture(), eof: 'yes', seeking: 'no'), isTrue);
    });

    test('superseded seek success cannot settle the latest pending seek', () {
      fence.recordPositionVersion(1);
      final oldSeek = fence.capture();
      fence.recordPositionVersion(2);
      expect(fence.settlePosition(oldSeek), isFalse);
      expect(fence.confirmsEnd(fence.capture(), eof: 'yes', seeking: 'no'), isFalse);
      expect(fence.settlePosition(fence.capture()), isTrue);
      expect(fence.confirmsEnd(fence.capture(), eof: 'yes', seeking: 'no'), isTrue);
    });

    test('failed seek remains untrusted without an observed settlement', () {
      fence.recordPositionVersion(1);
      for (var index = 0; index < 8; index++) {
        final state = fence.capture();
        expect(fence.accept(state), isTrue);
        expect(fence.confirmsEnd(state, eof: 'yes', seeking: 'no'), isFalse);
      }
    });

    test('new engine session rejects old end and old successful seek', () {
      fence.recordPositionVersion(1);
      final old = fence.capture();
      fence.beginSession(1);
      expect(fence.settlePosition(old), isFalse);
      expect(fence.accept(old), isFalse);
      expect(fence.confirmsEnd(old, eof: 'yes', seeking: 'no'), isFalse);
      expect(fence.confirmsEnd(fence.capture(), eof: 'yes', seeking: 'no'), isTrue);
    });

    test('release invalidates previously confirmed terminal evidence', () {
      final old = fence.capture();
      fence.invalidateSession();
      expect(fence.confirmsEnd(old, eof: 'yes', seeking: 'no'), isFalse);
      expect(fence.accept(old), isFalse);
    });

    test('late native seek repair invalidates older EOF reads without rearming', () {
      final old = fence.capture();
      fence.invalidateEndEvidence();
      expect(fence.confirmsEnd(old, eof: 'yes', seeking: 'no'), isFalse);
      expect(fence.confirmsEnd(fence.capture(), eof: 'yes', seeking: 'no'), isFalse);
      fence.recordPositionVersion(1);
      fence.invalidateEndEvidence();
      expect(fence.confirmsEnd(fence.capture(), eof: 'yes', seeking: 'no'), isFalse);
      fence.settlePosition(fence.capture());
      expect(fence.confirmsEnd(fence.capture(), eof: 'no', seeking: 'no'), isFalse);
      expect(fence.confirmsEnd(fence.capture(), eof: 'yes', seeking: 'no'), isTrue);
    });

    test('old same-version settlement cannot unlock a newer repair', () {
      final oldSeek = fence.capture();
      fence.invalidateEndEvidence();
      final currentRepair = fence.capture();
      expect(fence.settlePosition(oldSeek), isFalse);
      expect(fence.confirmsEnd(fence.capture(), eof: 'yes', seeking: 'no'), isFalse);
      expect(fence.settlePosition(currentRepair), isTrue);
      expect(fence.confirmsEnd(fence.capture(), eof: 'yes', seeking: 'no'), isTrue);
    });

    test('position and sequence fences still reject duplicate and reversed state', () {
      final older = fence.capture();
      final newer = fence.capture();
      expect(fence.accept(newer), isTrue);
      expect(fence.accept(newer), isFalse);
      expect(fence.accept(older), isFalse);
      expect(fence.recordPositionVersion(-1), isFalse);
      fence.recordPositionVersion(1);
      expect(fence.accept(newer), isFalse);
    });
  });
}
