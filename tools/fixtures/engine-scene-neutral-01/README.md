# Engine Scene Neutral 01 fixture

这是 Scene v7 中立模式的产品级最小样例。它只声明普通 Sprite，不声明 `gameplay`，因此没有 Player、Goal、Hazard、胜负、倒计时或 Gameplay 音频语义。

验证 Editor 工作流时，把本目录复制为安装包内的 `bin/projects/engine-scene-neutral-01`。`mover` 的 Behavior 在 Neutral fixed-step 中持续移动，并通过 `runtime-marker` Prototype 生成一个瞬态对象；瞬态对象约三秒后自毁，用于证明 Object/Phase/Behavior/Render 的完整生命周期仍然工作。

验收观察：窗口首先显示两个普通 Sprite，随后出现第三个瞬态 marker，约三秒后回到两个对象；`mover` 应持续水平移动。Runtime 日志应包含 `Behavior on_start hooks applied to neutral scene objects=2` 与 `Runtime host initialized with Vulkan RHI neutral scene objects=2`，且不应出现 GameSession、Outcome 或 Gameplay Audio 记录。
