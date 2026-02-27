// WU CLI — Child Process Management
//
// Spawns and manages child processes (Vite dev servers, build commands).
// Cross-platform: uses std.process.Child on both Windows and POSIX.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ansi = @import("../util/ansi.zig");

pub const ProcessState = enum {
    idle,
    starting,
    running,
    stopping,
    stopped,
    crashed,
};

pub const ManagedProcess = struct {
    name: []const u8,
    framework: []const u8,
    port: u16,
    dir: []const u8,
    command: []const u8,
    state: ProcessState = .idle,
    child: ?std.process.Child = null,
    allocator: Allocator,
    color: []const u8,

    /// Spawn the process. Non-blocking — the process runs in background.
    pub fn start(self: *ManagedProcess) !void {
        self.state = .starting;

        // Build argv: we use the system shell to run the command
        // so that npx, node, etc. resolve correctly.
        const argv = if (builtin.os.tag == .windows)
            &[_][]const u8{ "cmd.exe", "/c", self.command }
        else
            &[_][]const u8{ "/bin/sh", "-c", self.command };

        var child = std.process.Child.init(argv, self.allocator);
        child.cwd = self.dir;

        // Pipe stderr so we can detect startup errors
        child.stderr_behavior = .Pipe;
        child.stdout_behavior = .Pipe;

        child.spawn() catch |err| {
            self.state = .crashed;
            return err;
        };

        self.child = child;
        self.state = .running;
    }

    /// Kill the process if running.
    pub fn stop(self: *ManagedProcess) void {
        if (self.child) |*child| {
            self.state = .stopping;

            if (builtin.os.tag == .windows) {
                // On Windows, just terminate the child directly
                _ = child.kill() catch {};
            } else {
                _ = child.kill() catch {};
            }
            _ = child.wait() catch {};
            self.child = null;
            self.state = .stopped;
        }
    }

    /// Terminate process tree on Windows using taskkill.
    pub fn killTree(self: *ManagedProcess) void {
        if (self.child) |*child| {
            self.state = .stopping;

            if (builtin.os.tag == .windows) {
                // Use taskkill /T /F /PID to kill the process tree
                const pid = @intFromPtr(child.id);
                var pid_buf: [10]u8 = undefined;
                const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch {
                    _ = child.kill() catch {};
                    _ = child.wait() catch {};
                    self.child = null;
                    self.state = .stopped;
                    return;
                };

                const kill_argv = [_][]const u8{
                    "taskkill", "/F", "/T", "/PID", pid_str,
                };
                var kill_proc = std.process.Child.init(&kill_argv, self.allocator);
                kill_proc.stderr_behavior = .Ignore;
                kill_proc.stdout_behavior = .Ignore;
                kill_proc.spawn() catch {
                    _ = child.kill() catch {};
                    _ = child.wait() catch {};
                    self.child = null;
                    self.state = .stopped;
                    return;
                };
                _ = kill_proc.wait() catch {};
            } else {
                // On POSIX, send SIGTERM to process group
                _ = child.kill() catch {};
            }

            _ = child.wait() catch {};
            self.child = null;
            self.state = .stopped;
        }
    }

    /// Check if the process is still alive.
    pub fn isAlive(self: *const ManagedProcess) bool {
        return self.state == .running and self.child != null;
    }

    pub fn stateStr(self: *const ManagedProcess) []const u8 {
        return switch (self.state) {
            .idle => "idle",
            .starting => "starting",
            .running => "running",
            .stopping => "stopping",
            .stopped => "stopped",
            .crashed => "crashed",
        };
    }

    pub fn stateColor(self: *const ManagedProcess) []const u8 {
        return switch (self.state) {
            .running => ansi.green,
            .starting => ansi.yellow,
            .crashed => ansi.red,
            .stopped, .stopping => ansi.dim,
            .idle => ansi.gray,
        };
    }
};
