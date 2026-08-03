const std = @import("std");
const WindowExtent = @import("main.zig").WindowExtent;
const PumpResult = @import("main.zig").PumpResult;
const InputSnapshot = @import("main.zig").InputSnapshot;
const NativeSurface = @import("main.zig").NativeSurface;
const preview_reload_scene_message = @import("main.zig").preview_reload_scene_message;
const preview_reload_script_message = @import("main.zig").preview_reload_script_message;

const c = @cImport({
    @cDefine("UNICODE", "1");
    @cDefine("_UNICODE", "1");
    @cInclude("windows.h");
});

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("KadathRuntimeWindow");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("Kadath Runtime");

pub const Platform = struct {
    instance: c.HINSTANCE = null,
    window: c.HWND = null,
    class_registered: bool = false,
    qpc_frequency: i64 = 0,
    qpc_start: i64 = 0,
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
    scene_reload_request_id: ?u64 = null,
    script_reload_request_id: ?u64 = null,

    pub fn init() !Platform {
        var self = Platform{};
        errdefer self.deinit();
        try self.initialize();
        return self;
    }

    fn initialize(self: *Platform) !void {
        if (c.QueryPerformanceFrequency(@ptrCast(&self.qpc_frequency)) == 0) {
            return error.MonotonicClockUnavailable;
        }
        if (c.QueryPerformanceCounter(@ptrCast(&self.qpc_start)) == 0) {
            return error.MonotonicClockUnavailable;
        }

        self.instance = c.GetModuleHandleW(null);
        if (self.instance == null) {
            return error.GetModuleHandleFailed;
        }

        var window_class = std.mem.zeroes(c.WNDCLASSW);
        window_class.lpfnWndProc = windowProc;
        window_class.hInstance = self.instance;
        window_class.lpszClassName = class_name.ptr;
        const atom = c.RegisterClassW(&window_class);
        if (atom == 0) {
            const last_error = c.GetLastError();
            if (last_error != c.ERROR_CLASS_ALREADY_EXISTS) {
                std.log.err("RegisterClassW failed: {d}", .{last_error});
                return error.RegisterClassFailed;
            }
        } else {
            self.class_registered = true;
        }

        self.window = c.CreateWindowExW(
            0,
            class_name.ptr,
            window_title.ptr,
            c.WS_OVERLAPPEDWINDOW | c.WS_VISIBLE,
            c.CW_USEDEFAULT,
            c.CW_USEDEFAULT,
            960,
            540,
            null,
            null,
            self.instance,
            null,
        );
        if (self.window == null) {
            std.log.err("CreateWindowExW failed: {d}", .{c.GetLastError()});
            return error.CreateWindowFailed;
        }

        _ = c.ShowWindow(self.window, c.SW_SHOW);
        _ = c.UpdateWindow(self.window);
        std.log.info("Platform window created (960x540)", .{});
    }

    pub fn deinit(self: *Platform) void {
        if (self.window != null) {
            _ = c.DestroyWindow(self.window);
            self.window = null;
        }
        if (self.class_registered and self.instance != null) {
            _ = c.UnregisterClassW(class_name.ptr, self.instance);
            self.class_registered = false;
        }
        self.instance = null;
        std.log.info("Platform shutdown complete", .{});
    }

    pub fn pumpEvents(self: *Platform) PumpResult {
        var result = PumpResult{};
        var message: c.MSG = undefined;
        while (c.PeekMessageW(&message, null, 0, 0, c.PM_REMOVE) != 0) {
            if (message.hwnd == self.window) self.consumeInputMessage(&message);
            if (message.message == c.WM_QUIT) {
                self.clearInput();
                result.quit_requested = true;
                break;
            }
            _ = c.TranslateMessage(&message);
            _ = c.DispatchMessageW(&message);
        }
        result.input = self.sampleInput();
        result.scene_reload_request_id = self.scene_reload_request_id;
        result.script_reload_request_id = self.script_reload_request_id;
        self.scene_reload_request_id = null;
        self.script_reload_request_id = null;
        return result;
    }

    fn consumeInputMessage(self: *Platform, message: *const c.MSG) void {
        switch (message.message) {
            c.WM_KEYDOWN, c.WM_SYSKEYDOWN => self.setKeyState(message.wParam, true),
            c.WM_KEYUP, c.WM_SYSKEYUP => self.setKeyState(message.wParam, false),
            preview_reload_scene_message => self.setPreviewReloadRequest(.scene, message.wParam),
            preview_reload_script_message => self.setPreviewReloadRequest(.script, message.wParam),
            c.WM_KILLFOCUS => self.clearInput(),
            else => {},
        }
    }

    const PreviewReloadKind = enum { scene, script };

    fn setPreviewReloadRequest(self: *Platform, kind: PreviewReloadKind, raw_request_id: c.WPARAM) void {
        const request_id: u64 = @intCast(raw_request_id);
        if (request_id == 0) {
            std.log.warn("Preview reload command ignored because requestId was zero", .{});
            return;
        }
        // 每种命令每帧只保留一个结构化请求；Launcher 在收到终态响应前不会重发同种命令。
        switch (kind) {
            .scene => self.scene_reload_request_id = request_id,
            .script => self.script_reload_request_id = request_id,
        }
    }

    fn setKeyState(self: *Platform, key: c.WPARAM, is_down: bool) void {
        switch (key) {
            c.VK_LEFT => self.left_down = is_down,
            c.VK_RIGHT => self.right_down = is_down,
            c.VK_UP => self.up_down = is_down,
            c.VK_DOWN => self.down_down = is_down,
            'R' => {
                // 自动重复 KeyDown 到达时 restart_down 已为 true，因此只保留首次按下沿。
                if (is_down and !self.restart_down) self.restart_pressed = true;
                self.restart_down = is_down;
            },
            c.VK_F5 => {
                // F5 仍是手动 Scene reload；WM_APP 只为旧 Windows Launcher 保留兼容。
                if (is_down and !self.reload_down) self.reload_pressed = true;
                self.reload_down = is_down;
            },
            c.VK_F6 => {
                // F6 仍是手动 Script reload；WM_APP 只为旧 Windows Launcher 保留兼容。
                if (is_down and !self.script_reload_down) self.script_reload_pressed = true;
                self.script_reload_down = is_down;
            },
            else => {},
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
    pub fn nowSeconds(self: *Platform) f64 {
        var current: i64 = 0;
        if (c.QueryPerformanceCounter(@ptrCast(&current)) == 0 or self.qpc_frequency <= 0) {
            return 0.0;
        }
        const elapsed_ticks = current - self.qpc_start;
        return @as(f64, @floatFromInt(elapsed_ticks)) /
            @as(f64, @floatFromInt(self.qpc_frequency));
    }

    pub fn sleepMilliseconds(self: *Platform, milliseconds: u32) void {
        _ = self;
        c.Sleep(milliseconds);
    }

    pub fn nativeSurface(self: *Platform) NativeSurface {
        return .{ .win32 = .{
            .window = @ptrCast(self.window orelse unreachable),
            .instance = @ptrCast(self.instance orelse unreachable),
        } };
    }

    pub fn clientExtent(self: *Platform) WindowExtent {
        if (self.window) |window| {
            var rect: c.RECT = undefined;
            if (c.GetClientRect(window, &rect) != 0 and rect.right > rect.left and rect.bottom > rect.top) {
                return .{
                    .width = @intCast(rect.right - rect.left),
                    .height = @intCast(rect.bottom - rect.top),
                };
            }
        }
        return .{};
    }
};

fn windowProc(
    window: c.HWND,
    message: c.UINT,
    w_param: c.WPARAM,
    l_param: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    switch (message) {
        c.WM_CLOSE => {
            // RHI 必须先释放 Surface/Device；Host 收到 WM_QUIT 后再逆序销毁 Platform。
            c.PostQuitMessage(0);
            return 0;
        },
        c.WM_DESTROY => {
            c.PostQuitMessage(0);
            return 0;
        },
        else => return c.DefWindowProcW(window, message, w_param, l_param),
    }
}
