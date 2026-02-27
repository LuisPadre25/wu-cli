// WU CLI — `wu serve` Command
//
// Serves production-built micro-apps through a unified proxy.
// Placeholder for Phase 3 — currently prints instructions.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ansi = @import("../util/ansi.zig");

pub fn run(_: Allocator, _: *std.process.ArgIterator) !void {
    std.debug.print("\n  {s}wu serve{s} — coming soon\n\n", .{
        ansi.bold, ansi.reset,
    });
    std.debug.print("  For now, use {s}wu build{s} + your preferred static server:\n\n", .{
        ansi.cyan, ansi.reset,
    });
    std.debug.print("    wu build\n", .{});
    std.debug.print("    npx serve dist/\n\n", .{});
}
