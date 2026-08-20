# P2 PowerShell 工具链迁移

## 目标

`P2-PowerShell-Toolchain-Migration-01` 删除仓库内全部 43 个 `.ps1`，同时保留它们曾经承载的产品契约与证据 oracle。迁移后的 Windows build/package/editor/runtime 验证路径不再启动 `powershell` 或 `pwsh`。

本任务不把脚本逐行翻译成新的浅包装；规则分别进入已有的 Zig、C# Workspace/Service 与专用 Windows Adapter。

## 模块边界

| 模块 | 拥有的职责 | 不拥有的职责 |
|---|---|---|
| `Kadath.Editor.Toolchain` | 严格 PNG/WAV/Scene codec 调用、源快照、cold-build preflight、build profile、Windows Runtime archive | Editor RPC、窗口像素、产品运行时规则 |
| Zig Behavior Tooling | Script v2 清单、Luau 分析/编译、KSCP v2、Host Interface v3 | 文件归档、Editor UI |
| C# Workspace/Service | Project Create/Open/Validate、Catalog、Authoring、Publication、Preview 生命周期、真实 stdio RPC | Vulkan/Win32 像素判定 |
| Avalonia | Windows 原生 Editor 工作流与 UI 投影 | 直接读写 Runtime 私有状态 |
| `Kadath.Runtime.Windows.ContractVerifier` | 真实 HWND/Vulkan 像素、按键、Restart、Player 移动、Won、Audio Cue、WM_CLOSE、进程树清理及证据落盘 | 产品构建与 artifact 生成 |

## Windows 产品工具入口

以下命令中的目标路径必须是绝对本地路径；输出使用 no-replace 语义。

### 资产导入

```text
dotnet Kadath.Editor.Toolchain.dll import <texture|audio|scene|script> <source> <destination> --profile <debug|release> --no-overwrite
```

Windows 产品包的 Script v2 不走 legacy `script` codec，而由 `kadath-behavior-tool.exe` 从 `packaging/runtime-assets/script.json` 构建。

### cold-build 见证

```text
dotnet Kadath.Editor.Toolchain.dll preflight <package-root> <local-cache> <global-cache> <destination> --no-overwrite
```

生成时三个被见证根必须都不存在且互不包含。sidecar 固定为 strict UTF-8 v1 exact-eight，记录 UTC 时间、规范路径和三个 absent witness。

### PNG 源快照

```text
dotnet Kadath.Editor.Toolchain.dll snapshot <source> <destination> --barrier <directory|-> --fault <mode|-> --no-overwrite
```

源文件必须为 `1..(8 MiB - 1)` 字节。实现持有稳定源句柄，以 `CreateNew + Flush(true) + no-replace move` 发布；失败清理按 Windows Volume/File ID 判定所有权，绝不按相同路径、长度或哈希误删 replacement。

### Runtime build profile

```text
dotnet Kadath.Editor.Toolchain.dll build-profile <runtime> <texture-source> <texture-artifact> <secondary-source> <secondary-artifact> <vertex-shader> <fragment-shader> <optimize> <package-root> <local-cache> <global-cache> <preflight|-> <destination> --no-overwrite
```

profile 固定为 strict UTF-8 v2 exact-eleven。Release archive 必须是 sidecar-bound `ReleaseSafe`，且 exe、两组 PNG/KDAT、两份 shader 与 marker 哈希全部一致。

### Windows Runtime archive

```text
dotnet Kadath.Editor.Toolchain.dll archive <package-root> <output-dir> <extract-dir> <kadath-root> --policy <kscp-v1|kscp-v2> --barrier <directory|-> --no-overwrite
```

主产品也可使用：

```text
zig build archive-windows-runtime -Doptimize=ReleaseSafe -Druntime-preflight-sidecar=<sidecar> -Druntime-archive-output-dir=<new-dir> -Druntime-archive-extract-dir=<new-dir>
```

KSCP v2 Windows 包固定为 18 项：旧 v1 的 15 项，加上 `behavior-tools/kadath-behavior-tool.exe`、`patrol.luau` 和 `player_controller.luau`。PDB、陈旧 `test.ppm` 或任何未知 extra 都 fail-closed。归档事务冻结完整源文件集，只从 retained handles 复制到 owned staging；ZIP 时间、entry 顺序和 manifest 均确定，成功前后复验 live package。

## Editor 与验证入口

```text
dotnet run --project editor/Kadath.Editor.Workspace.ContractVerifier -c <Debug|Release>
dotnet run --project editor/Kadath.Editor.Service.ContractVerifier -c <Debug|Release>
dotnet run --project editor/Kadath.Editor.Client.ContractVerifier -c <Debug|Release>
dotnet run --project editor/Kadath.Editor.Client.ContractVerifier -c <Debug|Release> -- --real-service-only <service-dll> <kadath-root> <package-root>
dotnet run --project editor/Kadath.Editor.Avalonia -c <Debug|Release> -- --headless-smoke
dotnet run --project editor/Kadath.Editor.Avalonia -c <Debug|Release> -- --workflow-smoke-owned <kadath-root> <package-root>
dotnet run --project editor/Kadath.Editor.Toolchain.ContractVerifier -c <Debug|Release> -- <kadath-root>
dotnet run --project editor/Kadath.Runtime.Windows.ContractVerifier.ContractVerifier -c <Debug|Release> -- <package-root>
dotnet run --project editor/Kadath.Runtime.Windows.ContractVerifier -c Release -- <package-root> <new-evidence-directory>
```

Runtime contract verifier 对 exact-18、未知 extra/PDB、Host Interface v3、ReleaseSafe sidecar 与 JSONL 失败分类执行无窗口故障注入；它不能替代下一条真实 HWND/Vulkan 产品验证。`--workflow-smoke-owned` 自行创建唯一项目 fixture，复制 Script v2 声明的 Luau 依赖，并在 finally 中只清理本次受控目录。真实 stdio Client verifier 同样自己取得和验证 fixture 所有权，调用方不再托管清理。

## 失败语义

- preflight、snapshot、profile、archive 和 Editor publication 都拒绝覆盖现有目标。
- 首次 archive 产品写入前失败，stderr 必须包含且只包含一条 `archive_write_started=false` 见证行；不得推进 output 或 extract。
- artifact、manifest、Preview loaded identity 和 Runtime 状态只在完整成功后推进。
- owned cleanup 必须验证路径边界、reparse point 与真实文件身份；replacement 或 foreign claim 必须保留。
- archive 对 output/extract 的全部目录持有 Windows R oplock；最终双树复验后，只有一次原子检查确认全部 oplock 未 break，事务才提交。提交前的成员变化必须 fail-closed。
- Window verifier 的环境缺失单独报告 `BLOCKED_ENV`；Null RHI、解析器或交叉编译不得替代 Windows HWND/Vulkan PASS。
- Runtime 启动已尝试后的失败保存首个因果错误、stdout/stderr、package identity、窗口/像素证据和最终清理状态。

## 删除裁决

实施前的逐脚本消费者表记录在 Outer 文档 `docs/superpowers/specs/2026-08-18-windows-baseline-powershell-active-consumer-audit.md`。删除按以下闸门执行：

1. `build.zig` 不再引用脚本或嵌入 PowerShell；Windows package 实际执行新的 snapshot/import/profile。
2. KSCP v2 exact-18 cold package 与可复现 archive 通过。
3. Workspace、Service、Client、Avalonia 和 Toolchain ContractVerifier 在 Windows Debug/Release 通过。
4. 真实 Windows Window/Vulkan 产品 verifier 通过，或对真实环境缺失给出 `BLOCKED_ENV`，不得用 headless 代替。
5. 仓库活动文件中 `rg --files -g '*.ps1'` 为零；活动构建和产品文档不再把 PowerShell 当作入口。
