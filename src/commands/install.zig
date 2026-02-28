// WU CLI — `wu install` Command
//
// Installs dependencies for an existing wu-framework project.
// Runs `npm install` using the project's existing package.json.
//
// Usage:
//   wu install          Install deps in current project
//   wu install --clean  Delete node_modules before installing

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const config_mod = @import("../config/config.zig");
const ansi = @import("../util/ansi.zig");

pub fn run(allocator: Allocator, args: *std.process.ArgIterator) !void {
    var clean = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--clean") or std.mem.eql(u8, arg, "-c")) {
            clean = true;
        }
    }

    // Verify this is a wu project
    const cfg = config_mod.loadConfig(allocator);
    if (!cfg.from_file) {
        std.debug.print("\n  {s}x{s} No wu.config.json found in current directory.\n", .{ ansi.red, ansi.reset });
        std.debug.print("    Run {s}wu create{s} first to scaffold a project.\n\n", .{ ansi.cyan, ansi.reset });
        return;
    }

    // Verify package.json exists
    std.fs.cwd().access("package.json", .{}) catch {
        std.debug.print("\n  {s}x{s} No package.json found in current directory.\n", .{ ansi.red, ansi.reset });
        std.debug.print("    Run {s}wu create{s} to generate the project structure.\n\n", .{ ansi.cyan, ansi.reset });
        return;
    };

    std.debug.print("\n  {s}WU{s}  Install dependencies\n", .{ ansi.bold, ansi.reset });
    std.debug.print("  {s}──────────────────────────{s}\n\n", .{ ansi.dim, ansi.reset });

    std.debug.print("  {s}Project:{s} {s}\n", .{ ansi.dim, ansi.reset, cfg.name });
    std.debug.print("  {s}Apps:{s}    {d}\n\n", .{ ansi.dim, ansi.reset, cfg.apps.len });

    // Clean if requested
    if (clean) {
        std.debug.print("  {s}Removing node_modules...{s}\n", .{ ansi.dim, ansi.reset });
        std.fs.cwd().deleteTree("node_modules") catch |err| if (err != error.FileNotFound) {
            std.debug.print("  {s}x{s} Failed to remove node_modules: {s}\n\n", .{ ansi.red, ansi.reset, @errorName(err) });
            return;
        };
        std.debug.print("  {s}+{s} Cleaned\n\n", .{ ansi.green, ansi.reset });
    }

    // Run npm install
    std.debug.print("  {s}Installing dependencies...{s}\n\n", .{ ansi.bold, ansi.reset });
    runNpmInstall(allocator);

    std.debug.print("\n  {s}Done!{s}\n\n", .{ ansi.green, ansi.reset });
}

// ── npm install ─────────────────────────────────────────────────────────────

fn runNpmInstall(allocator: Allocator) void {
    const argv = [_][]const u8{ "npm", "install", "--silent" };
    var child = std.process.Child.init(&argv, allocator);
    child.cwd = null;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;

    child.spawn() catch {
        std.debug.print("    {s}x{s} npm not found. Install Node.js and try again.\n", .{ ansi.red, ansi.reset });
        return;
    };

    const stderr_out = if (child.stderr) |se|
        se.readToEndAlloc(allocator, 64 * 1024) catch null
    else
        null;
    defer if (stderr_out) |s| allocator.free(s);

    const term = child.wait() catch {
        std.debug.print("    {s}x{s} npm install failed\n", .{ ansi.red, ansi.reset });
        return;
    };

    if (term.Exited == 0) {
        std.debug.print("    {s}+{s} Dependencies installed\n", .{ ansi.green, ansi.reset });
    } else {
        std.debug.print("    {s}x{s} npm install failed (exit {d})\n", .{ ansi.red, ansi.reset, term.Exited });
        if (stderr_out) |se| {
            if (se.len > 0) {
                std.debug.print("    {s}{s}{s}\n", .{ ansi.dim, se, ansi.reset });
            }
        }
    }
}
