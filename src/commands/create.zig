// WU CLI — `wu create` Command
//
// Interactive guided project scaffolding.
//
// Flow:
//   1. Project name
//   2. Add micro-apps one by one (name + framework)
//   3. Generate all files (shell, apps, config)
//   4. Generate merged root package.json + single npm install
//      (each app keeps its own package.json for identity/ejection/debug)
//   5. Ready → `wu dev`

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const config_mod = @import("../config/config.zig");
const ansi = @import("../util/ansi.zig");

// NOTE: "qwik" disabled — qwikloader's global event delegation is incompatible with Shadow DOM
// (event.target retargeting breaks QRL resolution). See: https://github.com/QwikDev/qwik-evolution/issues/283
const fw_names = [_][]const u8{ "react", "vue", "svelte", "solid", "preact", "lit", "vanilla", "angular", "alpine", "stencil", "htmx", "stimulus" };
const fw_labels = [_][]const u8{ "React", "Vue", "Svelte", "Solid", "Preact", "Lit", "Vanilla", "Angular", "Alpine.js", "Stencil", "HTMX", "Stimulus" };

pub const MicroApp = struct {
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    framework: []const u8 = "react",
    port: u16 = 5001,

    fn name(self: *const MicroApp) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    fn dirName(self: *const MicroApp, buf: *[256]u8) []const u8 {
        return std.fmt.bufPrint(buf, "mf-{s}", .{self.name()}) catch "mf-app";
    }
};

pub fn run(allocator: Allocator, args: *std.process.ArgIterator) !void {
    // Quick mode: wu create my-project --template react (backwards compat)
    var quick_name: ?[]const u8 = null;
    var quick_template: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--template") or std.mem.eql(u8, arg, "-t")) {
            quick_template = args.next();
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            quick_name = arg;
        }
    }

    // If --template given, use the old quick mode
    if (quick_name != null and quick_template != null) {
        return quickCreate(allocator, quick_name.?, quick_template.?);
    }

    // ── Interactive mode ────────────────────────────────────────────────
    const stdin_handle = if (builtin.os.tag == .windows)
        std.os.windows.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) catch return
    else
        @as(std.fs.File.Handle, 0);
    const stdin = std.fs.File{ .handle = stdin_handle };

    std.debug.print("\n  {s}WU{s}  Create new project\n", .{ ansi.bold, ansi.reset });
    std.debug.print("  {s}────────────────────────{s}\n\n", .{ ansi.dim, ansi.reset });

    // 1. Project name
    var name_buf: [128]u8 = undefined;
    const project_name = if (quick_name) |qn| qn else blk: {
        std.debug.print("  {s}Project name:{s} ", .{ ansi.bold, ansi.reset });
        const trimmed = readLine(&stdin, &name_buf) orelse return;
        if (trimmed.len == 0) {
            std.debug.print("  {s}No name provided.{s}\n", .{ ansi.red, ansi.reset });
            return;
        }
        break :blk trimmed;
    };

    // Check if exists
    if (std.fs.cwd().openDir(project_name, .{})) |_| {
        std.debug.print("  {s}Directory '{s}' already exists.{s}\n", .{
            ansi.red, project_name, ansi.reset,
        });
        return;
    } else |_| {}

    // 2. Add micro-apps
    var apps: [16]MicroApp = undefined;
    var app_count: usize = 0;
    var next_port: u16 = 5001;

    std.debug.print("\n  {s}Add micro-apps{s} {s}(press Enter without name to finish){s}\n\n", .{
        ansi.bold, ansi.reset, ansi.dim, ansi.reset,
    });

    while (app_count < 16) {
        std.debug.print("  {s}App name:{s} ", .{ ansi.cyan, ansi.reset });

        var app_name_buf: [128]u8 = undefined;
        const app_name = readLine(&stdin, &app_name_buf) orelse break;

        if (app_name.len == 0) break;

        // Check for duplicate names
        const sanitized_check = blk: {
            var tmp: [64]u8 = undefined;
            const clen = @min(app_name.len, 64);
            for (app_name[0..clen], 0..) |c, idx| {
                tmp[idx] = if (c == ' ' or c == '_' or c == '.' or c == '/')
                    @as(u8, '-')
                else if (c >= 'A' and c <= 'Z')
                    c + 32
                else
                    c;
            }
            break :blk tmp[0..clen];
        };
        var is_dup = false;
        for (apps[0..app_count]) |*existing| {
            if (std.mem.eql(u8, existing.name(), sanitized_check)) {
                is_dup = true;
                break;
            }
        }
        if (is_dup) {
            std.debug.print("  {s}Name '{s}' already used. Pick a different name.{s}\n\n", .{
                ansi.red, app_name, ansi.reset,
            });
            continue;
        }

        // Pick framework
        std.debug.print("  {s}Framework:{s}", .{ ansi.dim, ansi.reset });
        for (fw_labels, 0..) |label, i| {
            const color = ansi.frameworkColor(fw_names[i]);
            std.debug.print("  {s}{d}.{s}{s}{s}", .{ ansi.dim, i + 1, ansi.reset, color, label });
        }
        std.debug.print("{s}\n", .{ansi.reset});
        std.debug.print("  {s}Choose [1-13]:{s} ", .{ ansi.dim, ansi.reset });

        var choice_buf: [16]u8 = undefined;
        const choice_str = readLine(&stdin, &choice_buf) orelse break;
        const choice_num = std.fmt.parseInt(usize, choice_str, 10) catch 1;
        const fw_idx = if (choice_num >= 1 and choice_num <= fw_names.len) choice_num - 1 else 0;

        var app = MicroApp{
            .framework = fw_names[fw_idx],
            .port = next_port,
        };
        // Sanitize: lowercase, replace spaces/special chars with hyphens
        const copy_len = @min(app_name.len, 64);
        var sanitized: [64]u8 = undefined;
        for (app_name[0..copy_len], 0..) |c, idx| {
            sanitized[idx] = if (c == ' ' or c == '_' or c == '.' or c == '/')
                @as(u8, '-')
            else if (c >= 'A' and c <= 'Z')
                c + 32
            else
                c;
        }
        @memcpy(app.name_buf[0..copy_len], sanitized[0..copy_len]);
        app.name_len = copy_len;

        apps[app_count] = app;
        app_count += 1;
        next_port += 1;

        const color = ansi.frameworkColor(fw_names[fw_idx]);
        std.debug.print("  {s}+{s} {s}{s}{s} ({s}{s}{s}) → port {d}\n\n", .{
            ansi.green, ansi.reset,
            ansi.bold,  app_name,  ansi.reset,
            color,      fw_labels[fw_idx], ansi.reset,
            app.port,
        });
    }

    if (app_count == 0) {
        std.debug.print("  {s}No apps added. Creating shell-only project.{s}\n\n", .{
            ansi.yellow, ansi.reset,
        });
    }

    // 3. Generate project
    std.debug.print("  {s}Generating project...{s}\n\n", .{ ansi.bold, ansi.reset });

    try std.fs.cwd().makeDir(project_name);

    // Generate shell
    try generateShell(allocator, project_name, apps[0..app_count]);

    // Generate each micro-app
    for (apps[0..app_count]) |*app| {
        try generateApp(allocator, project_name, app);
    }

    // Generate wu.config.json
    try generateConfig(allocator, project_name, apps[0..app_count]);

    // Generate root package.json
    try generateRootPackageJson(allocator, project_name, apps[0..app_count]);

    // Print summary
    std.debug.print("  {s}Created:{s}\n", .{ ansi.green, ansi.reset });
    std.debug.print("    {s}/shell/{s}           HTML shell\n", .{ project_name, "" });
    for (apps[0..app_count]) |*app| {
        var dir_buf: [256]u8 = undefined;
        const dir = app.dirName(&dir_buf);
        const color = ansi.frameworkColor(app.framework);
        std.debug.print("    {s}/{s:<18}{s}{s}{s}  port {d}\n", .{
            project_name, dir, color, app.framework, ansi.reset, app.port,
        });
    }

    // 4. Install dependencies
    std.debug.print("\n  {s}Installing dependencies...{s}\n\n", .{ ansi.bold, ansi.reset });
    try installDeps(allocator, project_name, apps[0..app_count]);

    // 5. Done
    std.debug.print("\n  {s}Ready!{s}\n\n", .{ ansi.green, ansi.reset });
    std.debug.print("    cd {s}\n", .{project_name});
    std.debug.print("    wu dev\n\n", .{});
}

// ── Shell Generation ────────────────────────────────────────────────────────

fn generateShell(_: Allocator, project: []const u8, _: []MicroApp) !void {
    var p: [512]u8 = undefined;

    const shell_dir = try std.fmt.bufPrint(&p, "{s}/shell", .{project});
    try std.fs.cwd().makeDir(shell_dir);

    // package.json
    const pkg_path = try std.fmt.bufPrint(&p, "{s}/shell/package.json", .{project});
    try writeFile(pkg_path,
        \\{
        \\  "name": "wu-shell",
        \\  "type": "module",
        \\  "dependencies": {
        \\    "wu-framework": "^1.1.17"
        \\  }
        \\}
        \\
    );

    // ── index.html — dynamic shell (no hardcoded apps) ──────────────────
    const index_path = try std.fmt.bufPrint(&p, "{s}/shell/index.html", .{project});
    try writeFile(index_path,
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="UTF-8" />
        \\  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        \\  <title>WU Shell</title>
        \\  <style>
        \\    * { margin: 0; padding: 0; box-sizing: border-box; }
        \\    body { font-family: system-ui, -apple-system, sans-serif; background: #0a0a0a; color: #e0e0e0; }
        \\    nav { width: 240px; position: fixed; top: 0; left: 0; bottom: 0; background: #111; padding: 1.5rem 1rem; border-right: 1px solid #222; display: flex; flex-direction: column; }
        \\    .nav-brand { display: flex; align-items: center; gap: 0.6rem; margin-bottom: 2rem; }
        \\    .nav-brand svg { width: 28px; height: 28px; }
        \\    .nav-brand span { font-size: 1.1rem; font-weight: 700; color: #a78bfa; letter-spacing: 0.04em; }
        \\    .nav-label { font-size: 0.7rem; text-transform: uppercase; color: #555; letter-spacing: 0.1em; margin: 1rem 0 0.5rem 0.5rem; }
        \\    nav button { display: flex; align-items: center; gap: 0.6rem; width: 100%; padding: 0.55rem 0.75rem; margin-bottom: 2px; background: none; border: none; color: #777; text-align: left; cursor: pointer; border-radius: 8px; font-size: 0.85rem; transition: all 0.15s; }
        \\    nav button:hover { background: #1a1a1a; color: #ccc; }
        \\    nav button.active { background: #7c3aed18; color: #a78bfa; }
        \\    .dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }
        \\    .nav-footer { margin-top: auto; padding-top: 1rem; border-top: 1px solid #222; font-size: 0.7rem; color: #444; text-align: center; }
        \\    main { margin-left: 240px; min-height: 100vh; }
        \\    .section { display: none; min-height: 100vh; }
        \\    .section.active { display: block; }
        \\    .welcome { display: flex; align-items: center; justify-content: center; min-height: 100vh; text-align: center; }
        \\    .welcome h1 { font-size: 2.5rem; font-weight: 300; color: #fff; margin-bottom: 0.5rem; }
        \\    .welcome h1 strong { font-weight: 700; color: #a78bfa; }
        \\    .welcome p { color: #666; font-size: 1rem; margin-bottom: 2rem; }
        \\    .app-grid { display: flex; gap: 1rem; flex-wrap: wrap; justify-content: center; margin-top: 1.5rem; }
        \\    .app-card { background: #151515; border: 1px solid #252525; border-radius: 12px; padding: 1.2rem 1.5rem; min-width: 140px; cursor: pointer; transition: all 0.2s; }
        \\    .app-card:hover { border-color: #7c3aed55; transform: translateY(-2px); }
        \\    .app-card .card-name { font-weight: 600; color: #e0e0e0; margin-bottom: 0.3rem; }
        \\    .app-card .card-fw { font-size: 0.75rem; }
        \\  </style>
        \\</head>
        \\<body>
        \\  <nav id="wu-nav">
        \\    <div class="nav-brand">
        \\      <svg viewBox="0 0 100 100"><defs><linearGradient id="wuG" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="#c084fc"/><stop offset="100%" stop-color="#6366f1"/></linearGradient></defs><rect width="100" height="100" rx="22" fill="url(#wuG)"/><polyline points="18,30 33,72 50,32 67,72 82,30" fill="none" stroke="#fff" stroke-width="8" stroke-linecap="round" stroke-linejoin="round"/><circle cx="78" cy="74" r="4.5" fill="#2dd4bf"/></svg>
        \\      <span>WU</span>
        \\    </div>
        \\    <button data-section="welcome" class="active"><div class="dot" style="background:#a78bfa"></div> Home</button>
        \\    <div class="nav-label">Micro-apps</div>
        \\    <div id="wu-nav-apps"></div>
        \\    <div class="nav-footer">wu dev</div>
        \\  </nav>
        \\  <main id="wu-main">
        \\    <div id="section-welcome" class="section active">
        \\      <div class="welcome">
        \\        <div>
        \\          <svg viewBox="0 0 100 100" style="width:80px;height:80px;margin-bottom:1.5rem"><defs><linearGradient id="wuGL" x1="0" y1="0" x2="1" y2="1"><stop offset="0%" stop-color="#c084fc"/><stop offset="100%" stop-color="#6366f1"/></linearGradient></defs><rect width="100" height="100" rx="22" fill="url(#wuGL)"/><polyline points="18,30 33,72 50,32 67,72 82,30" fill="none" stroke="#fff" stroke-width="8" stroke-linecap="round" stroke-linejoin="round"/><circle cx="78" cy="74" r="4.5" fill="#2dd4bf"/></svg>
        \\          <h1>Welcome to <strong>WU</strong></h1>
        \\          <p id="wu-app-count"></p>
        \\          <div class="app-grid" id="wu-app-grid"></div>
        \\        </div>
        \\      </div>
        \\    </div>
        \\  </main>
        \\  <script type="module" src="/shell/main.js"></script>
        \\</body>
        \\</html>
        \\
    );

    // ── main.js — dynamic shell logic ───────────────────────────────────
    const js_path = try std.fmt.bufPrint(&p, "{s}/shell/main.js", .{project});
    try writeFile(js_path,
        \\import _wuPkg from 'wu-framework';
        \\const wu = _wuPkg.default || _wuPkg;
        \\if (typeof window !== 'undefined') window.wu = wu;
        \\
        \\// App list injected by dev server into HTML as window.__wu_apps
        \\const apps = window.__wu_apps || [];
        \\const appEntries = {};
        \\const mounted = new Set();
        \\
        \\// Initialize wu-framework with full mount pipeline (Shadow DOM, sandboxing, lifecycle)
        \\const baseUrl = location.origin;
        \\const initPromise = wu.init({
        \\  apps: apps.map(a => ({ name: a.name, url: baseUrl + '/' + a.dir }))
        \\}).then(() => {
        \\  console.log('%c[wu] Framework initialized — full mount pipeline active', 'color: #a78bfa; font-weight: bold');
        \\}).catch(err => {
        \\  console.warn('[wu] init failed, falling back to direct mount', err);
        \\});
        \\
        \\async function switchSection(name) {
        \\  document.querySelectorAll('.section').forEach(s => s.classList.remove('active'));
        \\  document.querySelectorAll('nav button').forEach(b => b.classList.remove('active'));
        \\  const el = document.getElementById('section-' + name);
        \\  const btn = document.querySelector('button[data-section="' + name + '"]');
        \\  if (el) el.classList.add('active');
        \\  if (btn) btn.classList.add('active');
        \\
        \\  if (name !== 'welcome' && !mounted.has(name)) {
        \\    mounted.add(name);
        \\    const entry = appEntries[name];
        \\    if (entry) await import(entry);
        \\    await initPromise;
        \\    const selector = '#wu-app-' + name;
        \\    try {
        \\      await wu.mount(name, selector);
        \\      console.log('%c[wu] ' + name + ' mounted via full pipeline', 'color: #a78bfa');
        \\    } catch (err) {
        \\      console.warn('[wu] wu.mount() failed for ' + name + ', falling back to direct mount', err);
        \\      const container = document.querySelector(selector);
        \\      const def = wu.definitions && wu.definitions.get(name);
        \\      if (def && container) def.mount(container);
        \\    }
        \\  }
        \\}
        \\window.switchSection = switchSection;
        \\
        \\const navContainer = document.getElementById('wu-nav-apps');
        \\const grid = document.getElementById('wu-app-grid');
        \\const main = document.getElementById('wu-main');
        \\
        \\apps.forEach(app => {
        \\  appEntries[app.name] = '/' + app.dir + '/src/main.' + app.ext;
        \\
        \\  const btn = document.createElement('button');
        \\  btn.dataset.section = app.name;
        \\  btn.innerHTML = '<div class="dot" style="background:' + app.color + '"></div> ' + app.name;
        \\  btn.addEventListener('click', () => switchSection(app.name));
        \\  navContainer.appendChild(btn);
        \\
        \\  const card = document.createElement('div');
        \\  card.className = 'app-card';
        \\  card.dataset.section = app.name;
        \\  card.innerHTML = '<div class="card-name">' + app.name + '</div><div class="card-fw" style="color:' + app.color + '">' + app.framework + '</div>';
        \\  card.addEventListener('click', () => switchSection(app.name));
        \\  grid.appendChild(card);
        \\
        \\  const sec = document.createElement('div');
        \\  sec.id = 'section-' + app.name;
        \\  sec.className = 'section';
        \\  sec.innerHTML = '<div id="wu-app-' + app.name + '" data-wu-app="' + app.name + '"></div>';
        \\  main.appendChild(sec);
        \\});
        \\
        \\document.getElementById('wu-app-count').textContent = apps.length + ' micro-app(s) running on one port';
        \\window.__wu_entries = appEntries;
        \\
        \\document.querySelector('button[data-section="welcome"]').addEventListener('click', () => switchSection('welcome'));
        \\
        \\console.log('%c[wu] Shell ready — ' + apps.length + ' apps loaded dynamically', 'color: #a78bfa; font-weight: bold');
        \\
    );
}

fn fwColor(framework: []const u8) []const u8 {
    const eql = std.mem.eql;
    if (eql(u8, framework, "react")) return "#61dafb";
    if (eql(u8, framework, "vue")) return "#42b883";
    if (eql(u8, framework, "svelte")) return "#ff3e00";
    if (eql(u8, framework, "solid")) return "#4f88c6";
    if (eql(u8, framework, "preact")) return "#673ab8";
    if (eql(u8, framework, "lit")) return "#325ccc";
    if (eql(u8, framework, "vanilla")) return "#f7df1e";
    if (eql(u8, framework, "angular")) return "#dd0031";
    if (eql(u8, framework, "alpine")) return "#77c1d2";
    if (eql(u8, framework, "qwik")) return "#ac7ef4";
    if (eql(u8, framework, "stencil")) return "#4c48ff";
    if (eql(u8, framework, "htmx")) return "#3366cc";
    if (eql(u8, framework, "stimulus")) return "#77e8b9";
    return "#888";
}

// ── App Generation ──────────────────────────────────────────────────────────

pub fn generateApp(allocator: Allocator, project: []const u8, app: *MicroApp) !void {
    var p: [512]u8 = undefined;
    var dir_buf: [256]u8 = undefined;
    const dir = app.dirName(&dir_buf);

    // Create directories (ignore if already exists)
    const app_dir = try std.fmt.bufPrint(&p, "{s}/{s}", .{ project, dir });
    std.fs.cwd().makeDir(app_dir) catch |err| if (err != error.PathAlreadyExists) return err;

    const src_dir = try std.fmt.bufPrint(&p, "{s}/{s}/src", .{ project, dir });
    std.fs.cwd().makeDir(src_dir) catch |err| if (err != error.PathAlreadyExists) return err;

    // package.json — each app is self-contained (can be ejected or run standalone)
    try generateAppPackageJson(allocator, project, dir, app);

    // vite.config.js
    try generateViteConfig(allocator, project, dir, app.framework);

    // index.html
    var html: std.ArrayList(u8) = .empty;
    defer html.deinit(allocator);
    try html.writer(allocator).print(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head><meta charset="UTF-8" /><title>{s}</title></head>
        \\<body><div id="app"></div><script type="module" src="/src/main.{s}"></script></body>
        \\</html>
        \\
    , .{ app.name(), mainExt(app.framework) });
    const html_path = try std.fmt.bufPrint(&p, "{s}/{s}/index.html", .{ project, dir });
    try writeFile(html_path, html.items);

    // src/App.{ext} — framework component
    try generateAppComponent(allocator, project, dir, app);

    // src/main.{ext} — adapter registration
    try generateMainFile(allocator, project, dir, app);
}

fn mainExt(framework: []const u8) []const u8 {
    const eql = std.mem.eql;
    if (eql(u8, framework, "react") or eql(u8, framework, "solid") or eql(u8, framework, "preact") or eql(u8, framework, "qwik")) return "jsx";
    if (eql(u8, framework, "angular")) return "ts";
    return "js";
}

fn appExt(framework: []const u8) []const u8 {
    const eql = std.mem.eql;
    if (eql(u8, framework, "react") or eql(u8, framework, "solid") or eql(u8, framework, "preact") or eql(u8, framework, "qwik")) return ".jsx";
    if (eql(u8, framework, "svelte")) return ".svelte";
    if (eql(u8, framework, "vue")) return ".vue";
    if (eql(u8, framework, "angular")) return ".ts";
    return ".js";
}

fn generateAppPackageJson(allocator: Allocator, project: []const u8, dir: []const u8, app: *MicroApp) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    const eql = std.mem.eql;

    try w.print(
        \\{{
        \\  "name": "wu-{s}",
        \\  "private": true,
        \\  "type": "module",
        \\  "scripts": {{
        \\    "dev": "vite --port {d}",
        \\    "build": "vite build"
        \\  }},
        \\  "dependencies": {{
        \\    "wu-framework": "^1.1.17"
    , .{ app.name(), app.port });

    if (eql(u8, app.framework, "react")) {
        try w.writeAll(",\n    \"react\": \"^19.0.0\",\n    \"react-dom\": \"^19.0.0\"");
    } else if (eql(u8, app.framework, "vue")) {
        try w.writeAll(",\n    \"vue\": \"^3.5.0\"");
    } else if (eql(u8, app.framework, "svelte")) {
        try w.writeAll(",\n    \"svelte\": \"^5.0.0\"");
    } else if (eql(u8, app.framework, "solid")) {
        try w.writeAll(",\n    \"solid-js\": \"^1.9.0\"");
    } else if (eql(u8, app.framework, "preact")) {
        try w.writeAll(",\n    \"preact\": \"^10.25.0\"");
    } else if (eql(u8, app.framework, "lit")) {
        try w.writeAll(",\n    \"lit\": \"^3.2.0\"");
    } else if (eql(u8, app.framework, "angular")) {
        try w.writeAll(",\n    \"@angular/core\": \"^19.0.0\",\n    \"@angular/common\": \"^19.0.0\",\n    \"@angular/compiler\": \"^19.0.0\",\n    \"@angular/platform-browser\": \"^19.0.0\",\n    \"@angular/platform-browser-dynamic\": \"^19.0.0\",\n    \"rxjs\": \"^7.8.0\",\n    \"zone.js\": \"^0.15.0\"");
    } else if (eql(u8, app.framework, "alpine")) {
        try w.writeAll(",\n    \"alpinejs\": \"^3.14.0\"");
    } else if (eql(u8, app.framework, "qwik")) {
        try w.writeAll(",\n    \"@builder.io/qwik\": \"^1.12.0\"");
    } else if (eql(u8, app.framework, "htmx")) {
        try w.writeAll(",\n    \"htmx.org\": \"^2.0.0\"");
    } else if (eql(u8, app.framework, "stimulus")) {
        try w.writeAll(",\n    \"@hotwired/stimulus\": \"^3.2.0\"");
    }
    // stencil: no runtime deps (compiles to vanilla Web Components)

    try w.writeAll("\n  },\n  \"devDependencies\": {\n    \"vite\": \"^6.0.0\"");

    // Vite plugins + wu dev compiler deps
    if (eql(u8, app.framework, "react")) {
        try w.writeAll(",\n    \"@vitejs/plugin-react\": \"^4.3.0\"");
    } else if (eql(u8, app.framework, "vue")) {
        try w.writeAll(",\n    \"@vitejs/plugin-vue\": \"^5.2.0\"");
    } else if (eql(u8, app.framework, "svelte")) {
        try w.writeAll(",\n    \"@sveltejs/vite-plugin-svelte\": \"^5.0.0\"");
    } else if (eql(u8, app.framework, "solid")) {
        try w.writeAll(",\n    \"vite-plugin-solid\": \"^2.11.0\",\n    \"babel-preset-solid\": \"^1.9.0\",\n    \"@babel/core\": \"^7.26.0\"");
    } else if (eql(u8, app.framework, "angular")) {
        try w.writeAll(",\n    \"@angular/compiler-cli\": \"^19.0.0\",\n    \"@analogjs/vite-plugin-angular\": \"^1.14.0\",\n    \"typescript\": \"^5.7.0\"");
    } else if (eql(u8, app.framework, "stencil")) {
        try w.writeAll(",\n    \"@stencil/core\": \"^4.22.0\"");
    }

    try w.writeAll("\n  }\n}\n");

    var p: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&p, "{s}/{s}/package.json", .{ project, dir });
    try writeFile(path, buf.items);
}

fn generateViteConfig(allocator: Allocator, project: []const u8, dir: []const u8, framework: []const u8) !void {
    var p: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&p, "{s}/{s}/vite.config.js", .{ project, dir });
    const eql = std.mem.eql;

    if (eql(u8, framework, "react")) {
        try writeFile(path,
            \\import { defineConfig } from 'vite';
            \\import react from '@vitejs/plugin-react';
            \\export default defineConfig({ plugins: [react()] });
            \\
        );
    } else if (eql(u8, framework, "vue")) {
        try writeFile(path,
            \\import { defineConfig } from 'vite';
            \\import vue from '@vitejs/plugin-vue';
            \\export default defineConfig({ plugins: [vue()] });
            \\
        );
    } else if (eql(u8, framework, "svelte")) {
        try writeFile(path,
            \\import { defineConfig } from 'vite';
            \\import { svelte } from '@sveltejs/vite-plugin-svelte';
            \\export default defineConfig({ plugins: [svelte()] });
            \\
        );
    } else if (eql(u8, framework, "angular")) {
        try writeFile(path,
            \\import { defineConfig } from 'vite';
            \\import angular from '@analogjs/vite-plugin-angular';
            \\export default defineConfig({ plugins: [angular()] });
            \\
        );
    } else {
        try writeFile(path,
            \\import { defineConfig } from 'vite';
            \\export default defineConfig({});
            \\
        );
    }
    _ = allocator;
}

fn generateAppComponent(allocator: Allocator, project: []const u8, dir: []const u8, app: *MicroApp) !void {
    var p: [512]u8 = undefined;
    const ext = appExt(app.framework);
    const eql = std.mem.eql;

    // Select template via @embedFile (compile-time embedded, zero runtime I/O)
    const template = if (eql(u8, app.framework, "react"))
        @embedFile("templates/react.jsx")
    else if (eql(u8, app.framework, "preact"))
        @embedFile("templates/preact.jsx")
    else if (eql(u8, app.framework, "vue"))
        @embedFile("templates/vue.vue")
    else if (eql(u8, app.framework, "svelte"))
        @embedFile("templates/svelte.svelte")
    else if (eql(u8, app.framework, "solid"))
        @embedFile("templates/solid.jsx")
    else if (eql(u8, app.framework, "lit"))
        @embedFile("templates/lit.js")
    else if (eql(u8, app.framework, "angular"))
        @embedFile("templates/angular.ts")
    else if (eql(u8, app.framework, "alpine"))
        @embedFile("templates/alpine.js")
    else if (eql(u8, app.framework, "qwik"))
        @embedFile("templates/qwik.jsx")
    else if (eql(u8, app.framework, "stencil"))
        @embedFile("templates/stencil.js")
    else if (eql(u8, app.framework, "htmx"))
        @embedFile("templates/htmx.js")
    else if (eql(u8, app.framework, "stimulus"))
        @embedFile("templates/stimulus.js")
    else
        @embedFile("templates/vanilla.js");

    // Replace __APP_NAME__ placeholder with the actual app name
    const content = try templateReplace(allocator, template, "__APP_NAME__", app.name());
    defer allocator.free(content);

    const comp_path = try std.fmt.bufPrint(&p, "{s}/{s}/src/App{s}", .{ project, dir, ext });
    try writeFile(comp_path, content);
}

/// Replace all occurrences of `needle` with `replacement` in `haystack`.
/// Returns an allocator-owned slice.
fn templateReplace(allocator: Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    // Count occurrences
    var count: usize = 0;
    var search_pos: usize = 0;
    while (search_pos <= haystack.len - needle.len) {
        if (std.mem.eql(u8, haystack[search_pos .. search_pos + needle.len], needle)) {
            count += 1;
            search_pos += needle.len;
        } else {
            search_pos += 1;
        }
    }
    if (count == 0) return allocator.dupe(u8, haystack);

    // Allocate result
    const new_len = haystack.len - (count * needle.len) + (count * replacement.len);
    const result = try allocator.alloc(u8, new_len);
    var out_pos: usize = 0;
    var in_pos: usize = 0;

    while (in_pos <= haystack.len - needle.len) {
        if (std.mem.eql(u8, haystack[in_pos .. in_pos + needle.len], needle)) {
            @memcpy(result[out_pos .. out_pos + replacement.len], replacement);
            out_pos += replacement.len;
            in_pos += needle.len;
        } else {
            result[out_pos] = haystack[in_pos];
            out_pos += 1;
            in_pos += 1;
        }
    }
    // Copy remaining bytes
    const remaining = haystack[in_pos..];
    @memcpy(result[out_pos .. out_pos + remaining.len], remaining);

    return result;
}

fn generateMainFile(allocator: Allocator, project: []const u8, dir: []const u8, app: *MicroApp) !void {
    var p: [512]u8 = undefined;
    const eql = std.mem.eql;
    const ext = mainExt(app.framework);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    if (eql(u8, app.framework, "react")) {
        try w.print(
            \\import {{ wuReact }} from 'wu-framework/adapters/react';
            \\import App from './App.jsx';
            \\
            \\await wuReact.register('{s}', App);
            \\
        , .{app.name()});
    } else if (eql(u8, app.framework, "vue")) {
        try w.print(
            \\import {{ wuVue }} from 'wu-framework/adapters/vue';
            \\import App from './App.vue';
            \\
            \\await wuVue.register('{s}', App);
            \\
        , .{app.name()});
    } else if (eql(u8, app.framework, "svelte")) {
        try w.print(
            \\import {{ wuSvelte }} from 'wu-framework/adapters/svelte';
            \\import App from './App.svelte';
            \\
            \\await wuSvelte.registerSvelte5('{s}', App);
            \\
        , .{app.name()});
    } else if (eql(u8, app.framework, "solid")) {
        try w.print(
            \\import {{ wuSolid }} from 'wu-framework/adapters/solid';
            \\import App from './App.jsx';
            \\
            \\await wuSolid.register('{s}', App);
            \\
        , .{app.name()});
    } else if (eql(u8, app.framework, "preact")) {
        try w.print(
            \\import {{ wuPreact }} from 'wu-framework/adapters/preact';
            \\import App from './App.jsx';
            \\
            \\await wuPreact.register('{s}', App);
            \\
        , .{app.name()});
    } else if (eql(u8, app.framework, "lit")) {
        try w.print(
            \\import {{ wuLit }} from 'wu-framework/adapters/lit';
            \\import App from './App.js';
            \\
            \\await wuLit.register('{s}', App);
            \\
        , .{app.name()});
    } else if (eql(u8, app.framework, "angular")) {
        try w.print(
            \\import 'zone.js';
            \\import '@angular/compiler';
            \\import {{ createApplication }} from '@angular/platform-browser';
            \\import {{ createComponent, provideZoneChangeDetection }} from '@angular/core';
            \\import {{ wuAngular }} from 'wu-framework/adapters/angular';
            \\import {{ AppComponent }} from './App.ts';
            \\
            \\wuAngular.registerStandalone('{s}', AppComponent, {{
            \\  createApplication,
            \\  createComponent,
            \\  provideZoneChangeDetection,
            \\}});
            \\
        , .{app.name()});
    } else if (eql(u8, app.framework, "alpine")) {
        try w.print(
            \\import {{ wuAlpine }} from 'wu-framework/adapters/alpine';
            \\import App from './App.js';
            \\
            \\await wuAlpine.register('{s}', App);
            \\
        , .{app.name()});
    } else if (eql(u8, app.framework, "qwik")) {
        try w.print(
            \\import {{ wuQwik }} from 'wu-framework/adapters/qwik';
            \\import App from './App.jsx';
            \\
            \\await wuQwik.register('{s}', App);
            \\
        , .{app.name()});
    } else if (eql(u8, app.framework, "stencil")) {
        try w.print(
            \\import {{ wuStencil }} from 'wu-framework/adapters/stencil';
            \\import './App.js';
            \\
            \\await wuStencil.register('{s}', 'wu-stencil-app');
            \\
        , .{app.name()});
    } else if (eql(u8, app.framework, "htmx")) {
        try w.print(
            \\import {{ wuHtmx }} from 'wu-framework/adapters/htmx';
            \\import App from './App.js';
            \\
            \\await wuHtmx.register('{s}', App);
            \\
        , .{app.name()});
    } else if (eql(u8, app.framework, "stimulus")) {
        try w.print(
            \\import {{ wuStimulus }} from 'wu-framework/adapters/stimulus';
            \\import App from './App.js';
            \\
            \\await wuStimulus.register('{s}', App);
            \\
        , .{app.name()});
    } else {
        // vanilla
        try w.print(
            \\import {{ wuVanilla }} from 'wu-framework/adapters/vanilla';
            \\import App from './App.js';
            \\
            \\await wuVanilla.register('{s}', {{
            \\  render(container) {{ App(container); }}
            \\}});
            \\
        , .{app.name()});
    }

    const main_path = try std.fmt.bufPrint(&p, "{s}/{s}/src/main.{s}", .{ project, dir, ext });
    try writeFile(main_path, buf.items);
}

// ── Config & Package.json ───────────────────────────────────────────────────

fn generateConfig(allocator: Allocator, project: []const u8, apps: []MicroApp) !void {
    // Build a proper WuConfig struct and use writeConfigTo for consistent output.
    // All strings here point into stack buffers or comptime literals that outlive
    // the writeConfigTo call, so no dupe needed.
    var app_configs_buf: [16]config_mod.AppConfig = undefined;
    var dir_bufs: [16][256]u8 = undefined;

    for (apps, 0..) |*app, i| {
        if (i >= 16) break;
        const dir = app.dirName(&dir_bufs[i]);
        app_configs_buf[i] = .{
            .name = app.name(),
            .dir = dir,
            .framework = app.framework,
            .port = app.port,
        };
    }

    const count = @min(apps.len, 16);
    const cfg = config_mod.WuConfig{
        .name = project,
        .version = "0.1.0",
        .shell = .{
            .dir = "shell",
            .port = 4321,
            .framework = "html",
        },
        .apps = app_configs_buf[0..count],
        .proxy = .{
            .port = 3000,
            .open_browser = true,
        },
        .from_file = true,
    };

    try config_mod.writeConfigTo(allocator, &cfg, project);
}

pub fn generateRootPackageJson(allocator: Allocator, project_dir: []const u8, apps: []MicroApp) !void {
    try generateRootPackageJsonNamed(allocator, project_dir, project_dir, apps);
}

pub fn generateRootPackageJsonNamed(allocator: Allocator, project_dir: []const u8, project_name: []const u8, apps: []MicroApp) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    const eql = std.mem.eql;

    // ── Auto-generated root package.json ─────────────────────────────
    //
    // Each app keeps its own package.json (identity, ejection, debug).
    // This root file MERGES all app deps so npm installs once into one
    // shared node_modules/. resolve.zig and Node's require() both walk
    // up from app dirs to find packages here.
    //
    // Apps declare → wu merges → npm installs → wu resolves.

    try w.writeAll("{\n");
    try w.print("  \"_wu\": \"auto-generated from app package.json files\",\n", .{});
    try w.print("  \"name\": \"{s}\",\n", .{project_name});
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
    var has_angular = false;
    var has_alpine = false;
    var has_qwik = false;
    var has_htmx = false;
    var has_stimulus = false;

    for (apps) |*app| {
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
        } else if (eql(u8, app.framework, "angular") and !has_angular) {
            try w.writeAll(",\n    \"@angular/core\": \"^19.0.0\",\n    \"@angular/common\": \"^19.0.0\",\n    \"@angular/compiler\": \"^19.0.0\",\n    \"@angular/platform-browser\": \"^19.0.0\",\n    \"@angular/platform-browser-dynamic\": \"^19.0.0\",\n    \"rxjs\": \"^7.8.0\",\n    \"zone.js\": \"^0.15.0\"");
            has_angular = true;
        } else if (eql(u8, app.framework, "alpine") and !has_alpine) {
            try w.writeAll(",\n    \"alpinejs\": \"^3.14.0\"");
            has_alpine = true;
        } else if (eql(u8, app.framework, "qwik") and !has_qwik) {
            try w.writeAll(",\n    \"@builder.io/qwik\": \"^1.12.0\"");
            has_qwik = true;
        } else if (eql(u8, app.framework, "htmx") and !has_htmx) {
            try w.writeAll(",\n    \"htmx.org\": \"^2.0.0\"");
            has_htmx = true;
        } else if (eql(u8, app.framework, "stimulus") and !has_stimulus) {
            try w.writeAll(",\n    \"@hotwired/stimulus\": \"^3.2.0\"");
            has_stimulus = true;
        }
        // stencil: no runtime deps
    }
    try w.writeAll("\n  },\n");

    // ── Merged devDependencies (toolchain + plugins) ─────────────────
    try w.writeAll("  \"devDependencies\": {\n    \"esbuild\": \"^0.25.0\",\n    \"vite\": \"^6.0.0\"");

    var has_react_p = false;
    var has_vue_p = false;
    var has_svelte_p = false;
    var has_solid_p = false;
    var has_angular_p = false;
    var has_stencil_p = false;

    for (apps) |*app| {
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
        } else if (eql(u8, app.framework, "angular") and !has_angular_p) {
            try w.writeAll(",\n    \"@angular/compiler-cli\": \"^19.0.0\"");
            try w.writeAll(",\n    \"@analogjs/vite-plugin-angular\": \"^1.14.0\"");
            try w.writeAll(",\n    \"typescript\": \"^5.7.0\"");
            has_angular_p = true;
        } else if (eql(u8, app.framework, "stencil") and !has_stencil_p) {
            try w.writeAll(",\n    \"@stencil/core\": \"^4.22.0\"");
            has_stencil_p = true;
        }
    }

    try w.writeAll("\n  }\n}\n");

    var p: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&p, "{s}/package.json", .{project_dir});
    try writeFile(path, buf.items);
}

// ── Dependency Installation ─────────────────────────────────────────────────

fn installDeps(allocator: Allocator, project: []const u8, apps: []MicroApp) !void {
    _ = apps;
    // One install at root using the merged package.json.
    // resolve.zig searches "." (root node_modules/) for all apps.
    // Node's require() walks up from app dirs to root automatically.
    runNpmInstall(allocator, project, project);
}

pub fn runNpmInstall(allocator: Allocator, cwd: []const u8, label: []const u8) void {
    const argv = [_][]const u8{ "npm", "install", "--silent" };
    var child = std.process.Child.init(&argv, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Pipe;

    child.spawn() catch {
        std.debug.print("    {s}x{s} {s}  (npm not found)\n", .{ ansi.red, ansi.reset, label });
        return;
    };

    // Read stderr for error messages
    const stderr_out = if (child.stderr) |se|
        se.readToEndAlloc(allocator, 64 * 1024) catch null
    else
        null;
    defer if (stderr_out) |s| allocator.free(s);

    const term = child.wait() catch {
        std.debug.print("    {s}x{s} {s}  (install failed)\n", .{ ansi.red, ansi.reset, label });
        return;
    };

    if (term.Exited == 0) {
        std.debug.print("    {s}+{s} {s}\n", .{ ansi.green, ansi.reset, label });
    } else {
        std.debug.print("    {s}x{s} {s}  (exit {d})\n", .{ ansi.red, ansi.reset, label, term.Exited });
    }
}

// ── Quick mode (backwards compat) ───────────────────────────────────────────

fn quickCreate(allocator: Allocator, name: []const u8, template: []const u8) !void {
    if (std.fs.cwd().openDir(name, .{})) |_| {
        std.debug.print("  {s}Directory '{s}' already exists.{s}\n", .{ ansi.red, name, ansi.reset });
        return;
    } else |_| {}

    try std.fs.cwd().makeDir(name);

    // Single-framework quick create
    var app = MicroApp{
        .framework = template,
        .port = 3000,
    };
    const copy_len = @min(name.len, 64);
    @memcpy(app.name_buf[0..copy_len], name[0..copy_len]);
    app.name_len = copy_len;

    var apps = [_]MicroApp{app};
    try generateShell(allocator, name, &apps);
    try generateApp(allocator, name, &app);
    try generateConfig(allocator, name, &apps);
    try generateRootPackageJson(allocator, name, &apps);

    std.debug.print("\n  {s}+ Created {s}{s}\n\n", .{ ansi.green, name, ansi.reset });
    std.debug.print("    cd {s}\n    npm install\n    wu dev\n\n", .{name});
}

// ── File Writer ─────────────────────────────────────────────────────────────

/// Read a line from stdin (blocking, byte-by-byte). Returns trimmed slice or null on EOF/error.
fn readLine(f: *const std.fs.File, buf: []u8) ?[]const u8 {
    var i: usize = 0;
    while (i < buf.len) {
        var byte: [1]u8 = undefined;
        const n = f.read(&byte) catch return null;
        if (n == 0) {
            // EOF
            if (i == 0) return null;
            break;
        }
        if (byte[0] == '\n') break;
        if (byte[0] != '\r') {
            buf[i] = byte[0];
            i += 1;
        }
    }
    return std.mem.trim(u8, buf[0..i], &[_]u8{ ' ', '\t' });
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}
