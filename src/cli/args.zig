// WU CLI — Argument parsing and help display

const std = @import("std");
const ansi = @import("../util/ansi.zig");

pub fn printUsage() void {
    std.debug.print(
        \\  {s}Usage:{s}  wu {s}<command>{s} [options]
        \\
        \\  {s}Commands:{s}
        \\    {s}dev{s}        Start all micro-apps in development mode
        \\    {s}build{s}      Build all micro-apps for production
        \\    {s}serve{s}      Serve production build
        \\    {s}create{s}     Scaffold a new wu-framework project
        \\    {s}add{s}        Add a new micro-app to the project
        \\    {s}install{s}    Install dependencies (alias: wu i)
        \\    {s}info{s}       Show project status and configuration
        \\
        \\  {s}Options:{s}
        \\    {s}-h, --help{s}       Show this help message
        \\    {s}-v, --version{s}    Show version number
        \\
        \\  {s}Examples:{s}
        \\    wu create my-project
        \\    wu dev
        \\    wu dev --port 3000
        \\    wu build
        \\    wu add react header
        \\    wu info
        \\
        \\  {s}https://wu-framework.com{s}
        \\
    , .{
        ansi.bold,    ansi.reset, ansi.cyan, ansi.reset,
        ansi.bold,    ansi.reset,
        ansi.green,   ansi.reset,
        ansi.green,   ansi.reset,
        ansi.green,   ansi.reset,
        ansi.green,   ansi.reset,
        ansi.green,   ansi.reset,
        ansi.green,   ansi.reset,
        ansi.green,   ansi.reset,
        ansi.bold,    ansi.reset,
        ansi.dim,     ansi.reset,
        ansi.dim,     ansi.reset,
        ansi.bold,    ansi.reset,
        ansi.dim,     ansi.reset,
    });
}
