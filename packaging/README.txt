Kadath Windows Runtime 包（KSCP v2 exact-18）
============================================

运行目录
--------

本包面向原生 Windows x64。包根目录记为 `<package-root>`，Runtime 的工作目录固定为
`<package-root>\bin`，入口为 `bin\kadath.exe`。请保持 `bin`、`bin\assets` 与
`behavior-tools` 的相对位置不变。

```text
cd <package-root>\bin
kadath.exe
```

运行真实窗口需要可用的 Windows 桌面会话、Vulkan 驱动和音频设备。构建工具只用于生成、
归档和验证产品包；运行 `bin\kadath.exe` 本身不要求安装 Zig 或 .NET SDK。

产品 artifact 契约
-----------------

- `bin\assets\scenes\preview.scene.json` 是 Scene authoring 源，
  `bin\assets\scenes\preview.scene` 是 Runtime 消费的 KSCN v5 artifact。
- `bin\assets\scripts\preview.script.json` 声明 Script v2 项目，
  `bin\assets\scripts\preview.script` 是 Runtime 消费的 KSCP v2 artifact。
- KSCP v2 固定使用 Host Interface v2。包中保留两个参与构建的 Luau 源：
  `patrol.luau` 与 `player_controller.luau`。
- `behavior-tools\kadath-behavior-tool.exe` 负责 Script v2 manifest、Luau 分析与
  KSCP v2 构建；Runtime 只加载已经生成的 `preview.script`。
- PNG/WAV 是可审计源；KDAT texture 与 canonical audio artifact 是 Runtime 资产。

KSCP v2 Windows 包必须恰好包含以下 18 个普通文件，归档路径使用 `/`：

```text
README.txt
behavior-tools/kadath-behavior-tool.exe
bin/assets/audio/lost.audio.wav
bin/assets/audio/lost.wav
bin/assets/audio/won.audio.wav
bin/assets/audio/won.wav
bin/assets/renderer2d/goal.png
bin/assets/renderer2d/goal.texture
bin/assets/renderer2d/test.png
bin/assets/renderer2d/test.texture
bin/assets/scenes/preview.scene
bin/assets/scenes/preview.scene.json
bin/assets/scripts/patrol.luau
bin/assets/scripts/player_controller.luau
bin/assets/scripts/preview.script
bin/assets/scripts/preview.script.json
bin/kadath-runtime-build-profile.json
bin/kadath.exe
```

缺失文件、未知 extra、PDB、目录链接或文件 reparse point 都会使产品门禁失败。

Kadath.Editor.Toolchain 原生 CLI
------------------------------

先发布原生 .NET Toolchain；后续命令中的路径均应替换为 canonical 本地绝对路径：

```text
dotnet publish editor\Kadath.Editor.Toolchain\Kadath.Editor.Toolchain.csproj -c Release --no-self-contained -p:NuGetAudit=false -o <toolchain-output>
```

当前 Windows 产品使用以下五类入口。

资产导入：

```text
dotnet <toolchain-output>\Kadath.Editor.Toolchain.dll import <texture|audio|scene> <source> <destination> --profile <debug|release> --no-overwrite
```

Behavior Script 由 `kadath-behavior-tool.exe` 构建，不经过通用资产导入入口。

ReleaseSafe cold-build preflight：

```text
dotnet <toolchain-output>\Kadath.Editor.Toolchain.dll preflight <package-root> <local-cache> <global-cache> <sidecar> --no-overwrite
```

PNG 源快照；正常产品构建关闭验证 barrier 与 fault：

```text
dotnet <toolchain-output>\Kadath.Editor.Toolchain.dll snapshot <source> <destination> --barrier - --fault - --no-overwrite
```

Runtime build profile：

```text
dotnet <toolchain-output>\Kadath.Editor.Toolchain.dll build-profile <runtime> <texture-source> <texture-artifact> <secondary-source> <secondary-artifact> <vertex-shader> <fragment-shader> ReleaseSafe <package-root> <local-cache> <global-cache> <sidecar> <destination> --no-overwrite
```

KSCP v2 Runtime 归档；正常产品构建关闭验证 barrier：

```text
dotnet <toolchain-output>\Kadath.Editor.Toolchain.dll archive <package-root> <new-output-dir> <new-extract-dir> <kadath-root> --policy kscp-v2 --barrier - --no-overwrite
```

`preflight` 生成 strict UTF-8、无 BOM、单行并以换行结束的 v1 exact-eight sidecar。
`build-profile` 生成同样编码约束的 v2 exact-eleven marker，并把 Runtime、两组 PNG/KDAT、
两份 shader 与 sidecar 的 SHA-256 绑定到本次 ReleaseSafe 构建。`snapshot` 在读取期间持有
源文件身份，并以 `CreateNew`、`Flush(true)` 和 no-replace 提交结果。

Windows 构包、归档与产品验证
--------------------------

`<package-root>`、`<local-cache>` 与 `<global-cache>` 必须在 preflight 前都不存在、彼此不包含，
`<sidecar>` 也必须与三者分离。每次 cold package、archive 或 Runtime 产品验证都应使用一组
全新路径，并先执行上面的 `preflight` 命令。

仅生成 exact-18 产品目录：

```text
zig build package -Doptimize=ReleaseSafe --prefix <package-root> --cache-dir <local-cache> --global-cache-dir <global-cache> -Druntime-preflight-sidecar=<sidecar>
```

在同一 build graph 中生成产品目录、确定性 ZIP、SHA-256 manifest，并终验 clean extract：

```text
zig build archive-windows-runtime -Doptimize=ReleaseSafe --prefix <package-root> --cache-dir <local-cache> --global-cache-dir <global-cache> -Druntime-preflight-sidecar=<sidecar> -Druntime-archive-output-dir=<new-output-dir> -Druntime-archive-extract-dir=<new-extract-dir>
```

归档输出目录只允许生成 `kadath-runtime-win-x64.zip` 与 `manifest.sha256`。ZIP entry 顺序、
时间戳和内容固定；package、ZIP、manifest 与 extract 必须保持同一 18 文件身份。

在真实 Windows HWND/Vulkan/Audio 环境执行产品 verifier：

```text
zig build verify-windows-runtime -Doptimize=ReleaseSafe --prefix <package-root> --cache-dir <local-cache> --global-cache-dir <global-cache> -Druntime-preflight-sidecar=<sidecar> -Dwindows-runtime-evidence-dir=<new-evidence-dir>
```

该入口用于检查真实窗口启动、像素、输入、Restart、Player 脚本移动、Won、Audio Cue、关闭
与有界清理；环境是否满足和验证是否成功，以当次退出码及 evidence 目录为准。

Editor 与 Toolchain 原生 .NET ContractVerifier
---------------------------------------------

先以目标配置构建整个 Editor solution：

```text
dotnet build editor\Kadath.Editor.sln -c <Debug|Release> -p:NuGetAudit=false
```

随后以同一配置执行各原生 verifier：

```text
dotnet run --project editor\Kadath.Editor.Workspace.ContractVerifier\Kadath.Editor.Workspace.ContractVerifier.csproj -c <Debug|Release> --no-build
dotnet run --project editor\Kadath.Editor.Service.ContractVerifier\Kadath.Editor.Service.ContractVerifier.csproj -c <Debug|Release> --no-build
dotnet run --project editor\Kadath.Editor.Client.ContractVerifier\Kadath.Editor.Client.ContractVerifier.csproj -c <Debug|Release> --no-build
dotnet run --project editor\Kadath.Editor.Toolchain.ContractVerifier\Kadath.Editor.Toolchain.ContractVerifier.csproj -c <Debug|Release> --no-build -- <kadath-root>
dotnet run --project editor\Kadath.Runtime.Windows.ContractVerifier.ContractVerifier\Kadath.Runtime.Windows.ContractVerifier.ContractVerifier.csproj -c <Debug|Release> --no-build -- <package-root>
```

Runtime contract verifier 以无窗口故障注入确认 exact-18、未知 extra/PDB、Host Interface v2、
ReleaseSafe sidecar 与 JSONL 失败分类；它不能替代真实 HWND/Vulkan 产品验证。

Client 到真实 stdio Service 的受控验证入口：

```text
dotnet run --project editor\Kadath.Editor.Client.ContractVerifier\Kadath.Editor.Client.ContractVerifier.csproj -c <Debug|Release> --no-build -- --real-service-only <service-dll> <kadath-root> <package-root>
```

其中 `<service-dll>` 对应
`editor\Kadath.Editor.Service\bin\<Debug|Release>\net8.0\Kadath.Editor.Service.dll`。

Avalonia 的资源 smoke 与原生 Windows workflow：

```text
dotnet run --project editor\Kadath.Editor.Avalonia\Kadath.Editor.Avalonia.csproj -c <Debug|Release> --no-build -- --headless-smoke
dotnet run --project editor\Kadath.Editor.Avalonia\Kadath.Editor.Avalonia.csproj -c <Debug|Release> --no-build -- --workflow-smoke-owned <kadath-root> <package-root>
```

`--workflow-smoke-owned` 只在 package 的受控 projects 目录内创建唯一 fixture，并负责验证其
所有权后清理。headless smoke 只验证资源和共享 ViewModel 接线，不能替代真实 Windows workflow
或 Runtime HWND/Vulkan 验证。

no-replace 与 fail-closed 语义
-----------------------------

- Toolchain 输出、sidecar、归档输出目录、extract 目录和 evidence 目录都必须是新目标；已有文件
  或目录会在覆盖前被拒绝。
- importer、snapshot、profile 与 archive 都先验证路径边界、reparse 状态和输入身份；任一不满足
  都不会发布新的产品身份。
- archive 在首次产品写入前失败时输出 `archive_write_started=false`，且不推进 output 或 extract。
- archive 只从 retained handles 复制到自身拥有的 staging；验证期间发生替换或篡改时，操作失败，
  cleanup 只删除已证明属于本次事务的对象，不删除 replacement 或外来对象。
- 只有 exact-18、ReleaseSafe profile/hash gate、manifest、ZIP、extract 与最终 live package 复验全部
  成功后，归档事务才算完成；未知 extra 和 PDB 一律 fail-closed。
- output 与 extract 的全部目录在最终复验期间持有 Windows R oplock；一次原子确认所有 oplock
  均未 break 的时刻是复合事务提交点。提交点前的成员新增、删除、大小或时间变化必须失败，
  提交点后的外部变更属于调用方并发，不再由已完成事务清理。

本文件定义当前产品入口与判定契约，不代表任何具体机器已经完成验收。每次结果应以实际命令、
首个因果错误、退出码以及生成的 manifest/evidence 为准。
