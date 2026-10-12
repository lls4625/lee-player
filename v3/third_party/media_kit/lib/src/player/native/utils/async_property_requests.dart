/// LeePlayer's additive patch to media_kit 1.2.6. See LOCAL_PATCH.md.
/// Uses the existing libmpv ABI and the player's sole event consumer.
import 'dart:async';
import 'dart:ffi';

import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as generated;
import 'async_property_error.dart';

class AsyncPropertyRequests {
  AsyncPropertyRequests({
    required this.mpv,
    required this.handle,
    required this.nextRequestId,
    this.maxPending = 64,
    this.reservedControl = 8,
  }) {
    if (maxPending < 2 ||
        reservedControl < 1 ||
        reservedControl >= maxPending) {
      throw ArgumentError('Invalid asynchronous property request limits');
    }
  }

  final generated.MPV mpv;
  final Pointer<generated.mpv_handle> Function() handle;
  final int Function() nextRequestId;
  final int maxPending;
  final int reservedControl;
  final Map<int, _PropertyRequest> _pending = {};
  bool _closed = false;
  int _controlPending = 0;

  int get pendingCount => _pending.length;
  int get controlPendingCount => _controlPending;
  bool get closed => _closed;

  Future<String> read(String property, {bool controlRead = false}) async {
    if (_closed) throw StateError('Asynchronous property reader is closed');
    final context = handle();
    if (context == nullptr) {
      throw StateError('Player native handle is not initialized');
    }
    final ordinaryPending = _pending.length - _controlPending;
    // Separate budgets: diagnostic traffic can never consume the eight
    // control slots. A frozen core can exhaust either budget; fail closed,
    // rather than freeing timed-out native slots and issuing unbounded work.
    if (_pending.length >= maxPending ||
        (controlRead
            ? _controlPending >= reservedControl
            : ordinaryPending >= maxPending - reservedControl)) {
      throw MpvPropertyReadBusy(controlRead);
    }
    final id = nextRequestId();
    if (_pending.containsKey(id))
      throw StateError('Duplicate property request ID');
    final name = property.toNativeUtf8();
    final request = _PropertyRequest(property, controlRead);
    _pending[id] = request;
    if (controlRead) _controlPending++;
    try {
      final status = mpv.mpv_get_property_async(
        context,
        id,
        name.cast(),
        generated.mpv_format.MPV_FORMAT_STRING,
      );
      if (status < 0) {
        _remove(id);
        // Throw through the returned Future. Do not complete the unused
        // request completer with an error that has no listener.
        throw MpvPropertyReadException(property, status, submission: true);
      }
    } catch (_) {
      _remove(id);
      rethrow;
    } finally {
      calloc.free(name);
    }
    // No timeout here: a caller's Future.timeout does not cancel the native
    // request. The map entry/budget survives until reply or close().
    return request.completer.future;
  }

  /// Called only by NativePlayer's existing event pump. Returns true for a
  /// GET reply, including a late/unknown reply. Never awaits client code.
  bool handleEvent(Pointer<generated.mpv_event> event) {
    if (event == nullptr ||
        event.ref.event_id !=
            generated.mpv_event_id.MPV_EVENT_GET_PROPERTY_REPLY) {
      return false;
    }
    final request = _remove(event.ref.reply_userdata);
    if (request == null) return true;
    try {
      if (event.ref.error < 0) {
        throw MpvPropertyReadException(request.property, event.ref.error);
      }
      if (event.ref.data == nullptr) {
        throw const FormatException('Missing property reply payload');
      }
      final property = event.ref.data.cast<generated.mpv_event_property>().ref;
      if (property.format != generated.mpv_format.MPV_FORMAT_STRING ||
          property.data == nullptr) {
        throw const FormatException('Invalid string property reply');
      }
      // MPV_FORMAT_STRING data is char**, NOT char*. Copy immediately: all
      // event memory belongs to libmpv and expires at the next wait_event.
      final value = property.data.cast<Pointer<Utf8>>().value;
      if (value == nullptr) throw const FormatException('Null property string');
      request.completer.complete(value.toDartString());
    } catch (error, stack) {
      request.completer.completeError(error, stack);
    }
    // Never mpv_free(event.data), property.data or the borrowed char*.
    return true;
  }

  _PropertyRequest? _remove(int id) {
    final request = _pending.remove(id);
    if (request?.controlRead == true) _controlPending--;
    return request;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    final requests = _pending.values.toList(growable: false);
    _pending.clear();
    _controlPending = 0;
    for (final request in requests) {
      request.completer.completeError(
        StateError('Player disposed during asynchronous property read'),
      );
    }
  }
}

class _PropertyRequest {
  _PropertyRequest(this.property, this.controlRead);
  final String property;
  final bool controlRead;
  final Completer<String> completer = Completer<String>();
}
