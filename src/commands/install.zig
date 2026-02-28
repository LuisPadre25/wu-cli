// WU CLI — `wu install` Command
//
// Installs dependencies for a wu-framework project.
//
// Flow:
//   1. Load wu.config.json from CWD
//   2. Generate/regenerate merged root package.json
//      (deduplicates deps across all micro-apps)
//   3. Run `npm install` at project root
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

    // 1. Load config
    const cfg = config_mod.loadConfig(allocator);
    if (!cfg.from_file) {
        std.debug.print("\n  {s}x{s} No wu.config.json found in current directory.\n", .{ ansi.red, ansi.reset });
        std.debug.print("    Run {s}wu create{s} first to scaffold a project.\n\n", .{ ansi.cyan, ansi.reset });
        return;
    }

    std.debug.print("\n  {s}WU{s}  Install dependencies\n", .{ ansi.bold, ansi.reset });
    std.debug.print("  {s}──────────────────────────{s}\n\n", .{ ansi.dim, ansi.reset });

    std.debug.print("  {s}Project:{s} {s}\n", .{ ansi.dim, ansi.reset, cfg.name });
    std.debug.print("  {s}Apps:{s}    {d}\n\n", .{ ansi.dim, ansi.reset, cfg.apps.len });

    // 2. Generate merged root package.json
    std.debug.print("  {s}Generating root package.json...{s}\n", .{ ansi.dim, ansi.reset });
    generateRootPackageJson(allocator, cfg) catch {
        std.debug.print("  {s}x{s} Failed to generate package.json\n\n", .{ ansi.red, ansi.reset });
        return;
    };
    std.debug.print("  {s}+{s} package.json\n\n", .{ ansi.green, ansi.reset });

    // 3. Clean if requested
    if (clean) {
        std.debug.print("  {s}Removing node_modules...{s}\n", .{ ansi.dim, ansi.reset });
        std.fs.cwd().deleteTree("node_modules") catch {};
        std.debug.print("  {s}+{s} Cleaned\n\n", .{ ansi.green, ansi.reset });
    }

    // 4. Run npm install
    std.debug.print("  {s}Installing dependencies...{s}\n\n", .{ ansi.bold, ansi.reset });
    runNpmInstall(allocator);

    std.debug.print("\n  {s}Done!{s}\n\n", .{ ansi.green, ansi.reset });
}

// ── Merged package.json Generation ──────────────────────────────────────────

fn generateRootPackageJson(allocator: Allocator, cfg: config_mod.WuConfig) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    const eql = std.mem.eql;

    try w.writeAll("{\n");
    try w.print("  \"_wu\": \"auto-generated from wu.config.json — do not edit manually\",\n", .{});
    try w.print("  \"name\": \"{s}\",\n", .{cfg.name});
    try w.writeAll("  \"private\": true,\n");
    try w.writeAll("  \"scripts\": {\n    \"dev\": \"wu dev\",\n    \"build\": \"wu build\"\n  },\n");

    // ── Merged dependencies (deduplicated across all apps) ───────────
    try w.writeAll("  \"dependencies\": {\n    \"wu-framework\": \"^1.1.17\"");

    var has_react = false;
    var has_vue = false;
    var has_svelte = false;
    var has_solid = false;
    var has_preact = false;
    var has_lit = false;

    for (cfg.apps) |app| {
        if (eql(u8, app.framework, "react") and !has_react) {
            try w.writeAll(",\n    \"react\": \"^19.0.0\",\n    \"react-dom\": \"^19.0.0\"");
            has_react = true;
        } else if (eql(u8, app.framework, "vue") and !has_vue) {
            try w.writeAll(",\n    \"vue\": \"^3.5.0\"");
            has_vue = true;
        } else if (eql(u8, app.framework, "svelte") and !has_svelte) {
            try w.writeAll(",\n    \"svelte\": \"^5.0.0\"");
            has_svelte = true;
        } else if (eql(u8, app.framework, "solid") and !has_solid) {
            try w.writeAll(",\n    \"solid-js\": \"^1.9.0\"");
            has_solid = true;
        } else if (eql(u8, app.framework, "preact") and !has_preact) {
            try w.writeAll(",\n    \"preact\": \"^10.25.0\"");
            has_preact = true;
        } else if (eql(u8, app.framework, "lit") and !has_lit) {
            try w.writeAll(",\n    \"lit\": \"^3.2.0\"");
            has_lit = true;
        }
    }
    try w.writeAll("\n  },\n");

    // ── Merged devDependencies (toolchain + plugins) ─────────────────
    try w.writeAll("  \"devDependencies\": {\n    \"esbuild\": \"^0.25.0\",\n    \"vite\": \"^6.0.0\"");

    var has_react_p = false;
    var has_vue_p = false;
    var has_svelte_p = false;
    var has_solid_p = false;

    for (cfg.apps) |app| {
        if (eql(u8, app.framework, "react") and !has_react_p) {
            try w.writeAll(",\n    \"@vitejs/plugin-react\": \"^4.3.0\"");
            has_react_p = true;
        } else if (eql(u8, app.framework, "vue") and !has_vue_p) {
            try w.writeAll(",\n    \"@vitejs/plugin-vue\": \"^5.2.0\"");
            has_vue_p = true;
        } else if (eql(u8, app.framework, "svelte") and !has_svelte_p) {
            try w.writeAll(",\n    \"@sveltejs/vite-plugin-svelte\": \"^5.0.0\"");
            has_svelte_p = true;
        } else if (eql(u8, app.framework, "solid") and !has_solid_p) {
            try w.writeAll(",\n    \"vite-plugin-solid\": \"^2.11.0\"");
            try w.writeAll(",\n    \"babel-preset-solid\": \"^1.9.0\"");
            try w.writeAll(",\n    \"@babel/core\": \"^7.26.0\"");
            has_solid_p = true;
        }
    }

    try w.writeAll("\n  }\n}\n");

    const file = try std.fs.cwd().createFile("package.json", .{});
    defer file.close();
    try file.writeAll(buf.items);
}

// ── npm install ─────────────────────────────────────────────────────────────

fn runNpmInstall(allocator: Allocator) void {
    const argv = [_][]const u8{ "npm", "install", "--silent" };
    var child = std.process.Child.init(&argv, allocator);
    child.cwd = null; // CWD = current directory
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
