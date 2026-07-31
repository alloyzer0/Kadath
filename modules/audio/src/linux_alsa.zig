const std = @import("std");
const Cue = @import("main.zig").Cue;

const c = @cImport({
    @cInclude("alsa/asoundlib.h");
    @cInclude("errno.h");
    @cInclude("time.h");
});

const won_path = "assets/audio/won.audio.wav";
const lost_path = "assets/audio/lost.audio.wav";
const queue_poll_ms: u64 = 2;
const cue_deadline_ms: u64 = 2_000;

const PcmFormat = struct {
    channels: u16,
    sample_rate: u32,
    block_align: u16,
};

const WavView = struct {
    format: PcmFormat,
    pcm: []const u8,
};

const OwnedClip = struct {
    bytes: []u8,
    view: WavView,

    fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !OwnedClip {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
        errdefer allocator.free(bytes);
        return .{ .bytes = bytes, .view = try parseCanonicalWav(bytes) };
    }

    fn deinit(self: *OwnedClip, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

const CueQueue = struct {
    pending: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn submit(self: *CueQueue, cue: Cue) bool {
        if (self.closed.load(.acquire)) return false;
        _ = self.pending.fetchOr(cueMask(cue), .release);
        return true;
    }

    fn take(self: *CueQueue) u8 {
        return self.pending.swap(0, .acquire);
    }

    fn close(self: *CueQueue) void {
        self.closed.store(true, .release);
    }

    fn finished(self: *const CueQueue) bool {
        return self.closed.load(.acquire) and self.pending.load(.acquire) == 0;
    }
};

const Sink = struct {
    context: *anyopaque,
    play_fn: *const fn (*anyopaque, WavView) anyerror!void,
    deinit_fn: *const fn (*anyopaque) void,

    fn play(self: Sink, clip: WavView) !void {
        try self.play_fn(self.context, clip);
    }

    fn deinit(self: Sink) void {
        self.deinit_fn(self.context);
    }
};

const AlsaSink = struct {
    allocator: std.mem.Allocator,
    handle: *c.snd_pcm_t,
    device_name: [:0]u8,
    format: PcmFormat,

    fn init(allocator: std.mem.Allocator, device_name: []const u8, format: PcmFormat) !*AlsaSink {
        const self = try allocator.create(AlsaSink);
        errdefer allocator.destroy(self);
        const device_z = try allocator.dupeZ(u8, device_name);
        errdefer allocator.free(device_z);

        var handle: ?*c.snd_pcm_t = null;
        if (c.snd_pcm_open(&handle, device_z, c.SND_PCM_STREAM_PLAYBACK, c.SND_PCM_NONBLOCK) < 0 or handle == null) {
            return error.AlsaDeviceOpenFailed;
        }
        errdefer _ = c.snd_pcm_close(handle.?);
        if (c.snd_pcm_set_params(
            handle.?,
            c.SND_PCM_FORMAT_S16_LE,
            c.SND_PCM_ACCESS_RW_INTERLEAVED,
            format.channels,
            format.sample_rate,
            1,
            100_000,
        ) < 0) return error.AlsaDeviceConfigureFailed;

        self.* = .{
            .allocator = allocator,
            .handle = handle.?,
            .device_name = device_z,
            .format = format,
        };
        return self;
    }

    fn asSink(self: *AlsaSink) Sink {
        return .{ .context = self, .play_fn = playAdapter, .deinit_fn = deinitAdapter };
    }

    fn playAdapter(context: *anyopaque, clip: WavView) !void {
        const self: *AlsaSink = @ptrCast(@alignCast(context));
        if (!std.meta.eql(self.format, clip.format)) return error.AudioFormatMismatch;
        if (c.snd_pcm_prepare(self.handle) < 0) return error.AlsaPrepareFailed;

        const total_frames = clip.pcm.len / clip.format.block_align;
        var frame_offset: usize = 0;
        const deadline = monotonicMilliseconds() +| cue_deadline_ms;
        while (frame_offset < total_frames) {
            const byte_offset = frame_offset * clip.format.block_align;
            const result = c.snd_pcm_writei(self.handle, clip.pcm.ptr + byte_offset, total_frames - frame_offset);
            if (result > 0) {
                frame_offset += @intCast(result);
                continue;
            }
            if (result == -c.EAGAIN) {
                if (monotonicMilliseconds() >= deadline) return error.AlsaWriteTimeout;
                sleepMilliseconds(queue_poll_ms);
                continue;
            }
            if (c.snd_pcm_recover(self.handle, @intCast(result), 1) < 0) return error.AlsaWriteFailed;
            if (monotonicMilliseconds() >= deadline) return error.AlsaWriteTimeout;
        }

        while (true) {
            const drain_result = c.snd_pcm_drain(self.handle);
            if (drain_result == 0) return;
            if (drain_result != -c.EAGAIN) return error.AlsaDrainFailed;
            if (monotonicMilliseconds() >= deadline) return error.AlsaDrainTimeout;
            sleepMilliseconds(queue_poll_ms);
        }
    }

    fn deinitAdapter(context: *anyopaque) void {
        const self: *AlsaSink = @ptrCast(@alignCast(context));
        _ = c.snd_pcm_drop(self.handle);
        _ = c.snd_pcm_close(self.handle);
        const allocator = self.allocator;
        allocator.free(self.device_name);
        allocator.destroy(self);
    }
};

const WorkerState = struct {
    allocator: std.mem.Allocator,
    queue: CueQueue = .{},
    sink: Sink,
    won: OwnedClip,
    lost: OwnedClip,

    fn run(self: *WorkerState) void {
        while (true) {
            const pending = self.queue.take();
            if (pending & cueMask(.lost) != 0) self.playCue(.lost, self.lost.view);
            if (pending & cueMask(.won) != 0) self.playCue(.won, self.won.view);
            if (self.queue.finished()) return;
            sleepMilliseconds(queue_poll_ms);
        }
    }

    fn playCue(self: *WorkerState, cue: Cue, clip: WavView) void {
        self.sink.play(clip) catch |err| {
            std.log.warn("Audio cue failed: {s}, reason={s}", .{ @tagName(cue), @errorName(err) });
            return;
        };
        std.log.info("Audio cue played: {s}", .{@tagName(cue)});
    }

    fn deinit(self: *WorkerState) void {
        self.sink.deinit();
        self.won.deinit(self.allocator);
        self.lost.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

pub const Backend = struct {
    state: *WorkerState,
    thread: std.Thread,
    device_name: []const u8,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) !Backend {
        var won = try OwnedClip.load(io, allocator, won_path);
        errdefer won.deinit(allocator);
        var lost = try OwnedClip.load(io, allocator, lost_path);
        errdefer lost.deinit(allocator);
        if (!std.meta.eql(won.view.format, lost.view.format)) return error.AudioFormatMismatch;

        const device = if (c.getenv("KADATH_AUDIO_DEVICE")) |value| std.mem.span(value) else "default";
        const alsa = try AlsaSink.init(allocator, device, won.view.format);
        errdefer alsa.asSink().deinit();
        const state = try allocator.create(WorkerState);
        errdefer allocator.destroy(state);
        state.* = .{
            .allocator = allocator,
            .sink = alsa.asSink(),
            .won = won,
            .lost = lost,
        };
        const thread = try std.Thread.spawn(.{}, WorkerState.run, .{state});
        return .{ .state = state, .thread = thread, .device_name = alsa.device_name };
    }

    pub fn deviceName(self: *const Backend) []const u8 {
        return self.device_name;
    }

    pub fn play(self: *Backend, cue: Cue) void {
        _ = self.state.queue.submit(cue);
    }

    pub fn deinit(self: *Backend) void {
        self.state.queue.close();
        self.thread.join();
        self.state.deinit();
        self.* = undefined;
    }
};

fn parseCanonicalWav(bytes: []const u8) !WavView {
    if (bytes.len < 44 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE")) {
        return error.InvalidCanonicalWav;
    }
    if (@as(u64, readU32(bytes[4..8])) + 8 != bytes.len or !std.mem.eql(u8, bytes[12..16], "fmt ") or readU32(bytes[16..20]) != 16) {
        return error.InvalidCanonicalWav;
    }
    const channels = readU16(bytes[22..24]);
    const sample_rate = readU32(bytes[24..28]);
    const byte_rate = readU32(bytes[28..32]);
    const block_align = readU16(bytes[32..34]);
    const bits_per_sample = readU16(bytes[34..36]);
    if (readU16(bytes[20..22]) != 1 or channels == 0 or channels > 2 or sample_rate == 0 or bits_per_sample != 16) {
        return error.InvalidCanonicalWav;
    }
    if (block_align != channels * 2 or @as(u64, byte_rate) != @as(u64, sample_rate) * block_align) return error.InvalidCanonicalWav;
    const pcm_size = readU32(bytes[40..44]);
    if (!std.mem.eql(u8, bytes[36..40], "data") or @as(u64, pcm_size) + 44 != bytes.len or pcm_size % block_align != 0) {
        return error.InvalidCanonicalWav;
    }
    return .{
        .format = .{ .channels = channels, .sample_rate = sample_rate, .block_align = block_align },
        .pcm = bytes[44..],
    };
}

fn cueMask(cue: Cue) u8 {
    return @as(u8, 1) << @intFromEnum(cue);
}

fn readU16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn readU32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24);
}

fn monotonicMilliseconds() u64 {
    var value = std.mem.zeroes(c.struct_timespec);
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &value) != 0 or value.tv_sec < 0 or value.tv_nsec < 0) return std.math.maxInt(u64);
    return @as(u64, @intCast(value.tv_sec)) * 1000 + @as(u64, @intCast(value.tv_nsec)) / 1_000_000;
}

fn sleepMilliseconds(milliseconds: u64) void {
    var request = c.struct_timespec{
        .tv_sec = @intCast(milliseconds / 1000),
        .tv_nsec = @intCast((milliseconds % 1000) * 1_000_000),
    };
    var remaining = std.mem.zeroes(c.struct_timespec);
    while (true) {
        const result = c.nanosleep(&request, &remaining);
        if (result == 0) return;
        if (std.c.errno(result) != .INTR) return;
        request = remaining;
    }
}

test "canonical WAV parser accepts shipped Won and Lost clips" {
    const won_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "assets/audio/won.wav", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(won_bytes);
    const lost_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "assets/audio/lost.wav", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(lost_bytes);
    const won = try parseCanonicalWav(won_bytes);
    const lost = try parseCanonicalWav(lost_bytes);
    try std.testing.expectEqual(PcmFormat{ .channels = 1, .sample_rate = 22_050, .block_align = 2 }, won.format);
    try std.testing.expectEqual(PcmFormat{ .channels = 1, .sample_rate = 22_050, .block_align = 2 }, lost.format);
    try std.testing.expectEqual(@as(usize, 7_938), won.pcm.len);
    try std.testing.expectEqual(@as(usize, 9_702), lost.pcm.len);
}

test "canonical WAV parser rejects malformed headers and sizes" {
    const fixture = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "assets/audio/won.wav", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(fixture);
    var bytes: [44]u8 = @splat(0);
    try std.testing.expectError(error.InvalidCanonicalWav, parseCanonicalWav(&bytes));
    @memcpy(bytes[0..4], "RIFF");
    @memcpy(bytes[8..12], "WAVE");
    @memcpy(bytes[12..16], "fmt ");
    @memcpy(bytes[36..40], "data");
    try std.testing.expectError(error.InvalidCanonicalWav, parseCanonicalWav(&bytes));
    const invalid = try std.testing.allocator.dupe(u8, fixture);
    defer std.testing.allocator.free(invalid);
    invalid[20] = 3;
    try std.testing.expectError(error.InvalidCanonicalWav, parseCanonicalWav(invalid));
    @memcpy(invalid, fixture);
    invalid[32] = 4;
    try std.testing.expectError(error.InvalidCanonicalWav, parseCanonicalWav(invalid));
    @memcpy(invalid, fixture);
    @memset(invalid[4..8], 0xff);
    try std.testing.expectError(error.InvalidCanonicalWav, parseCanonicalWav(invalid));
    @memcpy(invalid, fixture);
    @memset(invalid[24..32], 0xff);
    try std.testing.expectError(error.InvalidCanonicalWav, parseCanonicalWav(invalid));
    @memcpy(invalid, fixture);
    invalid[40] = 1;
    invalid[41] = 0;
    invalid[42] = 0;
    invalid[43] = 0;
    try std.testing.expectError(error.InvalidCanonicalWav, parseCanonicalWav(invalid));
    try std.testing.expectError(error.InvalidCanonicalWav, parseCanonicalWav(fixture[0 .. fixture.len - 1]));
}

test "Cue queue keeps Won and Lost independently and rejects after close" {
    var queue = CueQueue{};
    try std.testing.expect(queue.submit(.won));
    try std.testing.expect(queue.submit(.won));
    try std.testing.expect(queue.submit(.lost));
    try std.testing.expectEqual(cueMask(.won) | cueMask(.lost), queue.take());
    try std.testing.expectEqual(@as(u8, 0), queue.take());
    queue.close();
    try std.testing.expect(!queue.submit(.won));
    try std.testing.expect(queue.finished());
}

test "worker continues after a sink failure and joins on close" {
    const Recorder = struct {
        calls: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
        deinit_calls: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

        fn play(context: *anyopaque, _: WavView) !void {
            const self: *@This() = @ptrCast(@alignCast(context));
            const call = self.calls.fetchAdd(1, .acq_rel);
            if (call == 0) return error.InjectedSinkFailure;
        }

        fn deinit(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            _ = self.deinit_calls.fetchAdd(1, .acq_rel);
        }
    };

    var recorder = Recorder{};
    var won = try OwnedClip.load(std.testing.io, std.testing.allocator, "assets/audio/won.wav");
    errdefer won.deinit(std.testing.allocator);
    var lost = try OwnedClip.load(std.testing.io, std.testing.allocator, "assets/audio/lost.wav");
    errdefer lost.deinit(std.testing.allocator);
    const state = try std.testing.allocator.create(WorkerState);
    state.* = .{
        .allocator = std.testing.allocator,
        .sink = .{ .context = &recorder, .play_fn = Recorder.play, .deinit_fn = Recorder.deinit },
        .won = won,
        .lost = lost,
    };
    const thread = try std.Thread.spawn(.{}, WorkerState.run, .{state});
    try std.testing.expect(state.queue.submit(.lost));
    try std.testing.expect(state.queue.submit(.won));

    const deadline = monotonicMilliseconds() +| 1_000;
    while (recorder.calls.load(.acquire) < 2 and monotonicMilliseconds() < deadline) sleepMilliseconds(1);
    try std.testing.expectEqual(@as(u8, 2), recorder.calls.load(.acquire));

    state.queue.close();
    thread.join();
    state.deinit();
    try std.testing.expectEqual(@as(u8, 1), recorder.deinit_calls.load(.acquire));
}

test "ALSA null sink accepts both shipped clips and invalid device is rejected" {
    const won_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "assets/audio/won.wav", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(won_bytes);
    const lost_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "assets/audio/lost.wav", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(lost_bytes);
    const format = (try parseCanonicalWav(won_bytes)).format;
    const sink = try AlsaSink.init(std.testing.allocator, "null", format);
    const adapter = sink.asSink();
    defer adapter.deinit();
    try adapter.play(try parseCanonicalWav(won_bytes));
    try adapter.play(try parseCanonicalWav(lost_bytes));
    try std.testing.expectError(error.AlsaDeviceOpenFailed, AlsaSink.init(std.testing.allocator, "kadath-invalid-device", format));
}
