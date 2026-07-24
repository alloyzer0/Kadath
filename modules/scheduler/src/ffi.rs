use crate::{Completion, JobOutcome, Scheduler, SubmitError};
use std::{
    collections::VecDeque,
    fs::File,
    io::{self, Read},
    num::NonZeroUsize,
    panic::{catch_unwind, AssertUnwindSafe},
    path::PathBuf,
    ptr,
    thread::{self, ThreadId},
};

#[allow(non_camel_case_types, non_upper_case_globals, dead_code)]
mod abi {
    include!(concat!(env!("OUT_DIR"), "/kadath_scheduler_bindings.rs"));
}

struct ReadRequest {
    path: PathBuf,
    exclusive_limit: usize,
}

#[derive(Debug)]
enum ReadFailure {
    NotFound,
    TooLarge,
    IoFailure,
    AllocationFailed,
}

type ReadScheduler = Scheduler<ReadRequest, Box<[u8]>, ReadFailure>;

struct FfiScheduler {
    owner_thread: ThreadId,
    scheduler: Option<ReadScheduler>,
    closed_completions: VecDeque<Completion<Box<[u8]>, ReadFailure>>,
}

impl FfiScheduler {
    fn start() -> io::Result<Self> {
        let capacity = NonZeroUsize::new(1).expect("scheduler capacity is non-zero");
        Ok(Self {
            owner_thread: thread::current().id(),
            scheduler: Some(Scheduler::start(capacity, read_bounded)?),
            closed_completions: VecDeque::new(),
        })
    }

    fn ensure_owner_thread(&self) -> Result<(), i32> {
        if self.owner_thread == thread::current().id() {
            Ok(())
        } else {
            Err(code(abi::KADATH_ERR_SCHEDULER_INVALID_STATE))
        }
    }

    fn try_next_completed(&mut self) -> Option<Completion<Box<[u8]>, ReadFailure>> {
        if let Some(completion) = self.closed_completions.pop_front() {
            return Some(completion);
        }
        self.scheduler.as_mut()?.try_next_completed()
    }

    fn close(&mut self) -> Result<(), i32> {
        let Some(scheduler) = self.scheduler.take() else {
            return Ok(());
        };
        let report = scheduler.shutdown();
        self.closed_completions = report.completions.into();
        if report.worker_panicked || report.abandoned_jobs != 0 {
            Err(code(abi::KADATH_ERR_SCHEDULER_WORKER_PANICKED))
        } else {
            Ok(())
        }
    }
}

fn read_bounded(request: ReadRequest) -> Result<Box<[u8]>, ReadFailure> {
    let mut file = File::open(&request.path).map_err(|error| {
        if error.kind() == io::ErrorKind::NotFound {
            ReadFailure::NotFound
        } else {
            ReadFailure::IoFailure
        }
    })?;
    let mut bytes = Vec::new();
    let mut scratch = [0_u8; 64 * 1024];

    loop {
        let read = file
            .read(&mut scratch)
            .map_err(|_| ReadFailure::IoFailure)?;
        if read == 0 {
            break;
        }
        let new_len = bytes.len().checked_add(read).ok_or(ReadFailure::TooLarge)?;
        // 关键边界：limit 是严格上界，精确达到 limit 的 artifact 也必须拒绝。
        if new_len >= request.exclusive_limit {
            return Err(ReadFailure::TooLarge);
        }
        bytes
            .try_reserve(read)
            .map_err(|_| ReadFailure::AllocationFailed)?;
        bytes.extend_from_slice(&scratch[..read]);
    }

    // try_reserve 的失败可报告；标准分配器在其他分配点仍可能 abort，本 ABI 不承诺全局 OOM 可恢复。
    Ok(bytes.into_boxed_slice())
}

fn code(value: u32) -> i32 {
    value as i32
}

#[allow(clippy::unnecessary_cast)]
fn outcome_code(value: abi::kadath_scheduler_completion_outcome_t) -> i32 {
    // bindgen 在 MSVC/GNU target 下可能选择 i32 或 u32；C POD 字段固定为 int32_t。
    value as i32
}

#[allow(clippy::unnecessary_cast)]
fn reason_code(value: abi::kadath_scheduler_completion_reason_t) -> i32 {
    // bindgen 在 MSVC/GNU target 下可能选择 i32 或 u32；C POD 字段固定为 int32_t。
    value as i32
}

fn ffi_boundary(operation: impl FnOnce() -> Result<(), i32>) -> i32 {
    match catch_unwind(AssertUnwindSafe(operation)) {
        Ok(Ok(())) => code(abi::KADATH_OK),
        Ok(Err(error)) => error,
        Err(_) => code(abi::KADATH_ERR_INTERNAL),
    }
}

fn copy_path(path: &[u8]) -> Result<PathBuf, i32> {
    let value =
        std::str::from_utf8(path).map_err(|_| code(abi::KADATH_ERR_SCHEDULER_INVALID_KEY))?;
    if value.is_empty() || value.as_bytes().contains(&0) {
        return Err(code(abi::KADATH_ERR_SCHEDULER_INVALID_KEY));
    }
    let mut owned = String::new();
    owned
        .try_reserve_exact(value.len())
        .map_err(|_| code(abi::KADATH_ERR_SCHEDULER_ALLOCATION_FAILED))?;
    owned.push_str(value);
    Ok(PathBuf::from(owned))
}

fn read_failure_reason(failure: ReadFailure) -> i32 {
    match failure {
        ReadFailure::NotFound => {
            reason_code(abi::kadath_scheduler_completion_reason_t_KADATH_SCHEDULER_REASON_NOT_FOUND)
        }
        ReadFailure::TooLarge => {
            reason_code(abi::kadath_scheduler_completion_reason_t_KADATH_SCHEDULER_REASON_TOO_LARGE)
        }
        ReadFailure::IoFailure => reason_code(
            abi::kadath_scheduler_completion_reason_t_KADATH_SCHEDULER_REASON_IO_FAILURE,
        ),
        ReadFailure::AllocationFailed => reason_code(
            abi::kadath_scheduler_completion_reason_t_KADATH_SCHEDULER_REASON_ALLOCATION_FAILED,
        ),
    }
}

fn completion_to_abi(
    completion: Completion<Box<[u8]>, ReadFailure>,
) -> abi::kadath_scheduler_completion_t {
    let mut result = abi::kadath_scheduler_completion_t {
        job_id: completion.job_id.get(),
        outcome: 0,
        failure_reason: reason_code(
            abi::kadath_scheduler_completion_reason_t_KADATH_SCHEDULER_REASON_NONE,
        ),
        bytes: abi::kadath_scheduler_bytes_t {
            data: ptr::null_mut(),
            len: 0,
        },
    };
    match completion.outcome {
        JobOutcome::Succeeded(bytes) => {
            result.outcome = outcome_code(
                abi::kadath_scheduler_completion_outcome_t_KADATH_SCHEDULER_COMPLETION_SUCCEEDED,
            );
            result.bytes.len = bytes.len();
            // Box<[u8]> 即使长度为零也提供非空所有权指针；必须由 paired free 重建。
            result.bytes.data = Box::into_raw(bytes) as *mut u8;
        }
        JobOutcome::Failed(failure) => {
            result.outcome = outcome_code(
                abi::kadath_scheduler_completion_outcome_t_KADATH_SCHEDULER_COMPLETION_FAILED,
            );
            result.failure_reason = read_failure_reason(failure);
        }
        JobOutcome::Panicked => {
            result.outcome = outcome_code(
                abi::kadath_scheduler_completion_outcome_t_KADATH_SCHEDULER_COMPLETION_PANICKED,
            );
        }
    }
    result
}

#[no_mangle]
pub extern "C" fn kadath_scheduler_create(out_scheduler: *mut abi::kadath_scheduler_t) -> i32 {
    ffi_boundary(|| {
        if out_scheduler.is_null() {
            return Err(code(abi::KADATH_ERR_INVALID_ARGUMENT));
        }
        let scheduler = FfiScheduler::start()
            .map_err(|_| code(abi::KADATH_ERR_SCHEDULER_WORKER_UNAVAILABLE))?;
        let raw = Box::into_raw(Box::new(scheduler)).cast::<abi::kadath_scheduler_opaque_t>();
        // 安全性：非空 out 指针由调用方提供，且只在完整构造成功后写入一次。
        unsafe { out_scheduler.write(raw) };
        Ok(())
    })
}

#[no_mangle]
pub extern "C" fn kadath_scheduler_submit_bounded_read(
    scheduler: abi::kadath_scheduler_t,
    path: *const u8,
    path_len: usize,
    exclusive_limit: usize,
    out_job_id: *mut u64,
) -> i32 {
    ffi_boundary(|| {
        if scheduler.is_null() || out_job_id.is_null() || path.is_null() || exclusive_limit == 0 {
            return Err(code(abi::KADATH_ERR_INVALID_ARGUMENT));
        }
        if path_len == 0 {
            return Err(code(abi::KADATH_ERR_SCHEDULER_INVALID_KEY));
        }
        // 安全性：调用方保证非空 path 指向至少 path_len 个在本次调用内有效的字节。
        let path = unsafe { std::slice::from_raw_parts(path, path_len) };
        let request = ReadRequest {
            path: copy_path(path)?,
            exclusive_limit,
        };
        // 安全性：opaque handle 只能来自 create，且契约要求在 destroy 后不再使用。
        let handle = unsafe { &mut *scheduler.cast::<FfiScheduler>() };
        handle.ensure_owner_thread()?;
        let scheduler = handle
            .scheduler
            .as_mut()
            .ok_or_else(|| code(abi::KADATH_ERR_SCHEDULER_INVALID_STATE))?;
        let job_id = match scheduler.try_submit(request) {
            Ok(job_id) => job_id,
            Err(SubmitError::AtCapacity(_)) => {
                return Err(code(abi::KADATH_ERR_SCHEDULER_AT_CAPACITY));
            }
            Err(SubmitError::WorkerUnavailable(_)) => {
                return Err(code(abi::KADATH_ERR_SCHEDULER_WORKER_UNAVAILABLE));
            }
            Err(SubmitError::JobIdExhausted(_)) => {
                return Err(code(abi::KADATH_ERR_SCHEDULER_JOB_ID_EXHAUSTED));
            }
        };
        // 安全性：out_job_id 已验证非空；提交成功后才事务性写出身份。
        unsafe { out_job_id.write(job_id.get()) };
        Ok(())
    })
}

#[no_mangle]
pub extern "C" fn kadath_scheduler_poll(
    scheduler: abi::kadath_scheduler_t,
    out_has_completion: *mut u8,
    out_completion: *mut abi::kadath_scheduler_completion_t,
) -> i32 {
    ffi_boundary(|| {
        if scheduler.is_null() || out_has_completion.is_null() || out_completion.is_null() {
            return Err(code(abi::KADATH_ERR_INVALID_ARGUMENT));
        }
        // 安全性：opaque handle 只能来自 create，且本函数只在 owner thread 调用。
        let handle = unsafe { &mut *scheduler.cast::<FfiScheduler>() };
        handle.ensure_owner_thread()?;
        let Some(completion) = handle.try_next_completed() else {
            // 安全性：无结果只写 has=0，保持 completion 原值不变。
            unsafe { out_has_completion.write(0) };
            return Ok(());
        };
        let output = completion_to_abi(completion);
        // 安全性：两个 out 指针均已验证；完整 POD 先写入，最后发布 has=1。
        unsafe {
            out_completion.write(output);
            out_has_completion.write(1);
        }
        Ok(())
    })
}

#[no_mangle]
pub extern "C" fn kadath_scheduler_close(scheduler: abi::kadath_scheduler_t) -> i32 {
    ffi_boundary(|| {
        if scheduler.is_null() {
            return Err(code(abi::KADATH_ERR_INVALID_ARGUMENT));
        }
        // 安全性：opaque handle 只能来自 create；close 不消费其分配。
        let handle = unsafe { &mut *scheduler.cast::<FfiScheduler>() };
        handle.ensure_owner_thread()?;
        handle.close()
    })
}

#[no_mangle]
pub extern "C" fn kadath_scheduler_destroy(inout_scheduler: *mut abi::kadath_scheduler_t) -> i32 {
    ffi_boundary(|| {
        if inout_scheduler.is_null() {
            return Err(code(abi::KADATH_ERR_INVALID_ARGUMENT));
        }
        // 安全性：先读取调用方唯一 handle 变量；空 handle 不是可重复 destroy 的对象。
        let raw = unsafe { inout_scheduler.read() };
        if raw.is_null() {
            return Err(code(abi::KADATH_ERR_INVALID_ARGUMENT));
        }
        // 安全性：raw 只能来自 create，在消费所有权前先验证 owner thread。
        let handle = unsafe { &mut *raw.cast::<FfiScheduler>() };
        handle.ensure_owner_thread()?;
        // 安全性：清空原变量后用同一 create 指针重建 Box，保证精确消费一次。
        unsafe { inout_scheduler.write(ptr::null_mut()) };
        let mut owned = unsafe { Box::from_raw(raw.cast::<FfiScheduler>()) };
        let close_result = owned.close();
        drop(owned);
        close_result
    })
}

#[no_mangle]
pub extern "C" fn kadath_scheduler_bytes_free(
    inout_bytes: *mut abi::kadath_scheduler_bytes_t,
) -> i32 {
    ffi_boundary(|| {
        if inout_bytes.is_null() {
            return Err(code(abi::KADATH_ERR_INVALID_ARGUMENT));
        }
        // 安全性：descriptor 指针非空，调用方保证它是 poll 返回且尚未释放的原对象。
        let descriptor = unsafe { &mut *inout_bytes };
        if descriptor.data.is_null() {
            return Err(code(abi::KADATH_ERR_INVALID_ARGUMENT));
        }
        let data = descriptor.data;
        let len = descriptor.len;
        descriptor.data = ptr::null_mut();
        descriptor.len = 0;
        // 安全性：data/len 来自 Box<[u8]>::into_raw；slice layout 与原分配完全一致。
        let raw_slice = ptr::slice_from_raw_parts_mut(data, len);
        drop(unsafe { Box::from_raw(raw_slice) });
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        sync::atomic::{AtomicU64, Ordering},
    };

    static NEXT_FILE: AtomicU64 = AtomicU64::new(1);

    fn temporary_file(bytes: &[u8]) -> PathBuf {
        let id = NEXT_FILE.fetch_add(1, Ordering::Relaxed);
        let path =
            std::env::temp_dir().join(format!("kadath-scheduler-{}-{id}.bin", std::process::id()));
        fs::write(&path, bytes).expect("temporary scheduler input must be writable");
        path
    }

    #[test]
    fn ffi_transfers_boxed_bytes_and_clears_descriptor() {
        let path = temporary_file(b"scheduler-bytes");
        let path_text = path.to_string_lossy();
        let mut scheduler: abi::kadath_scheduler_t = ptr::null_mut();
        assert_eq!(
            kadath_scheduler_create(&mut scheduler),
            code(abi::KADATH_OK)
        );
        let mut job_id = 0;
        assert_eq!(
            kadath_scheduler_submit_bounded_read(
                scheduler,
                path_text.as_bytes().as_ptr(),
                path_text.len(),
                1024,
                &mut job_id,
            ),
            code(abi::KADATH_OK)
        );
        assert_ne!(job_id, 0);
        assert_eq!(kadath_scheduler_close(scheduler), code(abi::KADATH_OK));

        let mut has_completion = 0;
        let mut completion = abi::kadath_scheduler_completion_t::default();
        assert_eq!(
            kadath_scheduler_poll(scheduler, &mut has_completion, &mut completion),
            code(abi::KADATH_OK)
        );
        assert_eq!(has_completion, 1);
        assert_eq!(
            completion.outcome,
            outcome_code(
                abi::kadath_scheduler_completion_outcome_t_KADATH_SCHEDULER_COMPLETION_SUCCEEDED,
            )
        );
        // 安全性：descriptor 尚未 free，data 指向 len 个有效字节。
        let actual =
            unsafe { std::slice::from_raw_parts(completion.bytes.data, completion.bytes.len) };
        assert_eq!(actual, b"scheduler-bytes");
        assert_eq!(
            kadath_scheduler_bytes_free(&mut completion.bytes),
            code(abi::KADATH_OK)
        );
        assert!(completion.bytes.data.is_null());
        assert_eq!(completion.bytes.len, 0);
        assert_eq!(
            kadath_scheduler_destroy(&mut scheduler),
            code(abi::KADATH_OK)
        );
        assert!(scheduler.is_null());
        fs::remove_file(path).expect("temporary scheduler input must be removable");
    }

    #[test]
    fn ffi_destroy_releases_unconsumed_completion() {
        let path = temporary_file(b"unconsumed");
        let path_text = path.to_string_lossy();
        let mut scheduler: abi::kadath_scheduler_t = ptr::null_mut();
        assert_eq!(
            kadath_scheduler_create(&mut scheduler),
            code(abi::KADATH_OK)
        );
        let mut job_id = 0;
        assert_eq!(
            kadath_scheduler_submit_bounded_read(
                scheduler,
                path_text.as_bytes().as_ptr(),
                path_text.len(),
                1024,
                &mut job_id,
            ),
            code(abi::KADATH_OK)
        );
        // destroy 通过 close/join 取得 completion，再由 Rust drop 未移交的 Box<[u8]>。
        assert_eq!(
            kadath_scheduler_destroy(&mut scheduler),
            code(abi::KADATH_OK)
        );
        assert!(scheduler.is_null());
        fs::remove_file(path).expect("temporary scheduler input must be removable");
    }
}
