const std = @import("std");
const builtin = @import("builtin");

const linux_alsa = if (builtin.os.tag == .linux) @import("linux_alsa.zig") else struct {};

pub const Cue = enum {
    won,
    lost,
};

const sound_async: u32 = 0x0001;
const sound_nodefault: u32 = 0x0002;
const sound_filename: u32 = 0x0002_0000;

const won_path = std.unicode.utf8ToUtf16LeStringLiteral("assets/audio/won.audio.wav");
const lost_path = std.unicode.utf8ToUtf16LeStringLiteral("assets/audio/lost.audio.wav");

extern "winmm" fn PlaySoundW(
    sound: ?[*:0]const u16,
    module: ?*anyopaque,
    flags: u32,
) callconv(.winapi) i32;

pub const Audio = struct {
    initialized: bool = false,
    linux_backend: if (builtin.os.tag == .linux) ?linux_alsa.Backend else void = if (builtin.os.tag == .linux) null else {},

    pub fn init(io: std.Io, allocator: std.mem.Allocator) Audio {
        if (builtin.os.tag == .linux) {
            const backend = linux_alsa.Backend.init(io, allocator) catch |err| {
                std.log.warn("Linux audio unavailable; using silent fallback: {s}", .{@errorName(err)});
                std.log.info("Audio initialized: backend=silent", .{});
                return .{ .initialized = true, .linux_backend = null };
            };
            std.log.info("Audio initialized: backend=alsa device={s}", .{backend.deviceName()});
            return .{ .initialized = true, .linux_backend = backend };
        }

        std.log.info("Audio initialized: backend={s}", .{if (builtin.os.tag == .windows) "winmm" else "silent"});
        return .{ .initialized = true };
    }

    pub fn deinit(self: *Audio) void {
        if (!self.initialized) return;
        if (builtin.os.tag == .windows) {
            _ = PlaySoundW(null, null, 0);
        } else if (builtin.os.tag == .linux) {
            if (self.linux_backend) |*backend| backend.deinit();
            self.linux_backend = null;
        }
        self.initialized = false;
        std.log.info("Audio shutdown complete", .{});
    }

    pub fn play(self: *Audio, cue: Cue) void {
        if (!self.initialized) return;
        if (builtin.os.tag == .linux) {
            if (self.linux_backend) |*backend| backend.play(cue);
            return;
        }
        if (builtin.os.tag != .windows) return;

        const path = switch (cue) {
            .won => won_path,
            .lost => lost_path,
        };
        if (PlaySoundW(path, null, sound_filename | sound_async | sound_nodefault) == 0) {
            std.log.warn("Audio cue failed: {s}", .{@tagName(cue)});
            return;
        }
        std.log.info("Audio cue played: {s}", .{@tagName(cue)});
    }
};

test "audio ignores cues before initialization" {
    var audio = Audio{};
    audio.play(.won);
    try std.testing.expect(!audio.initialized);
}

test "audio cue names stay stable" {
    try std.testing.expectEqualStrings("won", @tagName(Cue.won));
    try std.testing.expectEqualStrings("lost", @tagName(Cue.lost));
}

test "linux audio missing package artifacts falls back to silent" {
    if (builtin.os.tag != .linux) return;
    var audio = Audio.init(std.testing.io, std.testing.allocator);
    defer audio.deinit();
    try std.testing.expect(audio.initialized);
    try std.testing.expect(audio.linux_backend == null);
    audio.play(.lost);
}

test {
    if (builtin.os.tag == .linux) _ = linux_alsa;
}
