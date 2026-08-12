# P2 Editor 行为脚本项目生命周期

## 目标

本阶段把行为脚本项目从“可以验证和发布”推进到“可以创建、打开、读取并展示”。
行为脚本使用 Luau 源文件，项目清单使用 Script v2，场景使用 Scene v5。

## 固定契约

- `script.json` 的 `schemaVersion=2` 是行为脚本清单，清单中的每个条目包含唯一的 `scriptId` 和 `scripts/*.luau` 源路径。
- `scene.json` 的 `schemaVersion=5` 在对象上声明 `behaviors`，每个绑定引用 `scriptId`，参数由稳定名称和值组成。
- `Create` 在模板校验通过后复制清单声明的全部 Luau 依赖；缺失依赖不得创建部分项目。
- `Open` 和 `Validate` 使用同一套项目边界与重解析点检查，且不修改项目树。
- `ReadModel` 的行为脚本快照保留 Scene v5、Script v2 版本，并公开脚本依赖和场景行为绑定。
- `Authoring` 接受完整 `SceneObjectDefinition` 行为绑定集合，可修改绑定参数；v5 场景始终以 v5 序列化，撤销恢复原始绑定。
- `WorkspaceScriptSourceAuthoringModel` 可按 `scriptId` 读取和修改单个 Luau 源文件，统一使用项目 `AuthoringRevision` 做乐观并发控制。
- Luau 源编辑采用同目录独占 staging 文件和原子替换；撤销只恢复仍由本次提交拥有的文件，外部修改必须报告修订冲突。
- v1 Hook 脚本仍保留原有 `GoalPosition` / `GoalVelocity` 投影；v2 行为脚本不伪造 Hook 指令，相关数组为空。
- v2 项目的 `AuthoringRevision` 使用场景字节哈希和完整脚本依赖集合修订，而不是只哈希 `script.json`。
- Behavior Tool 在提取参数和校验返回表时会执行 Luau 顶层代码；tooling VM 必须同时施加 2 MiB 内存上限和 100000 次中断预算，失控脚本只能使本次发布失败，不得无限占用 Editor Service。

## 实现位置

- 项目创建、依赖复制与有界清理：`editor/Kadath.Editor.Workspace/WorkspaceProjectLifecycleModel.cs`
- Script v2 清单、依赖读取与修订：`editor/Kadath.Editor.Workspace/WorkspaceScriptSourceModel.cs`
- Scene v5 行为绑定解析与模型转换：`editor/Kadath.Editor.Workspace/WorkspaceSceneDocument.cs`
- Scene v5 行为绑定 Authoring 与事务：`editor/Kadath.Editor.Workspace/WorkspaceAuthoringModel.cs`
- Luau 源文件读取、原子提交和撤销：`editor/Kadath.Editor.Workspace/WorkspaceScriptSourceAuthoringModel.cs`
- ReadModel 快照和 Hierarchy 投影：`editor/Kadath.Editor.Workspace/WorkspaceReadModel.cs`
- Editor RPC DTO：`editor/Kadath.Editor.Protocol/Contracts.cs`
- Editor Service 路由：`editor/Kadath.Editor.Service/EditorRpcHost.cs`
- Editor Client 调用：`editor/Kadath.Editor.Client/EditorRpcClient.cs`
- 生命周期与脚本源端到端验证：`editor/Kadath.Editor.Client.ContractVerifier/Program.cs`

## 已验证项

- Workspace Contract Verifier：`verification=ok`
- Service Contract Verifier：`verification=ok`
- 行为项目创建后可被 `ReadProjectAsync` 和 `ReadHierarchyAsync` 读取。
- Hierarchy 会展示 `ScriptDependency`、`SceneBehavior` 和 `BehaviorParameter` 节点。
- 依赖缺失、创建中途失败和所有权清理边界保持失败闭环。
- v5 行为参数修改不会降级为 v4，也不会在撤销时丢失绑定顺序和参数值。
- Luau 源修改会更新完整项目 `AuthoringRevision`；旧修订、未知 `scriptId`、超出 64 KiB 和撤销前外部修改均被拒绝。
- 真实 stdio RPC 已覆盖 `script_source_read`、`script_source_edit`、`script_source_undo`，并验证过期修订和空撤销错误码。
- Luau tooling 已覆盖顶层无限循环和超预算内存分配失败路径。
- Linux Debug、ReleaseSafe、cold-cache、负向路径和 ReleaseSafe 完整产品包矩阵均已通过；包验收覆盖归档清单、ELF 依赖、窗口像素、ALSA、静音回退和有界退出清理。

## 当前边界

本阶段完成 Workspace、Editor Service RPC 与 Client 的脚本源编辑能力，但尚未提供 Avalonia 代码编辑器或运行时脚本调试器；UI 接入和调试器仍是后续独立切片。
当前候选已完成 Linux 固定点验收；跨平台 UI 接入和脚本调试器不属于本候选边界。
