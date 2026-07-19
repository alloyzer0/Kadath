Kadath Runtime Package (Windows x64)
====================================

启动方式
--------
1. 保持本目录结构不变。
2. 进入 bin 目录并运行 kadath.exe；也可以直接双击 bin\kadath.exe。
3. 预览工具可使用 kadath.exe --scene assets\scenes\preview.scene.json 启动指定场景。

运行前置
--------
- Windows x64
- 支持 Vulkan 的 GPU 与已安装的 Vulkan 显卡驱动
- 不需要安装 Zig、Cargo/Rust、MinGW 或 Vulkan SDK

目录约束
--------
bin\kadath.exe 使用同目录下的 assets 读取纹理和 WAV 反馈音效（完整路径为 bin\assets）。
移动 exe 时必须同时保留 assets 目录及其相对位置。预览场景为 `assets\scenes\preview.scene.json`，运行中按 F5 可显式重载该文件。

当前包不包含安装器、自动更新、代码签名或跨平台运行时。
