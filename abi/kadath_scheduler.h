#ifndef KADATH_SCHEDULER_H
#define KADATH_SCHEDULER_H

#include <stddef.h>
#include <stdint.h>

#include "kadath_errors.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct kadath_scheduler_opaque_t kadath_scheduler_opaque_t;
typedef kadath_scheduler_opaque_t* kadath_scheduler_t;

typedef enum kadath_scheduler_completion_outcome_t {
    KADATH_SCHEDULER_COMPLETION_SUCCEEDED = 1,
    KADATH_SCHEDULER_COMPLETION_FAILED = 2,
    KADATH_SCHEDULER_COMPLETION_PANICKED = 3,
} kadath_scheduler_completion_outcome_t;

typedef enum kadath_scheduler_completion_reason_t {
    KADATH_SCHEDULER_REASON_NONE = 0,
    KADATH_SCHEDULER_REASON_NOT_FOUND = 1,
    KADATH_SCHEDULER_REASON_TOO_LARGE = 2,
    KADATH_SCHEDULER_REASON_IO_FAILURE = 3,
    KADATH_SCHEDULER_REASON_ALLOCATION_FAILED = 4,
} kadath_scheduler_completion_reason_t;

typedef struct kadath_scheduler_bytes_t {
    uint8_t* data;
    size_t len;
} kadath_scheduler_bytes_t;

typedef struct kadath_scheduler_completion_t {
    uint64_t job_id;
    int32_t outcome;
    int32_t failure_reason;
    kadath_scheduler_bytes_t bytes;
} kadath_scheduler_completion_t;

// Thread-affine：create、submit、poll、close、destroy 必须由同一 owner thread 调用。
// 成功时写出 handle；失败时不修改 out_scheduler。
int32_t kadath_scheduler_create(kadath_scheduler_t* out_scheduler);

// path 在调用期间借用；成功提交前 Rust 会复制它。exclusive_limit 为严格上界。
// 只有成功提交时写 out_job_id，其他返回值不修改该 out 参数。
int32_t kadath_scheduler_submit_bounded_read(
    kadath_scheduler_t scheduler,
    const uint8_t* path,
    size_t path_len,
    size_t exclusive_limit,
    uint64_t* out_job_id
);

// 非阻塞摄取一个完成项。无结果时只写 out_has_completion=0，保持 completion 不变。
// 成功 bytes descriptor 必须由原对象精确调用一次 kadath_scheduler_bytes_free。
int32_t kadath_scheduler_poll(
    kadath_scheduler_t scheduler,
    uint8_t* out_has_completion,
    kadath_scheduler_completion_t* out_completion
);

// 停止接收并等待已接受任务完成。handler 永不返回时，本调用会一直阻塞。
int32_t kadath_scheduler_close(kadath_scheduler_t scheduler);

// 精确消费 handle 并清空原变量；未摄取 completion 在 Rust 侧释放。
int32_t kadath_scheduler_destroy(kadath_scheduler_t* inout_scheduler);

// 消费原 descriptor 并在成功后将 data/len 清零。len=0 仍拥有非空 Box 指针，
// 调用方不得解引用 data，但仍必须释放一次。复制 descriptor、修改字段或重复释放
// 均属于调用方契约违反。
int32_t kadath_scheduler_bytes_free(kadath_scheduler_bytes_t* inout_bytes);

#ifdef __cplusplus
}
#endif

#endif
