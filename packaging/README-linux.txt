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

资产
----
- `assets/renderer2d/test.texture`：TextureId 1；
- `assets/renderer2d/goal.texture`：TextureId 2；
- `assets/audio/won.audio.wav` 与 `lost.audio.wav`：规范 PCM WAV；
- `assets/scenes/preview.scene`：KSCN v1；
- `assets/scripts/preview.script`：KSCP v1。

完整性
------
正式 archive 根目录包含 `SHA256SUMS`。请从 archive 根执行：

`sha256sum -c SHA256SUMS`

本包只声明 Linux x86_64 Runtime 产品能力，不包含 Linux Editor、Wayland、installer 或完整跨平台验收声明。
