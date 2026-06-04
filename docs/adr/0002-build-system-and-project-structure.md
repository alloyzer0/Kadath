# ADR-0002: 构建系统与项目结构

## 元信息

- **状态**: 已采纳
- **日期**: 2026-05-27
- **决策者**: @alloyzer0
- **相关主题**: Phase 1 第一轮基础设施决策：构建系统与项目结构
- **依赖**: ADR-0001（语言选型策略）

---

## 背景

ADR-0001 确定了 Zig + Rust 双语言策略。现在需要决定：

1. **构建系统**：如何编排两种语言的编译和链接
2. **项目结构**：模块如何组织、目录如何划分
3. **依赖管理**：Zig 和 Rust 的依赖如何管理

### 约束条件

- Zig 模块需要编译为静态库（.a / .lib）
- Rust 模块需要编译为静态库
- 最终链接为单一可执行文件
- 开发时需要增量编译（改一个模块不重编全部）
- 需要支持 Windows 和 Linux 构建；混合工程的交叉编译能力需显式处理 Zig/Rust 的 target 对齐
- 单人开发，不需要复杂的 CI/CD 集成（早期）

### 候选方案

之前讨论过三种方案：

| 方案 | 顶层工具 | 优点 | 缺点 |
|---|---|---|---|
| A. Zig build 顶层 | `zig build` | Zig 对 C ABI 链接原生支持；一条命令完成 | Rust 开发者需要适应 |
| B. Cargo 顶层 | `cargo build` | Rust 工具链完整；build.rs 成熟 | build.rs 可编程性不如 zig build |
| C. 独立编译 + 脚本 | Makefile / just | 两侧完全独立 | 增量编译需要手动管理 |

---

## 决策

### 1. 采用 Zig build 作为顶层编排（方案 A）

**理由**：

1. **Zig 是基础设施层** — 平台、内存、RHI 都在 Zig 侧，这些是引擎的"地基"。让地基的构建系统做顶层编排，逻辑上更自然。

2. **Zig build 对 C ABI 库的链接是一等能力** — 不需要任何 hack，直接 `linkLibrary()` 即可。而 cargo 调用外部构建系统需要 build.rs 胶水。

3. **Zig 适合作为交叉编译入口** — 目标平台是 Windows + Linux，Zig 能统一管理目标平台、链接器和系统库。对于混合工程，Rust 侧 target 仍需由顶层构建脚本显式映射与传递。

4. **Zig build 本身是 Zig 代码** — 可编程性极强，可以实现复杂的构建逻辑（如条件编译、代码生成）。对学习目标来说，这是额外收益。

5. **一条命令完成全部编译** — `zig build` 负责顶层编排，自动调用 `cargo build` 并向 Rust 侧传递一致的 profile / target 参数，开发者不需要记忆多条命令。

**工作流**：

```bash
# 日常开发
zig build run          # 编译全部 + 运行

# 只编译 Zig 侧（快速迭代底层模块）
zig build platform     # 只编译 platform 模块

# Rust 侧单独测试（不需要链接 Zig）
cd modules/world && cargo test

# 发布构建
zig build -Doptimize=ReleaseFast

# 指定目标平台（Rust target 由顶层构建脚本同步传递）
zig build -Dtarget=x86_64-linux-gnu
```

---

### 2. 项目目录结构

采用**模块优先、语言内置**的结构：

```
Kadath/
├── build.zig                  ← 顶层构建入口
├── build.zig.zon              ← Zig 依赖声明
├── Cargo.toml                 ← Rust workspace 根
│
├── modules/                   ← 所有模块（语言无关）
│   ├── platform/              ← Zig 模块
│   │   ├── build.zig          ← 模块构建脚本
│   │   └── src/
│   │       ├── main.zig       ← 模块入口
│   │       ├── win32.zig
│   │       └── linux.zig
│   ├── mem/                   ← Zig 模块
│   │   ├── build.zig
│   │   └── src/
│   ├── rhi/                   ← Zig 模块
│   │   ├── build.zig
│   │   └── src/
│   ├── world/                 ← Rust 模块
│   │   ├── Cargo.toml
│   │   └── src/
│   │       └── lib.rs
│   ├── scheduler/             ← Rust 模块
│   │   ├── Cargo.toml
│   │   └── src/
│   └── ...
│
├── abi/                       ← 跨语言接口契约（C 头文件）
│   ├── kadath_platform.h
│   ├── kadath_mem.h
│   ├── kadath_rhi.h
│   └── README.md
│
├── app/                       ← 最终可执行文件入口
│   └── main.zig               ← 引擎启动入口
│
├── shaders/                   ← GPU 着色器源码
│   └── sprite.wgsl
│
├── examples/                  ← 可运行示例
│   └── hello_triangle/
│
├── tests/                     ← 跨模块集成测试
│
├── tools/                     ← 开发辅助工具
│
├── assets/                    ← 测试用资产
│
├── docs/                      ← 架构文档、ADR
│   ├── adr/
│   └── architecture/
│
├── .gitignore
├── LICENSE
└── README.md
```

#### 设计原则

1. **模块是一等公民** — 所有模块在 `modules/` 下平铺，不按语言分层。

2. **语言由构建文件声明** — 模块内有 `build.zig` 就是 Zig 模块，有 `Cargo.toml` 就是 Rust 模块。

3. **`abi/` 是中立的契约层** — 不属于任何模块，是模块间的公共协议。

4. **`app/` 是最终入口** — 独立于模块，负责初始化和主循环。

#### 为什么不按语言分层（foundation/ + engine/）

- 按语言分层会让目录结构暗示"Zig = 底层，Rust = 上层"，限制了语言选择的灵活性
- 如果后续某个底层模块改用 Rust 重写，不需要搬目录
- 所有模块在同一层级可见，打开 `modules/` 就能看到引擎的全部子系统

---

### 3. 构建流程

#### 顶层 `build.zig` 结构

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ========== Zig 模块编译 ==========
    
    const mem_lib = b.addStaticLibrary(.{
        .name = "kadath_mem",
        .root_source_file = b.path("modules/mem/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(mem_lib);

    const platform_lib = b.addStaticLibrary(.{
        .name = "kadath_platform",
        .root_source_file = b.path("modules/platform/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    platform_lib.linkLibrary(mem_lib);  // platform 依赖 mem
    b.installArtifact(platform_lib);

    const rhi_lib = b.addStaticLibrary(.{
        .name = "kadath_rhi",
        .root_source_file = b.path("modules/rhi/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    rhi_lib.linkLibrary(platform_lib);
    rhi_lib.linkLibrary(mem_lib);
    b.installArtifact(rhi_lib);

    // ========== Rust 模块编译 ==========
    
    const rust_target = mapZigTargetToRust(target.result);
    const rust_profile = mapZigOptimizeToCargoProfile(optimize);
    const cargo_build = b.addSystemCommand(&.{
        "cargo", "build",
        "--profile", rust_profile,
        "--target", rust_target,
        "--manifest-path", "Cargo.toml",
    });

    // ========== 最终可执行文件 ==========
    
    const exe = b.addExecutable(.{
        .name = "kadath",
        .root_source_file = b.path("app/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 链接 Zig 模块
    exe.linkLibrary(mem_lib);
    exe.linkLibrary(platform_lib);
    exe.linkLibrary(rhi_lib);

    // 链接 Rust 模块
    exe.addLibraryPath(b.path(b.fmt("target/{s}/{s}", .{ rust_target, rust_profile })));
    exe.linkSystemLibrary("kadath_world");
    exe.linkSystemLibrary("kadath_scheduler");
    exe.step.dependOn(&cargo_build.step);

    // 链接系统库
    exe.linkLibC();
    if (target.result.os.tag == .windows) {
        exe.linkSystemLibrary("user32");
        exe.linkSystemLibrary("gdi32");
    } else if (target.result.os.tag == .linux) {
        exe.linkSystemLibrary("X11");
    }

    b.installArtifact(exe);

    // ========== run 命令 ==========
    
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the engine");
    run_step.dependOn(&run_cmd.step);
}
```

#### Rust workspace `Cargo.toml`

```toml
[workspace]
resolver = "2"
members = [
    "modules/world",
    "modules/scheduler",
]

[workspace.package]
version = "0.0.1"
edition = "2021"
rust-version = "1.80.0"

[workspace.dependencies]
# 共享依赖
```

#### 单个 Rust 模块 `modules/world/Cargo.toml`

```toml
[package]
name = "kadath_world"
version.workspace = true
edition.workspace = true

[lib]
crate-type = ["staticlib"]  # 编译为静态库

[dependencies]
# 模块特定依赖
```

---

### 4. 依赖管理

#### Zig 依赖

使用 `build.zig.zon` 管理：

```zig
.{
    .name = "kadath",
    .version = "0.0.1",
    .dependencies = .{
        // 如果需要第三方 Zig 库
        // .zigimg = .{
        //     .url = "https://github.com/zigimg/zigimg/archive/refs/tags/v0.13.0.tar.gz",
        //     .hash = "...",
        // },
    },
}
```

#### Rust 依赖

使用 workspace `Cargo.toml` 统一管理共享依赖，各模块的 `Cargo.toml` 引用 workspace 依赖。

---

### 5. 增量编译

- **Zig 侧**：Zig build 自动处理增量编译，只重编修改的模块
- **Rust 侧**：cargo 自动处理增量编译
- **跨语言**：修改 Zig 模块不会触发 Rust 重编（除非修改了 `abi/*.h`）

---

### 6. 交叉编译

```bash
# 编译 Linux 版本（在 Windows 上）
# 顶层 build.zig 必须同步向 cargo 传递 x86_64-unknown-linux-gnu
zig build -Dtarget=x86_64-linux-gnu

# 编译 Windows 版本（在 Linux 上）
# 顶层 build.zig 必须同步向 cargo 传递 x86_64-pc-windows-gnu
zig build -Dtarget=x86_64-windows-gnu
```

Rust 侧的交叉编译需要额外配置（如安装对应 target 和标准库），因此本决策只确认：

- Zig 负责统一接收目标平台参数
- 顶层 `build.zig` 必须将 Zig target 显式映射为 Rust target triple
- 若 Rust target 未准备好，混合工程交叉编译不视为“自动可用”

---

## 后果

### 正面影响

1. **一条命令完成全部编译** — 开发者体验简洁
2. **Zig 统一顶层构建入口** — 目标平台、系统库和最终链接都由 Zig 侧集中编排
3. **模块独立性** — 每个模块可以独立编译和测试
4. **构建逻辑可编程** — build.zig 是 Zig 代码，可以实现复杂逻辑

### 负面影响

1. **Rust 开发者需要适应 zig build** — 习惯 cargo 的开发者需要学习 zig build 命令
2. **构建脚本维护成本** — 每增加一个模块，需要手动更新 `build.zig` 和 `Cargo.toml`
3. **Rust 交叉编译仍需额外配置** — 顶层 build.zig 只能传递 target/profile，不能替代 Rust 侧安装目标工具链

### 缓解措施

1. **提供常用命令别名** — 在 README 中列出常用命令，降低学习成本
2. **模块模板** — 提供 Zig 和 Rust 模块的模板，减少手动配置
3. **构建脚本文档** — 在 `docs/` 中说明如何添加新模块，以及 Zig target 到 Rust target/profile 的映射规则

---

## 替代方案

### 为什么不选 Cargo 顶层（方案 B）

- Rust 侧是应用层，不是基础设施层
- build.rs 调用 zig build 需要额外胶水代码
- Zig 的交叉编译能力无法被 cargo 利用

### 为什么不选独立编译 + 脚本（方案 C）

- 增量编译需要手动管理依赖关系
- 多了一层胶水脚本要维护
- Windows 上 Makefile/shell 体验差

---

## 相关决策

- **ADR-0001: 语言选型策略** — 本决策依赖 ADR-0001 的双语言策略
- **ADR-0003: 跨语言边界规范** — `abi/` 目录的接口定义规范

---

## 未来演进

### 可能的优化方向

1. **自动化模块注册** — 如果模块数量增多，可以考虑用脚本扫描 `modules/` 自动生成 `build.zig` 的模块列表
2. **模块注册表** — 引入 `modules.yaml` 作为模块元信息的单一真相来源（但不作为构建输入）
3. **并行编译** — Zig build 和 cargo build 可以并行执行（当前是串行）

### 不考虑的方向

- **CMake 作为顶层** — 引入重工具，对学习目标无额外价值
- **Bazel / Buck2** — 过度工程化，单人项目不需要

---

## 审阅记录

- 2026-05-27: 初稿，待主导者审阅
- 2026-06-04: 主导者确认采用，状态调整为“已采纳”
