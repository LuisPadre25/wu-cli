// WU CLI — ANSI Terminal Colors
// Provides color constants and formatting for terminal output.

const std = @import("std");
const builtin = @import("builtin");

// On Windows, check if we can use ANSI. For simplicity, always emit
// ANSI codes — Windows Terminal and modern cmd.exe support them.
const enable_colors = true;

fn col(comptime code: []const u8) []const u8 {
    return if (enable_colors) code else "";
}

// ── Colors ──
pub const reset = col("\x1b[0m");
pub const bold = col("\x1b[1m");
pub const dim = col("\x1b[2m");
pub const italic = col("\x1b[3m");
pub const underline = col("\x1b[4m");

pub const red = col("\x1b[31m");
pub const green = col("\x1b[32m");
pub const yellow = col("\x1b[33m");
pub const blue = col("\x1b[34m");
pub const magenta = col("\x1b[35m");
pub const cyan = col("\x1b[36m");
pub const white = col("\x1b[37m");
pub const gray = col("\x1b[90m");

pub const bg_red = col("\x1b[41m");
pub const bg_green = col("\x1b[42m");
pub const bg_yellow = col("\x1b[43m");
pub const bg_blue = col("\x1b[44m");
pub const bg_magenta = col("\x1b[45m");
pub const bg_cyan = col("\x1b[46m");

// ── Framework colors (consistent across output) ──
pub const fw_react = col("\x1b[36m"); // cyan
pub const fw_vue = col("\x1b[32m"); // green
pub const fw_svelte = col("\x1b[31m"); // red
pub const fw_angular = col("\x1b[31m"); // red
pub const fw_solid = col("\x1b[34m"); // blue
pub const fw_preact = col("\x1b[35m"); // magenta
pub const fw_lit = col("\x1b[34m"); // blue
pub const fw_vanilla = col("\x1b[33m"); // yellow
pub const fw_astro = col("\x1b[35m"); // magenta

pub fn frameworkColor(framework: []const u8) []const u8 {
    if (std.mem.eql(u8, framework, "react")) return fw_react;
    if (std.mem.eql(u8, framework, "vue")) return fw_vue;
    if (std.mem.eql(u8, framework, "svelte")) return fw_svelte;
    if (std.mem.eql(u8, framework, "angular")) return fw_angular;
    if (std.mem.eql(u8, framework, "solid")) return fw_solid;
    if (std.mem.eql(u8, framework, "preact")) return fw_preact;
    if (std.mem.eql(u8, framework, "lit")) return fw_lit;
    if (std.mem.eql(u8, framework, "vanilla")) return fw_vanilla;
    if (std.mem.eql(u8, framework, "astro")) return fw_astro;
    return white;
}

/// Print a colored label like [react] or [vue]
pub fn printLabel(writer: anytype, name: []const u8, color: []const u8) !void {
    try writer.print("{s}[{s}]{s} ", .{ color, name, reset });
}
