const std = @import("std");
const WindowExtent = @import("main.zig").WindowExtent;
const PumpResult = @import("main.zig").PumpResult;

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
        _ = self;
        var result = PumpResult{};
        var message: c.MSG = undefined;
        while (c.PeekMessageW(&message, null, 0, 0, c.PM_REMOVE) != 0) {
            if (message.message == c.WM_QUIT) {
                result.quit_requested = true;
                break;
            }
            _ = c.TranslateMessage(&message);
            _ = c.DispatchMessageW(&message);
        }
        return result;
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

    pub fn nativeWindowHandle(self: *Platform) usize {
        if (self.window) |window| {
            return @intFromPtr(window);
        }
        return 0;
    }

    pub fn nativeInstanceHandle(self: *Platform) usize {
        if (self.instance) |instance| {
            return @intFromPtr(instance);
        }
        return 0;
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
