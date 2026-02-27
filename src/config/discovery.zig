// WU CLI — Auto-discovery Engine
//
// When no wu.config.json exists, scans the project tree to find
// micro-app directories by looking for vite.config.js/ts, package.json,
// and astro.config.mjs patterns. Extracts ports from config files.
// Pattern inspired by VIGIL's file walker.

const std = @import("std");
const Allocator = std.mem.Allocator;
const config = @import("config.zig");

/// Known framework indicators in package.json dependencies.
const FrameworkHint = struct {
    dep: []const u8,
    framework: []const u8,
};

const framework_hints = [_]FrameworkHint{
    .{ .dep = "react", .framework = "react" },
    .{ .dep = "vue", .framework = "vue" },
    .{ .dep = "@angular/core", .framework = "angular" },
    .{ .dep = "svelte", .framework = "svelte" },
    .{ .dep = "solid-js", .framework = "solid" },
    .{ .dep = "preact", .framework = "preact" },
    .{ .dep = "lit", .framework = "lit" },
    .{ .dep = "astro", .framework = "astro" },
};

/// Discover micro-apps in the current directory tree.
/// Returns a WuConfig populated with found apps.
pub fn discover(allocator: Allocator) config.WuConfig {
    var cfg = config.WuConfig{};
    var apps: std.ArrayList(config.AppConfig) = .empty;
    var next_port: u16 = 5001;

    // Scan immediate subdirectories for vite.config.* or astro.config.*
    var dir = std.fs.cwd().openDir(".", .{ .iterate = true }) catch return cfg;
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        // Skip hidden dirs and node_modules
        if (entry.name[0] == '.' or std.mem.eql(u8, entry.name, "node_modules") or
            std.mem.eql(u8, entry.name, "dist") or std.mem.eql(u8, entry.name, "build"))
            continue;

        const app_info = probeDirectory(allocator, entry.name, next_port);
        if (app_info) |info| {
            if (std.mem.eql(u8, info.framework, "astro")) {
                cfg.shell = .{
                    .dir = info.dir, // already duped in probeDirectory
                    .port = info.port,
                    .framework = "astro",
                };
            } else {
                apps.append(allocator, info) catch continue;
                next_port = info.port + 1;
            }
        }
    }

    cfg.apps = apps.toOwnedSlice(allocator) catch &.{};
    return cfg;
}

/// Check if a subdirectory looks like a micro-app.
/// Dupes all strings so they survive past the directory iterator.
fn probeDirectory(allocator: Allocator, name: []const u8, default_port: u16) ?config.AppConfig {
    // Check for vite.config.js, vite.config.ts, or astro.config.mjs
    const config_files = [_][]const u8{
        "vite.config.js",
        "vite.config.ts",
        "vite.config.mjs",
        "astro.config.mjs",
        "astro.config.ts",
    };

    var found_config = false;
    var is_astro = false;

    for (config_files) |cfg_file| {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ name, cfg_file }) catch continue;

        if (std.fs.cwd().access(path, .{})) |_| {
            found_config = true;
            if (std.mem.startsWith(u8, cfg_file, "astro")) {
                is_astro = true;
            }
            break;
        } else |_| {}
    }

    if (!found_config) return null;

    // Try to detect framework from package.json
    const framework = detectFramework(name) orelse if (is_astro) "astro" else "vanilla";

    // Try to extract port from config file
    const port = extractPort(name) orelse default_port;

    // Dupe all strings so they outlive the directory iterator buffer
    const dir_dupe = allocator.dupe(u8, name) catch return null;

    // Derive app name from directory name
    var app_name: []const u8 = dir_dupe;
    if (std.mem.startsWith(u8, dir_dupe, "mf-")) {
        app_name = dir_dupe[3..]; // sub-slice of duped memory, safe
    }

    return .{
        .name = app_name,
        .dir = dir_dupe,
        .framework = framework,
        .port = port,
    };
}

/// Read package.json to detect which framework is used.
fn detectFramework(dir_name: []const u8) ?[]const u8 {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/package.json", .{dir_name}) catch return null;

    var buf: [8192]u8 = undefined;
    const contents = readSmallFile(path, &buf) orelse return null;

    for (framework_hints) |hint| {
        if (std.mem.indexOf(u8, contents, hint.dep) != null) {
            return hint.framework;
        }
    }
    return null;
}

/// Extract port number from vite.config.js (looks for --port NNNN or port: NNNN).
fn extractPort(dir_name: []const u8) ?u16 {
    const config_names = [_][]const u8{
        "vite.config.js",
        "vite.config.ts",
        "vite.config.mjs",
    };

    for (config_names) |cfg_name| {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_name, cfg_name }) catch continue;

        var buf: [4096]u8 = undefined;
        const contents = readSmallFile(path, &buf) orelse continue;

        // Look for port: NNNN pattern
        if (findPortInText(contents)) |port| return port;
    }

    // Also check package.json scripts for --port NNNN
    {
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/package.json", .{dir_name}) catch return null;

        var buf: [8192]u8 = undefined;
        const contents = readSmallFile(path, &buf) orelse return null;

        if (std.mem.indexOf(u8, contents, "--port ")) |idx| {
            const after = contents[idx + 7 ..];
            var end: usize = 0;
            while (end < after.len and std.ascii.isDigit(after[end])) end += 1;
            if (end > 0) {
                return std.fmt.parseInt(u16, after[0..end], 10) catch null;
            }
        }
    }

    return null;
}

fn findPortInText(text: []const u8) ?u16 {
    // Match "port:" or "port :" followed by digits
    var i: usize = 0;
    while (i + 4 < text.len) : (i += 1) {
        if (std.mem.startsWith(u8, text[i..], "port")) {
            var j = i + 4;
            // skip whitespace and colon
            while (j < text.len and (text[j] == ' ' or text[j] == ':' or text[j] == '\t')) j += 1;
            // read digits
            const start = j;
            while (j < text.len and std.ascii.isDigit(text[j])) j += 1;
            if (j > start) {
                return std.fmt.parseInt(u16, text[start..j], 10) catch null;
            }
        }
    }
    return null;
}

fn readSmallFile(path: []const u8, buf: []u8) ?[]const u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const n = file.readAll(buf) catch return null;
    return buf[0..n];
}
