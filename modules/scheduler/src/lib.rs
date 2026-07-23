#![forbid(unsafe_code)]

//! Kadath 的最小后台任务调度器。
//!
//! 本模块只负责后台执行和结果回流；Runtime 仍在 owner/main thread 的受控同步点
//! 调用 [`Scheduler::drain_completed`]，决定何时把结果并入 World、Resource 或渲染状态。

use std::{
    marker::PhantomData,
    num::{NonZeroU64, NonZeroUsize},
    panic::{catch_unwind, RefUnwindSafe, UnwindSafe},
    rc::Rc,
    sync::mpsc::{self, Receiver, SyncSender, TrySendError},
    thread::{self, JoinHandle},
};

/// Scheduler 为每个成功接收的任务分配的进程内身份。
///
/// 身份从 1 开始单调递增，在同一个 Scheduler 生命周期内不复用。
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct JobId(NonZeroU64);

impl JobId {
    pub fn get(self) -> u64 {
        self.0.get()
    }
}

/// 后台任务完成后的稳定结果分类。
#[derive(Debug, PartialEq, Eq)]
pub enum JobOutcome<Output, Error> {
    Succeeded(Output),
    Failed(Error),
    /// handler panic 已在 worker 内捕获，没有越过线程边界。
    Panicked,
}

/// owner thread 在同步点摄取的任务结果。
#[derive(Debug, PartialEq, Eq)]
pub struct Completion<Output, Error> {
    pub job_id: JobId,
    pub outcome: JobOutcome<Output, Error>,
}

/// 非阻塞提交失败；每个分支都把尚未被 Scheduler 接收的输入返还给调用方。
#[derive(Debug, PartialEq, Eq)]
pub enum SubmitError<Input> {
    /// outstanding 已达到容量上限。
    AtCapacity(Input),
    /// worker 已异常退出，不能再接收任务。
    WorkerUnavailable(Input),
    /// 当前 Scheduler 已用尽全部可分配的 `u64` 身份。
    JobIdExhausted(Input),
}

impl<Input> SubmitError<Input> {
    pub fn into_input(self) -> Input {
        match self {
            Self::AtCapacity(input)
            | Self::WorkerUnavailable(input)
            | Self::JobIdExhausted(input) => input,
        }
    }
}

/// 确定性关闭后的结果摘要。
#[derive(Debug)]
pub struct ShutdownReport<Output, Error> {
    /// 关闭前尚未被 `drain_completed` 摄取的完成项，保持 FIFO 顺序。
    pub completions: Vec<Completion<Output, Error>>,
    /// 仅表示 worker 在线程入口内部发生了未被任务边界捕获的 panic。
    pub worker_panicked: bool,
    /// worker 异常退出时，已接收但没有形成 Completion 的任务数量。
    pub abandoned_jobs: usize,
}

impl<Output, Error> ShutdownReport<Output, Error> {
    pub fn is_clean(&self) -> bool {
        !self.worker_panicked && self.abandoned_jobs == 0
    }
}

struct Job<Input> {
    id: JobId,
    input: Input,
}

/// 单 worker、FIFO 的最小后台 Scheduler。
///
/// `Scheduler` 本体通过 `PhantomData<Rc<()>>` 明确为 `!Send + !Sync`：提交、结果摄取
/// 和关闭都只能由创建它的 owner thread 执行。只有任务输入、输出和 handler 会跨线程。
pub struct Scheduler<Input, Output, Error> {
    capacity: usize,
    outstanding: usize,
    next_job_id: Option<NonZeroU64>,
    job_sender: Option<SyncSender<Job<Input>>>,
    completion_receiver: Receiver<Completion<Output, Error>>,
    worker: Option<JoinHandle<()>>,
    // 关键不变量：owner 句柄不能被移动到其他线程，后台结果只能在原线程同步点摄取。
    _owner_thread: PhantomData<Rc<()>>,
}

impl<Input, Output, Error> Scheduler<Input, Output, Error>
where
    Input: Send + UnwindSafe + 'static,
    Output: Send + 'static,
    Error: Send + 'static,
{
    /// 启动一个后台 worker。
    ///
    /// `capacity` 限制全部 outstanding：排队、执行中以及已经完成但尚未摄取的任务
    /// 都会占用一个槽位。handler 必须满足 unwind-safe 约束，单个任务 panic 会转换为
    /// [`JobOutcome::Panicked`]，worker 随后继续处理队列。
    pub fn start<Handler>(capacity: NonZeroUsize, handler: Handler) -> std::io::Result<Self>
    where
        Handler: Fn(Input) -> Result<Output, Error> + Send + RefUnwindSafe + 'static,
    {
        let (job_sender, job_receiver) = mpsc::sync_channel(capacity.get());
        let (completion_sender, completion_receiver) = mpsc::channel();
        let worker = thread::Builder::new()
            .name("kadath-scheduler".to_owned())
            .spawn(move || {
                while let Ok(job) = job_receiver.recv() {
                    let Job { id, input } = job;
                    let handler_ref = &handler;
                    let outcome = match catch_unwind(move || handler_ref(input)) {
                        Ok(Ok(output)) => JobOutcome::Succeeded(output),
                        Ok(Err(error)) => JobOutcome::Failed(error),
                        Err(_) => JobOutcome::Panicked,
                    };

                    // 单 worker 在发送完成项后才接收下一任务，因此完成顺序与接受顺序一致。
                    if completion_sender
                        .send(Completion {
                            job_id: id,
                            outcome,
                        })
                        .is_err()
                    {
                        break;
                    }
                }
            })?;

        Ok(Self {
            capacity: capacity.get(),
            outstanding: 0,
            next_job_id: NonZeroU64::new(1),
            job_sender: Some(job_sender),
            completion_receiver,
            worker: Some(worker),
            _owner_thread: PhantomData,
        })
    }

    /// 非阻塞提交任务；只有成功进入队列后才转移输入所有权并消耗 JobId。
    pub fn try_submit(&mut self, input: Input) -> Result<JobId, SubmitError<Input>> {
        if self
            .worker
            .as_ref()
            .is_none_or(|worker| worker.is_finished())
        {
            return Err(SubmitError::WorkerUnavailable(input));
        }
        if self.outstanding == self.capacity {
            return Err(SubmitError::AtCapacity(input));
        }
        let Some(raw_id) = self.next_job_id else {
            return Err(SubmitError::JobIdExhausted(input));
        };
        let id = JobId(raw_id);
        let job = Job { id, input };
        let Some(sender) = self.job_sender.as_ref() else {
            return Err(SubmitError::WorkerUnavailable(job.input));
        };

        match sender.try_send(job) {
            Ok(()) => {
                // 关键不变量：JobId 只在提交成功后推进；失败提交可原样重试且不制造身份空洞。
                self.next_job_id = raw_id.get().checked_add(1).and_then(NonZeroU64::new);
                self.outstanding += 1;
                Ok(id)
            }
            Err(TrySendError::Full(job)) => Err(SubmitError::AtCapacity(job.input)),
            Err(TrySendError::Disconnected(job)) => Err(SubmitError::WorkerUnavailable(job.input)),
        }
    }
}

impl<Input, Output, Error> Scheduler<Input, Output, Error> {
    pub fn capacity(&self) -> usize {
        self.capacity
    }

    /// 尚未被 owner thread 摄取的任务数。
    pub fn outstanding(&self) -> usize {
        self.outstanding
    }

    /// 非阻塞取走调用时已经到达的全部完成项。
    pub fn drain_completed(&mut self) -> Vec<Completion<Output, Error>> {
        let mut completions = Vec::new();
        while let Ok(completion) = self.completion_receiver.try_recv() {
            // completion 只有在成功 submit 后才会产生，因此正常路径下 outstanding 必然大于 0。
            debug_assert!(self.outstanding > 0);
            self.outstanding = self.outstanding.saturating_sub(1);
            completions.push(completion);
        }
        completions
    }

    /// 停止接收新任务，等待全部已接收任务结束，并返回尚未摄取的完成项。
    ///
    /// 如果 handler 永不返回，本调用会一直阻塞；`Drop` 具有相同语义。最小 tracer bullet
    /// 不提供取消或强制终止线程，以免把不可靠的中断语义写入公共契约。
    pub fn shutdown(mut self) -> ShutdownReport<Output, Error> {
        self.finish()
    }

    fn finish(&mut self) -> ShutdownReport<Output, Error> {
        // 丢弃唯一 sender 会关闭输入队列；worker 会按 FIFO 处理完此前已接受的任务后退出。
        self.job_sender.take();
        let worker_panicked = self
            .worker
            .take()
            .is_some_and(|worker| worker.join().is_err());
        let completions = self.drain_completed();
        let abandoned_jobs = self.outstanding;
        self.outstanding = 0;

        ShutdownReport {
            completions,
            worker_panicked,
            abandoned_jobs,
        }
    }
}

impl<Input, Output, Error> Drop for Scheduler<Input, Output, Error> {
    fn drop(&mut self) {
        // join 的 panic 结果只进入 ShutdownReport；Drop 绝不因 worker/handler panic 主动再次 panic。
        drop(self.finish());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        panic::catch_unwind,
        sync::{Arc, Barrier},
    };

    fn capacity(value: usize) -> NonZeroUsize {
        NonZeroUsize::new(value).expect("test capacity must be non-zero")
    }

    #[test]
    fn shutdown_returns_successes_in_fifo_order() {
        let mut scheduler = Scheduler::start(capacity(3), |input: String| {
            Ok::<_, &'static str>(format!("done:{input}"))
        })
        .unwrap();

        let first = scheduler.try_submit("first".to_owned()).unwrap();
        let second = scheduler.try_submit("second".to_owned()).unwrap();
        assert_eq!(first.get(), 1);
        assert_eq!(second.get(), 2);
        assert_eq!(scheduler.outstanding(), 2);

        let report = scheduler.shutdown();
        assert!(report.is_clean());
        assert_eq!(report.completions.len(), 2);
        assert_eq!(report.completions[0].job_id, first);
        assert_eq!(report.completions[1].job_id, second);
        assert_eq!(
            report.completions[0].outcome,
            JobOutcome::Succeeded("done:first".to_owned())
        );
        assert_eq!(
            report.completions[1].outcome,
            JobOutcome::Succeeded("done:second".to_owned())
        );
    }

    #[test]
    fn failure_and_panic_are_results_and_worker_continues() {
        let mut scheduler = Scheduler::start(capacity(3), |input: u32| {
            if input == 1 {
                panic!("expected task panic");
            }
            if input == 2 {
                return Err("expected task failure");
            }
            Ok(input * 10)
        })
        .unwrap();

        let panicked = scheduler.try_submit(1).unwrap();
        let failed = scheduler.try_submit(2).unwrap();
        let succeeded = scheduler.try_submit(3).unwrap();
        let report = scheduler.shutdown();

        assert!(report.is_clean());
        assert_eq!(report.completions.len(), 3);
        assert_eq!(report.completions[0].job_id, panicked);
        assert_eq!(report.completions[0].outcome, JobOutcome::Panicked);
        assert_eq!(report.completions[1].job_id, failed);
        assert_eq!(
            report.completions[1].outcome,
            JobOutcome::Failed("expected task failure")
        );
        assert_eq!(report.completions[2].job_id, succeeded);
        assert_eq!(report.completions[2].outcome, JobOutcome::Succeeded(30));
    }

    #[test]
    fn unconsumed_completion_counts_toward_capacity() {
        let second_started = Arc::new(Barrier::new(2));
        let release_second = Arc::new(Barrier::new(2));
        let worker_started = Arc::clone(&second_started);
        let worker_release = Arc::clone(&release_second);
        let mut scheduler = Scheduler::start(capacity(2), move |input: u32| {
            if input == 2 {
                // worker 只有在发送任务 1 的 Completion 后，才可能开始执行任务 2。
                worker_started.wait();
                worker_release.wait();
            }
            Ok::<_, ()>(input * 10)
        })
        .unwrap();

        let first = scheduler.try_submit(1).unwrap();
        let second = scheduler.try_submit(2).unwrap();
        second_started.wait();

        assert_eq!(scheduler.outstanding(), 2);
        assert_eq!(scheduler.try_submit(3), Err(SubmitError::AtCapacity(3)));

        let ready = scheduler.drain_completed();
        assert_eq!(ready.len(), 1);
        assert_eq!(ready[0].job_id, first);
        assert_eq!(scheduler.outstanding(), 1);
        let third = scheduler.try_submit(3).unwrap();

        release_second.wait();
        let report = scheduler.shutdown();
        assert!(report.is_clean());
        assert_eq!(report.completions.len(), 2);
        assert_eq!(report.completions[0].job_id, second);
        assert_eq!(report.completions[1].job_id, third);
    }

    #[test]
    fn drain_is_non_blocking_while_job_is_running() {
        let started = Arc::new(Barrier::new(2));
        let release = Arc::new(Barrier::new(2));
        let worker_started = Arc::clone(&started);
        let worker_release = Arc::clone(&release);
        let mut scheduler = Scheduler::start(capacity(1), move |input: u32| {
            worker_started.wait();
            worker_release.wait();
            Ok::<_, ()>(input)
        })
        .unwrap();

        let job = scheduler.try_submit(7).unwrap();
        started.wait();
        assert!(scheduler.drain_completed().is_empty());
        assert_eq!(scheduler.outstanding(), 1);

        release.wait();
        let report = scheduler.shutdown();
        assert!(report.is_clean());
        assert_eq!(report.completions.len(), 1);
        assert_eq!(report.completions[0].job_id, job);
    }

    #[test]
    fn drop_does_not_repanic_after_handler_panic() {
        let drop_result = catch_unwind(|| {
            let mut scheduler = Scheduler::start(capacity(1), |(): ()| -> Result<(), ()> {
                panic!("expected task panic during Drop");
            })
            .unwrap();
            scheduler.try_submit(()).unwrap();
            drop(scheduler);
        });

        assert!(drop_result.is_ok());
    }
}
