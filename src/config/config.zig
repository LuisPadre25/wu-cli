// WU CLI — Configuration Loader
//
// Reads wu.config.json from CWD. The config file is optional —
// if missing, auto-discovery kicks in (see discovery.zig).
// Hand-rolled JSON parser — zero dependencies, like STORM.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ─── Config Structures ────────────────────────────────────────────────────

pub const AppConfig = struct {
    name: []const u8 = "",
    dir: []const u8 = "",
    framework: []const u8 = "vanilla",
    port: u16 = 0,
    dev_cmd: []const u8 = "npx vite",
    build_cmd: []const u8 = "npx vite build",
};

pub const ShellConfig = struct {
    dir: []const u8 = "shell",
    port: u16 = 4321,
    framework: []const u8 = "astro",
    dev_cmd: []const u8 = "npx astro dev",
    build_cmd: []const u8 = "npx astro build",
};

pub const ProxyConfig = struct {
    port: u16 = 3000,
    open_browser: bool = true,
};

pub const WuConfig = struct {
    name: []const u8 = "wu-project",
    version: []const u8 = "0.1.0",
    shell: ShellConfig = .{},
    apps: []AppConfig = &.{},
    proxy: ProxyConfig = .{},
    from_file: bool = false,

    // Owned memory for cleanup (set by loadConfig)
    _json_buf: ?[]const u8 = null,
    _apps_owned: bool = false,

    pub fn appCount(self: *const WuConfig) usize {
        return self.apps.len;
    }

    pub fn totalPorts(self: *const WuConfig) usize {
        return self.apps.len + 1; // +1 for shell
    }

    /// Free memory allocated by loadConfig.
    pub fn deinit(self: *WuConfig, allocator: Allocator) void {
        if (self._apps_owned and self.apps.len > 0) {
            allocator.free(self.apps);
            self.apps = &.{};
            self._apps_owned = false;
        }
        if (self._json_buf) |buf| {
            allocator.free(buf);
            self._json_buf = null;
        }
    }
};

// ─── Config Loader ────────────────────────────────────────────────────────

/// Load wu.config.json from CWD. Returns defaults if missing.
/// Call deinit() to free allocated memory when done.
pub fn loadConfig(allocator: Allocator) WuConfig {
    const contents = std.fs.cwd().readFileAlloc(allocator, "wu.config.json", 256 * 1024) catch {
        return .{};
    };

    var cfg = parseConfigJson(allocator, contents) catch .{};
    cfg._json_buf = contents;
    return cfg;
}

/// Load wu.config.json from a specific directory path.
/// Call deinit() to free allocated memory when done.
pub fn loadConfigFrom(allocator: Allocator, dir_path: []const u8) WuConfig {
    const path = std.fmt.allocPrint(allocator, "{s}/wu.config.json", .{dir_path}) catch return .{};
    defer allocator.free(path);

    const contents = std.fs.cwd().readFileAlloc(allocator, path, 256 * 1024) catch {
        return .{};
    };

    var cfg = parseConfigJson(allocator, contents) catch .{};
    cfg._json_buf = contents;
    return cfg;
}

/// Write config to wu.config.json in CWD.
pub fn writeConfig(allocator: Allocator, cfg: *const WuConfig) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("{\n");
    try w.print("  \"name\": \"{s}\",\n", .{cfg.name});
    try w.print("  \"version\": \"{s}\",\n", .{cfg.version});

    // Shell
    try w.writeAll("  \"shell\": {\n");
    try w.print("    \"dir\": \"{s}\",\n", .{cfg.shell.dir});
    try w.print("    \"port\": {d},\n", .{cfg.shell.port});
    try w.print("    \"framework\": \"{s}\"\n", .{cfg.shell.framework});
    try w.writeAll("  },\n");

    // Apps
    try w.writeAll("  \"apps\": [\n");
    for (cfg.apps, 0..) |app, i| {
        try w.writeAll("    {\n");
        try w.print("      \"name\": \"{s}\",\n", .{app.name});
        try w.print("      \"dir\": \"{s}\",\n", .{app.dir});
        try w.print("      \"framework\": \"{s}\",\n", .{app.framework});
        try w.print("      \"port\": {d}\n", .{app.port});
        if (i < cfg.apps.len - 1) {
            try w.writeAll("    },\n");
        } else {
            try w.writeAll("    }\n");
        }
    }
    try w.writeAll("  ],\n");

    // Proxy
    try w.writeAll("  \"proxy\": {\n");
    try w.print("    \"port\": {d},\n", .{cfg.proxy.port});
    try w.print("    \"open_browser\": {s}\n", .{if (cfg.proxy.open_browser) "true" else "false"});
    try w.writeAll("  }\n");
    try w.writeAll("}\n");

    try std.fs.cwd().writeFile(.{
        .sub_path = "wu.config.json",
        .data = buf.items,
    });
}

/// Write config to a specific directory.
pub fn writeConfigTo(allocator: Allocator, cfg: *const WuConfig, dir_path: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("{\n");
    try w.print("  \"name\": \"{s}\",\n", .{cfg.name});
    try w.print("  \"version\": \"{s}\",\n", .{cfg.version});

    try w.writeAll("  \"shell\": {\n");
    try w.print("    \"dir\": \"{s}\",\n", .{cfg.shell.dir});
    try w.print("    \"port\": {d},\n", .{cfg.shell.port});
    try w.print("    \"framework\": \"{s}\"\n", .{cfg.shell.framework});
    try w.writeAll("  },\n");

    try w.writeAll("  \"apps\": [\n");
    for (cfg.apps, 0..) |app, i| {
        try w.writeAll("    {\n");
        try w.print("      \"name\": \"{s}\",\n", .{app.name});
        try w.print("      \"dir\": \"{s}\",\n", .{app.dir});
        try w.print("      \"framework\": \"{s}\",\n", .{app.framework});
        try w.print("      \"port\": {d}\n", .{app.port});
        if (i < cfg.apps.len - 1) {
            try w.writeAll("    },\n");
        } else {
            try w.writeAll("    }\n");
        }
    }
    try w.writeAll("  ],\n");

    try w.writeAll("  \"proxy\": {\n");
    try w.print("    \"port\": {d},\n", .{cfg.proxy.port});
    try w.print("    \"open_browser\": {s}\n", .{if (cfg.proxy.open_browser) "true" else "false"});
    try w.writeAll("  }\n");
    try w.writeAll("}\n");

    const file_path = std.fmt.allocPrint(allocator, "{s}/wu.config.json", .{dir_path}) catch return error.OutOfMemory;
    defer allocator.free(file_path);

    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();
    try file.writeAll(buf.items);
}

// ─── JSON Parser (hand-rolled, zero deps) ────────────────────────────────

fn parseConfigJson(allocator: Allocator, json: []const u8) !WuConfig {
    var cfg = WuConfig{ .from_file = true };
    var apps_list: std.ArrayList(AppConfig) = .empty;

    var pos: usize = 0;

    // Find opening brace
    pos = std.mem.indexOfScalar(u8, json, '{') orelse return cfg;
    pos += 1;

    while (pos < json.len and json[pos] != '}') {
        while (pos < json.len and isWs(json[pos])) pos += 1;
        if (pos >= json.len or json[pos] == '}') break;

        const key = readString(json, &pos) orelse break;
        skipColon(json, &pos);

        if (std.mem.eql(u8, key, "name")) {
            cfg.name = readString(json, &pos) orelse "";
        } else if (std.mem.eql(u8, key, "version")) {
            cfg.version = readString(json, &pos) orelse "";
        } else if (std.mem.eql(u8, key, "shell")) {
            cfg.shell = parseShell(json, &pos);
        } else if (std.mem.eql(u8, key, "apps")) {
            parseAppsArray(allocator, json, &pos, &apps_list) catch {};
        } else if (std.mem.eql(u8, key, "proxy")) {
            cfg.proxy = parseProxy(json, &pos);
        } else {
            skipValue(json, &pos);
        }

        // skip comma
        while (pos < json.len and (isWs(json[pos]) or json[pos] == ',')) pos += 1;
    }

    cfg.apps = apps_list.toOwnedSlice(allocator) catch &.{};
    cfg._apps_owned = cfg.apps.len > 0;
    return cfg;
}

fn parseShell(json: []const u8, pos: *usize) ShellConfig {
    var shell = ShellConfig{};
    // Find {
    while (pos.* < json.len and json[pos.*] != '{') pos.* += 1;
    if (pos.* < json.len) pos.* += 1;

    while (pos.* < json.len and json[pos.*] != '}') {
        while (pos.* < json.len and isWs(json[pos.*])) pos.* += 1;
        if (pos.* >= json.len or json[pos.*] == '}') break;

        const key = readString(json, pos) orelse break;
        skipColon(json, pos);

        if (std.mem.eql(u8, key, "dir")) {
            shell.dir = readString(json, pos) orelse "";
        } else if (std.mem.eql(u8, key, "port")) {
            shell.port = readU16(json, pos);
        } else if (std.mem.eql(u8, key, "framework")) {
            shell.framework = readString(json, pos) orelse "astro";
        } else if (std.mem.eql(u8, key, "dev_cmd")) {
            shell.dev_cmd = readString(json, pos) orelse "npx astro dev";
        } else if (std.mem.eql(u8, key, "build_cmd")) {
            shell.build_cmd = readString(json, pos) orelse "npx astro build";
        } else {
            skipValue(json, pos);
        }
        while (pos.* < json.len and (isWs(json[pos.*]) or json[pos.*] == ',')) pos.* += 1;
    }
    if (pos.* < json.len) pos.* += 1; // skip }
    return shell;
}

fn parseProxy(json: []const u8, pos: *usize) ProxyConfig {
    var proxy = ProxyConfig{};
    while (pos.* < json.len and json[pos.*] != '{') pos.* += 1;
    if (pos.* < json.len) pos.* += 1;

    while (pos.* < json.len and json[pos.*] != '}') {
        while (pos.* < json.len and isWs(json[pos.*])) pos.* += 1;
        if (pos.* >= json.len or json[pos.*] == '}') break;

        const key = readString(json, pos) orelse break;
        skipColon(json, pos);

        if (std.mem.eql(u8, key, "port")) {
            proxy.port = readU16(json, pos);
        } else if (std.mem.eql(u8, key, "open_browser")) {
            proxy.open_browser = readBool(json, pos);
        } else {
            skipValue(json, pos);
        }
        while (pos.* < json.len and (isWs(json[pos.*]) or json[pos.*] == ',')) pos.* += 1;
    }
    if (pos.* < json.len) pos.* += 1;
    return proxy;
}

fn parseAppsArray(allocator: Allocator, json: []const u8, pos: *usize, list: *std.ArrayList(AppConfig)) !void {
    while (pos.* < json.len and json[pos.*] != '[') pos.* += 1;
    if (pos.* < json.len) pos.* += 1;

    while (pos.* < json.len and json[pos.*] != ']') {
        while (pos.* < json.len and isWs(json[pos.*])) pos.* += 1;
        if (pos.* >= json.len or json[pos.*] == ']') break;

        if (json[pos.*] == '{') {
            const app = parseOneApp(json, pos);
            try list.append(allocator, app);
        } else {
            pos.* += 1;
        }
        while (pos.* < json.len and (isWs(json[pos.*]) or json[pos.*] == ',')) pos.* += 1;
    }
    if (pos.* < json.len) pos.* += 1; // skip ]
}

fn parseOneApp(json: []const u8, pos: *usize) AppConfig {
    var app = AppConfig{};
    if (pos.* < json.len) pos.* += 1; // skip {

    while (pos.* < json.len and json[pos.*] != '}') {
        while (pos.* < json.len and isWs(json[pos.*])) pos.* += 1;
        if (pos.* >= json.len or json[pos.*] == '}') break;

        const key = readString(json, pos) orelse break;
        skipColon(json, pos);

        if (std.mem.eql(u8, key, "name")) {
            app.name = readString(json, pos) orelse "";
        } else if (std.mem.eql(u8, key, "dir")) {
            app.dir = readString(json, pos) orelse "";
        } else if (std.mem.eql(u8, key, "framework")) {
            app.framework = readString(json, pos) orelse "vanilla";
        } else if (std.mem.eql(u8, key, "port")) {
            app.port = readU16(json, pos);
        } else if (std.mem.eql(u8, key, "dev_cmd")) {
            app.dev_cmd = readString(json, pos) orelse "npx vite";
        } else if (std.mem.eql(u8, key, "build_cmd")) {
            app.build_cmd = readString(json, pos) orelse "npx vite build";
        } else {
            skipValue(json, pos);
        }
        while (pos.* < json.len and (isWs(json[pos.*]) or json[pos.*] == ',')) pos.* += 1;
    }
    if (pos.* < json.len) pos.* += 1; // skip }
    return app;
}

// ─── JSON Primitives ─────────────────────────────────────────────────────

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn readString(json: []const u8, pos: *usize) ?[]const u8 {
    while (pos.* < json.len and json[pos.*] != '"') pos.* += 1;
    if (pos.* >= json.len) return null;
    pos.* += 1; // skip opening "

    const start = pos.*;
    while (pos.* < json.len and json[pos.*] != '"') {
        if (json[pos.*] == '\\') pos.* += 1; // skip escape
        pos.* += 1;
    }
    const end = pos.*;
    if (pos.* < json.len) pos.* += 1; // skip closing "
    return json[start..end];
}

fn readU16(json: []const u8, pos: *usize) u16 {
    while (pos.* < json.len and !std.ascii.isDigit(json[pos.*])) pos.* += 1;
    const start = pos.*;
    while (pos.* < json.len and std.ascii.isDigit(json[pos.*])) pos.* += 1;
    return std.fmt.parseInt(u16, json[start..pos.*], 10) catch 0;
}

fn readBool(json: []const u8, pos: *usize) bool {
    while (pos.* < json.len and isWs(json[pos.*])) pos.* += 1;
    if (pos.* < json.len and json[pos.*] == 't') {
        pos.* += 4; // true
        return true;
    }
    pos.* += 5; // false
    return false;
}

fn skipColon(json: []const u8, pos: *usize) void {
    while (pos.* < json.len and json[pos.*] != ':') pos.* += 1;
    if (pos.* < json.len) pos.* += 1;
    while (pos.* < json.len and isWs(json[pos.*])) pos.* += 1;
}

fn skipValue(json: []const u8, pos: *usize) void {
    while (pos.* < json.len and isWs(json[pos.*])) pos.* += 1;
    if (pos.* >= json.len) return;

    const c = json[pos.*];
    if (c == '"') {
        _ = readString(json, pos);
    } else if (c == '{') {
        var depth: usize = 1;
        pos.* += 1;
        while (pos.* < json.len and depth > 0) : (pos.* += 1) {
            if (json[pos.*] == '{') depth += 1;
            if (json[pos.*] == '}') depth -= 1;
        }
    } else if (c == '[') {
        var depth: usize = 1;
        pos.* += 1;
        while (pos.* < json.len and depth > 0) : (pos.* += 1) {
            if (json[pos.*] == '[') depth += 1;
            if (json[pos.*] == ']') depth -= 1;
        }
    } else {
        // number, bool, null
        while (pos.* < json.len and json[pos.*] != ',' and json[pos.*] != '}' and json[pos.*] != ']') pos.* += 1;
    }
}

// ─── Tests ──────────────────────────────────────────────────────────────

test "parse minimal config" {
    const json =
        \\{
        \\  "name": "test-project",
        \\  "shell": { "dir": "shell", "port": 4321 },
        \\  "apps": [
        \\    { "name": "header", "dir": "mf-header", "framework": "react", "port": 5001 }
        \\  ]
        \\}
    ;
    const cfg = try parseConfigJson(std.testing.allocator, json);
    defer std.testing.allocator.free(cfg.apps);

    try std.testing.expectEqualStrings("test-project", cfg.name);
    try std.testing.expectEqual(@as(u16, 4321), cfg.shell.port);
    try std.testing.expectEqual(@as(usize, 1), cfg.apps.len);
    try std.testing.expectEqualStrings("header", cfg.apps[0].name);
    try std.testing.expectEqual(@as(u16, 5001), cfg.apps[0].port);
}
