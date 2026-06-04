# ADR-0003: 跨语言边界规范

## 元信息

- **状态**: 已采纳
- **日期**: 2026-05-27
- **决策者**: @alloyzer0
- **相关主题**: Phase 1 第一轮基础设施决策：跨语言边界规范
- **依赖**: ADR-0001（语言选型策略）、ADR-0002（构建系统与项目结构）
- **阻塞**: 任何首个跨语言调用必须等本 ADR 进入"已采纳"状态后才能落地

---

## 背景

ADR-0001 已经确定 Zig + Rust 的边界由 **C ABI** 承载，并在"禁止事项"中规定：在本规范完成前，不得新增跨语言调用。原因是单纯说"走 C ABI"并不足以让两侧实现稳定地协作 —— 字符串、错误、内存、所有权、线程、panic 这些语义在两种语言里都有自己的"母语表达"，跨过边界时如果没有统一约定，第一个跨语言调用就会暴露不可调和的歧义。

本 ADR 的任务是把这些边界语义一次性写清楚，让：

1. Zig 侧导出 C ABI 时知道**自己应当承诺什么**
2. Rust 侧通过 `bindgen` 调用时知道**自己可以期望什么**
3. 两侧 reviewer 在评审跨语言接口时有**统一的判定依据**

本 ADR 不规定具体某个模块的 API 长什么样，只规定**跨语言边界处的通用契约**。具体模块（platform / mem / rhi）的 C 头文件在各自模块 ADR 或接口文档中定义，但必须遵守本 ADR 的通用规则。

### 已知约束

- 边界数量上限按 ADR-0001 规定为 **5 个主要边界**
- 边界契约的单一真相来源是 `abi/*.h`（ADR-0002）
- Rust 侧使用 `bindgen` 自动生成绑定，禁止手写 FFI 声明
- 当前目标是将 Zig 与 Rust 产物链接为单一可执行文件，不考虑动态库分发；具体 debug/release profile 由顶层构建系统决定

---

## 决策

### 1. 决策摘要与适用范围

#### 1.1 一句话摘要

跨语言边界采用**三层契约 + 四类失败语义**：以 C 头文件作为接口契约，以"调用方持有所有权"作为内存默认规则，以 `int32_t` 错误码作为统一返回通道；并明确规定 panic、abort、错误码、不变量违反四类失败的处理边界。

#### 1.2 适用范围（In Scope）

- `abi/*.h` 中声明的所有 `extern "C"` 函数
- 这些函数的**参数类型、返回类型、所有权、错误传播、线程语义**
- Zig 侧 `export fn` / Rust 侧 `extern "C" fn` 的实现约束
- 不透明句柄（opaque handle）的生命周期管理
- 跨语言传递的回调函数的调用约定

#### 1.3 不适用范围（Out of Scope）

- 单一语言模块**内部**的实现细节（Zig 内部用什么 allocator、Rust 内部用什么 trait，本 ADR 不管）
- Rust 模块之间的纯 Rust API（仍可使用 `Vec`、`Result` 等）
- Zig 模块之间的纯 Zig API（仍可使用切片、`error{...}`）
- 第三方 C 库（如 SDL、OpenGL loader）的封装规则 —— 它们的 C ABI 不由我们设计，封装层位于"中立 abi" 之外
- 构建产物的 ABI 兼容（当前是单可执行文件，无需关心 ABI 版本号）

#### 1.4 与 ADR-0001 禁止事项的对齐

ADR-0001 规定边界禁止传递语言特定类型。本 ADR 进一步细化：**任何不能用纯 C 头文件描述的类型，都不允许出现在边界上**。包括但不限于：

- Rust 的 `Vec<T>` / `String` / `&str` / `Box<T>` / `Rc<T>` / `Arc<T>` / trait object
- Zig 的 `[]T` / `?T`（Optional）/ `error{...}` / `ArrayList(T)` / `HashMap`
- 任何带有非 trivial 析构语义的类型（即使 layout 兼容）

边界上能出现的类型只有 C 头文件能直接表达的：基本数值、指针、`size_t`、显式定义的 POD 结构体、不透明句柄、函数指针。

---

### 2. 内存与所有权规则

跨语言内存管理是本 ADR 最容易出错的部分，规则按"四种内存模式"枚举，**每个 ABI 函数必须显式声明自己采用哪一种**，并在 C 头文件 doc comment 中标注。

#### 2.1 模式 A：调用方分配，被调用方只读使用（默认推荐）

```c
// abi/kadath_rhi.h
// Mode: caller-allocates, callee-reads
// Lifetime: data must outlive this call; callee must NOT retain pointer.
int32_t kadath_rhi_submit_commands(
    const uint8_t* data,
    size_t len
);
```

约定：
- 调用方负责分配 `data`，并保证在函数返回前其指向的内存有效
- 被调用方**禁止**持有指针超过函数调用范围（不得存入全局、不得交给其他线程）
- 如果被调用方需要副本，必须自行拷贝到自己管理的内存中
- 这是默认模式，无特殊理由优先使用此模式

#### 2.2 模式 B：被调用方分配，调用方释放

```c
// Mode: callee-allocates, caller-frees
// The returned buffer must be released via kadath_mem_free_buffer.
int32_t kadath_platform_read_file(
    const char* path,
    uint8_t** out_data,
    size_t* out_len
);

int32_t kadath_mem_free_buffer(uint8_t* data, size_t len);
```

约定：
- 被调用方在边界处分配，调用方负责调用配套的 `*_free_*` 函数释放
- **必须**有配套的释放函数（不允许调用方用自己的 free / dealloc 释放对方分配的内存，因为两侧的 allocator 可能不同）
- 释放函数的命名规则：`<module>_<noun>_free` 或 `<module>_free_<noun>`
- Rust 调用 Zig 分配的内存时，**禁止**用 Rust 的 `Box::from_raw` 接管；必须把指针交还给 Zig 侧的释放函数

#### 2.3 模式 C：调用方传入 allocator，被调用方使用

仅限 Zig 侧导出 allocator 抽象的少量场景（mem 模块）。

```c
// Mode: caller-provides-allocator
typedef struct kadath_allocator_t kadath_allocator_t;

int32_t kadath_world_serialize(
    kadath_allocator_t* allocator,
    uint8_t** out_data,
    size_t* out_len
);
```

约定：
- 调用方把 allocator 句柄传入，被调用方用此 allocator 分配
- 调用方用同一个 allocator 释放
- 此模式只用于 Zig 侧已经设计好 allocator C ABI 的模块；Rust 侧暂不导出 allocator
- 此模式与模式 B 的区别：B 由被调用方决定 allocator，C 由调用方决定

#### 2.4 模式 D：不透明句柄，生命周期由创建方拥有

```c
// Mode: opaque-handle
typedef struct kadath_window_s* kadath_window_t;

int32_t kadath_window_create(/* ... */, kadath_window_t* out_handle);
int32_t kadath_window_destroy(kadath_window_t handle);
```

约定：
- 句柄是 `void*` / 不透明结构体指针，**调用方不得解引用、不得 cast 到具体类型**
- 句柄的生命周期由 `*_create` / `*_destroy` 配对管理
- 句柄在 destroy 之后立即视为悬垂，调用方有责任清零
- 句柄**不允许**跨线程传递，除非该句柄类型在文档中显式标注为 `thread-safe`

#### 2.5 通用禁令

- **禁止**跨语言传递包含"裸指针字段"的 POD 结构体，除非每个指针字段在头文件 doc comment 中显式声明所有权和生命周期
- **禁止**双重释放：每块跨边界内存必须有唯一的释放函数；调用方释放后必须不再使用
- **禁止**让 Rust 的 `Drop` 跨越边界生效。所有跨语言资源必须显式调用对应的 `*_destroy` / `*_free`，不依赖语言析构
- **禁止**循环引用导致的所有权歧义：当 A 模块创建的句柄被 B 模块持有时，必须在文档中明确"B 不拥有所有权，仅借用，A 销毁前 B 必须先释放借用"

---

### 3. 错误码与返回值约定

跨语言边界的错误传播是最容易出现"两侧各说各话"的地方。Rust 的 `Result<T, E>` 和 Zig 的 `error{...}!T` 都是语言特定的错误类型，不能跨边界。本节规定统一的错误传递机制。

#### 3.1 统一返回类型：`int32_t` 错误码

所有 ABI 函数（包括 `destroy/free/close`）的返回值必须是 `int32_t`，含义如下：

| 值范围 | 含义 |
|---|---|
| `0` | 成功（`KADATH_OK`） |
| `0x0001..=0x0FFF` | 通用错误（跨模块共享，如参数无效、内存不足） |
| `0x1000..=0x1FFF` | platform 模块错误 |
| `0x2000..=0x2FFF` | mem 模块错误 |
| `0x3000..=0x3FFF` | rhi 模块错误 |
| `0x4000..=0x4FFF` | world 模块错误 |
| `0x5000..=0x5FFF` | scheduler 模块错误 |
| `< 0` | 保留，**禁止使用**（避免与系统调用错误混淆） |

错误码在 `abi/kadath_errors.h` 中集中定义：

```c
// abi/kadath_errors.h
#define KADATH_OK                     0

// 通用错误（0x0001..0x0FFF）
#define KADATH_ERR_INVALID_ARGUMENT   0x0001
#define KADATH_ERR_OUT_OF_MEMORY      0x0002
#define KADATH_ERR_BUFFER_TOO_SMALL   0x0003
#define KADATH_ERR_NOT_FOUND          0x0004
#define KADATH_ERR_NOT_SUPPORTED      0x0005
#define KADATH_ERR_INTERNAL           0x0006

// 模块错误 base
#define KADATH_ERR_PLATFORM_BASE      0x1000
#define KADATH_ERR_MEM_BASE           0x2000
#define KADATH_ERR_RHI_BASE           0x3000
#define KADATH_ERR_WORLD_BASE         0x4000
#define KADATH_ERR_SCHEDULER_BASE     0x5000

// platform 错误（0x1000..0x1FFF）
#define KADATH_ERR_PLATFORM_WINDOW_FAILED  (KADATH_ERR_PLATFORM_BASE + 0x0001)
#define KADATH_ERR_PLATFORM_INPUT_FAILED   (KADATH_ERR_PLATFORM_BASE + 0x0002)
// ...
```

#### 3.2 输出参数通过指针返回

由于返回值已被错误码占用，"实际结果"通过 out-parameter 返回：

```c
// 推荐写法
int32_t kadath_world_get_entity_count(
    kadath_world_t world,
    size_t* out_count
);

// 反例（禁止）：用 size_t 返回值，错误用魔法值表示
size_t kadath_world_get_entity_count(kadath_world_t world); // 不允许
```

约定：
- out-parameter 命名以 `out_` 开头
- 函数失败时（返回非 `KADATH_OK`），out-parameter 的内容**未定义**，调用方不得读取
- 多个 out-parameter 的写入顺序未定义；调用方不能依赖部分写入

#### 3.3 错误名称与简短描述

错误码本身只携带"错误类型"信息。为便于日志、调试与跨语言绑定，Kadath 提供稳定的错误名称与简短描述查询接口：

```c
// abi/kadath_errors.h
const char* kadath_err_to_name(int32_t code);
const char* kadath_err_to_message(int32_t code);
```

约定：
- `kadath_err_to_name()` 返回稳定的错误码名称，如 `KADATH_ERR_OUT_OF_MEMORY`
- `kadath_err_to_message()` 返回简短英文描述，如 `out of memory`
- 返回的字符串由 Kadath 内部静态持有，调用方不得释放，也不得修改
- 这两个接口不承载动态上下文信息；具体模块日志可额外记录上下文，但 ABI 默认不提供 `last_error_message`

#### 3.4 Rust 侧 → 错误码的映射

Rust 模块导出 ABI 时，必须在边界处把 `Result<T, E>` 转换为 `int32_t`：

```rust
// modules/world/src/abi.rs
#[no_mangle]
pub extern "C" fn kadath_world_step(world: *mut World, dt: f32) -> i32 {
    let world = match unsafe { world.as_mut() } {
        Some(w) => w,
        None => return KADATH_ERR_INVALID_ARGUMENT,
    };

    match world.step(dt) {
        Ok(()) => KADATH_OK,
        Err(WorldError::InvalidState) => KADATH_ERR_WORLD_INVALID_STATE,
        Err(WorldError::Internal(_)) => KADATH_ERR_INTERNAL,
    }
}
```

#### 3.5 Zig 侧 → 错误码的映射

Zig 模块导出 ABI 时，把 `error{...}` 转换为 `i32`：

```zig
// modules/platform/src/abi.zig
export fn kadath_platform_open_window(
    width: u32,
    height: u32,
    out_handle: *?*WindowOpaque,
) callconv(.C) i32 {
    const handle = createWindow(width, height) catch |err| {
        return switch (err) {
            error.InvalidArg => KADATH_ERR_INVALID_ARGUMENT,
            error.OutOfMemory => KADATH_ERR_OUT_OF_MEMORY,
            error.PlatformFailure => KADATH_ERR_PLATFORM_WINDOW_FAILED,
        };
    };
    out_handle.* = handle;
    return KADATH_OK;
}
```

#### 3.6 错误码命名与维护规则

- 错误码常量必须以 `KADATH_ERR_` 或 `KADATH_OK` 开头
- 模块特定错误码命名：`KADATH_ERR_<MODULE>_<REASON>`
- 一旦发布到 `abi/kadath_errors.h`，**值不允许改变**（只能新增）
- 删除错误码必须先标记 `// DEPRECATED` 至少一个版本周期后再移除
- 通用错误码（`0x0001..0x0FFF`）只能由本 ADR 修订时添加，模块不得占用

---

### 4. 线程、重入与失败边界

边界处的并发与失败语义比内存所有权更隐蔽。本节定义跨语言调用的并发安全与失败处理规则。

#### 4.1 线程安全标注（强制）

每个 ABI 函数必须在头文件 doc comment 中标注线程安全等级，从以下四类中选择：

| 标注 | 含义 |
|---|---|
| `Thread-safe` | 任意多线程并发调用安全 |
| `Thread-compatible` | 不同对象的并发调用安全；同一对象的并发调用不安全 |
| `Single-thread` | 必须在创建该对象的线程上调用 |
| `Main-thread` | 必须在主线程上调用（如窗口、输入相关） |

```c
// Thread-compatible: concurrent calls on different worlds are safe.
//                    concurrent calls on the same world are NOT safe.
int32_t kadath_world_step(kadath_world_t world, float dt);

// Main-thread only: must be called on the thread that created the window.
int32_t kadath_platform_poll_events(kadath_window_t window);
```

约定：
- 默认（未标注）等价于 `Single-thread`
- 跨线程传递的不透明句柄必须显式标注为 `Thread-safe`
- 违反线程标注的行为是**未定义行为**，被调用方可以选择 abort、检测并返回错误码或不检查

#### 4.2 重入规则

重入指 ABI 函数 A 在执行过程中，通过回调调用了同一模块的另一个 ABI 函数 B。

约定：
- 默认所有 ABI 函数**不可重入**
- 需要支持重入的函数必须在 doc comment 中显式标注 `Reentrant: yes`
- 通过 ABI 注册的回调函数，在其执行期间调用回该模块的 ABI 函数属于"重入"，需要被调用模块显式支持
- 回调函数本身的签名必须是 `extern "C"`，禁止注册带语言特定调用约定的回调

```c
typedef int32_t (*kadath_event_callback_t)(
    int32_t event_type,
    void* user_data
);

// Reentrant: NO. The callback must NOT call back into kadath_platform_*.
int32_t kadath_platform_register_callback(
    kadath_event_callback_t cb,
    void* user_data
);
```

#### 4.3 失败边界：四类失败的处理规则

跨语言边界存在四类失败，每类有不同的处理边界：

##### 4.3.1 类别 1：可恢复错误（错误码）

定义：操作失败但程序状态仍然一致（参数无效、文件不存在、内存不足等）。

处理：返回非 `KADATH_OK` 错误码，调用方决定如何应对。

##### 4.3.2 类别 2：Rust panic

定义：Rust 侧代码触发 `panic!`、数组越界、`unwrap` on `None` 等。

**强制规则**：
- 若当前 Rust ABI crate 使用 `panic=unwind`，则每个 ABI 函数必须用 `std::panic::catch_unwind` 包裹整个函数体
- 捕获到的 panic 必须转换为 `KADATH_ERR_INTERNAL` 返回，**禁止**让 panic 跨越 FFI 边界（这是 Rust 的未定义行为）
- 若某个 build profile 配置为 `panic=abort`，则该 profile 下 panic 的边界行为是进程终止，不得宣称满足 `catch_unwind` 语义
- panic 的动态上下文可以写入日志，但 ABI 层默认只暴露稳定错误码以及 `kadath_err_to_name()` / `kadath_err_to_message()`

```rust
#[no_mangle]
pub extern "C" fn kadath_world_step(world: *mut World, dt: f32) -> i32 {
    let result = std::panic::catch_unwind(|| {
        // ... 实际逻辑 ...
        KADATH_OK
    });
    match result {
        Ok(code) => code,
        Err(_) => {
            KADATH_ERR_INTERNAL
        }
    }
}
```

##### 4.3.3 类别 3：Zig 不可恢复错误

定义：Zig 侧的 `unreachable`、断言失败、内存损坏等。

**规则**：
- Zig 的 `error{...}` 是可恢复的，必须按 3.5 节映射为错误码，**禁止**让 Zig error 跨越 `extern "C"` 函数边界
- Zig 的 `@panic` / 断言失败会触发 abort，这是预期行为；不需要在边界处特殊捕获
- 调试构建中允许 abort 以便定位问题；release 构建仍允许 abort（但应通过日志记录上下文）

##### 4.3.4 类别 4：调用方违反契约

定义：调用方传入悬垂指针、错误的句柄、跨线程使用 `Single-thread` 句柄等。

**规则**：
- 被调用方**没有义务**检测此类错误（检测成本可能过高）
- 被调用方**可以选择**：
  - (a) 不检查，行为未定义（性能优先）
  - (b) 在 debug 构建中检测并 abort（安全优先）
  - (c) 检测并返回 `KADATH_ERR_INVALID_ARGUMENT`（防御性编程）
- 选择哪种策略由各模块自行决定，但必须在头文件 doc comment 中说明
- 当前阶段推荐 **debug 构建用 (b)，release 构建用 (a)**

#### 4.4 失败边界总结表

| 失败类别 | 跨边界传播 | 处理方 | 默认机制 |
|---|---|---|---|
| 可恢复错误 | 通过错误码 | 调用方 | 返回 `int32_t` |
| Rust panic | **禁止** | Rust 侧捕获 | `catch_unwind` → `KADATH_ERR_INTERNAL` |
| Zig 不可恢复错误 | abort | 进程终止 | 记录日志后 abort |
| 契约违反 | 未定义 | 调用方责任 | debug abort / release UB |

---

### 5. 回调函数约定

回调是跨语言边界中"反向调用"的唯一合法通道。本节补充回调的具体约束。

#### 5.1 回调签名规则

```c
// 所有回调必须是 extern "C" 函数指针 + void* user_data 配对
typedef int32_t (*kadath_callback_fn)(
    int32_t event_type,
    const void* event_data,
    void* user_data
);
```

约定：
- 回调函数必须使用 C 调用约定（`extern "C"` / `callconv(.C)`）
- 必须携带 `void* user_data` 参数，由注册方传入，被调用方原样回传
- 回调的返回值同样使用 `int32_t` 错误码
- 回调内部**禁止** panic（Rust 侧必须 `catch_unwind`）；如果回调 panic 且未捕获，行为未定义

#### 5.2 回调生命周期

- 注册回调时，注册方保证回调函数指针和 `user_data` 在注销前有效
- 被调用方在注销后**禁止**再调用该回调
- 注销函数必须与注册函数配对存在

```c
int32_t kadath_platform_register_event_callback(
    kadath_window_t window,
    kadath_callback_fn callback,
    void* user_data
);

int32_t kadath_platform_unregister_event_callback(
    kadath_window_t window,
    kadath_callback_fn callback
);
```

#### 5.3 回调执行线程

- 回调在哪个线程被调用，由注册方的 doc comment 显式声明
- 默认假设：回调在注册它的同一线程上被调用
- 如果回调可能在不同线程被调用，必须标注 `Callback-thread: any`

---

### 6. 命名约定

#### 6.1 函数命名

```
kadath_<module>_<verb>_<noun>
```

示例：
- `kadath_platform_open_window`
- `kadath_mem_alloc_buffer`
- `kadath_rhi_submit_commands`
- `kadath_world_create`

#### 6.2 类型命名

```
kadath_<module>_<noun>_t        // 不透明句柄 / POD 结构体
kadath_<module>_<noun>_fn       // 函数指针 typedef
```

#### 6.3 常量命名

```
KADATH_<MODULE>_<NAME>          // 全大写下划线
KADATH_ERR_<MODULE>_<REASON>    // 错误码
KADATH_OK                       // 成功
```

#### 6.4 头文件命名

```
abi/kadath_<module>.h           // 模块接口
abi/kadath_errors.h             // 统一错误码
abi/kadath_types.h              // 共享 POD 类型（如 vec2, rect 等）
```

---

## 后果

### 正面影响

1. **边界语义无歧义** — 两侧开发者不需要猜测"这个指针谁释放"、"这个函数能不能并发调用"，头文件 doc comment 就是答案
2. **错误传播可预测** — 统一的 `int32_t` 错误码让调用方可以用 switch/match 穷举处理，不存在"意外异常"
3. **panic 不跨边界** — Rust panic 在 `panic=unwind` 配置下被强制捕获；Zig abort 是进程级终止；两种失败都不会以未定义方式泄露给对方
4. **内存所有权显式** — 四种模式覆盖了所有合理场景，每个函数必须声明自己属于哪种，reviewer 可以机械检查
5. **可增量落地** — 规范是通用规则，不依赖具体模块 API 设计；模块可以逐个实现，每个模块只需遵守本 ADR

### 负面影响

1. **边界代码冗余** — 每个 ABI 函数都需要错误码映射、`catch_unwind` 包裹、doc comment 标注，代码量比纯语言内部调用多
2. **错误信息表达受限** — `int32_t` 错误码不如 `Result<T, DetailedError>` 表达力强；当前仅通过 `kadath_err_to_name()` 与 `kadath_err_to_message()` 提供稳定的调试辅助
3. **回调模式受限** — 不能传闭包、不能传 trait object，回调只能是 C 函数指针 + `void*`，表达力低于语言原生回调
4. **线程标注维护成本** — 每个函数都需要标注线程安全等级，且标注错误可能导致难以复现的并发 bug
5. **学习曲线** — 开发者需要理解四种内存模式、四类失败语义、线程标注规则，才能正确编写 ABI 函数

### 缓解措施

1. **提供 ABI 函数模板** — 在 `tools/` 或 `docs/` 中提供 Zig 和 Rust 的 ABI 函数模板，包含 `catch_unwind`、错误码映射、doc comment 骨架
2. **ABI 审查 checklist** — 每次新增 ABI 函数时，reviewer 按 checklist 逐项确认：内存模式标注、线程标注、错误码范围、panic 捕获
3. **统一的 Rust ABI 宏（可选）** — 后续可考虑提供 `#[kadath_abi]` proc-macro，自动生成 `catch_unwind` + 错误码映射骨架
4. **错误文本仅用于调试** — `kadath_err_to_name()` 与 `kadath_err_to_message()` 不作为程序逻辑分支依据，仅用于日志和调试输出，降低维护压力
5. **渐进式标注** — 首批模块（platform / mem / rhi）先落地标注，后续模块参照已有模式

---

## 替代方案

### 为什么不用"跨语言 Result 结构体"

```c
// 被否决的方案
typedef struct {
    int32_t code;
    void* value;
    size_t value_size;
} kadath_result_t;
```

否决理由：
- `void*` 返回值需要调用方 cast，类型安全完全丧失
- 结构体返回值在不同平台的 ABI 不一致（有些平台通过寄存器，有些通过栈）
- 增加了每次调用的认知负担（需要先检查 code，再 cast value）
- 纯 `int32_t` + out-parameter 更简单、更可预测、跨平台行为一致

### 为什么不用 errno 风格

否决理由：
- `errno` 是全局/线程局部状态，容易被中间调用覆盖
- 调用方容易忘记检查
- 返回值被占用为"实际结果"时，无法区分"返回 0 是成功"还是"返回 0 是结果值"
- 本方案用返回值做错误码 + out-parameter 做结果，语义更清晰

### 为什么不用 C++ 异常

否决理由：
- 项目不使用 C++ 作为实现语言（ADR-0001 禁止）
- C++ 异常跨 C ABI 边界是未定义行为
- 异常的运行时开销和二进制膨胀不可接受

### 为什么不让 Zig error 直接跨边界

否决理由：
- Zig 的 `error{...}` 是编译期枚举，ABI 不稳定（不同编译版本可能改变枚举值）
- Rust 侧无法理解 Zig 的 error union 内存布局
- C ABI 没有 error union 的概念
- 统一为 `int32_t` 是唯一跨语言稳定的方案

---

## 相关决策

- **ADR-0001: 语言选型策略** — 本 ADR 是 ADR-0001 "禁止事项第 3 条"的解锁条件
- **ADR-0002: 构建系统与项目结构** — `abi/` 目录结构和 `bindgen` 集成由 ADR-0002 定义
- **ADR-0005: 世界模型方向** — world 模块的 ABI 函数设计将遵守本 ADR

---

## 未来演进

### 可能的优化方向

1. **`#[kadath_abi]` proc-macro** — 自动生成 Rust 侧的 `catch_unwind` + 错误码映射 + `set_last_error` 调用，减少样板代码
2. **ABI 兼容性测试** — 编写跨语言集成测试，验证错误码传播、内存释放、线程标注的正确性
3. **错误码自动生成** — 从 `abi/kadath_errors.h` 自动生成 Zig 和 Rust 侧的常量定义，避免手动同步
4. **静态分析** — 后续可考虑用 clang-tidy 或自定义 lint 检查头文件是否符合本 ADR 的标注要求

### 不考虑的方向

- **动态类型边界**（如 protobuf / flatbuffers 序列化）— 性能开销不可接受，引擎内部调用不需要序列化
- **COM / CORBA 风格接口** — 过度工程化，单进程内不需要
- **自动 ABI 生成工具**（如 cbindgen 反向生成）— 当前规模手写可控，且手写能保证命名和文档质量

---

## 审阅记录

- 2026-05-27: 初稿，待主导者审阅
- 2026-06-04: 主导者确认采用，状态调整为“已采纳”
