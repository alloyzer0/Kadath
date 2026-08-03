const std = @import("std");

pub const CommandKind = enum {
    reload_scene,
    reload_script,
    shutdown,
};

pub const Command = struct {
    request_id: u64,
    kind: CommandKind,
};

const WireCommand = struct {
    schemaVersion: u32,
    requestId: u64,
    command: CommandKind,
};

const queue_capacity: usize = 64;
const max_line_bytes: usize = 1024;

const CommandQueue = struct {
    entries: [queue_capacity]Command = undefined,
    write_index: std.atomic.Value(usize) = .init(0),
    read_index: std.atomic.Value(usize) = .init(0),

    fn submit(self: *CommandQueue, command: Command) void {
        const write_index = self.write_index.load(.monotonic);
        const next_index = (write_index + 1) % queue_capacity;
        while (next_index == self.read_index.load(.acquire)) {
            std.Thread.yield() catch {};
        }
        self.entries[write_index] = command;
        self.write_index.store(next_index, .release);
    }

    fn poll(self: *CommandQueue) ?Command {
        const read_index = self.read_index.load(.monotonic);
        if (read_index == self.write_index.load(.acquire)) return null;
        const command = self.entries[read_index];
        self.read_index.store((read_index + 1) % queue_capacity, .release);
        return command;
    }
};

const ReaderState = struct {
    io: std.Io,
    queue: CommandQueue = .{},

    fn run(self: *ReaderState) void {
        var buffer: [max_line_bytes + 1]u8 = undefined;
        var file_reader = std.Io.File.stdin().readerStreaming(self.io, &buffer);
        while (true) {
            const line = file_reader.interface.takeDelimiter('\n') catch |err| {
                if (err == error.StreamTooLong) {
                    _ = file_reader.interface.discardDelimiterInclusive('\n') catch return;
                    std.log.warn("Preview control command rejected: PreviewControlLineTooLong", .{});
                    continue;
                }
                std.log.warn("Preview control input stopped: {s}", .{@errorName(err)});
                return;
            } orelse return;
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (trimmed.len == 0) continue;
            const command = parseCommand(std.heap.page_allocator, trimmed) catch |err| {
                std.log.warn("Preview control command rejected: {s}", .{@errorName(err)});
                continue;
            };
            self.queue.submit(command);
            if (command.kind == .shutdown) return;
        }
    }
};

pub const PreviewControl = struct {
    state: ?*ReaderState,
    thread: ?std.Thread,

    pub fn init(io: std.Io, enabled: bool) !PreviewControl {
        if (!enabled) return .{ .state = null, .thread = null };
        const state = try std.heap.page_allocator.create(ReaderState);
        errdefer std.heap.page_allocator.destroy(state);
        state.* = .{ .io = io };
        const thread = try std.Thread.spawn(.{}, ReaderState.run, .{state});
        return .{ .state = state, .thread = thread };
    }

    pub fn poll(self: *PreviewControl) ?Command {
        const state = self.state orelse return null;
        return state.queue.poll();
    }

    pub fn deinit(self: *PreviewControl, wait_for_reader: bool) void {
        const state = self.state orelse return;
        const thread = self.thread orelse unreachable;
        if (wait_for_reader) {
            thread.join();
            std.heap.page_allocator.destroy(state);
        } else {
            thread.detach();
        }
        self.* = undefined;
    }
};

fn parseCommand(allocator: std.mem.Allocator, line: []const u8) !Command {
    if (line.len > max_line_bytes) return error.PreviewControlLineTooLong;
    const parsed = try std.json.parseFromSlice(WireCommand, allocator, line, .{});
    defer parsed.deinit();
    if (parsed.value.schemaVersion != 1) return error.UnsupportedPreviewControlSchema;
    if (parsed.value.requestId == 0) return error.InvalidPreviewControlRequestId;
    return .{ .request_id = parsed.value.requestId, .kind = parsed.value.command };
}

test "preview control parses the frozen command schema" {
    try std.testing.expectEqual(
        Command{ .request_id = 41, .kind = .reload_scene },
        try parseCommand(std.testing.allocator, "{\"schemaVersion\":1,\"requestId\":41,\"command\":\"reload_scene\"}"),
    );
    try std.testing.expectEqual(
        Command{ .request_id = 42, .kind = .reload_script },
        try parseCommand(std.testing.allocator, "{\"schemaVersion\":1,\"requestId\":42,\"command\":\"reload_script\"}"),
    );
    try std.testing.expectEqual(
        Command{ .request_id = 43, .kind = .shutdown },
        try parseCommand(std.testing.allocator, "{\"schemaVersion\":1,\"requestId\":43,\"command\":\"shutdown\"}"),
    );
}

test "preview control rejects invalid envelopes" {
    try std.testing.expectError(
        error.UnsupportedPreviewControlSchema,
        parseCommand(std.testing.allocator, "{\"schemaVersion\":2,\"requestId\":1,\"command\":\"shutdown\"}"),
    );
    try std.testing.expectError(
        error.InvalidPreviewControlRequestId,
        parseCommand(std.testing.allocator, "{\"schemaVersion\":1,\"requestId\":0,\"command\":\"shutdown\"}"),
    );
    try std.testing.expectError(
        error.InvalidEnumTag,
        parseCommand(std.testing.allocator, "{\"schemaVersion\":1,\"requestId\":1,\"command\":\"pause\"}"),
    );
    try std.testing.expectError(
        error.UnknownField,
        parseCommand(std.testing.allocator, "{\"schemaVersion\":1,\"requestId\":1,\"command\":\"shutdown\",\"extra\":true}"),
    );
    var overlong: [max_line_bytes + 1]u8 = @splat(' ');
    try std.testing.expectError(error.PreviewControlLineTooLong, parseCommand(std.testing.allocator, &overlong));
}

test "preview control queue preserves FIFO order" {
    var queue = CommandQueue{};
    queue.submit(.{ .request_id = 7, .kind = .reload_scene });
    queue.submit(.{ .request_id = 8, .kind = .reload_script });
    queue.submit(.{ .request_id = 9, .kind = .shutdown });
    try std.testing.expectEqual(Command{ .request_id = 7, .kind = .reload_scene }, queue.poll().?);
    try std.testing.expectEqual(Command{ .request_id = 8, .kind = .reload_script }, queue.poll().?);
    try std.testing.expectEqual(Command{ .request_id = 9, .kind = .shutdown }, queue.poll().?);
    try std.testing.expectEqual(@as(?Command, null), queue.poll());
}
