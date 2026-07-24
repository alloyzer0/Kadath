const std = @import("std");

const c = @cImport({
    @cInclude("kadath_scheduler.h");
});

pub const JobId = u64;

pub const ReadFailure = enum {
    not_found,
    too_large,
    io_failure,
    allocation_failed,
    internal,
};

pub const OwnedBytes = struct {
    descriptor: c.kadath_scheduler_bytes_t,

    pub fn slice(self: *const OwnedBytes) []const u8 {
        if (self.descriptor.len == 0) return &.{};
        return self.descriptor.data[0..self.descriptor.len];
    }

    pub fn deinit(self: *OwnedBytes) void {
        check(c.kadath_scheduler_bytes_free(&self.descriptor)) catch |err| {
            std.log.err("Scheduler bytes release failed: {s}", .{@errorName(err)});
        };
    }
};

pub const Outcome = union(enum) {
    succeeded: OwnedBytes,
    failed: ReadFailure,
    panicked,
};

pub const Completion = struct {
    job_id: JobId,
    outcome: Outcome,

    pub fn deinit(self: *Completion) void {
        switch (self.outcome) {
            .succeeded => |*bytes| bytes.deinit(),
            else => {},
        }
    }
};

pub const Scheduler = struct {
    handle: c.kadath_scheduler_t,

    pub fn init() !Scheduler {
        var handle: c.kadath_scheduler_t = null;
        try check(c.kadath_scheduler_create(&handle));
        if (handle == null) return error.SchedulerCreationFailed;
        return .{ .handle = handle };
    }

    pub fn submitBoundedRead(self: *Scheduler, path: []const u8, exclusive_limit: usize) !JobId {
        var job_id: u64 = 0;
        try check(c.kadath_scheduler_submit_bounded_read(
            self.handle,
            path.ptr,
            path.len,
            exclusive_limit,
            &job_id,
        ));
        if (job_id == 0) return error.SchedulerInvalidJobId;
        return job_id;
    }

    pub fn poll(self: *Scheduler) !?Completion {
        var has_completion: u8 = 0;
        var raw = std.mem.zeroes(c.kadath_scheduler_completion_t);
        try check(c.kadath_scheduler_poll(self.handle, &has_completion, &raw));
        if (has_completion == 0) return null;
        if (has_completion != 1 or raw.job_id == 0) {
            releaseUnexpectedBytes(&raw);
            return error.SchedulerInvalidCompletion;
        }

        const outcome: Outcome = switch (raw.outcome) {
            c.KADATH_SCHEDULER_COMPLETION_SUCCEEDED => blk: {
                if (raw.bytes.data == null) return error.SchedulerInvalidCompletion;
                break :blk .{ .succeeded = .{ .descriptor = raw.bytes } };
            },
            c.KADATH_SCHEDULER_COMPLETION_FAILED => blk: {
                releaseUnexpectedBytes(&raw);
                break :blk .{ .failed = switch (raw.failure_reason) {
                    c.KADATH_SCHEDULER_REASON_NOT_FOUND => .not_found,
                    c.KADATH_SCHEDULER_REASON_TOO_LARGE => .too_large,
                    c.KADATH_SCHEDULER_REASON_IO_FAILURE => .io_failure,
                    c.KADATH_SCHEDULER_REASON_ALLOCATION_FAILED => .allocation_failed,
                    else => .internal,
                } };
            },
            c.KADATH_SCHEDULER_COMPLETION_PANICKED => blk: {
                releaseUnexpectedBytes(&raw);
                break :blk .panicked;
            },
            else => {
                releaseUnexpectedBytes(&raw);
                return error.SchedulerInvalidCompletion;
            },
        };
        return .{ .job_id = raw.job_id, .outcome = outcome };
    }

    pub fn close(self: *Scheduler) !void {
        try check(c.kadath_scheduler_close(self.handle));
    }

    pub fn deinit(self: *Scheduler) void {
        if (self.handle == null) return;
        check(c.kadath_scheduler_destroy(&self.handle)) catch |err| {
            // destroy 已消费并清空 handle；worker/handler panic 不得再次向 Host panic。
            std.log.err("Scheduler destroy failed: {s}", .{@errorName(err)});
        };
    }
};

fn releaseUnexpectedBytes(raw: *c.kadath_scheduler_completion_t) void {
    if (raw.bytes.data == null) return;
    check(c.kadath_scheduler_bytes_free(&raw.bytes)) catch |err| {
        std.log.err("Unexpected Scheduler bytes release failed: {s}", .{@errorName(err)});
    };
}

fn check(result: i32) !void {
    return switch (result) {
        c.KADATH_OK => {},
        c.KADATH_ERR_INVALID_ARGUMENT => error.InvalidSchedulerArgument,
        c.KADATH_ERR_INTERNAL => error.SchedulerInternal,
        c.KADATH_ERR_SCHEDULER_INVALID_KEY => error.InvalidSchedulerKey,
        c.KADATH_ERR_SCHEDULER_INVALID_STATE => error.InvalidSchedulerState,
        c.KADATH_ERR_SCHEDULER_AT_CAPACITY => error.SchedulerAtCapacity,
        c.KADATH_ERR_SCHEDULER_WORKER_UNAVAILABLE => error.SchedulerWorkerUnavailable,
        c.KADATH_ERR_SCHEDULER_JOB_ID_EXHAUSTED => error.SchedulerJobIdExhausted,
        c.KADATH_ERR_SCHEDULER_WORKER_PANICKED => error.SchedulerWorkerPanicked,
        c.KADATH_ERR_SCHEDULER_ALLOCATION_FAILED => error.SchedulerAllocationFailed,
        else => error.UnknownSchedulerError,
    };
}

comptime {
    // 关键 ABI 不变量：Resource Adapter 按值接收 completion，布局漂移必须在编译期失败。
    if (@sizeOf(c.kadath_scheduler_bytes_t) != @sizeOf(usize) * 2) {
        @compileError("Scheduler bytes descriptor ABI layout changed");
    }
}
