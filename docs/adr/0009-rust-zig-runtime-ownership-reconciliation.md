# ADR-0009: Rust / Zig Runtime Ownership 对账

## 元信息

- **状态**: 已采纳
- **日期**: 2026-08-21
- **决策者**: @alloyzer0
- **相关主题**: Phase 1 架构治理回环；Rust / Zig 高层 Runtime ownership
- **依赖**:
  - `ADR-0001`: 语言选型策略
  - `ADR-0002`: 构建系统与项目结构
  - `ADR-0003`: 跨语言边界规范
  - `ADR-0005`: 世界模型方向
  - `ADR-0006`: 编辑器与 Runtime 边界
  - `ADR-0008`: 调度 / 执行模型

---

## 背景

`ADR-0001`、`ADR-0005` 与 `ADR-0008` 在 Phase 1 确立了以下方向：

- Zig 负责 Platform、Memory、RHI 与底层系统互操作；
- Rust 负责 World、Scheduler、Gameplay 与复杂状态；
- World 以对象/实体导向语义对外，内部热点路径可以数据导向；
- Host 驱动 Runtime 生命周期和阶段顺序，但不吸收业务核心；
- Zig / Rust 通过少量、显式、可验证的 C ABI seam 协作。

这些决策没有规定 Rust 或 Zig 的代码行数比例。它们约束的是 **ownership 和 Interface**。

Phase 2 的实际演进形成了不同的重心：

- Zig Host、Platform、RHI、Renderer2D、Resource 先形成可运行产品主路径；
- Rust `world` 落地了 Sprite Entity 存储、fixed-step、spawn/despawn、position 与 render extraction；
- Rust `scheduler` 落地了单 worker 异步读取 tracer；
- 此后 Scene Generation、ObjectId→Entity 映射、collision/contact、GameSession、Behavior phase、事件、reload transaction、Runtime Object Registry、动态生命周期和结构提交主要落在 Zig；
- C# Editor/Workspace/Service/Avalonia 与 Luau/C++ Behavior VM 成为真实产品组成；
- “开发者主要直接调用 Rust API”不再描述当前 authoring 与 scripting 入口。

截至 `P2-Runtime-Object-Lifecycle-01` 候选 `bfc5504`，Rust 仍拥有底层 Sprite Entity 存储，但高层对象 authority 已分散在 Zig `SceneGeneration`、`BehaviorHost` 和 `RuntimeObjectRegistry`。这是可工作的产品实现，也是必须显式治理的架构漂移。

本 ADR 补充而不追溯改写旧 ADR：旧 ADR 保留当时的决策背景，本 ADR 记录 2026-08-21 的当前事实、目标 ownership 与迁移规则。

---

## 1. 术语

- **Ownership（所有权）**：某类运行时事实的唯一写入权威，包括其不变量、生命周期、错误和提交语义。它不是“哪个文件调用了哪个函数”。
- **Runtime Core（运行时核心）**：拥有 World 对象权威、生命周期、阶段事务、Gameplay 状态与只读输出快照的深 Module。
- **Host（宿主）**：拥有进程、平台事件、时钟、设备、产品生命周期和阶段调用时机的外层驱动者。
- **Object Authority（对象权威）**：ObjectId、Runtime Entity、generation、source/transient 身份和 stale 裁决的唯一来源。
- **Phase Commit（阶段提交）**：fixed/frame 阶段中对象 mutation、结构请求、事件和预算的接受、排序与提交规则。
- **Adapter（适配器）**：位于 C ABI、Luau VM、Renderer、Editor 或 Platform seam 的具体连接实现；Adapter 不复制被连接 Module 的业务状态机。
- **Current（当前态）**：当前已合并或已形成候选固定点的实现事实。
- **Target（目标态）**：迁移完成后应达到的 ownership；不得在代码完成前写成 Current。

---

## 2. 当前态

### 2.1 Zig 当前拥有

- Runtime 进程、主循环、Platform event pump、Clock 与阶段调用；
- Win32/XCB Platform、Vulkan RHI、Renderer2D、Audio；
- Resource I/O、artifact loader、package/archive 装配；
- Scene/KSCN/KSCP 解码与 Scene Generation；
- source ObjectId 到 Rust EntityId 的映射；
- Behavior fixed/update/event 调度、ObjectRef Adapter 与 Activation Overlay；
- Runtime Object Registry、transient ObjectId、generation、stale、spawn/despawn reservation；
- fixed/frame Structural Flush、对象/实例/结构/事件预算；
- contact query、GameSession 与部分 demo gameplay；
- reload/restart candidate 的外层事务编排。

### 2.2 Rust 当前拥有

- Sprite Entity 存储；
- spawn、replace、despawn；
- bounds 与 position；
- fixed-step 输入移动；
- render sprite extraction；
- Scheduler 的 bounded read worker 与 completion ownership。

### 2.3 其它语言当前拥有

- C#：Editor、Workspace、Publication、Service、Client、Avalonia；
- Luau：项目 Behavior source；
- C++：vendored Luau 与受限 native bridge；
- C ABI：Zig / Rust / C++ 之间的稳定外部契约。

### 2.4 当前问题

当前 Zig `SceneGeneration` 与 Rust `world` 共同参与对象状态，Zig `RuntimeObjectRegistry` 又拥有动态对象身份和 stale 语义。虽然具体字段尚未形成直接双写，但 Object Authority、Phase Commit 和 Gameplay ownership 已跨多个浅 Interface 分散：

- 新对象能力需要同时理解 Host、SceneGeneration、BehaviorHost、Registry、World Adapter 与 C++ bridge；
- Rust World 无法独立验证完整对象生命周期；
- 原 ADR 中“复杂状态归 Rust”的约束不再具备实施门禁；
- 后续 Physics、Component、Prefab 或更多 Behavior 能力会继续放大分散成本。

---

## 3. 决策

### 3.1 恢复 Rust Runtime Core

Kadath 采用 **Zig Host + Rust Runtime Core** 的目标结构：

- Zig Host 决定阶段何时发生，并拥有所有平台、设备和产品生命周期；
- Rust Runtime Core 决定阶段内 World 状态如何变化，并拥有对象、生命周期、事务和 gameplay 不变量；
- 两者通过稳定 C ABI + 版本化接口描述符形成粗粒度、可失败闭环的 Interface；
- Editor、Luau 和 Renderer 通过 Adapter 消费外部语义，不依赖 Rust 内部 layout。

该决策恢复 `ADR-0001/0005/0008` 的职责意图，但不要求回到早期“开发者直接编写 Rust API”的产品入口。当前开发者入口是 Scene Authoring + Luau Behavior；Rust 是其高层 Runtime 语义的内部权威实现。

### 3.2 不设置语言行数配额

不设置 Rust 占比、Zig 占比、文件数或提交数 KPI。验收只看：

- ownership 是否唯一；
- Runtime Core Interface 是否具有 Depth；
- 旧 Zig authority 是否在迁移完成后删除；
- 行为与产品证据是否等价；
- 新功能是否落在正确 Module。

机械翻译稳定代码、复制测试、增加无消费者抽象或提前建设通用 Scheduler，都不能作为架构对账成果。

### 3.3 Zig 长期 ownership

Zig 长期拥有：

1. Runtime executable、启动参数、退出码与进程生命周期；
2. Platform Window、Input Snapshot、Clock；
3. Vulkan RHI、Renderer2D、Audio device；
4. Resource I/O、artifact 装载、package/archive 产品装配；
5. Scene/KSCN/KSCP 的底层解码 Adapter；
6. Luau C++ bridge 的 Zig Adapter；
7. Preview control/status Adapter；
8. Rust Runtime Core C ABI Adapter；
9. Linux/Windows 产品矩阵入口与跨平台装配。

Zig Host 可以拥有 `fixed_dt`、frame timing、0..N fixed step 选择与调用顺序。它不得长期复制 Rust Runtime Core 的 ObjectId generation、结构队列、collision state、GameSession state 或对象生命周期 authority。

### 3.4 Rust 长期 ownership

Rust Runtime Core 长期拥有：

1. World、ObjectId、Runtime Entity 与 generation 的权威关系；
2. source object 与 transient object 的运行时生命周期；
3. spawn/despawn、stale ObjectRef 与 Behavior instance 生命周期；
4. fixed/frame phase mutation、结构请求、事件和预算的接受与提交；
5. restart/reload candidate 的 Runtime state prepare/commit/abort；
6. collision/contact 与纯 gameplay state；
7. 供 Renderer 消费的 caller-owned、只读、稳定、有界 snapshot；
8. 可独立执行的 Rust 单元、属性与失败路径测试。

Rust Runtime Core 不拥有 Window、Vulkan handle、RHI resource、Audio device、Editor document、项目文件路径、Luau VM 指针或 Preview transport。

### 3.5 C#、Luau 与 C++

- C# Editor 是 Runtime 外部容器，不违反 Runtime 核心采用 Zig + Rust 的决策；
- Luau 是项目 Behavior 语言，不成为引擎核心实现语言；
- C++ 仅用于 vendored Luau/native bridge Adapter，不扩张为 World、Gameplay、Resource 或 Renderer 实现；
- 新增第三方 native dependency 必须继续由明确 Adapter 隔离。

---

## 4. Runtime Core Interface

### 4.1 深 Module

Runtime Core 必须用少量 Interface 隐藏以下实现复杂度：

- ObjectId/Entity/generation 解析；
- source/transient 生命周期；
- phase queue、排序、预算和 failure domain；
- collision/gameplay；
- reload/restart transaction；
- render/event snapshot。

删除 Runtime Core 后，这些规则会重新散落到 Host、SceneGeneration、BehaviorHost、Registry 和测试中。该删除测试是 Module Depth 的基本门禁。

### 4.2 C ABI seam

Runtime Core 的外部 Interface 必须：

- 使用 opaque handle；
- 不引入构建产物级全局 ABI version；需要演进的 descriptor、callback table 和 snapshot 使用显式 `struct_size`，只有语义确实不兼容时才增加该 Interface 自己的 `interface_version`；
- 只传递纯 C POD、caller-owned buffer 和 bounded descriptor；
- 对 count、length、alignment、enum、reserved field 与 null 做完整 preflight；
- 保证错误返回前无未声明的部分提交；
- 捕获 Rust panic，不允许 unwind 穿越 ABI；
- 不传递 `Vec`、`String`、slice、trait object、Rust reference 或 allocator 私有状态。

首个代码增量再冻结具体函数表。本 ADR 只冻结能力类别：

1. create/destroy；
2. prepare/commit/abort Scene candidate；
3. begin/end fixed 或 frame phase；
4. ObjectRef resolve/read/mutate；
5. bounded structural/event submission；
6. restart/reload transaction；
7. render/event snapshot extraction。

### 4.3 Adapter 纪律

- Zig Adapter 负责类型转换、调用编排和错误映射，不复制 Runtime state machine；
- Luau ObjectRef 可以经 Zig Adapter 调用 Runtime Core，但 stale 与 mutation 合法性只有 Rust authority；
- Renderer 只消费 snapshot，不查询 World 内部容器；
- Editor 只消费 Scene/Publication/Preview 外部契约；
- Scheduler completion 只能在 Host 选择的受控同步点交给 Runtime Core。

---

## 5. 迁移策略

### 5.1 固定行为后迁移 ownership

`P2-Runtime-Object-Lifecycle-01` 候选 `bfc5504` 是首个迁移行为 oracle。它的单元、契约、Linux cold-cache、Window/package、Editor/stdio/Avalonia 证据用于证明迁移等价，而不是作为必须保留的 Zig 实现形状。

### 5.2 替换而不是叠层

迁移增量可以在分支内短暂同时存在旧 Adapter 和新 Adapter，但合并前必须删除已被替代的旧 authority。禁止长期存在：

- Zig Registry + Rust Registry；
- Zig generation + Rust generation；
- Zig structural queue + Rust structural queue；
- Zig GameSession + Rust GameSession 双写。

### 5.3 三个代码增量

#### A. `P1-Rust-Runtime-Core-Object-Authority-01`

- 进入条件：`P2-Runtime-Object-Lifecycle-01` 与本 ADR/C4 对账均已完成 Inner/Outer 合并，Outer gitlink 指向包含 `bfc5504` 和本 ADR 的固定点；
- 授权条件：单独完成该任务的 contract discovery，冻结最终 C Interface、文件级写集和产品矩阵，并收到独立 `GO_IMPLEMENT P1-Rust-Runtime-Core-Object-Authority-01`；
- 演进现有 Rust World 为 Runtime Core 起点；
- 迁移 ObjectId、Entity、generation、source/transient 关系；
- 迁移 Registry、spawn/despawn、stale 与 restart serial high-water；
- 迁移 Runtime 对象状态的 Scene candidate `prepare/commit/abort` 与 restart replacement；Zig Host 继续拥有文件读取、Scene/KSCN 解码、Texture Registry、Luau VM candidate 和跨 Module 的外层提交编排；
- Zig SceneGeneration/BehaviorHost 改为单一 Adapter；
- 删除对应 Zig authority；
- 保持 Scene/KSCN v6、Luau Interface、phase 顺序和产品行为；
- 候选文件级写集边界如下，后续 discovery 可以收窄；若需要增加该列表之外的生产路径，必须先修订并重新冻结契约：
  - `Cargo.toml`
  - `build.zig`
  - `abi/kadath_runtime_core.h`（新增）
  - `abi/kadath_world.h`（现有 World C Interface 被 Runtime Core 取代后删除或降为私有）
  - `modules/runtime_core/Cargo.toml`（新增）
  - `modules/runtime_core/build.rs`（新增）
  - `modules/runtime_core/src/lib.rs`（新增 Rust Core）
  - `modules/runtime_core/src/main.zig`（新增 Zig Adapter）
  - `modules/runtime_core/tests/public_contract.c`（新增 public C misuse seam）
  - `modules/runtime_core/tests/runtime_core_contract.zig`（新增 Zig Adapter contract）
  - `modules/world/Cargo.toml`
  - `modules/world/build.rs`
  - `modules/world/src/lib.rs`
  - `modules/world/src/main.zig`
  - `app/runtime_object_registry.zig`（被替代后删除）
  - `app/scene_generation.zig`
  - `app/behavior_host.zig`
  - `app/behavior_host_contract.zig`
  - `app/host.zig`
- 上述新文件名称是本 ADR 的候选 seam；后续 discovery 可以在不扩张职责的前提下改名或收窄，但任何新增生产路径必须修订并重新冻结契约，且不得扩张到 Editor、Preview、Packaging 或 Platform；
- 删除目标：Zig `RuntimeObjectRegistry`、`SceneGeneration.runtime_objects` 及其 ObjectId/generation/stale/spawn/despawn authority；BehaviorHost 的 phase queue 在本增量保留，避免与 Phase Commit 同时迁移；
- 产品等价门禁：Rust unit/property、public C misuse、Zig Scene/Behavior focused、Debug/ReleaseSafe、cold-cache、Linux Window/package、Editor/stdio/Avalonia 回归必须保持 `bfc5504` 行为；Windows 仍只由真实 Windows 环境验收。

#### B. `P1-Rust-Runtime-Core-Phase-Commit-01`

- 迁移 fixed/frame structural queue；
- 迁移对象、实例、结构和事件预算；
- 迁移 same-flush destroy、activation/despawn 和 phase generation；
- 保持 Host 决定调用时机。

#### C. `P1-Rust-Runtime-Core-Gameplay-01`

- 迁移 collision/contact authority；
- 迁移 Demo GameSession 与 Hazard/Goal/Player 纯逻辑；
- 输出只读 render/event snapshot；
- 使 render extraction 不承担 gameplay mutation。

#### C.1 2026-08-25 Gameplay implementation 分段澄清

`P1-Rust-Runtime-Core-Gameplay-01` 收到独立 `GO_IMPLEMENT` 后，按冻结并窄修订的contract将Gameplay作为同一opaque Runtime Core内的深Module实现：

- Rust唯一拥有session phase/timer/cause、outcome与step token high-water、previous contact ledger、strict Player↔source Goal/Hazard collision、legacy patrol、terminal priority和Player final tint；Zig只保留本次调用结果、caller-owned scratch与render count。
- Scene transaction必须配齐Object、Gameplay和ready Phase candidate后由Object commit一次发布。restart要求live Gameplay已terminal，保持epoch/source identity和sequence high-water；reload令epoch加一；两者都清空timer/contact transient state。
- fixed顺序为timer begin、terminal input suppression、Luau fixed/direct mutation、callback structural visibility settle、Rust movement、Rust contact、Hazard优先于Goal、全部contact end后全部begin、event/structural最终Phase settle、frame callback、Rust snapshot。contact event与普通fixed event共享既有64条Phase硬预算并fail closed。
- Rust public seam只暴露versioned C17 descriptor、capacity-1 outcome、step result与caller-owned bounded snapshot；不暴露VM、Renderer、Audio、Window或Editor类型。Host继续将successful outcome映射到一次Audio cue与一次日志，失败不反向写Gameplay。
- `SceneGeneration`改为堆上持有解码后的固定容量Scene，并通过指针进入prepare/restart/reload路径；legacy v4 decoder写入caller storage。该内存形状修复不改变Scene/KSCN/KSCP schema、wire、容量或Gameplay语义。
- 同一candidate删除`app/game.zig`、`app/collision.zig`及BehaviorHost/Host中的persistent contact、GameSession和final tint writer，遵循replace-not-layer。

### 5.3A 2026-08-21 Object Authority 分段澄清

`P1-Rust-Runtime-Core-Object-Authority-01` 的独立 contract discovery 已冻结以下分段；本节是 dated clarification，不改写上述长期 TARGET：

- 128 Runtime Object 是 Rust Object Authority 的物理 record storage hard limit，本增量随 ObjectId/Entity/generation/lifecycle 一并迁入 Rust；
- 256 Behavior Instance、fixed/frame 各 64 structural request、fixed/frame 各 64 event 与跨资源 admission 继续由 Zig `BehaviorHost` 持有，直到 `P1-Rust-Runtime-Core-Phase-Commit-01`；
- Object Authority 的 `ACTIVE_OBJECTS` 是供当前 Zig Adapter 消费的 coherent read view，不是 Gameplay 增量最终的 Rust render snapshot；
- 本增量仍由 Zig `SceneGeneration` 将 active Object View 投影为现有 `RenderSprite` POD，只有 `P1-Rust-Runtime-Core-Gameplay-01` 建立专用 Rust render snapshot 后才删除该投影；
- 上述临时分段不得形成 Zig/Rust 双写：Zig 不保存 object count、slot、logical generation、serial high-water、Entity 映射或 lifecycle writer，Rust 不接管 Behavior/queue/event/phase admission。

### 5.3B 2026-08-22 Phase Commit 分段澄清

`P1-Rust-Runtime-Core-Phase-Commit-01` 在收到独立 `GO_IMPLEMENT` 后，按已冻结 contract discovery 将 Phase Commit authority 从 Zig `BehaviorHost` 替换到同一 opaque Rust Runtime Core；本节记录目标态，不能在实现候选合并前反写为 CURRENT：

- Rust Core 唯一拥有 fixed/frame event queue、structural queue、event/structural sequence、dispatch generation、256 Behavior admission、每 domain 64 event 与 64 structural budget，以及 structural flush token、activation transaction、same-flush cancellation 和 failure domain；fixed/frame 两个 domain 的 state 完全隔离。
- Zig Host 继续拥有 clock、fixed accumulator、fixed-step 次数、frame timing、phase 调用时机、Luau VM/C++ bridge、callback 执行、ActiveSet 实例存储、callback-local staging、诊断、collision/contact observer、GameSession/gameplay 与 render projection；Adapter 只做 caller-owned POD 转换、调用编排和错误映射。
- Phase Interface 是 Object Authority v1 的独立 versioned descriptor，不复用 Object Authority mutation tags，不建立构建产物级 global ABI version，不暴露 VM pointer、Gameplay、Renderer、Window、Editor 或 scheduler API。
- `drain_events`/`take_structural` 只消费一个最低 generation bucket；Host 必须循环 drain → dispatch → submit successor → take/complete/activate，直至 queue 与 in-flight token 均为空。generation `0..8`、stale delivery drop、四个 64 budget、same-flush spawn→destroy 和 callback failure isolation 必须由 public C17 与 Zig consumer seam 观察。
- 同一 candidate 必须删除 Zig persistent `EventQueue`、`StructuralQueue`、`BehaviorAdmission`、phase `next_sequence` 与 generation writer；允许保留 callback-local staging，但不得保留第二个长期 ledger 或 queue mirror。
- Scene/KSCN/KSCP、Luau Host v4、Editor/Preview/Package wire、collision/gameplay authority、最终 Rust render snapshot 和 Scheduler 均不属于本增量；任何新增生产路径必须先回到 contract revision。

### 5.4 Scheduler

Scheduler 只有在出现第二个真实异步消费者，或 Runtime Core 需要统一 completion ingestion 时才扩张。禁止为了提高 Rust 占比提前引入线程池、`rayon`、`tokio`、async runtime 或通用 task graph。

---

## 6. 不变量

1. 同一运行时事实只有一个 writer authority；
2. Host 决定“何时推进”，Runtime Core 决定“状态如何推进”；
3. World/Runtime Core 不依赖 RHI、Window、Editor 或 Luau VM layout；
4. Renderer 只读 snapshot；
5. Editor source identity 与 Runtime Entity identity 分离；
6. ObjectRef 不保存裸指针或跨 reload EntityId；
7. 跨语言 Interface 必须可由纯 C header 完整描述；
8. 每个迁移增量必须删除旧 authority，不建立长期双核；
9. 每个迁移增量必须独立验证、提交和回退；
10. Linux 证据不能代理 Windows 产品验收。

---

## 7. 新模块语言选择门禁

新增或扩张 Runtime 模块时必须先回答：

1. 它是否拥有 World/Object/Gameplay/复杂阶段状态？若是，默认 Rust Runtime Core 内部实现；
2. 它是否直接拥有 OS、设备、GPU、Audio、文件 I/O 或产品装配？若是，默认 Zig；
3. 它是否只是连接外部系统与既有 Module？若是，作为 Adapter，不复制业务状态；
4. 它是否会产生高频跨语言往返？若是，优先重设计 coarse descriptor/batch/snapshot Interface，而不是把 ownership 随意移回调用侧；
5. 它是否要求新的 authority？若是，必须指出旧 authority 的删除点；
6. 它是否只是为了提高某语言占比？若是，拒绝。

任何偏离上述默认归属的实现都需要新的 contract discovery 或 dated ADR addendum。

---

## 8. 后果

### 正面影响

- 恢复 Rust 在复杂状态与实体生命周期上的实际学习和工程价值；
- Zig Host 回到高杠杆装配与平台职责，不继续增长为业务大对象；
- Object Authority、Phase Commit、collision/gameplay 的不变量可以在 Rust 内聚测试；
- C ABI 从零散 getter/setter 走向 coarse descriptor/batch/snapshot；
- 后续 Physics、Component、Prefab 和更多 Behavior 能力有明确落点。

### 负面影响

- 迁移期间需要同时理解当前 Zig 行为与目标 Rust Module；
- C ABI、bindgen、Zig Adapter 和双侧测试会增加短期工作量；
- 已验证 Zig 实现的一部分会在后续增量中被替换；
- 错误原子性、panic containment 与 caller-owned buffer 需要更严格公共契约测试；
- 迁移必须保持 WIP=1，不能与大规模新玩法并行扩张。

### 缓解措施

- 使用 `bfc5504` 作为行为固定点；
- 每次只迁移一个 authority cluster；
- 在同一 candidate 中删除旧 authority；
- 先跑 Rust/public C/Zig focused，再跑 Linux 产品矩阵；
- Windows 门禁留待真实 Windows 环境，不阻塞当前 Linux 开发迭代。

---

## 9. 拒绝方案

### 9.1 保持 Zig-first Runtime，只修改旧 ADR

拒绝作为当前方向。它会让 Rust World/Scheduler 成为成本高于价值的薄岛，并放弃原始双语言学习目标。若后续迁移实证表明 coarse C ABI 仍不可维护，可用新的 ADR 重新评审。

### 9.2 设置 Rust 行数目标

拒绝。LOC 不能证明 ownership、Depth、Locality 或产品价值。

### 9.3 把整个 Host、Platform 和 RHI 重写成 Rust

拒绝。稳定底层实现不需要为了语言平衡重写，且该方向违反原始语言分工。

### 9.4 立即一次性重写 Runtime

拒绝。World、Behavior、reload、collision、Editor 和 product packaging 同时变化会失去可定位性与回退点。

### 9.5 长期保留 Rust Core 与 Zig Core 双 authority

拒绝。Adapter 可以并存，authority 不能并存。

---

## 10. 与既有 ADR 的关系

- `ADR-0001`：保留 Zig/Rust 按职责分工；本 ADR 明确当前多语言产品事实、禁止 LOC KPI，并将 Rust 的高层职责收敛为内部 Runtime Core ownership；
- `ADR-0002`：继续由 `zig build` 顶层编排 Cargo；未来 Runtime Core crate 仍在 `modules/` 下，通过 `abi/` 暴露 C Interface；
- `ADR-0003`：全部 C ABI、ownership、panic、错误和线程规则继续有效；本 ADR 的“版本化接口描述符”不建立构建产物级全局 ABI version；
- `ADR-0005`：保留对象/实体导向外部语义和内部数据导向演进；开发者入口从“直接 Rust API”更新为 Scene/Luau/Editor Adapter，Rust Core 仍是 World authority；
- `ADR-0006`：Editor 继续位于 Runtime 外部，不访问 Rust 内部 layout；
- `ADR-0008`：保留双时钟和受控同步点；Zig Host 拥有 phase timing，Rust Runtime Core 逐步拥有 phase state transition。

---

## 11. 一句话结论

Kadath 采用 **“Zig Host 驱动平台与产品生命周期，Rust Runtime Core 统一拥有 World 对象、生命周期、阶段事务和 Gameplay 状态，通过稳定 C ABI + 版本化接口描述符输出 coarse snapshot”** 的目标架构；迁移按 Object Authority、Phase Commit、Gameplay 三个固定点替换旧 Zig authority，不设置语言行数配额，也不进行一次性重写。

---

## 12. 审阅记录

- 2026-08-21: 基于 `bfc5504`、现有 ADR/C4、Rust 代码历史和当前 ownership 审计形成初稿。
- 2026-08-21: 主导者确认先固定 Runtime Object Lifecycle candidate，再实施 Rust/Zig 架构对账；状态设为“已采纳”。
