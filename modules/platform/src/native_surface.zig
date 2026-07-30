const std = @import("std");

pub const NativeSurface = union(enum) {
    win32: struct {
        window: *anyopaque,
        instance: *anyopaque,
    },
    xcb: struct {
        connection: *anyopaque,
        window: u32,
    },
};

test "native surface variants preserve platform payloads" {
    var window_token: u8 = 0;
    var instance_token: u8 = 0;
    var connection_token: u8 = 0;

    const win32 = NativeSurface{ .win32 = .{
        .window = @ptrCast(&window_token),
        .instance = @ptrCast(&instance_token),
    } };
    const xcb = NativeSurface{ .xcb = .{
        .connection = @ptrCast(&connection_token),
        .window = 42,
    } };

    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&window_token)), win32.win32.window);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&instance_token)), win32.win32.instance);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&connection_token)), xcb.xcb.connection);
    try std.testing.expectEqual(@as(u32, 42), xcb.xcb.window);
}
