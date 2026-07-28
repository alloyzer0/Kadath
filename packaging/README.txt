Kadath Runtime Package (Windows x64)
====================================

启动方式
--------
1. 保持本目录结构不变。
2. 进入 bin 目录并运行 kadath.exe；也可以直接双击 bin\kadath.exe。
3. 预览工具可使用 kadath.exe --scene assets\scenes\preview.scene --script assets\scripts\preview.script 启动场景和受限脚本 Hook。

纹理资产
--------
分发包的默认 source 是 `assets\renderer2d\test.png`，安装阶段始终以 release texture profile 生成 `test.texture` KDAT v2 mip chain。Texture Importer 保留 P3 PPM/PNG 两个私有 source Adapter，Runtime 只消费 KDAT，不直接解码 PNG/PPM。`bin\kadath-runtime-build-profile.json` 的 raw JSON root 必须是 Object，且属性名称大小写敏感、唯一并恰好为九项：`Version`、`Optimize`、`TextureProfile`、`RuntimeExeSha256`、`TextureSourceSha256`、`TextureArtifactSha256`、`VertexShaderSourceSha256`、`FragmentShaderSourceSha256` 与 `BuildPreflightSidecarSha256`。对于可通过 Runtime/archive gate 的 marker，`Version` 必须是可由 `GetInt32` 读取的 JSON number 1，其余八项必须是 JSON string；重复、额外、缺失、大小写错误或错误 ValueKind 均在 archive 首次写入和 Runtime 启动前拒绝。普通 no-sidecar developer marker 的 `BuildPreflightSidecarSha256=null` 是保留的 negative case，不能通过上述 gate。marker 不记录绝对路径或其 hash。
preflight sidecar 是 UTF-8 JSON：`Version=1`、UTC O-format `GeneratedAtUtc`，`PackageRoot`、`TaskLocalCacheDirectory`、`GlobalCacheDirectory` 为当次三个 canonical 本地绝对路径，并且 `PackageRootAbsentBefore`、`TaskLocalCacheAbsentBefore`、`GlobalCacheAbsentBefore` 均为 JSON boolean `true`。sidecar 必须位于三根与 Inner 之外，并在三根创建前写入；`GeneratedAtUtc` 与 sidecar `LastWriteTimeUtc` 的绝对差不得超过 2 秒，且二者都不得晚于任一 build root creation time 加 2 秒。最终 Runtime package 必须以 `-Druntime-preflight-sidecar=<absolute-sidecar>` 构建；build graph 校验 sidecar roots/timestamps 与 Zig 实际 install/local/global-cache roots，marker 记录 sidecar SHA-256。不传该 option 的普通开发构建会记录 null，不能归档或用于 Runtime 像素验收。
Runtime verifier 还要求独立的 strict UTF-8 JSON build-command evidence v1，字段恰好为 `Version`、`Executable`、`Arguments`、`WorkingDirectory`、`StartedAtUtc`、`EndedAtUtc`、`ExitCode`、`PackageRoot`、`TaskLocalCacheDirectory`、`GlobalCacheDirectory`。`Executable` 必须是当前 `Get-Command zig -CommandType Application` 的 canonical absolute Source，`WorkingDirectory` 必须 canonical exact 等于干净的 Inner `KadathRoot`，UTC O-format 时间必须满足 start <= end，exit 必须为 0，三个 root 必须与 verifier 调用一致。`Arguments` 精确冻结为 `build package -Doptimize=ReleaseSafe --prefix <package> --cache-dir <local-cache> --global-cache-dir <global-cache> -Druntime-preflight-sidecar=<sidecar>`；参数顺序、大小写和值均不得变化。command evidence 与 sidecar 都是运行前后 identity 的一部分。
`tools\verify-texture-png-runtime.ps1` 的 `BuildCommandEvidencePath`、`PreflightSidecarPath` 为 mandatory canonical regular file，且必须位于 repository、package、cache 与 evidence roots 之外。verifier 在启动 Runtime 前及其最终退出后，对 exe、marker、PNG、KDAT、两个 shader source、sidecar 和 command evidence 记录并严格比较稳定 `RelativePath` label、字节 `Length`、小写 `Sha256`、Windows `VolumeSerialNumber` 与 `FileIndexHigh/FileIndexLow`；同字节原子替换也会因文件对象身份变化而拒绝。identity 记录不包含绝对路径。任一 pre-launch gate 失败时，stderr 恰好包含一行 `runtime_start_attempted=false`；Runtime start 已尝试后的失败不得输出该行。

运行前置
--------
- Windows x64
- 支持 Vulkan 的 GPU 与已安装的 Vulkan 显卡驱动
- 不需要安装 Zig、Cargo/Rust、MinGW 或 Vulkan SDK

目录约束
--------
bin\kadath.exe 使用同目录下的 assets 读取纹理和 WAV 反馈音效（完整路径为 bin\assets）。
开发侧 `packaging\archive-runtime.ps1` 只接受 sidecar-bound `ReleaseSafe` package；Debug marker、null/非小写 64-hex `BuildPreflightSidecarSha256`、marker 缺失或 marker 与包内 exe/PNG/KDAT 身份不一致，均必须在首次写入前拒绝。PackageRoot、OutputDirectory 与 ExtractDirectory 必须是两两分离的本地绝对路径，不得互为祖先/后代，不接受 UNC、Win32 device 或 extended path alias；任一现存路径/ancestor 含 reparse point或输出已存在时同样提前拒绝。所有 pre-write gate 失败时，stderr 恰好包含一行 `archive_write_started=false`；首次输出写入已尝试后的内部失败不得误报该行。通过前置后，archive 从全文件身份一致的 owned package snapshot 生成 manifest/ZIP，并在成功或失败时清理该 staging；内部失败还会回滚本调用已确认拥有的 output/extract，不修改 PackageRoot、被替换的目录对象或其它 pre-existing 目录。
移动 exe 时必须同时保留 assets 目录及其相对位置。分发 Runtime 默认消费 `assets\scenes\preview.scene`（KSCN Scene Artifact v1）；源文件 `assets\scenes\preview.scene.json` 仅用于 Editor 导入和重新构建。运行中按 F5 可显式重载 authoring project 的 JSON 场景；Runtime 默认消费 `assets\scripts\preview.script`（KSCP Script Artifact v1）；源文件 `assets\scripts\preview.script.json` 仅用于 Editor authoring、重新导入和 JSON reload；按 F6 可事务式重载脚本文档，Scene restart/reload 仍会重新进入 `on_start`。Preview Launcher 可用 `-ReloadScriptAfterMilliseconds` 发送自动验证命令，也可用 `-WatchChanges` 开启文件轮询、debounce 和自动 Scene/Script reload（默认 100ms 轮询、250ms debounce）。需要机器可读响应时增加 `-StructuredStatus`，Launcher 会通过 WM_APP requestId 发送 reload，并输出 JSONL v1 的 ready、received、completed 和 stopping 事件。薄 GUI 可从仓库工具目录启动：`pwsh -NoProfile -File tools\editor-gui.ps1 -PackageRoot <package> -ProjectName <name>`；GUI 继续复用 Authoring CLI 和 Preview Launcher，不改变 Runtime 边界。Project Model v1、Hierarchy Snapshot v1、Asset Catalog Snapshot v1、只读 TreeView/Assets/Inspector 和真实 GUI workflow smoke 可使用仓库工具 `tools\verify-editor-gui-workflow.ps1 -PackageRoot <package>` 验证；资产目录也可用 `tools\verify-editor-asset-catalog.ps1 -PackageRoot <package>` 独立验证。GUI 不写 Runtime 状态、资产文件或直接编辑 JSON。Asset Tool Command v1 可用 `pwsh -NoProfile -File tools\editor-asset-tool.ps1 -Action Import -SourceRoot <source-assets> -StagingDirectory <new-staging> [-DryRun]` 生成隔离 staging 与 `asset-tool.manifest.json`；命令拒绝覆盖 `bin\assets`，不代表已完成真实 importer/baker。独立 verifier 为 `tools\verify-editor-asset-tool.ps1 -SourceRoot <source-assets>`。已验证的 staging 可使用 `pwsh -NoProfile -File tools\editor-asset-promote.ps1 -StagingDirectory <staging> -DestinationRoot <new-candidate> -Profile debug|release [-DryRun]` 生成候选资产包和 `bin\asset-promotion.manifest.json`；Promotion 拒绝覆盖现有 `bin\assets`，候选目录不包含 Runtime exe。Build Contract v1 可用 `pwsh -NoProfile -File tools\editor-asset-build-contract.ps1 -CandidateRoot <candidate> -ContractDirectory <new-contract> -Profile debug|release [-DryRun]` 生成 `asset-build.contract.json`，显式记录 artifact type、工具版本和 importer/baker 状态；Script JSON -> KSCP Script Artifact v1 与 Scene JSON -> KSCN Scene Artifact v1 已由 build 安装阶段自动执行；Texture Importer 的 P3 PPM/PNG 私有 source Adapter 支持 KDAT Texture Artifact v1/v2（debug base-only；release mipmap profile）；当前固定 build/install 仅从 test.png 生成 release KDAT v2。RIFF PCM WAV→Canonical PCM WAV Artifact v1 已由 build 安装阶段自动执行，独立 verifier 分别为 `tools\verify-editor-texture-importer.ps1` 和 `tools\verify-editor-audio-importer.ps1`。Runtime 对纹理、音频、场景和脚本分别消费 release `test.texture`、`*.audio.wav`、`preview.scene` 与 `preview.script` 派生 artifact；源文件保留用于 Catalog、GUI authoring 和重新导入。KDAT v2 的 mip chain 会由 Resource→Renderer2D→Vulkan RHI 完整上传，release 默认请求 `smooth_mipmap_anisotropic` sampler policy（linear min/mag/mip、LOD 0..N-1、支持设备上 4x anisotropy；不支持时降级为 `smooth_mipmap`）；可用 `tools\verify-texture-mip-upload.ps1 -PackageRoot <package>` 验证。

Scene importer/baker 可用 `pwsh -NoProfile -File tools\editor-scene-importer.ps1 -SourcePath <scene.json> -DestinationPath <new.scene> -Profile debug|release [-DryRun]` 执行，独立 verifier 为 `tools\verify-editor-scene-importer.ps1`。Script importer/baker 可用 tools\editor-script-importer.ps1 执行，独立 verifier 为 tools\verify-editor-script-importer.ps1；Runtime 证据 verifier 为 tools\verify-script-artifact-runtime.ps1。GUI 项目仍保持 JSON authoring 与热重载边界，不直接编辑或覆盖 package/bin/assets。

当前包不包含安装器、自动更新、代码签名或跨平台运行时。

Live Bake / Watch（Editor 工具）
-------------------------------
项目 Preview 可显式启用 artifact-first live workflow：
  pwsh -NoProfile -File tools\editor-author.ps1 -Action Preview -PackageRoot <package> -ProjectName <name> -LiveBake -WatchChanges -StructuredStatus

`-LiveBake` 会在 Runtime 启动前把项目 `scene.json` / `script.json` bake 到 `bin\projects\<name>\.kadath\derived\scene.scene` 与 `script.script`，并将 Runtime 参数只在内存中切换到派生 artifact。`-WatchChanges` 继续控制是否持续监听；不传时只执行启动 bake。默认 profile 为 debug，可用 `-BakeProfile release` 显式选择。

`.live-bake.manifest.json` 记录 source/artifact SHA-256、相对路径、格式和工具版本。source hash 与 manifest 匹配时复用 artifact；运行中 bake 失败会输出 `live_bake_failed`，保留最近成功 artifact/manifest，且不发送 reload。成功时依次输出 `live_bake_completed`、`command_requested(source=live_bake)` 和 `command_response`。live 派生目录不进入 Asset Catalog、promotion、archive，也不得写入 `bin\assets`。 P2-M4-27A 继续输出 runtime_reload_requested，随后按 Runtime 终态输出 runtime_reload_acknowledged、runtime_reload_failed 或 runtime_reload_stale；旧 command_response 保持兼容。

GUI 的 `Live Bake` 复选框默认关闭；与默认开启的“自动监听”同时选中即可启用 live bake/watch。独立 adapter verifier：
  pwsh -NoProfile -File tools\verify-editor-live-bake.ps1 -PackageRoot <package>

Editor Service / Avalonia Client（P2-M4-26A—P2-M4-27A）
-------------------------------------------------
Editor Service 是 Avalonia/CLI/兼容 WinForms 共用的本地编排层，使用 stdio JSONL，不监听网络端口：
  dotnet editor\Kadath.Editor.Service\bin\Debug\net8.0\Kadath.Editor.Service.dll --kadath-root <KadathRoot>

客户端先接收 `hello` 并发送 `hello_ack`，再使用 `get_capabilities`、`project_open`、`project_validate`、`bake_start`、`watch_start` / `watch_stop`、`preview_start` / `preview_stop` 和 `shutdown`。Service 内部复用现有 importer/live-bake/Preview adapter，前端不需要知道 staging、manifest、WM_APP 或 Runtime 参数。

P2-M4-26B—P2-M4-27A 的共享组件：
- `editor\Kadath.Editor.Client`：stdio transport、typed request correlation、迟到 response 丢弃、严格 event sequence、EOF/shutdown/dispose 关闭通知；
- `editor\Kadath.Editor.ViewModels`：Project/Authoring/Publication/Bake/Watch/Preview 状态、最小 Bake Changes target、artifact retention、capability gating 和 UI dispatcher；
- `editor\Kadath.Editor.Avalonia`：Desktop 壳、Live Bake/Watch、external-window Preview 状态和事件日志；Live Bake/Watch 默认关闭并保持 opt-in，View 不直接读取 JSON、artifact 或 PowerShell。

构建整个 Editor solution：
  dotnet build editor\Kadath.Editor.sln --no-restore -m:1 -p:NuGetAudit=false

启动桌面客户端：
  dotnet run --project editor\Kadath.Editor.Avalonia\Kadath.Editor.Avalonia.csproj

受限离线构建在项目内关闭 NuGet vulnerability feed 与 Avalonia 用户级 telemetry 写入；联网 CI 可显式重新开启 NuGet audit。自动 smoke 不打开可见桌面窗口：
  pwsh -NoProfile -File tools\verify-editor-avalonia.ps1 -EditorRoot <KadathRoot>\editor
  pwsh -NoProfile -File tools\verify-editor-avalonia-workflow.ps1 -PackageRoot <package>
  pwsh -NoProfile -File editor\verify-editor-client-service.ps1 -PackageRoot <package>

真实 Avalonia workflow smoke 跨越共享 Client/Workspace 和 Editor Service，验证 open、snapshot/publication、authoring、Bake Changes、watch start/stop、带 Live Bake/Watch 的 Preview external-window、Runtime source/artifact revision acknowledgement 和 shutdown。26A wire workflow 仍可独立验证：
  pwsh -NoProfile -File tools\verify-editor-rpc-workflow.ps1 -PackageRoot <package>

各命令/事件的外部 wire contract 与共享 module seam 独立记录在工作区 docs\superpowers\contracts\p2-m4-26\README.md；Runtime reload acknowledgement 扩展单独记录在 docs\superpowers\contracts\p2-m4-27\README.md。变更字段、事件、错误码、关闭/retention/stale 语义或兼容策略时必须同步对应契约和 verifier。

Preview v1 只公布 `external-window` surface 元数据，不通过 RPC 传送像素。`shared-texture` / `frame-stream` 尚未实现。26C 已通过 `project_snapshot`、`hierarchy_snapshot`、`asset_catalog_snapshot`、`publication_snapshot` 将真实 project model、8 节点 hierarchy 和当前 fixture 的 10 项 asset catalog 投影到 Avalonia；查询为只读，失败保留 Workspace 最近成功快照。现有 PowerShell/WinForms 入口继续可用，正式 package、`bin\assets`、Asset Catalog、promotion 和 archive 不因 Service、Avalonia 或 live bake 改变。
P2-M4-26C/26D/26E Snapshot、Authoring Transaction 与 Publication State 验证：在仓库根 Kadath 下执行 dotnet build editor\Kadath.Editor.sln --no-restore -m:1 -p:NuGetAudit=false、dotnet run --project editor\Kadath.Editor.Client.ContractVerifier --no-build、pwsh -NoProfile -File tools\verify-editor-snapshot.ps1 -PackageRoot (Resolve-Path zig-out).Path、pwsh -NoProfile -File tools\verify-editor-authoring-transaction.ps1 -PackageRoot (Resolve-Path zig-out).Path、pwsh -NoProfile -File tools\verify-editor-publication-snapshot.ps1 -PackageRoot (Resolve-Path zig-out).Path、pwsh -NoProfile -File editor\verify-editor-client-service.ps1 -PackageRoot (Resolve-Path zig-out).Path 和 pwsh -NoProfile -File tools\verify-editor-avalonia-workflow.ps1 -PackageRoot (Resolve-Path zig-out).Path。外部字段、版本、事件、错误码和路径边界见 ..\docs\superpowers\contracts\p2-m4-26\snapshot-queries-v1.md、authoring-transactions-v1.md、publication-snapshot-v1.md 与 publication-state-seam-v1.md。
P2-M4-26D Authoring Transactions
--------------------------------
Editor Service 的 authoring 写入只允许通过独立的 `authoring_apply` / `authoring_undo` RPC；Avalonia 不直接编辑 JSON。Apply/Undo 必须携带 Project Snapshot 的 `authoringRevision`（64-hex SHA-256），stale revision 返回 `authoring_revision_conflict`，非法 vector patch 返回 `invalid_authoring_patch`。Service 在 Scene/Script source pair 上执行原子写入、提交后重新生成 Project/Hierarchy Snapshot，并在当前 session 保留最多 32 条 undo；失败、冲突或空 undo 不覆盖最近成功内容。

Authoring mutation 只作用于 `bin\projects\<name>\scene.json` / `script.json`，不写 `.kadath\derived`、`bin\assets`、Asset Catalog、promotion candidate 或 package archive；Apply 成功也不会隐式 bake/reload。正式 package 构建和 archive 仍沿用既有 release 流程。独立外部契约见 `..\docs\superpowers\contracts\p2-m4-26\authoring-transactions-v1.md`、`authoring-apply-v1.md` 与 `authoring-undo-v1.md`；独立 verifier：
  pwsh -NoProfile -File tools\verify-editor-authoring-transaction.ps1 -PackageRoot <package>

真实 Avalonia workflow smoke 额外覆盖 `workflow_authoring_apply=ok` 与 `workflow_authoring_undo=ok`。26D 稳定事务契约不因 26E 改变。

P2-M4-26E Publication State / Bake Changes
------------------------------------------
`publication_snapshot` 只读比较 source JSON、`.kadath\derived` manifest 和 KSCN/KSCP artifact，返回 Scene/Script 的 `current`、`source_dirty`、`missing`、`artifact_invalid` 或 `profile_mismatch`。Avalonia 的 `Bake Changes` 使用共享 Workspace 选择最小 Scene/Script/Both target；Service Watch 或 Preview Live Bake + Watch 运行时，手动 bake 被禁用/拒绝，避免交错提交。

Bake Changes 只执行 source → derived，不隐式 Runtime reload；失败保留最近成功 artifact。正式 `bin\assets`、catalog、promotion 和 archive 保持不变。独立 verifier：
  pwsh -NoProfile -File tools\verify-editor-publication-snapshot.ps1 -PackageRoot <package>

真实 Avalonia workflow 额外覆盖 `workflow_publication_missing=ok`、`workflow_publication_dirty=ok` 与 `workflow_bake_changes=ok`。外部 wire/module 契约见 `..\docs\superpowers\contracts\p2-m4-26\publication-snapshot-v1.md` 和 `publication-state-seam-v1.md`。
P2-M4-27A Preview Runtime Reload Acknowledgement
------------------------------------------------
Preview Launcher 为 Scene/Script 独立关联 Runtime requestId、source SHA-256、live-bake artifact SHA-256/bytes 与 completion。Editor Service 在保留 preview_status 的同时，对外发布 preview_reload_requested、preview_reload_acknowledged、preview_reload_failed、preview_reload_stale。只有 acknowledged 推进 Runtime loaded revision；rejected/timeout 保留最近 acknowledged identity；旧 requestId 的迟到响应只记 stale。

Avalonia 的 Runtime sync 状态与兼容 WinForms 日志消费同一语义。该扩展不新增 Runtime IPC，继续使用 reload_scene / reload_script；不改变正式 bin\assets、catalog、promotion、archive 或 Bake Changes 的 source → derived 边界。验证：

  dotnet run --project editor\Kadath.Editor.Client.ContractVerifier --no-build
  pwsh -NoProfile -File tools\verify-preview-protocol-quality.ps1 -PackageRoot <package>
  pwsh -NoProfile -File tools\verify-editor-rpc-workflow.ps1 -PackageRoot <package>
  pwsh -NoProfile -File tools\verify-editor-avalonia-workflow.ps1 -PackageRoot <package>
  pwsh -NoProfile -File tools\verify-editor-gui-workflow.ps1 -PackageRoot <package>

关键输出为 preview_reload_ack_state=ok、runtime_reload_ack=ok、preview_reload_ack=ok、workflow_preview_reload_ack=ok 与 workflow_reload_acknowledged=2。外部 wire/module 契约见 ..\docs\superpowers\contracts\p2-m4-27\README.md。
