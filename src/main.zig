// ═══════════════════════════════════════════════════════════════════════════
// WU CLI — The Microfrontend Orchestrator
//
// Single binary. Zero dependencies. Inspired by Bun's speed,
// Vite's developer experience, and Lerna's orchestration.
//
// "One command to rule them all."
// ═══════════════════════════════════════════════════════════════════════════

const std = @import("std");
const builtin = @import("builtin");

// ── Module exports (for tests) ──
pub const cli = @import("cli/args.zig");
pub const banner_mod = @import("cli/banner.zig");
pub const config_mod = @import("config/config.zig");
pub const discovery = @import("config/discovery.zig");
pub const ansi = @import("util/ansi.zig");
pub const signals = @import("util/signals.zig");
pub const process_mod = @import("orchestrator/process.zig");
pub const supervisor_mod = @import("orchestrator/supervisor.zig");
pub const dev_cmd = @import("commands/dev.zig");
pub const build_cmd = @import("commands/build.zig");
pub const info_cmd = @import("commands/info.zig");
pub const create_cmd = @import("commands/create.zig");
pub const add_cmd = @import("commands/add.zig");
pub const serve_cmd = @import("commands/serve.zig");
pub const proxy_server = @import("proxy/server.zig");
pub const runtime = @import("runtime/dev_server.zig");
pub const runtime_transform = @import("runtime/transform.zig");
pub const runtime_mime = @import("runtime/mime.zig");

const log = std.log.scoped(.wu);

pub const version = "0.1.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // skip binary name

    const command = args.next() orelse {
        banner_mod.printBanner();
        cli.printUsage();
        return;
    };

    if (std.mem.eql(u8, command, "dev")) {
        try dev_cmd.run(allocator, &args);
    } else if (std.mem.eql(u8, command, "build")) {
        try build_cmd.run(allocator, &args);
    } else if (std.mem.eql(u8, command, "create")) {
        try create_cmd.run(allocator, &args);
    } else if (std.mem.eql(u8, command, "add")) {
        try add_cmd.run(allocator, &args);
    } else if (std.mem.eql(u8, command, "serve")) {
        try serve_cmd.run(allocator, &args);
    } else if (std.mem.eql(u8, command, "info")) {
        try info_cmd.run(allocator);
    } else if (std.mem.eql(u8, command, "version") or
        std.mem.eql(u8, command, "--version") or
        std.mem.eql(u8, command, "-v"))
    {
        banner_mod.printVersion();
    } else if (std.mem.eql(u8, command, "help") or
        std.mem.eql(u8, command, "--help") or
        std.mem.eql(u8, command, "-h"))
    {
        banner_mod.printBanner();
        cli.printUsage();
    } else {
        std.debug.print("{s}Unknown command: {s}{s}\n\n", .{
            ansi.red, command, ansi.reset,
        });
        cli.printUsage();
        std.process.exit(1);
    }
}
