# P2 Editor 行为脚本项目生命周期

## 目标

本阶段把行为脚本项目从“可以验证和发布”推进到“可以创建、打开、读取、编辑，并在 Editor 内管理脚本资产生命周期”。
行为脚本使用 Luau 源文件，项目清单使用 Script v2，场景使用 Scene v5。

## 固定契约

- `script.json` 的 `schemaVersion=2` 是行为脚本清单，清单中的每个条目包含唯一的 `scriptId` 和 `scripts/*.luau` 源路径。
- `scene.json` 的 `schemaVersion=5` 在对象上声明 `behaviors`，每个绑定引用 `scriptId`，参数由稳定名称和值组成。
- `Create` 在模板校验通过后复制清单声明的全部 Luau 依赖；缺失依赖不得创建部分项目。
- `Open` 和 `Validate` 使用同一套项目边界与重解析点检查，且不修改项目树。
- `ReadModel` 的行为脚本快照保留 Scene v5、Script v2 版本，并公开脚本依赖和场景行为绑定。
- `Authoring` 接受完整 `SceneObjectDefinition` 行为绑定集合，可修改绑定参数；v5 场景始终以 v5 序列化，撤销恢复原始绑定。
- Avalonia 对象草稿必须无损保留 `ProjectModelSceneObject.Behaviors`；修改位置、尺寸、颜色、纹理或对象顺序时，必须按原顺序和参数重新提交绑定，不得把已有绑定误序列化为空集合。
- Avalonia 必须区分 v4 原生 `patrol` 字段与 v5 `behaviors` 字段；v5 不显示或提交已废弃的原生 Patrol 参数，v4 继续保持原有编辑语义。
- Avalonia 在 Script v2 项目中从 Hierarchy 的 `ScriptDependency` 加载 Luau 源码，提供 UTF-8 文本编辑、保存、放弃修改、重新读取和脚本源码撤销；Script v1 项目继续显示 Hook 编辑区，不展示行为脚本源码编辑区。
- Editor 对当前未保存的 Script Buffer Snapshot 使用 `projectName + scriptId + sourceHash` 关联结构化诊断；RPC request id 只用于传输关联，不能覆盖内容身份。
- Native `kadath_luau_analyze` 遵循 ADR-0003 的 `int32_t` 错误码契约：只有 `KADATH_OK` 表示分析完整执行，源码 valid/invalid 由结果状态表达；输入、内存或内部失败使用稳定 `KADATH_ERR_*`，所有输入输出指针仅在调用期间借用且结果由调用方持有。
- Native Luau Tooling 对同一源码依次执行严格 Analysis、compile、受限顶层执行、参数提取和 Behavior Table 校验；源码错误返回稳定的 `stage / code / message / range`，不要求 C# 解析英文错误文本。
- `script_source_analyze` 是无副作用 typed RPC；每个 Editor Session 只允许一个分析进程在途，第二个请求立即返回 busy，Host shutdown 必须取消并收割活动分析。
- 共享诊断 ViewModel 使用 400 ms debounce、一个在途加一个 pending latest，并按 project generation、`scriptId`、`sourcePath` 和 `sourceHash` 丢弃过期结果。
- 诊断为 invalid 不禁用源码保存；Publication 仍重新读取磁盘依赖并独立验证，Live Bake 失败必须保留旧 KSCP、manifest 与 Runtime Script Package identity。
- 公开诊断位置使用 1-based、end-exclusive、Unicode scalar-value column；Avalonia 只在展示边界把它转换成 .NET UTF-16 caret index。
- 脚本源码保存必须携带已加载文档的 `AuthoringRevision`；修订冲突不得覆盖外部修改，也不得丢弃 Avalonia 中尚未保存的源码缓冲区。
- 场景 Authoring、脚本源码 Authoring 与脚本资产生命周期共用项目修订，但各自保留独立撤销历史；只有当前全局最新操作所属的栈可撤销，顺序错误返回 `*_history_diverged`，按真实逆序退回后较早历史重新可用。
- 脚本资产生命周期提供 Create、Rename、Delete 与 Undo；Workspace 分配当前 Manifest 中最小的未使用正 `scriptId`，重命名保持 ID、顺序、源码字节和 Scene Binding，删除拒绝仍被引用的资产与最后一个依赖。
- 生命周期事务统一校验 `scripts/*.luau` 受控路径、portable case 冲突、orphan、reparse point、revision 和文件 ownership；第一项文件发布后不再响应取消，失败补偿必须尝试全部 owned rollback 动作。
- `WorkspaceScriptSourceAuthoringModel` 可按 `scriptId` 读取和修改单个 Luau 源文件，统一使用项目 `AuthoringRevision` 做乐观并发控制。
- Luau 源编辑采用同目录独占 staging 文件和原子替换；撤销只恢复仍由本次提交拥有的文件，外部修改必须报告修订冲突。
- v1 Hook 脚本仍保留原有 `GoalPosition` / `GoalVelocity` 投影；v2 行为脚本不伪造 Hook 指令，相关数组为空。
- v2 项目的 `AuthoringRevision` 使用场景字节哈希和完整脚本依赖集合修订，而不是只哈希 `script.json`。
- Behavior Tool 在提取参数和校验返回表时会执行 Luau 顶层代码；tooling VM 必须同时施加 2 MiB 内存上限和 100000 次中断预算，失控脚本只能使本次发布失败，不得无限占用 Editor Service。
- Behavior Host Interface v2 新增 `kadath.input.move_axis() -> (number, number)`；它只在 Hook 期间读取当前 fixed-step 的不可变规范化输入，`on_start` 固定观察 `0,0`，顶层 Tooling 执行调用必须失败。
- Native `KadathLuauInputSnapshot` 由调用方拥有、仅在 `kadath_luau_instance_fixed_update` 调用期间借用；null 或超出 `-1 / 0 / 1` 的轴值必须在 Luau 与 Command Buffer 产生副作用前失败，Hook 退出和失败路径均清除活动输入上下文。
- Scene v5 Player 存在任意 Behavior Binding 时，Host 把 World 的移动输入清零并把原始 gated input 交给全部 Behavior Binding；无 Binding 或 Scene v4 时继续由 Native World 移动，脚本失败不得隐式恢复 Native fallback。
- 默认 Linux 产品固定包含 `scriptId=1 / patrol.luau` 与 `scriptId=2 / player_controller.luau`，Player 绑定后者且保留 `moveSpeed=180`；因此默认项目中新建 Script Asset 的最小可用 ID 为 `3`。
- KSCP 物理格式保持 v2，但 `host_interface_version` 推进到 `2`；Runtime 与 Editor 必须拒绝 Host v1 artifact 并要求重新 Bake，不能降级运行或推进 Preview loaded identity。

## 实现位置

- 项目创建、依赖复制与有界清理：`editor/Kadath.Editor.Workspace/WorkspaceProjectLifecycleModel.cs`
- Script v2 清单、依赖读取与修订：`editor/Kadath.Editor.Workspace/WorkspaceScriptSourceModel.cs`
- Scene v5 行为绑定解析与模型转换：`editor/Kadath.Editor.Workspace/WorkspaceSceneDocument.cs`
- Scene v5 行为绑定 Authoring 与事务：`editor/Kadath.Editor.Workspace/WorkspaceAuthoringModel.cs`
- Avalonia Scene 对象草稿、v4/v5 边界与行为绑定无损回传：`editor/Kadath.Editor.Avalonia/ViewModels/SceneObjectDraftViewModel.cs`、`editor/Kadath.Editor.Avalonia/ViewModels/AvaloniaEditorViewModel.cs`
- Avalonia 行为脚本源码状态、命令与界面：`editor/Kadath.Editor.ViewModels/EditorScriptSourceViewModel.cs`、`editor/Kadath.Editor.ViewModels/EditorWorkspaceViewModel.cs`、`editor/Kadath.Editor.Avalonia/ViewModels/AvaloniaEditorViewModel.cs`、`editor/Kadath.Editor.Avalonia/Views/MainWindow.axaml`
- Native 结构化诊断 ABI 与 Luau 共享管线：`modules/behavior_script/native/kadath_luau.h`、`modules/behavior_script/native/tooling_bridge.cpp`、`modules/behavior_script/src/tooling.zig`
- Behavior Input Native Runtime Adapter、Tooling 类型和 Host version：`modules/behavior_script/native/runtime_bridge.cpp`、`modules/behavior_script/native/tooling_bridge.cpp`、`modules/behavior_script/src/runtime.zig`、`modules/behavior_script/src/artifact.zig`
- Player movement ownership 与 Host 输入路由：`app/player_movement_ownership.zig`、`app/host.zig`、`app/behavior_host.zig`
- 默认 Player Controller、Scene Binding 与 Linux package：`packaging/linux-assets/scripts/player_controller.luau`、`packaging/linux-assets/preview.scene.json`、`packaging/linux-assets/preview.script.json`、`build.zig`
- 单帧 stdin/stdout 分析 Adapter：`tools/behavior-script-tool.zig`
- 未保存缓冲区校验、受控 Tool 解析、进程超时与协议验证：`editor/Kadath.Editor.Workspace/WorkspaceScriptDiagnosticsModel.cs`
- typed RPC、后台 Host 生命周期与 Service 路由：`editor/Kadath.Editor.Protocol/Contracts.cs`、`editor/Kadath.Editor.Core/IEditorSession.cs`、`editor/Kadath.Editor.Service/EditorRpcHost.cs`、`editor/Kadath.Editor.Service/WorkspaceEditorBackend.cs`
- debounce、single-flight、pending-latest 与 stale-result 淘汰：`editor/Kadath.Editor.ViewModels/EditorScriptDiagnosticsViewModel.cs`
- Avalonia 中文状态、诊断列表、重新分析和光标跳转：`editor/Kadath.Editor.Avalonia/ViewModels/AvaloniaEditorViewModel.cs`、`editor/Kadath.Editor.Avalonia/Views/MainWindow.axaml`
- Luau 源文件读取、原子提交和撤销：`editor/Kadath.Editor.Workspace/WorkspaceScriptSourceAuthoringModel.cs`
- Script v2 Manifest/source Create、Rename、Delete、Undo 与事务回滚：`editor/Kadath.Editor.Workspace/WorkspaceScriptAssetLifecycleModel.cs`
- ReadModel 快照和 Hierarchy 投影：`editor/Kadath.Editor.Workspace/WorkspaceReadModel.cs`
- Editor RPC DTO：`editor/Kadath.Editor.Protocol/Contracts.cs`
- Editor Service 路由：`editor/Kadath.Editor.Service/EditorRpcHost.cs`
- Editor Client 调用：`editor/Kadath.Editor.Client/EditorRpcClient.cs`
- 生命周期与脚本源端到端验证：`editor/Kadath.Editor.Client.ContractVerifier/Program.cs`

## 已验证项

- Workspace Contract Verifier：`verification=ok`
- Service Contract Verifier：`verification=ok`
- Native/Behavior Runtime contract 已覆盖 Tooling 类型可见、顶层调用失败、`on_start=0,0`、null/越界输入零输出、同一步多 Binding 共享输入、失败 Hook 上下文清理，以及 Host v1 artifact 拒绝。
- Player movement ownership contract 已覆盖 Scene v4、Scene v5 无 Player Binding、Scene v5 任意 Player Binding 三条路由；多 Binding 继续按 Scene 顺序产生 additive translation，脚本失败保持 fail-closed。
- 默认产品已迁移到两个 Script v2 dependency 和 Host Interface v2；Linux XCB 真实按键通过 `player_controller.luau` 驱动 Player 到达 Goal，并保留 Won 状态、Audio Cue 与 Patrol Hazard 行为。
- Workspace、真实 stdio Service、Client、Avalonia headless 与 Xvfb 工作流均按 `scriptId/sourcePath` 选择两个 Behavior Contract；Player Controller 源码读取、in-use 删除保护、下一资产 ID `3` 和绑定保留均已验证。
- 行为项目创建后可被 `ReadProjectAsync` 和 `ReadHierarchyAsync` 读取。
- Hierarchy 会展示 `ScriptDependency`、`SceneBehavior` 和 `BehaviorParameter` 节点。
- 依赖缺失、创建中途失败和所有权清理边界保持失败闭环。
- v5 行为参数修改不会降级为 v4，也不会在撤销时丢失绑定顺序和参数值。
- Avalonia 在 Scene v5 中修改非行为字段后，Apply、快照刷新和 Undo 均保持每个对象的行为绑定签名；v4 原生 Patrol 草稿仍保留原生 Patrol 语义。
- Avalonia headless smoke 已覆盖 v4 原生 Patrol 与 v5 行为绑定草稿投影；真实 workflow 已覆盖 Scene v5 的 Apply、刷新和 Undo 无损回归。
- Avalonia headless smoke 已覆盖脚本源码共享 ReadModel；真实 stdio workflow 已覆盖从 `ScriptDependency` 自动加载、保存、撤销、修订冲突保留未保存缓冲区，以及受控 fixture 恢复。
- Luau 源修改会更新完整项目 `AuthoringRevision`；旧修订、未知 `scriptId`、超出 64 KiB 和撤销前外部修改均被拒绝。
- 真实 stdio RPC 已覆盖 `script_source_read`、`script_source_edit`、`script_source_undo`，并验证过期修订、空撤销错误码，以及场景、脚本源码与脚本资产生命周期历史独立保留、只能按全局真实逆序撤销；顺序错误会稳定返回 `*_history_diverged`，不会覆盖较新的编辑。
- Workspace 已覆盖脚本资产 Create/Rename/Delete/Undo、最小 ID、1–16 容量、引用中/最后依赖拒绝、portable case/orphan/reparse 路径、十个提交阶段故障、提交后取消、终态 ownership 丢失和补偿继续执行。
- Client/ViewModel/Avalonia 已覆盖四命令 capability、dirty buffer/in-flight 门控、原子 Snapshot 投影、选择与诊断 generation 刷新、失败保留，以及 `history_diverged` 后 Undo 深度不被错误清空。
- 真实 Xvfb 工作流已覆盖新建脚本、修改源码、绑定玩家、Bake/Preview 后真实执行、绑定不变的重命名与二次 Bake/Preview、引用中删除拒绝、解除绑定后删除，以及跨 Authoring/Source/Lifecycle 栈的完整真实逆序 Undo。
- Runtime 的既有 `runtime_log` 投影现在识别 Debug/ReleaseSafe 均存在的 `info` 日志；产品工作流通过 `player_position` 证据确认新脚本 `on_start` 在两次 Preview 中均真实生效，不新增 Runtime command 或 JSONL 协议。
- Luau tooling 已覆盖顶层无限循环和超预算内存分配失败路径。
- Native、Adapter 与 Workspace 已覆盖多条 Analysis error、嵌入 NUL、严格 UTF-8、scalar range、32 条诊断上限、64 KiB frame、非法 JSON/schema、超时、取消、kill-tree 与无 orphan 失败路径。
- Native public seam 已覆盖同一输入的完整结果 byte-for-byte 确定性、LF/CRLF、BMP 与 supplementary-plane scalar column，以及 compiler-limit 到 `compile / LUAU_COMPILE_ERROR` 的短路分类。
- Workspace 已确定性覆盖 cooperative wait → entire-tree kill 后仍无法确认退出的 `Cleanup` 分支；Service 使用真实 Host 验证最终 RPC code 为 `script_source_analysis_cleanup_failed` 且 started 后只有一个 failed 终态。
- Service Host 已覆盖 analyze-only 后台调度、并发 busy、保存/项目切换不阻塞、shutdown/EOF 取消收割，以及 started 后恰好一个 completed/failed terminal event。
- Client/共享 ViewModel 已覆盖 capability fallback、100 次快速输入仅保留最新内容、一个在途加一个 pending、过期结果丢弃、分析失败保留仍匹配结果，以及无效 UTF-16 不发送 RPC。
- Avalonia headless smoke 已覆盖中文状态、诊断列表、重新分析、scalar → UTF-16 光标转换和 `preview_status` 内嵌事件名投影。
- 真实 stdio/Xvfb 产品工作流已覆盖未保存 invalid 诊断、允许保存、Live Bake 拒绝并保留旧 KSCP/manifest/Runtime identity，随后修复、重新发布并由 Preview reload acknowledgement 推进 identity。
- Debug Runtime 在默认 8 MiB Linux 线程栈下已通过真实 Scene v5 + KSCP v2 启动；Behavior Runtime 的 Package/ActiveSet 与 Host 本体改为明确堆所有权，消除 Debug 大型值返回造成的启动栈溢出，不改变 Runtime/Preview 协议。
- 单次进程 Adapter 各预热 3 次后分别执行 40 次：valid p95 为 45.336 ms，invalid p95 为 38.342 ms，均低于 150 ms 门槛。
- Linux Debug、ReleaseSafe、cold-cache、负向路径和 ReleaseSafe 完整产品包矩阵均已通过；包验收覆盖归档清单、ELF 依赖、窗口像素、ALSA、静音回退和有界退出清理。
- Standards / Spec 双轴审查发现的 ABI、资源 ownership 与验收覆盖问题已全部修复；复核无阻断问题。

## 当前边界

本阶段已提供 Avalonia 基础 Luau 源码编辑器、未保存缓冲区结构化诊断和单资产 Create/Rename/Delete/Undo，但不包含语法高亮、自动补全、LSP、调试器、多标签页、文件夹树、批量操作或诊断 range 波浪线；这些能力仍是后续独立切片。
诊断通过不授权保存、Bake 或 Runtime reload；保存后热发布继续由既有 opt-in Live Bake/Preview Watch 链路负责。
当前候选的验收边界是 Linux 上的 Host Interface v2、Player movement ownership、共享 ViewModel、Avalonia 编译资源、真实 stdio RPC/Xvfb 源码工作流与现有产品矩阵；不包含完整 Input Action、键位配置、鼠标、手柄、多玩家输入或新的输入 Hook。跨平台窗口验收不属于本候选边界。
