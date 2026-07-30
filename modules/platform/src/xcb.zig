const std = @import("std");
const WindowExtent = @import("main.zig").WindowExtent;
const PumpResult = @import("main.zig").PumpResult;
const InputSnapshot = @import("main.zig").InputSnapshot;
const NativeSurface = @import("main.zig").NativeSurface;

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
    @cInclude("X11/keysym.h");
    @cInclude("xcb/xcb.h");
});

const window_title = "Kadath Runtime";
const initial_width: u16 = 960;
const initial_height: u16 = 540;

const KeyCodes = struct {
    left: c.xcb_keycode_t = 0,
    right: c.xcb_keycode_t = 0,
    up: c.xcb_keycode_t = 0,
    down: c.xcb_keycode_t = 0,
    restart: c.xcb_keycode_t = 0,
    reload_scene: c.xcb_keycode_t = 0,
    reload_script: c.xcb_keycode_t = 0,

    fn complete(self: KeyCodes) bool {
        return self.left != 0 and self.right != 0 and self.up != 0 and self.down != 0 and
            self.restart != 0 and self.reload_scene != 0 and self.reload_script != 0;
    }
};

const PendingKeyRelease = struct {
    detail: c.xcb_keycode_t,
    time: c.xcb_timestamp_t,
};

pub const Platform = struct {
    connection: ?*c.xcb_connection_t = null,
    window: c.xcb_window_t = 0,
    extent: WindowExtent = .{},
    start_nanoseconds: u64 = 0,
    last_time_seconds: f64 = 0.0,
    wm_protocols: c.xcb_atom_t = c.XCB_ATOM_NONE,
    wm_delete_window: c.xcb_atom_t = c.XCB_ATOM_NONE,
    key_codes: KeyCodes = .{},
    key_mapping_valid: bool = false,
    left_down: bool = false,
    right_down: bool = false,
    up_down: bool = false,
    down_down: bool = false,
    restart_down: bool = false,
    restart_pressed: bool = false,
    reload_down: bool = false,
    reload_pressed: bool = false,
    script_reload_down: bool = false,
    script_reload_pressed: bool = false,

    pub fn init() !Platform {
        var self = Platform{};
        errdefer self.deinit();

        self.start_nanoseconds = try monotonicNanoseconds();

        var screen_index: c_int = 0;
        const connection_result = c.xcb_connect(null, &screen_index);
        if (connection_result == null or c.xcb_connection_has_error(connection_result) != 0) {
            if (connection_result != null) c.xcb_disconnect(connection_result);
            return error.XcbConnectionFailed;
        }
        const connection = connection_result.?;
        self.connection = connection;

        var screen_iterator = c.xcb_setup_roots_iterator(c.xcb_get_setup(connection));
        var remaining_index = screen_index;
        while (remaining_index > 0 and screen_iterator.rem > 0) : (remaining_index -= 1) {
            c.xcb_screen_next(&screen_iterator);
        }
        if (screen_iterator.rem == 0 or screen_iterator.data == null) return error.XcbScreenUnavailable;
        const screen = screen_iterator.data.?;
        self.key_codes = try loadKeyCodes(connection);
        self.key_mapping_valid = true;
        self.wm_protocols = try internAtom(connection, "WM_PROTOCOLS");
        self.wm_delete_window = try internAtom(connection, "WM_DELETE_WINDOW");
        const net_wm_pid = try internAtom(connection, "_NET_WM_PID");

        self.window = c.xcb_generate_id(connection);
        if (self.window == 0) return error.XcbWindowIdUnavailable;

        const event_mask: u32 = c.XCB_EVENT_MASK_STRUCTURE_NOTIFY |
            c.XCB_EVENT_MASK_KEY_PRESS |
            c.XCB_EVENT_MASK_KEY_RELEASE |
            c.XCB_EVENT_MASK_FOCUS_CHANGE |
            c.XCB_EVENT_MASK_EXPOSURE;
        const values = [_]u32{ screen.*.black_pixel, event_mask };
        try checkRequest(connection, c.xcb_create_window_checked(
            connection,
            c.XCB_COPY_FROM_PARENT,
            self.window,
            screen.*.root,
            0,
            0,
            initial_width,
            initial_height,
            0,
            c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
            screen.*.root_visual,
            c.XCB_CW_BACK_PIXEL | c.XCB_CW_EVENT_MASK,
            &values,
        ), error.XcbCreateWindowFailed);

        try checkRequest(connection, c.xcb_change_property_checked(
            connection,
            c.XCB_PROP_MODE_REPLACE,
            self.window,
            c.XCB_ATOM_WM_NAME,
            c.XCB_ATOM_STRING,
            8,
            window_title.len,
            window_title.ptr,
        ), error.XcbWindowTitleFailed);
        try checkRequest(connection, c.xcb_change_property_checked(
            connection,
            c.XCB_PROP_MODE_REPLACE,
            self.window,
            self.wm_protocols,
            c.XCB_ATOM_ATOM,
            32,
            1,
            &self.wm_delete_window,
        ), error.XcbWindowProtocolFailed);
        const process_id: u32 = @intCast(c.getpid());
        try checkRequest(connection, c.xcb_change_property_checked(
            connection,
            c.XCB_PROP_MODE_REPLACE,
            self.window,
            net_wm_pid,
            c.XCB_ATOM_CARDINAL,
            32,
            1,
            &process_id,
        ), error.XcbWindowPidFailed);
        try checkRequest(connection, c.xcb_map_window_checked(connection, self.window), error.XcbMapWindowFailed);
        if (c.xcb_flush(connection) <= 0) return error.XcbFlushFailed;

        self.extent = .{ .width = initial_width, .height = initial_height };
        std.log.info("Platform XCB window created ({d}x{d})", .{ initial_width, initial_height });
        return self;
    }

    pub fn deinit(self: *Platform) void {
        if (self.connection) |connection| {
            if (self.window != 0) {
                _ = c.xcb_destroy_window(connection, self.window);
                _ = c.xcb_flush(connection);
            }
            c.xcb_disconnect(connection);
        }
        self.* = .{};
        std.log.info("Platform shutdown complete", .{});
    }

    pub fn pumpEvents(self: *Platform) PumpResult {
        var result = PumpResult{};
        const connection = self.connection orelse {
            result.quit_requested = true;
            return result;
        };
        var pending_release: ?PendingKeyRelease = null;

        while (c.xcb_poll_for_event(connection)) |event| {
            defer c.free(event);
            const response_type = event.*.response_type & 0x7f;

            if (pending_release) |release| {
                if (response_type == c.XCB_KEY_PRESS) {
                    const press: *const c.xcb_key_press_event_t = @ptrCast(event);
                    if (press.detail == release.detail and press.time == release.time) {
                        self.setKeyState(press.detail, true);
                        pending_release = null;
                        continue;
                    }
                }
                self.setKeyState(release.detail, false);
                pending_release = null;
            }

            switch (response_type) {
                c.XCB_KEY_PRESS => {
                    const key_event: *const c.xcb_key_press_event_t = @ptrCast(event);
                    self.setKeyState(key_event.detail, true);
                },
                c.XCB_KEY_RELEASE => {
                    const key_event: *const c.xcb_key_release_event_t = @ptrCast(event);
                    pending_release = .{ .detail = key_event.detail, .time = key_event.time };
                },
                c.XCB_FOCUS_OUT, c.XCB_UNMAP_NOTIFY => self.clearInput(),
                c.XCB_CONFIGURE_NOTIFY => {
                    const configure: *const c.xcb_configure_notify_event_t = @ptrCast(event);
                    self.extent = .{ .width = configure.width, .height = configure.height };
                },
                c.XCB_CLIENT_MESSAGE => {
                    const message: *const c.xcb_client_message_event_t = @ptrCast(event);
                    if (message.type == self.wm_protocols and
                        message.format == 32 and
                        message.data.data32[0] == self.wm_delete_window)
                    {
                        self.clearInput();
                        result.quit_requested = true;
                    }
                },
                c.XCB_MAPPING_NOTIFY => {
                    const refreshed_key_codes = loadKeyCodes(connection) catch |err| {
                        self.key_mapping_valid = false;
                        self.clearInput();
                        std.log.err("XCB keyboard mapping refresh failed: {s}", .{@errorName(err)});
                        continue;
                    };
                    self.clearInput();
                    self.key_codes = refreshed_key_codes;
                    self.key_mapping_valid = refreshed_key_codes.complete();
                },
                else => {},
            }
        }
        if (pending_release) |release| self.setKeyState(release.detail, false);
        if (c.xcb_connection_has_error(connection) != 0) {
            self.clearInput();
            result.quit_requested = true;
        }
        result.input = self.sampleInput();
        return result;
    }

    pub fn nowSeconds(self: *Platform) f64 {
        const current = monotonicNanoseconds() catch return self.last_time_seconds;
        const elapsed_nanoseconds = current -| self.start_nanoseconds;
        const elapsed = @as(f64, @floatFromInt(elapsed_nanoseconds)) / std.time.ns_per_s;
        if (elapsed > self.last_time_seconds) self.last_time_seconds = elapsed;
        return self.last_time_seconds;
    }

    pub fn sleepMilliseconds(self: *Platform, milliseconds: u32) void {
        _ = self;
        var request = c.struct_timespec{
            .tv_sec = @intCast(milliseconds / std.time.ms_per_s),
            .tv_nsec = @intCast((milliseconds % std.time.ms_per_s) * std.time.ns_per_ms),
        };
        var remaining = std.mem.zeroes(c.struct_timespec);
        while (true) {
            const result = c.nanosleep(&request, &remaining);
            if (result == 0) return;
            if (std.c.errno(result) != .INTR) return;
            request = remaining;
        }
    }

    pub fn nativeSurface(self: *Platform) NativeSurface {
        return .{ .xcb = .{
            .connection = @ptrCast(self.connection.?),
            .window = self.window,
        } };
    }

    pub fn clientExtent(self: *Platform) WindowExtent {
        return self.extent;
    }

    fn setKeyState(self: *Platform, keycode: c.xcb_keycode_t, is_down: bool) void {
        if (!self.key_mapping_valid) return;
        if (keycode == self.key_codes.left) {
            self.left_down = is_down;
        } else if (keycode == self.key_codes.right) {
            self.right_down = is_down;
        } else if (keycode == self.key_codes.up) {
            self.up_down = is_down;
        } else if (keycode == self.key_codes.down) {
            self.down_down = is_down;
        } else if (keycode == self.key_codes.restart) {
            if (is_down and !self.restart_down) self.restart_pressed = true;
            self.restart_down = is_down;
        } else if (keycode == self.key_codes.reload_scene) {
            if (is_down and !self.reload_down) self.reload_pressed = true;
            self.reload_down = is_down;
        } else if (keycode == self.key_codes.reload_script) {
            if (is_down and !self.script_reload_down) self.script_reload_pressed = true;
            self.script_reload_down = is_down;
        }
    }

    fn clearInput(self: *Platform) void {
        self.left_down = false;
        self.right_down = false;
        self.up_down = false;
        self.down_down = false;
        self.restart_down = false;
        self.restart_pressed = false;
        self.reload_down = false;
        self.reload_pressed = false;
        self.script_reload_down = false;
        self.script_reload_pressed = false;
    }

    fn sampleInput(self: *Platform) InputSnapshot {
        const restart_pressed: u8 = @intFromBool(self.restart_pressed);
        self.restart_pressed = false;
        const reload_pressed: u8 = @intFromBool(self.reload_pressed);
        self.reload_pressed = false;
        const script_reload_pressed: u8 = @intFromBool(self.script_reload_pressed);
        self.script_reload_pressed = false;
        return .{
            .move_x = if (self.right_down and !self.left_down) 1 else if (self.left_down and !self.right_down) -1 else 0,
            .move_y = if (self.down_down and !self.up_down) 1 else if (self.up_down and !self.down_down) -1 else 0,
            .restart_pressed = restart_pressed,
            .reload_pressed = reload_pressed,
            .script_reload_pressed = script_reload_pressed,
        };
    }
};

fn monotonicNanoseconds() !u64 {
    var value = std.mem.zeroes(c.struct_timespec);
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &value) != 0 or value.tv_sec < 0 or value.tv_nsec < 0) {
        return error.MonotonicClockUnavailable;
    }
    const seconds: u64 = @intCast(value.tv_sec);
    const nanoseconds: u64 = @intCast(value.tv_nsec);
    return std.math.add(u64, try std.math.mul(u64, seconds, std.time.ns_per_s), nanoseconds);
}

fn checkRequest(connection: *c.xcb_connection_t, cookie: c.xcb_void_cookie_t, failure: anyerror) !void {
    const request_error = c.xcb_request_check(connection, cookie);
    if (request_error) |xcb_error| {
        defer c.free(xcb_error);
        std.log.err("XCB request failed: code={d}", .{xcb_error.*.error_code});
        return failure;
    }
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

fn loadKeyCodes(connection: *c.xcb_connection_t) !KeyCodes {
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
    var result = KeyCodes{};
    var raw_keycode: u16 = minimum;
    while (raw_keycode <= maximum) : (raw_keycode += 1) {
        const keycode: c.xcb_keycode_t = @intCast(raw_keycode);
        const offset = (@as(usize, keycode) - minimum) * per_keycode;
        for (0..per_keycode) |index| {
            const keysym = keysyms[offset + index];
            if (keysym == c.XK_Left and result.left == 0) result.left = keycode;
            if (keysym == c.XK_Right and result.right == 0) result.right = keycode;
            if (keysym == c.XK_Up and result.up == 0) result.up = keycode;
            if (keysym == c.XK_Down and result.down == 0) result.down = keycode;
            if ((keysym == c.XK_r or keysym == c.XK_R) and result.restart == 0) result.restart = keycode;
            if (keysym == c.XK_F5 and result.reload_scene == 0) result.reload_scene = keycode;
            if (keysym == c.XK_F6 and result.reload_script == 0) result.reload_script = keycode;
        }
    }
    if (!result.complete()) return error.KeyboardMappingIncomplete;
    return result;
}
