// WU CLI — Cross-platform Signal Handling
// Graceful shutdown on Ctrl+C for both Windows and POSIX.
// Pattern from FORJA/GOLEM.

const std = @import("std");
const builtin = @import("builtin");

/// Callback type for shutdown notification.
pub const ShutdownFn = *const fn () void;

var g_shutdown_fn: ?ShutdownFn = null;

/// Install Ctrl+C / SIGINT / SIGTERM handlers.
/// The provided callback will be invoked on signal.
pub fn install(shutdown_fn: ShutdownFn) void {
    g_shutdown_fn = shutdown_fn;

    if (builtin.os.tag == .windows) {
        const k32 = std.os.windows.kernel32;
        _ = k32.SetConsoleCtrlHandler(&windowsCtrlHandler, 1);
    } else {
        const act = std.posix.Sigaction{
            .handler = .{ .handler = posixSignalHandler },
            .mask = std.posix.empty_sigset,
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null) catch {};
        std.posix.sigaction(std.posix.SIG.TERM, &act, null) catch {};
    }
}

fn posixSignalHandler(_: c_int) callconv(.c) void {
    if (g_shutdown_fn) |f| f();
}

fn windowsCtrlHandler(ctrl_type: std.os.windows.DWORD) callconv(.c) std.os.windows.BOOL {
    if (ctrl_type <= 2) {
        if (g_shutdown_fn) |f| f();
        return 1;
    }
    return 0;
}
