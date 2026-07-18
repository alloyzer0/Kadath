const std = @import("std");
const builtin = @import("builtin");

pub const Cue = enum {
    won,
    lost,
};

const sound_async: u32 = 0x0001;
const sound_nodefault: u32 = 0x0002;
const sound_filename: u32 = 0x0002_0000;

const won_path = std.unicode.utf8ToUtf16LeStringLiteral("assets/audio/won.wav");
const lost_path = std.unicode.utf8ToUtf16LeStringLiteral("assets/audio/lost.wav");

extern "winmm" fn PlaySoundW(
    sound: ?[*:0]const u16,
    module: ?*anyopaque,
    flags: u32,
) callconv(.winapi) i32;

pub const Audio = struct {
    initialized: bool = false,

    pub fn init() Audio {
        std.log.info("Audio initialized: backend={s}", .{if (builtin.os.tag == .windows) "winmm" else "silent"});
        return .{ .initialized = true };
    }

    pub fn deinit(self: *Audio) void {
        if (!self.initialized) return;
        if (builtin.os.tag == .windows) {
            // 关键生命周期：停止异步 WAV，避免 Host 退出后仍保留系统播放资源。
            _ = PlaySoundW(null, null, 0);
        }
        self.initialized = false;
        std.log.info("Audio shutdown complete", .{});
    }

    pub fn play(self: *Audio, cue: Cue) void {
        if (!self.initialized) return;
        if (builtin.os.tag != .windows) return;

        const path = switch (cue) {
            .won => won_path,
            .lost => lost_path,
        };
        // 异步播放保证音频反馈不阻塞 fixed-step；失败只降级为 warning。
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
