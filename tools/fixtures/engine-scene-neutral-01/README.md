# Engine Scene Neutral 01 fixture

这是 Scene v7 中立模式的产品级最小样例。它只声明普通 Sprite，不声明 `gameplay`，因此没有 Player、Goal、Hazard、胜负、倒计时或 Gameplay 音频语义。

验证 Editor 工作流时，把本目录复制为安装包内的 `bin/projects/engine-scene-neutral-01`。`script.json` 仅用于兼容当前 Editor Project v1 的固定三文件结构；因为 Scene 没有 Behavior 绑定，Runtime 不会加载或执行它。

验收观察：窗口应显示两个普通 Sprite；Runtime 日志应包含 `Runtime host initialized with Vulkan RHI neutral scene objects=2`，且不应进入 Gameplay lifecycle。
