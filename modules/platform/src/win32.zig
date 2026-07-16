const std = @import("std");

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
    timer: std.time.Timer = undefined,

    pub fn init() !Platform {
        var self = Platform{};
        errdefer self.deinit();
        try self.initialize();
        return self;
    }

    fn initialize(self: *Platform) !void {
        self.timer = std.time.Timer.start() catch {
            return error.MonotonicClockUnavailable;
        };

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
    }

    pub fn pumpEvents(self: *Platform) bool {
        var message: c.MSG = undefined;
        while (c.PeekMessageW(&message, null, 0, 0, c.PM_REMOVE) != 0) {
            if (message.message == c.WM_QUIT) {
                self.window = null;
                return true;
            }
            _ = c.TranslateMessage(&message);
            _ = c.DispatchMessageW(&message);
        }
        return false;
    }

    pub fn nowSeconds(self: *Platform) f64 {
        const elapsed_ns = self.timer.read();
        return @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_s);
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
            _ = c.DestroyWindow(window);
            return 0;
        },
        c.WM_DESTROY => {
            c.PostQuitMessage(0);
            return 0;
        },
        else => return c.DefWindowProcW(window, message, w_param, l_param),
    }
}
