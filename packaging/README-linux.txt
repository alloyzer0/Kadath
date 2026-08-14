Kadath Runtime Package (Linux x86_64)
=====================================

启动方式
--------
1. 保持目录结构不变。
2. 进入 `bin` 目录并运行 `./kadath`。
3. 若要加载随包 Scene/Script，运行：
   `./kadath --scene assets/scenes/preview.scene --script assets/scripts/preview.script`

运行依赖
--------
- x86_64 Linux 与 glibc；
- XCB；
- Vulkan loader 和一个支持 XCB surface/present 的 Vulkan ICD；
- ALSA runtime（`libasound.so.2`）和一个可打开的 PCM 设备；PipeWire/Pulse 可通过 ALSA compatibility 提供默认设备；
- 可用的 X11 DISPLAY。

包内不携带 Vulkan ICD、validation layer、X server、Zig、Rust、PowerShell、libpng 或源码树。
`libpng` 仅用于构建阶段生成 KDAT，不是 Runtime 动态依赖。
若默认 PCM 设备不可用，Runtime 会记录 warning 并降级为 silent；可用 `KADATH_AUDIO_DEVICE` 指定 ALSA PCM 名称。

Editor 诊断工具
--------------
- `behavior-tools/kadath-behavior-tool` 是供 Kadath Editor Service 调用的 Luau 行为脚本工具；
- Editor Service 通过有界 stdin/stdout frame 使用 `--analyze-stdin`，可分析未保存缓冲区而不创建临时 `.luau` 文件；
- 该工具不等于完整 Linux Editor，本包仍不携带 .NET、Avalonia 或 Editor Service。

资产
----
- `assets/renderer2d/test.texture`：TextureId 1；
- `assets/renderer2d/goal.texture`：TextureId 2；
- `assets/audio/won.audio.wav` 与 `lost.audio.wav`：规范 PCM WAV；
- `assets/scenes/preview.scene`：KSCN v5，对两个 Patrol Hazard 声明 Behavior Binding；
- `assets/scripts/preview.script`：聚合 KSCP v2，包含默认 `patrol.luau`；
- `assets/scenes/preview.scene.json`、`assets/scripts/preview.script.json` 与 `assets/scripts/patrol.luau`：Linux 默认行为项目的 source dependency set，不是 Runtime 启动输入。

完整性
------
正式 archive 根目录包含 `SHA256SUMS`。请从 archive 根执行：

`sha256sum -c SHA256SUMS`

本包只声明 Linux x86_64 Runtime 产品能力，不包含 Linux Editor、Wayland、installer 或完整跨平台验收声明。

仓库开发验证说明
----------------
Linux Runtime 包的默认资产由 Zig + Luau tooling 生成 KSCN v5/KSCP v2，不依赖 PowerShell。Editor Service 的 legacy v4/v1 Publication 路径继续兼容旧项目；包内只携带受控 Behavior Tool，不包含完整 Linux Editor。
