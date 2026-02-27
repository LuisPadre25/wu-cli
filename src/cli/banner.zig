// WU CLI — Banner and version display

const std = @import("std");
const ansi = @import("../util/ansi.zig");
const root = @import("../main.zig");

pub fn printBanner() void {
    std.debug.print(
        \\
        \\{s}              ██╗    ██╗██╗   ██╗{s}
        \\{s}              ██║    ██║██║   ██║{s}
        \\{s}              ██║ █╗ ██║██║   ██║{s}
        \\{s}              ██║███╗██║██║   ██║{s}
        \\{s}              ╚███╔███╔╝╚██████╔╝{s}
        \\{s}               ╚══╝╚══╝  ╚═════╝ {s}
        \\
        \\  {s}The Microfrontend Orchestrator{s}  {s}v{s}{s}
        \\
        \\
    , .{
        ansi.cyan,     ansi.reset,
        ansi.cyan,     ansi.reset,
        ansi.cyan,     ansi.reset,
        ansi.cyan,     ansi.reset,
        ansi.cyan,     ansi.reset,
        ansi.cyan,     ansi.reset,
        ansi.bold,     ansi.reset,
        ansi.dim,      root.version,
        ansi.reset,
    });
}

pub fn printVersion() void {
    std.debug.print("wu {s}\n", .{root.version});
}
