// WU CLI — `wu add` Command
//
// Add a new micro-app to an existing wu project.
//
// Usage:
//   wu add react header        → creates mf-header/ with React setup
//   wu add vue sidebar          → creates mf-sidebar/ with Vue setup

const std = @import("std");
const Allocator = std.mem.Allocator;
const config_mod = @import("../config/config.zig");
const ansi = @import("../util/ansi.zig");

pub fn run(allocator: Allocator, args: *std.process.ArgIterator) !void {
    const framework = args.next() orelse {
        std.debug.print("  {s}Usage:{s} wu add {s}<framework> <name>{s}\n\n", .{
            ansi.bold, ansi.reset, ansi.cyan, ansi.reset,
        });
        std.debug.print("  {s}Frameworks:{s} react, vue, svelte, solid, preact, lit, angular, vanilla\n\n", .{
            ansi.dim, ansi.reset,
        });
        std.debug.print("  {s}Example:{s} wu add react header\n\n", .{
            ansi.dim, ansi.reset,
        });
        return;
    };

    const app_name = args.next() orelse {
        std.debug.print("  {s}Please provide an app name:{s} wu add {s} {s}<name>{s}\n", .{
            ansi.red, ansi.reset, framework, ansi.cyan, ansi.reset,
        });
        return;
    };

    // Validate framework
    const valid = [_][]const u8{
        "react", "vue", "svelte", "solid", "preact", "lit", "angular", "vanilla",
    };
    var is_valid = false;
    for (valid) |v| {
        if (std.mem.eql(u8, framework, v)) {
            is_valid = true;
            break;
        }
    }
    if (!is_valid) {
        std.debug.print("  {s}Unknown framework: {s}{s}\n", .{
            ansi.red, framework, ansi.reset,
        });
        return;
    }

    // Directory name: mf-<name>
    var dir_buf: [256]u8 = undefined;
    const dir_name = std.fmt.bufPrint(&dir_buf, "mf-{s}", .{app_name}) catch return;

    // Check if exists
    if (std.fs.cwd().openDir(dir_name, .{})) |_| {
        std.debug.print("  {s}Directory '{s}' already exists.{s}\n", .{
            ansi.red, dir_name, ansi.reset,
        });
        return;
    } else |_| {}

    // Load current config to find next available port
    var cfg = config_mod.loadConfig(allocator);
    var next_port: u16 = 5001;
    for (cfg.apps) |app| {
        if (app.port >= next_port) next_port = app.port + 1;
    }

    const color = ansi.frameworkColor(framework);
    std.debug.print("\n  {s}Adding micro-app:{s} {s}{s}{s} ({s}{s}{s}) on port {s}:{d}{s}\n", .{
        ansi.bold,  ansi.reset,
        ansi.cyan,  app_name,
        ansi.reset,
        color,      framework,
        ansi.reset,
        ansi.cyan,  next_port,
        ansi.reset,
    });

    // Create directory structure
    try std.fs.cwd().makeDir(dir_name);

    var path_buf: [512]u8 = undefined;
    const src_dir = try std.fmt.bufPrint(&path_buf, "{s}/src", .{dir_name});
    try std.fs.cwd().makeDir(src_dir);

    // package.json
    var pkg: std.ArrayList(u8) = .empty;
    defer pkg.deinit(allocator);
    const pw = pkg.writer(allocator);
    try pw.print(
        \\{{
        \\  "name": "wu-mf-{s}",
        \\  "private": true,
        \\  "type": "module",
        \\  "scripts": {{
        \\    "dev": "vite --port {d}",
        \\    "build": "vite build"
        \\  }},
        \\  "dependencies": {{
        \\    "wu-framework": "^1.1.17"
        \\  }},
        \\  "devDependencies": {{
        \\    "vite": "^6.0.0"
        \\  }}
        \\}}
        \\
    , .{ app_name, next_port });

    const pkg_path = try std.fmt.bufPrint(&path_buf, "{s}/package.json", .{dir_name});
    try writeFile(pkg_path, pkg.items);

    // vite.config.js
    const vite_path = try std.fmt.bufPrint(&path_buf, "{s}/vite.config.js", .{dir_name});
    try writeFile(vite_path, "import { defineConfig } from 'vite';\nexport default defineConfig({ build: { target: 'esnext' } });\n");

    // index.html
    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(allocator);
    const hw = html.writer(allocator);
    try hw.print(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head><meta charset="UTF-8" /><title>{s}</title></head>
        \\<body><div id="app"></div><script type="module" src="/src/main.js"></script></body>
        \\</html>
        \\
    , .{app_name});
    const html_path = try std.fmt.bufPrint(&path_buf, "{s}/index.html", .{dir_name});
    try writeFile(html_path, html.items);

    // src/main.js
    var main_js: std.ArrayList(u8) = .empty;
    defer main_js.deinit(allocator);
    const mw = main_js.writer(allocator);
    try mw.print(
        \\import {{ wuVanilla }} from 'wu-framework/adapters/vanilla';
        \\
        \\wuVanilla.register('{s}', {{
        \\  render(container) {{
        \\    container.innerHTML = '<h2>{s} ({s})</h2>';
        \\  }}
        \\}});
        \\
    , .{ app_name, app_name, framework });
    const main_path = try std.fmt.bufPrint(&path_buf, "{s}/src/main.js", .{dir_name});
    try writeFile(main_path, main_js.items);

    // Update wu.config.json if it exists
    if (cfg.from_file) {
        // Add app to config — create new apps array
        var new_apps: std.ArrayList(config_mod.AppConfig) = .empty;
        defer new_apps.deinit(allocator);
        for (cfg.apps) |app| try new_apps.append(allocator, app);
        try new_apps.append(allocator, .{
            .name = app_name,
            .dir = dir_name,
            .framework = framework,
            .port = next_port,
        });
        cfg.apps = try new_apps.toOwnedSlice(allocator);
        config_mod.writeConfig(allocator, &cfg) catch {};
    }

    std.debug.print("\n  {s}✓ Created {s}/{s}\n\n", .{
        ansi.green, dir_name, ansi.reset,
    });
    std.debug.print("  {s}Next:{s} cd {s} && npm install\n\n", .{
        ansi.dim, ansi.reset, dir_name,
    });
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}
