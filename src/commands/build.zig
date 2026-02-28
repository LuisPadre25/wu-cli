// WU CLI — `wu build` Command
//
// Builds all micro-apps for production in parallel.
// Each app's build command (default: npx vite build) runs as a child process.

const std = @import("std");
const Allocator = std.mem.Allocator;
const config_mod = @import("../config/config.zig");
const discovery = @import("../config/discovery.zig");
const ansi = @import("../util/ansi.zig");
const builtin = @import("builtin");

pub fn run(allocator: Allocator, _: *std.process.ArgIterator) !void {
    var cfg = config_mod.loadConfig(allocator);
    defer cfg.deinit(allocator);
    if (!cfg.from_file) {
        cfg = discovery.discover(allocator);
    }

    const total = cfg.apps.len + @as(usize, if (cfg.shell.dir.len > 0) 1 else 0);
    if (total == 0) {
        std.debug.print("  {s}No micro-apps found to build.{s}\n", .{
            ansi.red, ansi.reset,
        });
        return;
    }

    std.debug.print("\n  {s}Building {d} micro-app(s)...{s}\n\n", .{
        ansi.bold, total, ansi.reset,
    });

    var success: usize = 0;
    var failed: usize = 0;

    // Build shell first if present
    if (cfg.shell.dir.len > 0) {
        const ok = buildOne(allocator, "shell", cfg.shell.framework, cfg.shell.dir, cfg.shell.build_cmd);
        if (ok) {
            success += 1;
            std.debug.print("  {s}✓{s} {s}shell{s}\n", .{
                ansi.green, ansi.reset, ansi.fw_astro, ansi.reset,
            });
        } else {
            failed += 1;
            std.debug.print("  {s}✗{s} {s}shell{s}\n", .{
                ansi.red, ansi.reset, ansi.fw_astro, ansi.reset,
            });
        }
    }

    // Build each micro-app
    for (cfg.apps) |app| {
        const color = ansi.frameworkColor(app.framework);
        const ok = buildOne(allocator, app.name, app.framework, app.dir, app.build_cmd);
        if (ok) {
            success += 1;
            std.debug.print("  {s}✓{s} {s}{s}{s}\n", .{
                ansi.green, ansi.reset, color, app.name, ansi.reset,
            });
        } else {
            failed += 1;
            std.debug.print("  {s}✗{s} {s}{s}{s}\n", .{
                ansi.red, ansi.reset, color, app.name, ansi.reset,
            });
        }
    }

    std.debug.print("\n  {s}Build complete:{s} {s}{d} passed{s}", .{
        ansi.bold, ansi.reset, ansi.green, success, ansi.reset,
    });
    if (failed > 0) {
        std.debug.print(", {s}{d} failed{s}", .{
            ansi.red, failed, ansi.reset,
        });
    }
    std.debug.print("\n\n", .{});

    if (failed > 0) std.process.exit(1);
}

fn buildOne(allocator: Allocator, name: []const u8, framework: []const u8, dir: []const u8, cmd: []const u8) bool {
    _ = name;
    _ = framework;

    const argv = if (builtin.os.tag == .windows)
        &[_][]const u8{ "cmd.exe", "/c", cmd }
    else
        &[_][]const u8{ "/bin/sh", "-c", cmd };

    var child = std.process.Child.init(argv, allocator);
    child.cwd = dir;
    child.stderr_behavior = .Ignore;
    child.stdout_behavior = .Ignore;

    child.spawn() catch return false;
    const result = child.wait() catch return false;

    return result.Exited == 0;
}
