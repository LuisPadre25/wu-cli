// WU CLI — `wu info` Command
//
// Display project configuration, detected micro-apps, ports, and status.

const std = @import("std");
const Allocator = std.mem.Allocator;
const config_mod = @import("../config/config.zig");
const discovery = @import("../config/discovery.zig");
const ansi = @import("../util/ansi.zig");
const root = @import("../main.zig");

pub fn run(allocator: Allocator) !void {
    var cfg = config_mod.loadConfig(allocator);
    const source: []const u8 = if (cfg.from_file) "wu.config.json" else blk: {
        cfg = discovery.discover(allocator);
        break :blk "auto-discovered";
    };

    std.debug.print("\n  {s}WU Project Info{s}  {s}v{s}{s}\n", .{
        ansi.bold, ansi.reset, ansi.dim, root.version, ansi.reset,
    });
    std.debug.print("  {s}Config:{s} {s}\n\n", .{
        ansi.dim, ansi.reset, source,
    });

    // Project
    std.debug.print("  {s}Project:{s}  {s}\n", .{
        ansi.bold, ansi.reset, cfg.name,
    });
    std.debug.print("  {s}Version:{s}  {s}\n", .{
        ansi.bold, ansi.reset, cfg.version,
    });

    // Shell
    if (cfg.shell.dir.len > 0) {
        std.debug.print("\n  {s}Shell:{s}\n", .{ ansi.bold, ansi.reset });
        const shell_color = ansi.frameworkColor(cfg.shell.framework);
        std.debug.print("    {s}●{s} {s}{s}{s}  dir={s}  port={s}:{d}{s}\n", .{
            shell_color,           ansi.reset,
            ansi.bold,             cfg.shell.dir,
            ansi.reset,            cfg.shell.framework,
            ansi.cyan,             cfg.shell.port,
            ansi.reset,
        });
    }

    // Apps
    if (cfg.apps.len > 0) {
        std.debug.print("\n  {s}Micro-apps ({d}):{s}\n", .{
            ansi.bold, cfg.apps.len, ansi.reset,
        });

        std.debug.print("    {s}{s} {s} {s} {s}{s}\n", .{
            ansi.dim, "Name", "Framework", "Port", "Directory", ansi.reset,
        });
        std.debug.print("    {s}──────────────────────────────────────────{s}\n", .{
            ansi.dim, ansi.reset,
        });

        for (cfg.apps) |app| {
            const color = ansi.frameworkColor(app.framework);
            std.debug.print("    {s}{s}{s} {s}{s}{s} {s}:{d}{s} {s}{s}{s}\n", .{
                color,     app.name,
                ansi.reset,
                ansi.dim,  app.framework,
                ansi.reset,
                ansi.cyan, app.port,
                ansi.reset,
                ansi.gray, app.dir,
                ansi.reset,
            });
        }
    }

    // Summary
    const total = cfg.apps.len + @as(usize, if (cfg.shell.dir.len > 0) 1 else 0);
    std.debug.print("\n  {s}Total:{s} {d} process(es)\n\n", .{
        ansi.bold, ansi.reset, total,
    });
}
