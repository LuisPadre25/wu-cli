// WU CLI — `wu dev` Command
//
// Starts all micro-apps in development mode.
//
// Two modes:
//   --native (default)  Single Zig HTTP server on one port. No Vite.
//   --vite              Legacy mode: spawn N Vite child processes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const config_mod = @import("../config/config.zig");
const discovery = @import("../config/discovery.zig");
const supervisor_mod = @import("../orchestrator/supervisor.zig");
const process_mod = @import("../orchestrator/process.zig");
const dev_server = @import("../runtime/dev_server.zig");
const ansi = @import("../util/ansi.zig");
const banner = @import("../cli/banner.zig");

pub fn run(allocator: Allocator, args: *std.process.ArgIterator) !void {
    var proxy_port: u16 = 3000;
    var use_vite = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port") or std.mem.eql(u8, arg, "-p")) {
            if (args.next()) |val| {
                proxy_port = std.fmt.parseInt(u16, val, 10) catch 3000;
            }
        } else if (std.mem.eql(u8, arg, "--vite")) {
            use_vite = true;
        } else if (std.mem.eql(u8, arg, "--native")) {
            use_vite = false;
        }
    }

    // Load config or auto-discover
    var cfg = config_mod.loadConfig(allocator);
    defer cfg.deinit(allocator);
    if (!cfg.from_file) {
        std.debug.print("  {s}No wu.config.json found. Scanning directory...{s}\n", .{
            ansi.yellow, ansi.reset,
        });
        cfg = discovery.discover(allocator);

        if (cfg.apps.len == 0 and cfg.shell.dir.len == 0) {
            std.debug.print("  {s}No micro-apps found.{s} Run {s}wu create{s} to scaffold a project.\n", .{
                ansi.red, ansi.reset, ansi.cyan, ansi.reset,
            });
            return;
        }

        std.debug.print("  {s}Found {d} micro-app(s).{s}\n\n", .{
            ansi.green, cfg.apps.len, ansi.reset,
        });
    }

    if (use_vite) {
        return runViteMode(allocator, cfg);
    }
    return runNativeMode(allocator, cfg, proxy_port);
}

// ── Native Mode: Single Zig HTTP Server ─────────────────────────────────────

fn runNativeMode(allocator: Allocator, cfg: config_mod.WuConfig, port: u16) !void {
    // Build app entries for the native server
    var app_entries: std.ArrayList(dev_server.AppEntry) = .empty;
    defer app_entries.deinit(allocator);

    var skipped: usize = 0;
    for (cfg.apps) |app| {
        // Skip apps whose directory no longer exists
        std.fs.cwd().access(app.dir, .{}) catch {
            std.debug.print("  {s}[skip]{s} {s}{s}{s} — directory '{s}' not found\n", .{
                ansi.yellow, ansi.reset, ansi.bold, app.name, ansi.reset, app.dir,
            });
            skipped += 1;
            continue;
        };
        // Skip duplicate directories
        var dup = false;
        for (app_entries.items) |existing| {
            if (std.mem.eql(u8, existing.dir, app.dir)) {
                dup = true;
                break;
            }
        }
        if (dup) {
            skipped += 1;
            continue;
        }
        try app_entries.append(allocator, .{
            .name = app.name,
            .dir = app.dir,
            .framework = app.framework,
            .port = app.port,
        });
    }
    if (skipped > 0) {
        std.debug.print("  {s}({d} app(s) skipped — clean up wu.config.json to remove){s}\n\n", .{
            ansi.dim, skipped, ansi.reset,
        });
    }

    var server = dev_server.DevServer.init(allocator, .{
        .port = port,
        .host = "127.0.0.1",
        .shell_dir = cfg.shell.dir,
        .shell_framework = cfg.shell.framework,
        .apps = app_entries.items,
    });
    defer server.shutdown();

    try server.run();
}

// ── Vite Mode: Legacy N-process supervisor ──────────────────────────────────

fn runViteMode(allocator: Allocator, cfg: config_mod.WuConfig) !void {
    banner.printBanner();

    var sup = supervisor_mod.Supervisor.init(allocator);
    defer sup.deinit();

    // Add shell process
    if (cfg.shell.dir.len > 0) {
        var cmd_buf: [256]u8 = undefined;
        const shell_cmd = std.fmt.bufPrint(&cmd_buf, "{s} --port {d}", .{
            cfg.shell.dev_cmd, cfg.shell.port,
        }) catch cfg.shell.dev_cmd;

        try sup.addProcess(.{
            .name = "shell",
            .framework = cfg.shell.framework,
            .port = cfg.shell.port,
            .dir = cfg.shell.dir,
            .command = shell_cmd,
            .allocator = allocator,
            .color = ansi.frameworkColor(cfg.shell.framework),
        });
    }

    // Add each micro-app (skip if directory missing)
    for (cfg.apps) |app| {
        std.fs.cwd().access(app.dir, .{}) catch continue;

        var cmd_buf: [256]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "{s} --port {d}", .{
            app.dev_cmd, app.port,
        }) catch app.dev_cmd;

        try sup.addProcess(.{
            .name = app.name,
            .framework = app.framework,
            .port = app.port,
            .dir = app.dir,
            .command = cmd,
            .allocator = allocator,
            .color = ansi.frameworkColor(app.framework),
        });
    }

    try sup.startAll();
    sup.wait();
}
