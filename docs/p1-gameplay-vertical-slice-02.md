# P1 Gameplay Vertical Slice 02 验收约定

状态：实现与验收约定已冻结
日期：2026-08-27

## 目标

用一条确定、可重放的多实体场景链路验证现有 Rust Gameplay Runtime Core 与 Zig Host/Behavior Adapter 的职责边界：

`Scene → Behavior → fixed-step → Contact/Phase → Snapshot → Outcome → Restart → Scene Reload`

本切片不新增 ABI，不把调度权威移入 Rust，也不把 Gameplay 状态复制回 Zig。Zig 仍决定调用时机；Rust Core 仍是对象、Gameplay、Contact、Phase、Outcome 与 Snapshot 的唯一权威。

## 固定场景与输入

- 初始场景包含 Player、Goal、两个 Hazard 和一个 Phase 探针对象。
- Player Behavior 每个 fixed step 固定向右移动，并把输入轴编码到正交方向；因此相同输入必须产生相同状态，不同输入必须改变 transcript。
- 初始场景先接触 Hazard A，再从 Hazard A 移到 Hazard B。探针通过公开 Behavior 事件记录 `contact_end` 后于旧接触发生、且先于新 `contact_begin` 投递。
- 第一次 Hazard Outcome 后继续执行一个 fixed step，验证终态不重复发布 Outcome，且 Host 路由的输入被抑制。
- Restart 使用候选 SceneGeneration 与候选 Behavior Runtime，提交后再次得到相同初始状态，并保持 restart 的世界身份规则。
- Scene Reload 使用第二个已解析场景：Goal 位于确定路径上、Hazard 移出路径。提交后世界 epoch 前进，并产生 Goal Outcome。

## 公开观察与 replay 签名

正确性断言直接读取公开 seam：

- `GameplayStepResult`：phase、cause、accepts_input、time remaining、step token、contact/outcome 数量；
- `GameplayOutcome`：sequence、phase、cause、player/other ObjectRef；
- `GameplaySnapshot`：world epoch、phase、cause、accepts_input、last outcome sequence、time remaining、render count；
- `RenderSprite`：按 Rust Snapshot 顺序记录 ObjectRef、entity、position、size、final color、texture；
- Phase 探针的公开位置；
- Restart/Reload 前后的公开 world epoch 与实体身份。

签名使用 SHA-256。所有整数采用固定宽度小端编码，浮点数记录 IEEE-754 bit pattern，字符串记录长度与原始字节；不得 hash C/Zig struct 的 padding、reserved 字段、地址、计时值或日志文本。

Hash 只作为“同一 transcript 完全一致”的证据，不代替字段级正确性断言。验收必须同时满足：

1. 两个独立 fresh session 在相同场景、脚本和输入下得到相同 digest；
2. 改动一个输入后 digest 不同；
3. Hazard、Contact 顺序、Outcome 不重放、Restart、Reload、Goal 的字段断言全部通过；
4. benchmark 报告同一 workload 的 p50/p95/p99、steady-state 分配计数与证据文件 SHA-256。

字段级测试不得只复核 phase/outcome：必须同时断言三个初始 step 的 token 连续性、begin/commit token 一致、time remaining、定向 contact event count、outcome count，以及最终五个 `RenderSprite` 的 Rust 顺序。Player sprite 还要逐字段断言 ObjectRef、entity、position、size、terminal tint 和 texture。

终态输入抑制必须调用 Host 生产路径共用的 `player_movement_ownership.routeGameplay`，并断言请求的非零 Y 输入没有改变 Player Y；测试或 benchmark 不得各自复制一份抑制规则。

## 性能与优化边界

- 先采集未优化基线，再 profile。
- 只允许优化一个由 profile 证明的热点；若没有明显热点，则记录“不做推测性优化”。
- RSS 只记录为诊断数据，不设 `256 KiB` 一类不符合完整引擎进程的门槛。
- gate 关注正确性、确定性、尾延迟、steady-state 分配增长、证据可追溯性与跨平台 smoke。
- 同场景 active fixed-step 单独采样 256 次，Session 构造与 `on_start` 排除在计数窗口外。2026-08-27 先复现历史基线每步 66 次，再按公开调用归因并只修改确认的 `object_query` 热点；优化后 256/256 样本均为 0，因此门禁按实测基线收紧为每步最多 0 次，并校验总数必须为 0。该上限不可由报告自行放宽。
- 上述计数与 direct Runtime Core 稳态门禁分开：后者连续 120 万 fixed-step 必须保持 Rust 分配为 0、RSS 增长不超过 64 KiB。两者分别回答“真实 Behavior 步进的稳定分配率”和“Core 是否持续增长”。

## 2026-08-27 实测与 profile 决策

固定 ReleaseSafe workload 为 5 个对象、7 个 fixed step、3 个 Outcome、一次 Restart 和一次 Scene Reload。Windows 与 WSL2 Linux 的 replay digest 均为：

`fa77c837f249f9dfe9cdf85d597d7a06d34b3c45ceccfe9e5209e46c0947aaaf`

优化前基线：

- Windows：p50 约 2.26 ms，p95 约 2.41 ms，p99 约 2.79 ms；
- WSL2 Linux：p50 约 2.35 ms，p95 约 2.50 ms，p99 约 2.85 ms；
- 每个完整冷生命周期记录 909 次 Rust 分配。该数字包含三次候选世界/VM 生命周期，不是 steady-state 零分配指标。

`gprofng` 对 4096 次 workload 的 profile 将 `Runtime.settlePhase` 识别为唯一可归因热点：每次 drain 前清零 64 个大型 `PhaseEvent` 占据明显 CPU 样本。Rust Core 的公开输出契约要求调用方先提供每项 `struct_size`，通过 ABI preflight 后会完整写入返回的 `count` 范围，因此无须预清零其余 payload。

因此只移除了这一处无效的 payload 预清零；每个输出项仍显式初始化 ABI preflight 必需的 `struct_size`，Rust 只在校验表头后覆盖返回 `count` 范围。优化后：

- Linux p50 约 2.15 ms，p95 约 2.47 ms；
- profile 总 CPU 样本约从 0.099 s 降至 0.090 s；
- `settlePhase` inclusive 占比约从 21% 降至 14%，direct fixed 路径中的该段约从 18% 降至 8%；
- digest、字段断言、Outcome 序号与分配计数不变。

尾延迟单次样本仍有调度噪声，因此 gate 采用宽松但明确的绝对上限：p95 ≤ 50 ms、p99 ≤ 100 ms。没有第二个同等可信的热点证据，本切片停止进一步优化。

## 2026-08-27 Behavior 分配归因与基线收紧

本轮没有建立新的 benchmark 或 lifecycle driver，而是在同一 `gameplay-vertical-slice-bench` 计数窗口中增加 quality-only 公开调用标签。优化前 Windows ReleaseSafe 连续 256 个样本均为 66 次，且 66/66 全部归属于 Runtime Core 公开 `object_query`；Phase、Gameplay begin/commit/snapshot 与 `object_mutate` 均为 0。

每个 active fixed-step 的 27 次单项查询分布为：

| query tag | 调用次数 / step | 分配次数 / step | 根因 |
|---|---:|---:|---|
| `STATE_INFO` | 1 | 2 | 通用 borrowed-range 与 result plan 使用临时 `Vec` |
| `FIND_BY_ID` | 12 | 24 | 每次单项查询固定 2 次临时分配 |
| `RESOLVE_EXACT_REF` | 10 | 20 | 每次单项查询固定 2 次临时分配 |
| `VISIBLE_OBJECTS` | 4 | 20 | 通用 2 次，加 ordered source/transient 与 caller view staging 3 次 |
| **合计** | **27** | **66** | `23 × 2 + 4 × 5` |

修复只改确认的热点实现：用 `MAX_OBJECTS` 有界栈上 borrowed-range / result plan 替代通用临时 `Vec`，并以 source-first、transient-serial 的无分配 visitor 直接写 caller-owned view。公开 ABI、查询次数、顺序、fault-before-publication 与 caller output 原子语义不变。

优化后同一机器、同一 ReleaseSafe workload 的 active fixed-step 为 `total=0, max=0, samples=256`；公开查询仍固定为每步 27 次。完整冷生命周期从 909 降至 14 次/样本，但它包含 Scene/VM candidate 生命周期，仍不与 active-step 零分配门禁混用。门槛由上述实测基线收紧到 0，不使用预先拍定的目标数字。

WSL2 的 WSLg 会把 `/tmp/.X11-unix` 只读挂载为 `0777`。Linux smoke 使用私有 user/mount namespace 覆盖为 `1777` tmpfs 后，Xvfb/XCB/Lavapipe/Validation、像素和关闭路径全部 PASS；该环境隔离不进入产品代码。
