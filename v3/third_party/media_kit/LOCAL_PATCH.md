# Local patch: media_kit 1.2.6 async property reads

## Provenance and scope

This directory is the complete published media_kit 1.2.6 package, with the small
additive patch below. Original MIT LICENSE and upstream source notices are intact.
Upstream: https://github.com/media-kit/media-kit and https://pub.dev/packages/media_kit/versions/1.2.6
Published package archive SHA-256 (the original application lock):
ae9e79597500c7ad6083a3c7b7b7544ddabfceacce7ae5c9709b0ec16a5d6643

UPSTREAM_FILE_HASHES.json records every unmodified package file before patching.
UPSTREAM_API_HASHES.json records the existing get/set/command/observe APIs.
UPSTREAM_PUBSPEC.yaml preserves the original published package metadata.
Run python3 tool/verify_media_kit_vendor.py from the application root to check
the expected file set, unchanged ABI bindings, LICENSE, and preserved APIs.

The root pubspec keeps media_kit: 1.2.6 and applies a relative dependency_overrides
path for this directory, including media_kit_video's transitive requirement.
Commit/package this directory with pubspec.yaml and pubspec.lock. Do not modify
the machine's .pub-cache, fetch a floating Git branch, or silently update mpv,
FFmpeg, media_kit_video or any other dependency. Other locked package versions,
archive hashes and original mirror metadata are unchanged.

## Runtime changes

- Add NativePlayer.getPropertyAsync. Original getProperty, setProperty, command,
  observeProperty and unobserveProperty retain their original source/semantics.
- Submit MPV_FORMAT_STRING requests using the existing generated
  mpv_get_property_async binding. No generated binding, C header or ABI change.
- GET requests have their own pending map but use NativePlayer's existing global
  async request counter. The existing sole event pump dispatches GET replies
  before its initialization early return. No new wait_event loop/client/wakeup.
- A successful property payload is char**. Copy it into a Dart String before the
  next mpv_wait_event. Never free mpv-owned event memory.
- Native negative status is MpvPropertyReadException (property, code, submission).
  Immediate submit failure removes the slot without completing an unobserved
  error Future. Malformed successful payloads fail with FormatException.
- Hard budget: 64 native outstanding reads, partitioned as 56 ordinary reads and
  8 control reads. Diagnostic reads cannot consume control slots. Only the two
  existing seek-confirmation reads in LeePlayer use controlRead: true.
- A caller Future.timeout does not cancel native work and DOES NOT release its
  slot. The slot lives until the real reply arrives or the reader permanently
  closes at dispose. No property/request merging is used, so a pre-seek request
  cannot accidentally stand in for a fresh post-command confirmation.
- If mpv never replies, either lane can eventually fill. Further requests fail
  locally as MpvPropertyReadBusy; there is no hidden retry/unbounded queue, no
  false success, and no promise that a frozen core can satisfy a seek.
- Disposal immediately rejects new additive reads, completes pending read Futures,
  and closes their map, even while the original dispose waits for its lock/init/
  stop. Existing teardown order remains unchanged. New reads recheck disposal
  after initialization awaits; a null native handle is rejected before FFI.

IMPORTANT: Do not await this new getter from an existing observeProperty listener
or awaited mpv hook/event handler. Those upstream callbacks are themselves
awaited by the sole event consumer, so doing so would wait for a reply that the
same blocked consumer must deliver. LeePlayer's migrated _readProperty entry is
outside those handlers, and it does not register observeProperty callbacks.

## Application behavior

Only the property-read adapter and explicit purpose markers on the two existing
seek-confirmation reads change. The 17 heartbeat properties, 250 ms cadence,
seek target/frequency/algorithm, playback parameters, state fences, diagnostics,
language strings, native code and UI do not change in this patch.

An actual PROPERTY_UNAVAILABLE reply (-10) maps to the existing unavailable
status. Unsupported property/format, request-budget failure, other native error,
malformed payload and disposal stay explicit error/unknown, never software
decoding, successful control, or a fabricated actual speed/track.

## Analyzer integration

The original package-development tests and examples are retained unchanged for
provenance, but excluded in this directory's analysis_options.yaml. Their separate
package:test/lints dev dependencies are not part of the application graph.
The unavailable upstream package:lints include is removed for that reason.
Runtime lib and the new application FFI tests are NOT excluded.

The unchanged upstream web/player/real.dart:1343 uses JSArray.add,
which the analyzer reports as available since Dart 3.10, while the original
package SDK minimum says 3.1. The local pubspec corrects the minimum to >=3.10.0;
the application already requires Dart 3.13.2. This is local metadata correction,
not an upstream release or changed runtime API; the version remains 1.2.6.
No sdk_version_since warning is suppressed. The original pubspec is preserved
byte-for-byte and the verifier permits only that one metadata substitution.

## Validation

Run from the app root after flutter pub get:
- python3 tool/verify_media_kit_vendor.py
- flutter analyze --no-pub lib test
- flutter analyze --no-pub third_party/media_kit/lib/src/player/native/player/real.dart third_party/media_kit/lib/src/player/native/player/stub.dart third_party/media_kit/lib/src/player/native/utils/async_property_error.dart third_party/media_kit/lib/src/player/native/utils/async_property_requests.dart
- flutter test --no-pub test/media_kit_async_property_test.dart
- flutter test --no-pub

The FFI test compiles tool/ffi/fake_mpv_property.c with a local C compiler into a
temporary directory. It calls the unchanged generated Dart ABI, tests borrowed
payload invalidation, errors, limits, timeouts, late/out-of-order replies and
close; it also instantiates real NativePlayer and uses its real NativeCallable
event pump for GET-before-initialization and dispose/init-await races. Its
configuration uses synchronous NO-OP setup/control methods in the fake library:
it does not establish runtime SET/COMMAND async coexistence, playback, audio,
renderer timing, iOS build or device behavior. Upstream tests are not claimed run.

A same-device release A/B remains necessary: reduced UI/FFI blocking does not by
itself prove that sustained underrun, physical A/V sync, or seek-to-first-frame
has been fixed.

## Official API basis

- https://github.com/mpv-player/mpv/blob/v0.36.0/libmpv/client.h#L86-L126
- https://github.com/mpv-player/mpv/blob/v0.36.0/libmpv/client.h#L1101-L1182
- https://github.com/mpv-player/mpv/blob/v0.36.0/libmpv/client.h#L1611-L1642
- https://github.com/mpv-player/mpv/blob/v0.36.0/player/client.c#L1292-L1426

