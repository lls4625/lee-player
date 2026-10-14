# media_kit_video 2.0.1: late-attachment render ordering

Unmodified upstream package: media_kit_video 2.0.1 from the project's locked
pub.dev cache. `UPSTREAM_FILE_HASHES.json` records every original file.
Upstream project: https://github.com/media-kit/media-kit
License: original MIT LICENSE retained.

The original source modification moves `vid=auto` from before
`VideoOutputManager.Create` to after the first texture-registration receipt in
`lib/src/video_controller/native_video_controller/real.dart`.

A Player opened headlessly is already playing audio when a VideoController is
attached. Enabling video before the libmpv render context exists fails with
`No render context set`; merely creating the context afterwards does not retry
the selected video output. On the bundled iOS implementation, TextureHW creates
the render context before registering its texture. The software path queues
initialization before registration on the same main queue. The Create method
reply by itself is not readiness. A 0x0 texture receipt establishes this ordering,
not that a real decoded frame was displayed.

The existing player initialization gate remains in place: public controls and
disposal wait for VideoController initialization, including this final write.
No changes to play/pause, rate, seeks, hardware policy, audio/subtitle selection,
render buffers or native rendering/disposal code. No global pub-cache edits.

Other native paths were source-checked, not executed: Linux
`video_output_set_texture_update_callback` emits an initial 1x1 texture receipt;
Windows constructs its default 1x1 texture and completes initialization before
`SetTextureUpdateCallback` immediately emits the ID; macOS registers its initial
0x0 texture after context creation. None of these receipts depends on decoding
the first video frame. Android/web use separate implementations, unchanged.

## 2026-10-13: PiP restore foreground admission

`ios/Classes/plugin/common/MediaKitVideoPlugin.swift` also accepts an optional
`requireForeground` flag on Create. Only the app's PiP inline-output restoration
sets it. If the platform message arrives while iOS is not active, the plugin
returns `video_output_background` before enqueuing any new output. The app
retains its engine/restore intent and retries after foreground confirmation.
The ordinary headless attachment path, GPU initialization worker, texture
registration receipt, and disposal ordering are unchanged. There is no native
wait-for-foreground or timeout-as-cancellation mechanism.

This gate does not make Create admission and its later worker execution atomic.
The pre-existing narrow race when iOS leaves active after Create admission but
before worker initialization still requires device stress verification; this
patch does not move potentially expensive libmpv initialization onto the main
thread or redesign renderer lifetime.
