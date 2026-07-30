const std = @import("std");
const platform_api = @import("platform");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("X11/keysym.h");
    @cInclude("xcb/xcb.h");
});

const Surface = struct {
    connection: *c.xcb_connection_t,
    window: c.xcb_window_t,
};

test "xcb platform creates a typed window surface and monotonic clock" {
    var platform = try platform_api.Platform.init();
    defer platform.deinit();

    const surface = platform.nativeSurface();
    switch (surface) {
        .xcb => |xcb| {
            try std.testing.expect(xcb.window != 0);
        },
        else => return error.UnexpectedNativeSurface,
    }

    try std.testing.expectEqual(platform_api.WindowExtent{ .width = 960, .height = 540 }, platform.clientExtent());
    const before = platform.nowSeconds();
    platform.sleepMilliseconds(5);
    const after = platform.nowSeconds();
    try std.testing.expect(after > before);
}

test "xcb platform reports held input and suppresses autorepeat edges" {
    var platform = try platform_api.Platform.init();
    defer platform.deinit();
    const surface = try xcbSurface(&platform);

    const right = try keycodeForKeysym(surface.connection, c.XK_Right);
    try sendKey(surface, right, c.XCB_KEY_PRESS, 10);
    var events = platform.pumpEvents();
    try std.testing.expectEqual(@as(i8, 1), events.input.move_x);
    try std.testing.expectEqual(@as(i8, 1), platform.pumpEvents().input.move_x);
    try sendKey(surface, right, c.XCB_KEY_RELEASE, 11);
    try std.testing.expectEqual(@as(i8, 0), platform.pumpEvents().input.move_x);

    const restart = try keycodeForKeysym(surface.connection, c.XK_r);
    try sendKey(surface, restart, c.XCB_KEY_PRESS, 20);
    events = platform.pumpEvents();
    try std.testing.expectEqual(@as(u8, 1), events.input.restart_pressed);

    try sendKey(surface, restart, c.XCB_KEY_RELEASE, 30);
    try sendKey(surface, restart, c.XCB_KEY_PRESS, 30);
    events = platform.pumpEvents();
    try std.testing.expectEqual(@as(u8, 0), events.input.restart_pressed);

    try sendKey(surface, restart, c.XCB_KEY_RELEASE, 40);
    _ = platform.pumpEvents();
    try sendKey(surface, restart, c.XCB_KEY_PRESS, 50);
    try std.testing.expectEqual(@as(u8, 1), platform.pumpEvents().input.restart_pressed);

    const reload_scene = try keycodeForKeysym(surface.connection, c.XK_F5);
    const reload_script = try keycodeForKeysym(surface.connection, c.XK_F6);
    try sendKey(surface, reload_scene, c.XCB_KEY_PRESS, 60);
    try sendKey(surface, reload_script, c.XCB_KEY_PRESS, 61);
    events = platform.pumpEvents();
    try std.testing.expectEqual(@as(u8, 1), events.input.reload_pressed);
    try std.testing.expectEqual(@as(u8, 1), events.input.script_reload_pressed);
}

test "xcb platform clears focus updates extent and accepts window close" {
    var platform = try platform_api.Platform.init();
    defer platform.deinit();
    const surface = try xcbSurface(&platform);

    const left = try keycodeForKeysym(surface.connection, c.XK_Left);
    try sendKey(surface, left, c.XCB_KEY_PRESS, 70);
    try std.testing.expectEqual(@as(i8, -1), platform.pumpEvents().input.move_x);
    try sendFocusOut(surface);
    try std.testing.expectEqual(@as(i8, 0), platform.pumpEvents().input.move_x);

    try resizeWindow(surface, 800, 600);
    const resized = try waitForExtent(&platform, .{ .width = 800, .height = 600 });
    try std.testing.expect(resized);

    try sendClose(surface);
    const closed = try waitForQuit(&platform);
    try std.testing.expect(closed);
}

test "xcb platform clears held input on keyboard mapping notification" {
    var platform = try platform_api.Platform.init();
    defer platform.deinit();
    const surface = try xcbSurface(&platform);

    const left = try keycodeForKeysym(surface.connection, c.XK_Left);
    try sendKey(surface, left, c.XCB_KEY_PRESS, 80);
    try std.testing.expectEqual(@as(i8, -1), platform.pumpEvents().input.move_x);

    try sendMappingNotify(surface, left);
    try std.testing.expectEqual(@as(i8, 0), platform.pumpEvents().input.move_x);
}

fn xcbSurface(platform: *platform_api.Platform) !Surface {
    return switch (platform.nativeSurface()) {
        .xcb => |xcb| .{
            .connection = @ptrCast(xcb.connection),
            .window = xcb.window,
        },
        else => error.UnexpectedNativeSurface,
    };
}

fn keycodeForKeysym(connection: *c.xcb_connection_t, keysym: c.xcb_keysym_t) !c.xcb_keycode_t {
    const setup = c.xcb_get_setup(connection);
    if (setup == null) return error.XcbSetupUnavailable;
    const minimum = setup.*.min_keycode;
    const maximum = setup.*.max_keycode;
    const count: u8 = @intCast(@as(u16, maximum) - @as(u16, minimum) + 1);
    var protocol_error: ?*c.xcb_generic_error_t = null;
    const reply = c.xcb_get_keyboard_mapping_reply(
        connection,
        c.xcb_get_keyboard_mapping(connection, minimum, count),
        &protocol_error,
    );
    if (protocol_error) |xcb_error| {
        c.free(xcb_error);
        if (reply != null) c.free(reply);
        return error.KeyboardMappingFailed;
    }
    if (reply == null) return error.KeyboardMappingFailed;
    defer c.free(reply);

    const keysyms = c.xcb_get_keyboard_mapping_keysyms(reply);
    const per_keycode: usize = reply.*.keysyms_per_keycode;
    var keycode = minimum;
    while (keycode <= maximum) : (keycode += 1) {
        const offset = (@as(usize, keycode) - minimum) * per_keycode;
        for (0..per_keycode) |index| {
            if (keysyms[offset + index] == keysym) return keycode;
        }
        if (keycode == maximum) break;
    }
    return error.KeysymUnavailable;
}

fn sendKey(surface: Surface, keycode: c.xcb_keycode_t, response_type: u8, timestamp: c.xcb_timestamp_t) !void {
    var event = std.mem.zeroes(c.xcb_key_press_event_t);
    event.response_type = response_type;
    event.detail = keycode;
    event.time = timestamp;
    event.event = surface.window;
    event.same_screen = 1;
    try sendEvent(surface, if (response_type == c.XCB_KEY_PRESS) c.XCB_EVENT_MASK_KEY_PRESS else c.XCB_EVENT_MASK_KEY_RELEASE, &event);
}

fn sendMappingNotify(surface: Surface, keycode: c.xcb_keycode_t) !void {
    var event = std.mem.zeroes(c.xcb_mapping_notify_event_t);
    event.response_type = c.XCB_MAPPING_NOTIFY;
    event.request = c.XCB_MAPPING_KEYBOARD;
    event.first_keycode = keycode;
    event.count = 1;
    try sendEvent(surface, c.XCB_EVENT_MASK_NO_EVENT, &event);
}

fn sendFocusOut(surface: Surface) !void {
    var event = std.mem.zeroes(c.xcb_focus_out_event_t);
    event.response_type = c.XCB_FOCUS_OUT;
    event.event = surface.window;
    try sendEvent(surface, c.XCB_EVENT_MASK_FOCUS_CHANGE, &event);
}

fn resizeWindow(surface: Surface, width: u32, height: u32) !void {
    const values = [_]u32{ width, height };
    try checkRequest(surface.connection, c.xcb_configure_window_checked(
        surface.connection,
        surface.window,
        c.XCB_CONFIG_WINDOW_WIDTH | c.XCB_CONFIG_WINDOW_HEIGHT,
        &values,
    ));
    if (c.xcb_flush(surface.connection) <= 0) return error.XcbFlushFailed;
}

fn sendClose(surface: Surface) !void {
    const wm_protocols = try internAtom(surface.connection, "WM_PROTOCOLS");
    const wm_delete_window = try internAtom(surface.connection, "WM_DELETE_WINDOW");
    var event = std.mem.zeroes(c.xcb_client_message_event_t);
    event.response_type = c.XCB_CLIENT_MESSAGE;
    event.window = surface.window;
    event.type = wm_protocols;
    event.format = 32;
    event.data.data32[0] = wm_delete_window;
    try sendEvent(surface, c.XCB_EVENT_MASK_NO_EVENT, &event);
}

fn internAtom(connection: *c.xcb_connection_t, name: []const u8) !c.xcb_atom_t {
    var protocol_error: ?*c.xcb_generic_error_t = null;
    const reply = c.xcb_intern_atom_reply(
        connection,
        c.xcb_intern_atom(connection, 0, @intCast(name.len), name.ptr),
        &protocol_error,
    );
    if (protocol_error) |xcb_error| {
        c.free(xcb_error);
        if (reply != null) c.free(reply);
        return error.XcbInternAtomFailed;
    }
    if (reply == null) return error.XcbInternAtomFailed;
    defer c.free(reply);
    return reply.*.atom;
}

fn sendEvent(surface: Surface, event_mask: u32, event: anytype) !void {
    try checkRequest(surface.connection, c.xcb_send_event_checked(
        surface.connection,
        0,
        surface.window,
        event_mask,
        @ptrCast(event),
    ));
    if (c.xcb_flush(surface.connection) <= 0) return error.XcbFlushFailed;
}

fn checkRequest(connection: *c.xcb_connection_t, cookie: c.xcb_void_cookie_t) !void {
    const protocol_error = c.xcb_request_check(connection, cookie);
    if (protocol_error) |xcb_error| {
        defer c.free(xcb_error);
        return error.XcbRequestFailed;
    }
}

fn waitForExtent(platform: *platform_api.Platform, expected: platform_api.WindowExtent) !bool {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        _ = platform.pumpEvents();
        if (std.meta.eql(expected, platform.clientExtent())) return true;
        platform.sleepMilliseconds(5);
    }
    return false;
}

fn waitForQuit(platform: *platform_api.Platform) !bool {
    var attempts: usize = 0;
    while (attempts < 100) : (attempts += 1) {
        if (platform.pumpEvents().quit_requested) return true;
        platform.sleepMilliseconds(5);
    }
    return false;
}
