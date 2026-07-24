# Kadath Scheduler tracer bullet

`kadath_scheduler` 是一个隔离的 Rust 后台任务模块，用于验证 ADR-0008 中“后台产生结果、owner/main thread 在受控同步点摄取”的执行边界。

它不是 Runtime 主循环、资产构建 DAG、通用 async runtime 或线程池框架。Resource 异步纹理 tracer 通过一个窄 C ABI 使用它；该 ABI 只提供有界文件读取、非阻塞 completion 摄取和确定性关闭，不暴露给 Host。

## 最小接口

- `Scheduler::start(capacity, handler)`：创建单 worker Scheduler；
- `try_submit(input)`：非阻塞提交，成功后返回单调且不复用的 `JobId`；
- `drain_completed()`：owner thread 非阻塞摄取当前已完成结果；
- `try_next_completed()`：为窄 FFI Adapter 摄取一个 FIFO 完成项；
- `shutdown()`：停止接收、等待所有已接受任务完成并返回未摄取结果。

任务结果分为：

- `Succeeded(output)`；
- `Failed(error)`；
- `Panicked`，由 worker 内部的 `catch_unwind` 产生。

## 线程与所有权

`Scheduler` 本体是 `!Send + !Sync`，只能在创建它的 owner thread 上提交、摄取和关闭。后台 worker 只获得已提交输入的所有权，不能直接持有或修改 World、RHI、Renderer2D 状态。

提交成功后，输入所有权转移给 Scheduler；提交失败时，输入通过 `SubmitError` 原样返还。成功输出或任务错误最终通过 `Completion` 转移回 owner thread。

单 worker 按 FIFO 执行。容量约束的是全部 outstanding，而不只是输入队列：排队、执行中、已完成但尚未 `drain` 的任务都会占用槽位。因此结果消费过慢会自然形成背压，不会让完成队列无限增长。

## 关闭与阻塞语义

`shutdown` 丢弃输入 sender，worker 按 FIFO 处理完全部已接受任务后退出；调用线程 join worker，再取回尚未消费的 Completion。handler panic 只形成 `Panicked` 完成项，worker 会继续执行后续任务。若 worker 在线程入口内部异常 panic，`ShutdownReport` 会记录 `worker_panicked` 和没有形成完成项的 `abandoned_jobs`，不会再次向调用方 panic。

`Drop` 采用同样的有序关闭路径，但丢弃未消费结果。它不会因为 handler/worker panic 主动再次 panic。

需要明确的性能语义：如果 handler 永不返回，`shutdown` 和 `Drop` 都会永久阻塞。当前 tracer bullet 不实现取消、超时或强制终止线程，因为 Rust 无法可靠地强杀普通线程；需要这类能力时应根据真实消费者另行设计协作式取消。

## Resource Adapter 与 bytes 所有权

`kadath_scheduler_submit_bounded_read` 复制调用期间借用的 UTF-8 path，并以固定 scratch buffer、checked length 与 `try_reserve` 保证结果长度严格小于 Resource 私有上限。显式 `try_reserve` 失败可报告，但 Rust 全局 allocator 在其他分配点仍可能 abort，本模块不承诺全部 OOM 可恢复。

成功 completion 使用 `Box<[u8]>` 跨 ABI 转移为 `data + len`。原 descriptor 必须精确调用一次 `kadath_scheduler_bytes_free`；释放后函数会清零字段。尚未 poll 的 completion 在 `destroy` 时由 Rust 释放。descriptor 不携带 Vec capacity，也不得复制或重复释放。

crate 根使用 `deny(unsafe_code)`；只有单个 `ffi` module 局部允许 unsafe，Scheduler core 保持 safe Rust。

## 验证

```powershell
cargo test --manifest-path modules/scheduler/Cargo.toml
cargo fmt --manifest-path modules/scheduler/Cargo.toml -- --check
cargo clippy --manifest-path modules/scheduler/Cargo.toml --all-targets -- -D warnings
```

测试通过 `Barrier` 控制 worker 时序，不使用 `sleep`，覆盖：正常完成、业务失败、panic 隔离、FIFO、outstanding 背压、非阻塞结果摄取、确定性 shutdown 和安全 Drop。
