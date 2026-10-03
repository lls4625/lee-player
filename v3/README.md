# 雷player · v1

基于 Flutter 的 iOS 本地音视频播放器。

应用名称为「雷player」，寓意连续的闪电。Logo 已采用用户确认版：深蓝背景、带柔和高光的黄橙平面渐变闪电与银蓝金属播放三角；闪电上下尖端靠近但不接触金属圈，左侧保留陡斜缺口。运行时图标已接入 `ios/Runner/Assets.xcassets/AppIcon.appiconset`，不再额外打包未使用的 Flutter Logo 资源。工程包名仍为 `leeplayer`。

## 当前状态

- 全项目可替换界面组件已迁移至 `liquid_glass_widgets 1.3.0`：页面、导航、列表、按钮、开关、滑块、输入、菜单、弹窗、底部面板、提示和进度指示。
- 源码使用 Flutter 界面与 iOS AVPlayer/AVFoundation 系统播放服务，入口为 `lib/main.dart`；发布依赖不再包含 media_kit、libmpv 或 FFmpeg。
- 四个页面入口：课程库、播放历史、收藏、设置；点击课程打开播放页，返回后保留迷你播放器。
- 文件夹和多文件复制导入，保留子目录，导入进度与取消，重名自动编号；目录浏览、自然顺序/修改时间/大小排序、新建目录、重命名、移动、回收站与恢复。
- 同目录视频与音频组成队列；支持顺序连播、文件夹循环、单集循环、随机、上一节/下一节、断点续播与收藏。
- 播放页支持拖动进度、前后跳转、0.5–3.0 倍速（弹窗按 0.05 调整，确定后持久保存，首次默认 1.0）、横竖屏、隐藏控件、控件锁定、双击左右画面跳转、画面适配、视频音量、屏幕亮度、A–B 复读与定时停止。
- 原生引擎保留系统可识别的音轨/字幕切换与 SRT/VTT 外置字幕；画中画使用 AVPlayerLayer。
- 已实现后台音频、锁屏媒体控制、音频中断恢复逻辑、耳机断开暂停。
- 主页和设置提供自愿打赏入口；打赏通过 StoreKit 2 可消耗型 IAP 完成，可重复购买，不解锁功能或内容，也不可恢复。
- 当前已通过 Flutter 自动化测试、静态分析、iOS 模拟器构建及本地 StoreKit 商品/消耗型交易测试；真实设备播放体验和 App Store 沙盒/正式商品仍需发布前验证。
- 分析与变更记录位于项目根目录的 `../docs/vibe`。

## 文件与播放规则

“设置 → 智能跳过空白片头”默认开启。支持检测的媒体会在从头播放时检查前 60 秒内连续的黑画面与静音，至少确认 2 秒空白才跳过，并保留内容开始前 0.5 秒；不支持检测的媒体正常保留片头，不报错、不提示。纯音频不检测。首次检测最多等待约 8 秒，超时或不确定就正常起播；结果按文件路径、大小、修改时间和文件标识缓存。有效断点续播优先，手动拖回开头不会反复跳过。检测不改动源文件；具体识别效果待真机确认。详见 `../docs/vibe/intro-skip-implementation-2026-09-08_12-14-01.md`。

课程保存在 App 的 Documents 目录，播放记录保存在 Application Support/LeiPlayer/library.json。通过系统“文件”中的“我的 iPhone / 雷player”或 Finder 文件共享复制内容后，回到应用刷新。App 内导入按每个选中项目完整复制后移入课程目录，失败或取消时清理当前未完成项目，保留此前已完成的项目。

播放一个媒体时，以它所在目录的直接子音视频文件按自然名称顺序组队，子文件夹独立播放。列表排序只改变课程库的显示顺序，不改变课程队列的自然顺序。移动、改名或回收正在使用的队列成员会停止并清空相关队列。回收站占用空间，清空后不可恢复。

播放仅使用 AVPlayer/AVFoundation，实际可播放格式和编码组合以当前 iOS 系统支持能力为准。MP4、MOV、M4V、MP3、M4A、AAC、WAV、AIFF 等常见系统格式可作为手动验证重点；MKV、FLV、AVI、WebM、Ogg、Opus 等不再承诺支持。格式识别不等于系统一定能解码。

为降低 App Store 开源许可证重链接风险，发布配置已移除 `media_kit`、`media_kit_video`、`media_kit_libs_video`、libmpv、FFmpeg 与历史 VLCKit 文件。播放能力完全由 Apple 系统框架提供；实际硬解、性能和音画同步仍需真机确认。

拖动期间暂停播放。AVPlayer 保留限频预览、预览 0.2 秒容差和最终零容差定位；原生定位队列串行并合并最新待处理目标。引擎位置确认不代表已测量物理音画同步。原生总定位超时为 8 秒，打开超时为 15 秒；失败不作为成功恢复播放。

“播放信息”保留复制按钮并展示 AVPlayer 播放状态与轨道信息。这些是运行诊断，不是自动化测试结果，也没有测量实际扬声器与屏幕输出偏差。

外置字幕需小于等于 10 MB。当前提供 SRT/VTT 基本文字时间轴，外置字幕不进入原生画中画；ASS/PGS 与字体附件不再承诺支持。音轨和内嵌字幕选项取决于系统对当前文件的识别。复读区间与字幕选择在切换视频时重置；倍速、循环和后台偏好持久保存。

后台服务负责跨视频连播，系统是否允许通话后自动恢复仍受音频会话状态限制。只有中断前有播放意图、开启恢复且 iOS 给出恢复许可时才尝试续播。强制退出应用后不会继续播放。后台导入使用系统提供的有限执行时间，大批文件建议保持前台。

## 源码分工

- `lib/glass_ui.dart`：液态玻璃公共组件、主题配色、列表与独立控件组合、菜单、面板和提示。
- `lib/player_model.dart`：Flutter 状态、事件订阅、原生方法通道和显示格式。
- `lib/library_page.dart`：课程库、历史、收藏、文件操作与设置。
- `lib/playback_page.dart`：视频视图、队列与播放控制。
- `ios/Runner/CourseLibrary.swift`：沙盒文件导入、管理和播放记录。
- `ios/Runner/PlaybackService.swift`：AVPlayer 播放、定位队列、断点时间轴、音频会话与锁屏控制。
- `ios/Runner/PlayerBridge.swift`：Flutter 桥接、系统文件选择器和画中画。

## 本机运行说明

本次采用 `flutter create --platforms=ios --empty --no-pub` 初始化，当前依赖已经解析，并已运行构建、静态分析和自动化测试。

工程沿用本机 Flutter 模板的 Dart SDK 约束（`^3.13.2`）及 iOS 最低版本（15.0）；正式 Bundle ID 为 `vip.ichiki.javalee.leeplayer`。Flutter 自动带入了本机签名团队，真机运行前请在 Xcode 中确认签名团队、App Store Connect 记录及六个可消耗型打赏商品均与该 Bundle ID 匹配。

本地打赏测试使用 `ios/Runner/DeveloperTips.storekit`。必须通过 Xcode 的 Runner Scheme 执行 Run，或执行 RunnerTests，才能激活本地 StoreKit 测试会话；普通 `flutter run` 和 `simctl launch` 只会走正常 App Store 商品查询，不会因为工程中存在 `.storekit` 文件而自动使用本地商品。`RunnerTests/DeveloperTipsStoreKitTests.swift` 会验证六个商品全部返回，并完成后清理一笔不会真实扣款的本地消耗型交易。

保留初始化所需的标准 iOS 工程文件，并加入打赏用 RunnerTests 测试目标。UI 使用 `liquid_glass_widgets: 1.3.0`；播放层只使用 iOS 系统框架。

本轮已离线解析 Flutter 依赖，并用 CocoaPods 将 iOS Pods 同步为仅含 Flutter。没有修改全局配置。发布前仍需由开发者手动归档并检查最终 `.app` 中不存在旧的 libmpv、FFmpeg、media_kit 或 VLCKit Framework。

Flutter 自动生成的 `NOTICES.Z` 负责在“设置 → 关于雷player → 开源软件许可”展示 Flutter、Dart、引擎间接组件以及 `liquid_glass_widgets 1.3.0` 的许可。工程同时将该组件对应版本的上游 MIT 许可证全文作为 `assets/legal/LIQUID_GLASS_WIDGETS_LICENSE.txt` 随包保留；打开许可页时会先核对 Flutter 注册表，仅在自动清单缺失该组件时补充注册，避免漏项或重复展示。

历史双引擎方案见 `../docs/vibe/avplayer-media-kit-migration-2026-09-10_02-02-04.md`；该文档只用于追溯，不代表当前发布配置。

液态玻璃组件包声明要求 Flutter ≥ 3.41.0，工程原有 Dart SDK 约束继续保留；依赖与锁文件由 Flutter 工具生成维护。

全量替换范围及注意事项见 `../docs/vibe/liquid-glass-migration-2026-09-07_23-56-39.md`。原生视频、系统文件选择器、系统画中画及锁屏媒体界面由 iOS 承载。叠在原生视频上的玻璃使用组件库的兼容渲染路径，独立 Flutter 控件区域使用标准液态折射；实际合成效果和大量课程滚动性能需在设备上手动确认。

建议先手动验证两三个短视频的导入、播放与前后台切换，再导入真实课程；完整手动检查清单见 `../docs/vibe/full-player-implementation-2026-09-07_22-51-44.md`。

## 版本方向

- v1：初始化和功能搭建，重点为课程文件夹与播放流程。
- v2：基础功能稳定。
- v3：全部功能稳定。

当前不包含 Android、Web 或桌面端工程。

设置页提供跟随系统、浅色、深色外观，选择后立即生效并全局持久保存；首次安装默认使用深色主题，视频画面控制区保持深色。

AVPlayer 播放时会移除各轨道共同的前置空时间，使有效内容从 00:00 开始；该修正不依赖智能片头开关，不修改原文件，并在打开课程时换算旧播放进度。

设置中的“记住播放进度”默认开启，可手动关闭；关闭后不再更新播放点，再次打开课程从头播放，已有历史与收藏保留。
