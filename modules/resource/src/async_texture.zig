const std = @import("std");
const scheduler_api = @import("scheduler");
const texture_decode = @import("texture_decode.zig");

pub const TextureData = texture_decode.TextureData;

pub const AsyncTextureFailureStage = enum {
    submit,
    read,
    decode,
};

pub const AsyncTextureFailureReason = enum {
    scheduler_unavailable,
    invalid_key,
    not_found,
    too_large,
    io_failure,
    worker_panicked,
    invalid_artifact,
    unsupported_version,
    allocation_failed,
    internal,
};

pub const AsyncTextureFailure = struct {
    stage: AsyncTextureFailureStage,
    reason: AsyncTextureFailureReason,
};

pub const AsyncTextureResult = union(enum) {
    loaded: TextureData,
    failed: AsyncTextureFailure,
};

const State = union(enum) {
    idle,
    pending: scheduler_api.JobId,
    ready: AsyncTextureResult,
    delivered,
};

/// Resource-owned 的一次性异步纹理加载器。
///
/// Scheduler JobId、raw bytes、8 MiB 上限和 decode seam 均为私有实现；Host 只能提交
/// 一个 key，并在 owner thread 非阻塞取得一次 loaded/failed。
pub const AsyncTextureLoader = struct {
    allocator: std.mem.Allocator,
    scheduler: ?scheduler_api.Scheduler,
    startup_failure: ?AsyncTextureFailureReason,
    state: State = .idle,
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator) AsyncTextureLoader {
        const scheduler = scheduler_api.Scheduler.init() catch |err| {
            return .{
                .allocator = allocator,
                .scheduler = null,
                .startup_failure = mapSubmitFailure(err),
            };
        };
        return .{
            .allocator = allocator,
            .scheduler = scheduler,
            .startup_failure = null,
        };
    }

    pub fn request(self: *AsyncTextureLoader, texture_key: []const u8) error{RequestAlreadyIssued}!void {
        if (self.closed or std.meta.activeTag(self.state) != .idle) return error.RequestAlreadyIssued;

        if (self.startup_failure) |reason| {
            self.state = .{ .ready = failed(.submit, reason) };
            return;
        }
        const scheduler = if (self.scheduler) |*value| value else {
            self.state = .{ .ready = failed(.submit, .scheduler_unavailable) };
            return;
        };
        const job_id = scheduler.submitBoundedRead(
            texture_key,
            texture_decode.texture_artifact_max_bytes,
        ) catch |err| {
            // 即时提交失败也锁存为一次 Resource result，不把 Scheduler 错误泄漏给 Host。
            self.state = .{ .ready = failed(.submit, mapSubmitFailure(err)) };
            return;
        };
        self.state = .{ .pending = job_id };
    }

    /// owner-thread 非阻塞同步点。loaded 使用 init allocator 分配，返回后所有权转给 Host。
    pub fn poll(self: *AsyncTextureLoader) ?AsyncTextureResult {
        self.advance();
        return switch (self.state) {
            .ready => |result| blk: {
                self.state = .delivered;
                break :blk result;
            },
            else => null,
        };
    }

    /// 确定性关闭只用于生命周期边界；handler 永不返回时会阻塞。
    pub fn close(self: *AsyncTextureLoader) void {
        if (self.closed) return;
        self.closed = true;
        if (self.scheduler) |*scheduler| {
            scheduler.close() catch |err| {
                if (std.meta.activeTag(self.state) == .pending) {
                    self.state = .{ .ready = failed(.read, mapCloseFailure(err)) };
                }
                return;
            };
            self.advance();
            // close 成功后已接受的单个任务必有 completion；缺失属于内部不变量破坏。
            if (std.meta.activeTag(self.state) == .pending) {
                self.state = .{ .ready = failed(.read, .internal) };
            }
        }
    }

    pub fn deinit(self: *AsyncTextureLoader) void {
        self.close();
        switch (self.state) {
            .ready => |*result| switch (result.*) {
                .loaded => |*texture| texture.deinit(self.allocator),
                .failed => {},
            },
            else => {},
        }
        if (self.scheduler) |*scheduler| scheduler.deinit();
        self.scheduler = null;
        self.state = .delivered;
    }

    fn advance(self: *AsyncTextureLoader) void {
        const expected_job = switch (self.state) {
            .pending => |job_id| job_id,
            else => return,
        };
        const scheduler = if (self.scheduler) |*value| value else {
            self.state = .{ .ready = failed(.read, .scheduler_unavailable) };
            return;
        };
        var completion = scheduler.poll() catch |err| {
            self.state = .{ .ready = failed(.read, mapPollFailure(err)) };
            return;
        } orelse return;
        // 关键所有权不变量：无论 decode 成功、失败或身份异常，raw bytes 都只释放一次。
        defer completion.deinit();

        if (completion.job_id != expected_job) {
            self.state = .{ .ready = failed(.read, .internal) };
            return;
        }
        self.state = .{ .ready = switch (completion.outcome) {
            .succeeded => |*bytes| decoded: {
                const texture = texture_decode.decodeTextureArtifact(
                    self.allocator,
                    bytes.slice(),
                ) catch |err| break :decoded failed(.decode, mapDecodeFailure(err));
                break :decoded .{ .loaded = texture };
            },
            .failed => |reason| failed(.read, switch (reason) {
                .not_found => .not_found,
                .too_large => .too_large,
                .io_failure => .io_failure,
                .allocation_failed => .allocation_failed,
                .internal => .internal,
            }),
            .panicked => failed(.read, .worker_panicked),
        } };
    }
};

fn failed(stage: AsyncTextureFailureStage, reason: AsyncTextureFailureReason) AsyncTextureResult {
    return .{ .failed = .{ .stage = stage, .reason = reason } };
}

fn mapSubmitFailure(err: anyerror) AsyncTextureFailureReason {
    return switch (err) {
        error.InvalidSchedulerKey => .invalid_key,
        error.SchedulerWorkerUnavailable, error.SchedulerCreationFailed => .scheduler_unavailable,
        error.SchedulerAllocationFailed, error.OutOfMemory => .allocation_failed,
        // 单 outstanding 正常路径不可触发 capacity/identity 等底层状态，统一收敛为 internal。
        else => .internal,
    };
}

fn mapPollFailure(err: anyerror) AsyncTextureFailureReason {
    return switch (err) {
        error.SchedulerWorkerPanicked => .worker_panicked,
        error.SchedulerAllocationFailed, error.OutOfMemory => .allocation_failed,
        else => .internal,
    };
}

fn mapCloseFailure(err: anyerror) AsyncTextureFailureReason {
    return switch (err) {
        error.SchedulerWorkerPanicked => .worker_panicked,
        else => .internal,
    };
}

fn mapDecodeFailure(err: anyerror) AsyncTextureFailureReason {
    return switch (err) {
        error.UnsupportedTextureArtifactVersion => .unsupported_version,
        error.OutOfMemory => .allocation_failed,
        else => .invalid_artifact,
    };
}
