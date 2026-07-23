Kadath Runtime Package (Windows x64)
====================================

启动方式
--------
1. 保持本目录结构不变。
2. 进入 bin 目录并运行 kadath.exe；也可以直接双击 bin\kadath.exe。
3. 预览工具可使用 kadath.exe --scene assets\scenes\preview.scene --script assets\scripts\preview.script 启动场景和受限脚本 Hook。

运行前置
--------
- Windows x64
- 支持 Vulkan 的 GPU 与已安装的 Vulkan 显卡驱动
- 不需要安装 Zig、Cargo/Rust、MinGW 或 Vulkan SDK

目录约束
--------
bin\kadath.exe 使用同目录下的 assets 读取纹理和 WAV 反馈音效（完整路径为 bin\assets）。
移动 exe 时必须同时保留 assets 目录及其相对位置。分发 Runtime 默认消费 `assets\scenes\preview.scene`（KSCN Scene Artifact v1）；源文件 `assets\scenes\preview.scene.json` 仅用于 Editor 导入和重新构建。运行中按 F5 可显式重载 authoring project 的 JSON 场景；Runtime 默认消费 `assets\scripts\preview.script`（KSCP Script Artifact v1）；源文件 `assets\scripts\preview.script.json` 仅用于 Editor authoring、重新导入和 JSON reload；按 F6 可事务式重载脚本文档，Scene restart/reload 仍会重新进入 `on_start`。Preview Launcher 可用 `-ReloadScriptAfterMilliseconds` 发送自动验证命令，也可用 `-WatchChanges` 开启文件轮询、debounce 和自动 Scene/Script reload（默认 100ms 轮询、250ms debounce）。需要机器可读响应时增加 `-StructuredStatus`，Launcher 会通过 WM_APP requestId 发送 reload，并输出 JSONL v1 的 ready、received、completed 和 stopping 事件。薄 GUI 可从仓库工具目录启动：`pwsh -NoProfile -File tools\editor-gui.ps1 -PackageRoot <package> -ProjectName <name>`；GUI 继续复用 Authoring CLI 和 Preview Launcher，不改变 Runtime 边界。Project Model v1、Hierarchy Snapshot v1、Asset Catalog Snapshot v1、只读 TreeView/Assets/Inspector 和真实 GUI workflow smoke 可使用仓库工具 `tools\verify-editor-gui-workflow.ps1 -PackageRoot <package>` 验证；资产目录也可用 `tools\verify-editor-asset-catalog.ps1 -PackageRoot <package>` 独立验证。GUI 不写 Runtime 状态、资产文件或直接编辑 JSON。Asset Tool Command v1 可用 `pwsh -NoProfile -File tools\editor-asset-tool.ps1 -Action Import -SourceRoot <source-assets> -StagingDirectory <new-staging> [-DryRun]` 生成隔离 staging 与 `asset-tool.manifest.json`；命令拒绝覆盖 `bin\assets`，不代表已完成真实 importer/baker。独立 verifier 为 `tools\verify-editor-asset-tool.ps1 -SourceRoot <source-assets>`。已验证的 staging 可使用 `pwsh -NoProfile -File tools\editor-asset-promote.ps1 -StagingDirectory <staging> -DestinationRoot <new-candidate> -Profile debug|release [-DryRun]` 生成候选资产包和 `bin\asset-promotion.manifest.json`；Promotion 拒绝覆盖现有 `bin\assets`，候选目录不包含 Runtime exe。Build Contract v1 可用 `pwsh -NoProfile -File tools\editor-asset-build-contract.ps1 -CandidateRoot <candidate> -ContractDirectory <new-contract> -Profile debug|release [-DryRun]` 生成 `asset-build.contract.json`，显式记录 artifact type、工具版本和 importer/baker 状态；Script JSON -> KSCP Script Artifact v1 与 Scene JSON -> KSCN Scene Artifact v1 已由 build 安装阶段自动执行；P3 PPM→KDAT Texture Artifact v1/v2（debug base-only；release mipmap profile）与 RIFF PCM WAV→Canonical PCM WAV Artifact v1 已由 build 安装阶段自动执行，独立 verifier 分别为 `tools\verify-editor-texture-importer.ps1` 和 `tools\verify-editor-audio-importer.ps1`。Runtime 对纹理、音频、场景和脚本分别消费 release `test.texture`、`*.audio.wav`、`preview.scene` 与 `preview.script` 派生 artifact；源文件保留用于 Catalog、GUI authoring 和重新导入。KDAT v2 的 mip chain 会由 Resource→Renderer2D→Vulkan RHI 完整上传，release 默认请求 `smooth_mipmap_anisotropic` sampler policy（linear min/mag/mip、LOD 0..N-1、支持设备上 4x anisotropy；不支持时降级为 `smooth_mipmap`）；可用 `tools\verify-texture-mip-upload.ps1 -PackageRoot <package>` 验证。

Scene importer/baker 可用 `pwsh -NoProfile -File tools\editor-scene-importer.ps1 -SourcePath <scene.json> -DestinationPath <new.scene> -Profile debug|release [-DryRun]` 执行，独立 verifier 为 `tools\verify-editor-scene-importer.ps1`。Script importer/baker 可用 tools\editor-script-importer.ps1 执行，独立 verifier 为 tools\verify-editor-script-importer.ps1；Runtime 证据 verifier 为 tools\verify-script-artifact-runtime.ps1。GUI 项目仍保持 JSON authoring 与热重载边界，不直接编辑或覆盖 package/bin/assets。

当前包不包含安装器、自动更新、代码签名或跨平台运行时。

Live Bake / Watch（Editor 工具）
-------------------------------
项目 Preview 可显式启用 artifact-first live workflow：
  pwsh -NoProfile -File tools\editor-author.ps1 -Action Preview -PackageRoot <package> -ProjectName <name> -LiveBake -WatchChanges -StructuredStatus

`-LiveBake` 会在 Runtime 启动前把项目 `scene.json` / `script.json` bake 到 `bin\projects\<name>\.kadath\derived\scene.scene` 与 `script.script`，并将 Runtime 参数只在内存中切换到派生 artifact。`-WatchChanges` 继续控制是否持续监听；不传时只执行启动 bake。默认 profile 为 debug，可用 `-BakeProfile release` 显式选择。

`.live-bake.manifest.json` 记录 source/artifact SHA-256、相对路径、格式和工具版本。source hash 与 manifest 匹配时复用 artifact；运行中 bake 失败会输出 `live_bake_failed`，保留最近成功 artifact/manifest，且不发送 reload。成功时依次输出 `live_bake_completed`、`command_requested(source=live_bake)` 和 `command_response`。live 派生目录不进入 Asset Catalog、promotion、archive，也不得写入 `bin\assets`。

GUI 的 `Live Bake` 复选框默认关闭；与默认开启的“自动监听”同时选中即可启用 live bake/watch。独立 adapter verifier：
  pwsh -NoProfile -File tools\verify-editor-live-bake.ps1 -PackageRoot <package>

Editor Service / Avalonia Client（P2-M4-26A/26B）
-------------------------------------------------
Editor Service 是 Avalonia/CLI/兼容 WinForms 共用的本地编排层，使用 stdio JSONL，不监听网络端口：
  dotnet editor\Kadath.Editor.Service\bin\Debug\net8.0\Kadath.Editor.Service.dll --kadath-root <KadathRoot>

客户端先接收 `hello` 并发送 `hello_ack`，再使用 `get_capabilities`、`project_open`、`project_validate`、`bake_start`、`watch_start` / `watch_stop`、`preview_start` / `preview_stop` 和 `shutdown`。Service 内部复用现有 importer/live-bake/Preview adapter，前端不需要知道 staging、manifest、WM_APP 或 Runtime 参数。

P2-M4-26B/26C 的共享组件：
- `editor\Kadath.Editor.Client`：stdio transport、typed request correlation、迟到 response 丢弃、严格 event sequence、EOF/shutdown/dispose 关闭通知；
- `editor\Kadath.Editor.ViewModels`：Project/Bake/Watch/Preview 状态、artifact retention、capability gating 和 UI dispatcher；
- `editor\Kadath.Editor.Avalonia`：Desktop 壳、Live Bake/Watch、external-window Preview 状态和事件日志；Live Bake/Watch 默认关闭并保持 opt-in，View 不直接读取 JSON、artifact 或 PowerShell。

构建整个 Editor solution：
  dotnet build editor\Kadath.Editor.sln --no-restore -m:1 -p:NuGetAudit=false

启动桌面客户端：
  dotnet run --project editor\Kadath.Editor.Avalonia\Kadath.Editor.Avalonia.csproj

受限离线构建在项目内关闭 NuGet vulnerability feed 与 Avalonia 用户级 telemetry 写入；联网 CI 可显式重新开启 NuGet audit。自动 smoke 不打开可见桌面窗口：
  pwsh -NoProfile -File tools\verify-editor-avalonia.ps1 -EditorRoot <KadathRoot>\editor
  pwsh -NoProfile -File tools\verify-editor-avalonia-workflow.ps1 -PackageRoot <package>
  pwsh -NoProfile -File editor\verify-editor-client-service.ps1 -PackageRoot <package>

真实 Avalonia workflow smoke 跨越共享 Client/Workspace 和 Editor Service，验证 open、validate、bake、watch start/stop、带 Live Bake 的 Preview external-window 生命周期和 shutdown。26A wire workflow 仍可独立验证：
  pwsh -NoProfile -File tools\verify-editor-rpc-workflow.ps1 -PackageRoot <package>

各命令/事件的外部 wire contract 与 `IEditorRpcTransport` / `IEditorRpcClient` / `EditorWorkspaceViewModel` module seam 独立记录在工作区 `docs\superpowers\contracts\p2-m4-26\README.md`。变更字段、事件、错误码、关闭语义或兼容策略时必须同步对应契约和 verifier。

Preview v1 只公布 `external-window` surface 元数据，不通过 RPC 传送像素。`shared-texture` / `frame-stream` 尚未实现。26C 已通过 `project_snapshot`、`hierarchy_snapshot`、`asset_catalog_snapshot` 将真实 project model、8 节点 hierarchy 和当前 fixture 的 10 项 asset catalog 投影到 Avalonia；查询为只读，失败保留 Workspace 最近成功快照。现有 PowerShell/WinForms 入口继续可用，正式 package、`bin\assets`、Asset Catalog、promotion 和 archive 不因 Service、Avalonia 或 live bake 改变。
P2-M4-26C/26D Editor Snapshot 与 Authoring Transaction 验证：在仓库根 Kadath 下执行 dotnet build editor\Kadath.Editor.sln --no-restore -m:1 -p:NuGetAudit=false、dotnet run --project editor\Kadath.Editor.Client.ContractVerifier --no-build、pwsh -NoProfile -File tools\verify-editor-snapshot.ps1 -PackageRoot (Resolve-Path zig-out).Path、pwsh -NoProfile -File tools\verify-editor-authoring-transaction.ps1 -PackageRoot (Resolve-Path zig-out).Path、pwsh -NoProfile -File editor\verify-editor-client-service.ps1 -PackageRoot (Resolve-Path zig-out).Path 和 pwsh -NoProfile -File tools\verify-editor-avalonia-workflow.ps1 -PackageRoot (Resolve-Path zig-out).Path。外部字段、版本、事件、错误码和路径边界见 ..\docs\superpowers\contracts\p2-m4-26\snapshot-queries-v1.md 与 authoring-transactions-v1.md；下一步 26E 评估 Apply 后 bake/reload 编排、redo 或持久化 history。
P2-M4-26D Authoring Transactions
--------------------------------
Editor Service 的 authoring 写入只允许通过独立的 `authoring_apply` / `authoring_undo` RPC；Avalonia 不直接编辑 JSON。Apply/Undo 必须携带 Project Snapshot 的 `authoringRevision`（64-hex SHA-256），stale revision 返回 `authoring_revision_conflict`，非法 vector patch 返回 `invalid_authoring_patch`。Service 在 Scene/Script source pair 上执行原子写入、提交后重新生成 Project/Hierarchy Snapshot，并在当前 session 保留最多 32 条 undo；失败、冲突或空 undo 不覆盖最近成功内容。

Authoring mutation 只作用于 `bin\projects\<name>\scene.json` / `script.json`，不写 `.kadath\derived`、`bin\assets`、Asset Catalog、promotion candidate 或 package archive；Apply 成功也不会隐式 bake/reload。正式 package 构建和 archive 仍沿用既有 release 流程。独立外部契约见 `..\docs\superpowers\contracts\p2-m4-26\authoring-transactions-v1.md`、`authoring-apply-v1.md` 与 `authoring-undo-v1.md`；独立 verifier：
  pwsh -NoProfile -File tools\verify-editor-authoring-transaction.ps1 -PackageRoot <package>

真实 Avalonia workflow smoke 现在额外覆盖 `workflow_authoring_apply=ok` 与 `workflow_authoring_undo=ok`。下一步 P2-M4-26E 只在产品确认后评估 Apply 后 bake/reload 编排、redo 或持久化 history，不改变 26D 稳定契约。