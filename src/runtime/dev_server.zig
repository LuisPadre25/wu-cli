// WU Runtime — Native Dev Server
//
// A Zig-native HTTP dev server that replaces N Vite processes with ONE.
// Single port, path-based routing, on-demand transforms, WebSocket + SSE HMR.
//
// Architecture:
//   HTTP Listener → Thread-per-connection (keep-alive) → SIMD Parse → Route → Transform → Respond
//   File Watcher → Atomic reload counter → WS/SSE push to connected browsers
//
// Integrations from: FORJA (HTTP server), STORM (JSX transform), ZigStorm (SIMD parser, WebSocket).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const mime_mod = @import("mime.zig");
const transform = @import("transform.zig");
const resolve_mod = @import("resolve.zig");
const compile_mod = @import("compile.zig");
const cache_mod = @import("cache.zig");
const http_parser = @import("http_parser.zig");
const ws_proto = @import("ws_protocol.zig");
const ansi = @import("../util/ansi.zig");
const signals = @import("../util/signals.zig");
const config_mod = @import("../config/config.zig");

// ── Configuration ───────────────────────────────────────────────────────────

pub const AppEntry = struct {
    name: []const u8,
    dir: []const u8,
    framework: []const u8,
    port: u16 = 0, // Original port (for display only)
};

pub const Config = struct {
    port: u16 = 3000,
    host: []const u8 = "127.0.0.1",
    shell_dir: []const u8 = "",
    shell_framework: []const u8 = "astro",
    apps: []const AppEntry = &.{},
};

// ── Server ──────────────────────────────────────────────────────────────────

var g_server: ?*DevServer = null;

pub const DevServer = struct {
    config: Config,
    allocator: Allocator,
    running: std.atomic.Value(bool),
    reload_counter: std.atomic.Value(u64),
    compile_cache: cache_mod.CompileCache,

    // HMR: pre-formatted SSE event for the last detected change
    hmr_mutex: std.Thread.Mutex,
    hmr_event_buf: [512]u8,
    hmr_event_len: usize,

    // Hot-reload: live app list (updated when wu.config.json changes)
    apps_mutex: std.Thread.Mutex,
    live_apps: []const AppEntry,
    _hot_cfgs: std.ArrayList(config_mod.WuConfig), // keeps old config memory alive
    _hot_app_bufs: std.ArrayList([]AppEntry), // keeps old app entry slices alive

    pub fn init(allocator: Allocator, config: Config) DevServer {
        return .{
            .config = config,
            .allocator = allocator,
            .running = std.atomic.Value(bool).init(false),
            .reload_counter = std.atomic.Value(u64).init(0),
            .compile_cache = cache_mod.CompileCache.init(allocator),
            .hmr_mutex = .{},
            .hmr_event_buf = undefined,
            .hmr_event_len = 0,
            .apps_mutex = .{},
            .live_apps = config.apps,
            ._hot_cfgs = .empty,
            ._hot_app_bufs = .empty,
        };
    }

    /// Get current live app list (thread-safe)
    fn getApps(self: *DevServer) []const AppEntry {
        self.apps_mutex.lock();
        defer self.apps_mutex.unlock();
        return self.live_apps;
    }

    /// Reload app list from wu.config.json (called by watcher thread)
    fn reloadApps(self: *DevServer) void {
        var cfg = config_mod.loadConfig(self.allocator);
        if (!cfg.from_file) {
            cfg.deinit(self.allocator);
            std.debug.print("  {s}[config]{s} could not parse wu.config.json — skipping reload\n", .{
                ansi.dim, ansi.reset,
            });
            return;
        }

        // Build new AppEntry list (filter missing dirs + dedup)
        var new_apps: std.ArrayList(AppEntry) = .empty;
        for (cfg.apps) |app| {
            std.fs.cwd().access(app.dir, .{}) catch continue;
            var dup = false;
            for (new_apps.items) |existing| {
                if (std.mem.eql(u8, existing.dir, app.dir)) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            new_apps.append(self.allocator, .{
                .name = app.name,
                .dir = app.dir,
                .framework = app.framework,
                .port = app.port,
            }) catch continue;
        }

        const new_slice = new_apps.toOwnedSlice(self.allocator) catch return;

        // Swap under lock — keep old memory alive (strings point into old cfgs)
        self.apps_mutex.lock();
        self.live_apps = new_slice;
        self.apps_mutex.unlock();

        // Store cfg and app buf to keep memory alive until shutdown
        self._hot_cfgs.append(self.allocator, cfg) catch {
            cfg.deinit(self.allocator);
        };
        self._hot_app_bufs.append(self.allocator, new_slice) catch {};

        std.debug.print("  {s}[config]{s} reloaded — {d} app(s) active\n", .{
            ansi.green, ansi.reset, new_slice.len,
        });
    }

    /// Start the dev server. Blocks until shutdown.
    pub fn run(self: *DevServer) !void {
        const address = try std.net.Address.parseIp4(self.config.host, self.config.port);
        var listener = try address.listen(.{
            .reuse_address = true,
        });
        defer listener.deinit();

        self.running.store(true, .release);

        // Install Ctrl+C handler
        g_server = self;
        signals.install(shutdownSignal);

        // Start file watcher in background
        const watcher = std.Thread.spawn(.{}, watcherThread, .{self}) catch null;
        _ = watcher;

        // Print startup banner
        self.printStartup();

        // Accept loop
        while (self.running.load(.acquire)) {
            const conn = listener.accept() catch {
                if (!self.running.load(.acquire)) break;
                continue;
            };

            const thread = std.Thread.spawn(.{}, connectionThread, .{ self, conn }) catch {
                conn.stream.close();
                continue;
            };
            thread.detach();
        }

        std.debug.print("\n  {s}Server stopped.{s}\n\n", .{ ansi.dim, ansi.reset });
    }

    pub fn shutdown(self: *DevServer) void {
        self.running.store(false, .release);
        self.compile_cache.deinit();
        compile_mod.shutdownDaemon();
    }

    fn printStartup(self: *DevServer) void {
        std.debug.print("\n", .{});
        std.debug.print("  {s}WU Dev Server{s}  {s}(native zig runtime){s}\n", .{
            ansi.bold, ansi.reset, ansi.dim, ansi.reset,
        });
        std.debug.print("  {s}>{s}  http://{s}:{d}/\n\n", .{
            ansi.green, ansi.reset, self.config.host, self.config.port,
        });

        if (self.config.shell_dir.len > 0) {
            const c = ansi.frameworkColor(self.config.shell_framework);
            std.debug.print("  {s}*{s} {s}shell{s}          {s}{s:<10}{s}  /{s}\n", .{
                c,         ansi.reset,
                ansi.bold, ansi.reset,
                ansi.dim,  self.config.shell_framework,
                ansi.reset, self.config.shell_dir,
            });
        }

        for (self.config.apps) |app| {
            const c = ansi.frameworkColor(app.framework);
            std.debug.print("  {s}*{s} {s}{s:<14}{s} {s}{s:<10}{s}  /{s}\n", .{
                c,         ansi.reset,
                ansi.bold, app.name,
                ansi.reset, ansi.dim,
                app.framework, ansi.reset,
                app.dir,
            });
        }

        const total = self.config.apps.len + @as(usize, if (self.config.shell_dir.len > 0) 1 else 0);
        std.debug.print("\n  {s}{d} micro-app(s) on one port  |  HMR enabled  |  Ctrl+C to stop{s}\n", .{
            ansi.dim, total, ansi.reset,
        });
        if (self.compile_cache.disk_ready) {
            std.debug.print("  {s}persistent cache: .wu-cache/{s}\n", .{ ansi.dim, ansi.reset });
        }
        std.debug.print("\n", .{});
    }

    // ── Connection handling ─────────────────────────────────────────────────

    fn connectionThread(self: *DevServer, conn: std.net.Server.Connection) void {
        defer conn.stream.close();

        // Keep-alive loop: reuse this TCP connection for multiple requests.
        // Browsers send 100+ module requests on page load — reusing connections
        // eliminates TCP handshake overhead for each one (~1ms per handshake saved).
        // For SSE/WS, the handler blocks until the client disconnects; the next
        // read then fails and breaks the loop naturally.
        while (self.running.load(.acquire)) {
            self.handleRequest(conn.stream) catch break;
        }
    }

    fn handleRequest(self: *DevServer, stream: std.net.Stream) !void {
        var recv_buf: [16384]u8 = undefined;
        const n = try platformRead(stream, &recv_buf);
        if (n == 0) return error.EndOfStream;

        const raw = recv_buf[0..n];

        // SIMD-accelerated HTTP parsing (from ZigStorm)
        const req = http_parser.HttpParser.parse(raw) catch {
            sendResponse(stream, 400, "text/plain", "Bad Request") catch {};
            return;
        };

        // CORS preflight
        if (req.method == .OPTIONS) {
            try sendResponse(stream, 204, "text/plain", "");
            return;
        }

        // Only handle GET
        if (req.method != .GET) {
            try sendResponse(stream, 405, "application/json", "{\"error\":\"method_not_allowed\"}");
            return;
        }

        // URL-decode %XX sequences
        var decoded_buf: [4096]u8 = undefined;
        const path = urlDecode(req.path, &decoded_buf);

        // WebSocket upgrade detection (for WS-based HMR)
        if (std.mem.eql(u8, path, "/__wu_ws")) {
            if (req.getHeader("Upgrade")) |upgrade| {
                if (std.ascii.eqlIgnoreCase(upgrade, "websocket")) {
                    if (req.getHeader("Sec-WebSocket-Key")) |ws_key| {
                        return self.handleWsHmr(stream, ws_key);
                    }
                }
            }
            // Not a valid WS upgrade — fall through to 404
        }

        // CSS module import: /path/style.css?import → serve CSS as JS module
        // (The ?import query is appended by transform.zig when it sees `import './style.css'`)
        if (req.query) |query| {
            if (std.mem.eql(u8, query, "import") and std.mem.endsWith(u8, path, ".css")) {
                return self.serveCssAsModule(stream, path);
            }
        }

        // Route
        self.routeRequest(stream, path) catch {
            sendResponse(stream, 500, "text/plain", "Internal Server Error") catch {};
        };
    }

    fn routeRequest(self: *DevServer, stream: std.net.Stream, path: []const u8) !void {
        // 1. HMR SSE endpoint (fallback for browsers without WS)
        if (std.mem.eql(u8, path, "/__wu_hmr")) {
            return self.handleHmr(stream);
        }

        // 2. Virtual module endpoint — pre-bundled node_modules
        if (std.mem.startsWith(u8, path, "/@modules/")) {
            return self.handleModuleRequest(stream, path[10..]);
        }

        // 3. WU client script (injected by HMR)
        if (std.mem.eql(u8, path, "/@wu/client.js")) {
            return sendResponse(stream, 200, "application/javascript; charset=utf-8", wu_hmr_client);
        }

        // 3b. Dynamic app list endpoint — shell reads this to build UI
        if (std.mem.eql(u8, path, "/@wu/apps.json")) {
            return self.serveAppsJson(stream);
        }

        // Normalize: strip leading slash (/ → "", /shell/main.js → "shell/main.js")
        const relative = if (path.len > 0 and path[0] == '/') path[1..] else path;

        // 3c. wu.json manifest requests — wu.init() fetches /<app>/wu.json
        //     1. Serve from disk if the file exists.
        //     2. Otherwise auto-generate a default manifest for registered apps
        //        so wu-framework gets a 200 (no console 404 noise).
        //     3. For unknown paths, return a clean 404 JSON.
        if (std.mem.endsWith(u8, relative, "/wu.json")) {
            const cwd = std.fs.cwd();
            // Try disk first
            if (cwd.openFile(relative, .{})) |file| {
                defer file.close();
                const contents = file.readToEndAlloc(self.allocator, 512 * 1024) catch {
                    return sendResponse(stream, 500, "application/json", "{\"error\":\"read_error\"}");
                };
                defer self.allocator.free(contents);
                return sendResponse(stream, 200, "application/json", contents);
            } else |_| {}
            // No file on disk — check if it matches a registered app and auto-generate
            const app_dir = relative[0 .. relative.len - "/wu.json".len];
            for (self.getApps()) |app| {
                if (std.mem.eql(u8, app_dir, app.dir)) {
                    var mbuf: [512]u8 = undefined;
                    const ext = fwMainExt(app.framework);
                    const manifest = std.fmt.bufPrint(&mbuf,
                        \\{{"name":"{s}","entry":"src/main.{s}","styleMode":"shared","wu":{{"exports":{{}},"imports":[],"routes":[],"permissions":[]}}}}
                    , .{ app.name, ext }) catch {
                        return sendResponse(stream, 500, "application/json", "{\"error\":\"format_error\"}");
                    };
                    return sendResponse(stream, 200, "application/json", manifest);
                }
            }
            return sendResponse(stream, 404, "application/json", "{\"error\":\"not_found\"}");
        }

        // 4. Match micro-app directories (exact prefix + '/' boundary)
        for (self.getApps()) |app| {
            if (std.mem.startsWith(u8, relative, app.dir) and
                (relative.len == app.dir.len or relative[app.dir.len] == '/'))
            {
                return self.serveAppFile(stream, relative, app);
            }
        }

        // 5. Shell / root — everything else routes to the shell directory
        if (self.config.shell_dir.len > 0) {
            return self.serveShellFile(stream, relative);
        }

        try sendResponse(stream, 404, "text/html; charset=utf-8",
            \\<!DOCTYPE html><html><body style="font-family:monospace;padding:2rem">
            \\<h1>404 — Not Found</h1>
            \\<p>wu dev server could not find this file.</p></body></html>
        );
    }

    // ── File Serving ────────────────────────────────────────────────────────

    fn serveAppFile(self: *DevServer, stream: std.net.Stream, path: []const u8, app: AppEntry) !void {
        // Security: reject path traversal
        if (std.mem.indexOf(u8, path, "..") != null) {
            return sendResponse(stream, 403, "text/plain", "Forbidden");
        }

        const ext = std.fs.path.extension(path);

        // Files that need framework compilation (.jsx, .tsx, .svelte, .vue)
        if (compile_mod.needsCompile(ext)) {
            return self.serveCompiledFile(stream, path, app);
        }

        // Regular files (JS, CSS, HTML, images, etc.)
        const cwd = std.fs.cwd();
        return self.serveFileFromDisk(stream, cwd, path);
    }

    fn serveCompiledFile(self: *DevServer, stream: std.net.Stream, path: []const u8, app: AppEntry) !void {
        const cwd = std.fs.cwd();
        const file = cwd.openFile(path, .{}) catch {
            return sendResponse(stream, 404, "text/plain", "Not Found");
        };
        defer file.close();

        // Stat first to get mtime for cache lookup
        const stat = file.stat() catch {
            return sendResponse(stream, 500, "text/plain", "Stat error");
        };
        const mtime = stat.mtime;

        // Cache hit? Serve directly — skip the 200-400ms node spawn
        if (self.compile_cache.get(path, mtime)) |cached| {
            defer self.allocator.free(cached);
            // Stamp relative imports with version to bust browser module cache
            const version = self.reload_counter.load(.acquire);
            const versioned = versionRelativeImports(self.allocator, cached, version) catch cached;
            defer if (versioned.ptr != cached.ptr) self.allocator.free(versioned);
            return sendResponse(stream, 200, "application/javascript; charset=utf-8", versioned);
        }

        // Cache miss — read source and compile
        const source = file.readToEndAlloc(self.allocator, 8 * 1024 * 1024) catch {
            return sendResponse(stream, 500, "text/plain", "File too large");
        };
        defer self.allocator.free(source);

        // Compile using the framework's own compiler (esbuild/svelte/vue)
        const compiled = compile_mod.compileFile(
            self.allocator,
            source,
            path,
            app.dir,
            app.framework,
        ) catch {
            var err_buf: [512]u8 = undefined;
            const err_js = std.fmt.bufPrint(&err_buf,
                "console.error('[wu] Compilation failed for {s}. Check that the framework compiler is installed.');",
                .{path},
            ) catch return sendResponse(stream, 500, "text/plain", "Compile error");
            return sendResponse(stream, 200, "application/javascript; charset=utf-8", err_js);
        };
        defer self.allocator.free(compiled);

        // Apply import rewriting to compiled output (bare specifiers → /@modules/)
        const rewritten = transform.rewriteImports(self.allocator, compiled) catch compiled;
        const r_owned = rewritten.ptr != compiled.ptr;
        defer if (r_owned) self.allocator.free(rewritten);

        // Store the final result in cache (version-free for reuse)
        self.compile_cache.put(path, mtime, rewritten);

        // Stamp relative imports with version to bust browser module cache
        const version = self.reload_counter.load(.acquire);
        const versioned = versionRelativeImports(self.allocator, rewritten, version) catch rewritten;
        defer if (versioned.ptr != rewritten.ptr) self.allocator.free(versioned);

        return sendResponse(stream, 200, "application/javascript; charset=utf-8", versioned);
    }

    fn serveShellFile(self: *DevServer, stream: std.net.Stream, relative: []const u8) !void {
        if (std.mem.indexOf(u8, relative, "..") != null) {
            return sendResponse(stream, 403, "text/plain", "Forbidden");
        }

        const cwd = std.fs.cwd();

        // For Astro/Vite shells, try dist/ first (compiled output).
        // Lookup order: dist/{relative} → dist/index.html → {relative} → index.html
        if (relative.len == 0) {
            // Root request → try shell/dist/index.html first
            var dist_buf: [1024]u8 = undefined;
            const dist_path = std.fmt.bufPrint(&dist_buf, "{s}/dist/index.html", .{self.config.shell_dir}) catch return error.Overflow;
            self.serveFileFromDisk(stream, cwd, dist_path) catch {
                // Fall back to shell/index.html
                var src_buf: [1024]u8 = undefined;
                const src_path = std.fmt.bufPrint(&src_buf, "{s}/index.html", .{self.config.shell_dir}) catch return;
                self.serveFileFromDisk(stream, cwd, src_path) catch {
                    sendResponse(stream, 404, "text/plain", "Not Found") catch {};
                };
            };
            return;
        }

        // Strip shell_dir prefix if already present
        const clean_rel = if (std.mem.startsWith(u8, relative, self.config.shell_dir))
            relative[self.config.shell_dir.len + 1 ..] // skip "shell/"
        else
            relative;

        // Try shell/dist/{relative} first (for /_astro/ and other compiled assets)
        var dist_buf: [1024]u8 = undefined;
        const dist_path = std.fmt.bufPrint(&dist_buf, "{s}/dist/{s}", .{ self.config.shell_dir, clean_rel }) catch {
            return sendResponse(stream, 500, "text/plain", "Path error");
        };
        self.serveFileFromDisk(stream, cwd, dist_path) catch {
            // Then try shell/{relative}
            var src_buf: [1024]u8 = undefined;
            const src_path = std.fmt.bufPrint(&src_buf, "{s}/{s}", .{ self.config.shell_dir, clean_rel }) catch return;
            self.serveFileFromDisk(stream, cwd, src_path) catch {
                // Try with /index.html appended
                var idx_buf: [1024]u8 = undefined;
                const idx_path = std.fmt.bufPrint(&idx_buf, "{s}/dist/{s}/index.html", .{ self.config.shell_dir, clean_rel }) catch return;
                self.serveFileFromDisk(stream, cwd, idx_path) catch {
                    sendResponse(stream, 404, "text/plain", "Not Found") catch {};
                };
            };
        };
    }

    fn serveAppsJson(self: *DevServer, stream: std.net.Stream) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);
        try w.writeAll("[");
        const live = self.getApps();
        for (live, 0..) |app, i| {
            if (i > 0) try w.writeAll(",");
            const color = fwColor(app.framework);
            const ext = mainExt(app.framework);
            try w.print(
                \\{{"name":"{s}","dir":"{s}","framework":"{s}","color":"{s}","ext":"{s}"}}
            , .{ app.name, app.dir, app.framework, color, ext });
        }
        try w.writeAll("]");
        return sendResponse(stream, 200, "application/json; charset=utf-8", buf.items);
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

    fn mainExt(framework: []const u8) []const u8 {
        const eql = std.mem.eql;
        if (eql(u8, framework, "react") or eql(u8, framework, "solid") or eql(u8, framework, "preact") or eql(u8, framework, "qwik")) return "jsx";
        if (eql(u8, framework, "angular")) return "ts";
        return "js";
    }

    fn serveFileFromDisk(self: *DevServer, stream: std.net.Stream, cwd: std.fs.Dir, path: []const u8) !void {
        const file = try cwd.openFile(path, .{});
        defer file.close();

        const max_size = 8 * 1024 * 1024; // 8MB
        const contents = try file.readToEndAlloc(self.allocator, max_size);
        defer self.allocator.free(contents);

        const ext = std.fs.path.extension(path);
        const ct = mime_mod.forExtension(ext);

        // Apply transforms for JS/TS/JSX/TSX
        if (needsTransform(ext)) {
            const transformed = transform.transformSource(self.allocator, contents, path) catch contents;
            const owned = transformed.ptr != contents.ptr;
            defer if (owned) self.allocator.free(transformed);
            // Stamp relative imports with version to bust browser module cache
            const version = self.reload_counter.load(.acquire);
            const versioned = versionRelativeImports(self.allocator, transformed, version) catch transformed;
            defer if (versioned.ptr != transformed.ptr) self.allocator.free(versioned);
            try sendResponse(stream, 200, ct, versioned);
            return;
        }

        // Inject HMR client + app data into HTML files
        if (std.mem.eql(u8, ext, ".html") or std.mem.eql(u8, ext, ".htm")) {
            const with_hmr = self.injectHmrScript(contents) catch contents;
            const hmr_owned = with_hmr.ptr != contents.ptr;
            defer if (hmr_owned) self.allocator.free(with_hmr);
            const with_apps = self.injectAppsData(with_hmr) catch with_hmr;
            const apps_owned = with_apps.ptr != with_hmr.ptr;
            defer if (apps_owned) self.allocator.free(with_apps);
            try sendResponse(stream, 200, ct, with_apps);
            return;
        }

        try sendResponse(stream, 200, ct, contents);
    }

    fn needsTransform(ext: []const u8) bool {
        return std.mem.eql(u8, ext, ".ts") or
            std.mem.eql(u8, ext, ".tsx") or
            std.mem.eql(u8, ext, ".jsx") or
            std.mem.eql(u8, ext, ".mts") or
            std.mem.eql(u8, ext, ".js") or
            std.mem.eql(u8, ext, ".mjs");
    }

    // ── CSS-as-Module (import './style.css' support) ───────────────────────

    /// Serve a CSS file as a JavaScript module that injects a <style> tag.
    /// Called when a request has ?import query (appended by transform.zig).
    fn serveCssAsModule(self: *DevServer, stream: std.net.Stream, path: []const u8) !void {
        const relative = if (path.len > 0 and path[0] == '/') path[1..] else path;
        const cwd = std.fs.cwd();
        const file = cwd.openFile(relative, .{}) catch {
            return sendResponse(stream, 404, "text/plain", "CSS not found");
        };
        defer file.close();

        const css = file.readToEndAlloc(self.allocator, 4 * 1024 * 1024) catch {
            return sendResponse(stream, 500, "text/plain", "File too large");
        };
        defer self.allocator.free(css);

        // Build JS module: creates <style> tag with the CSS content
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);

        try out.appendSlice(self.allocator,
            \\(function() {
            \\  var id = '
        );
        // Append escaped file path as attribute value for HMR targeting
        for (relative) |c| {
            if (c == '\'' or c == '\\') {
                try out.append(self.allocator, '\\');
            }
            try out.append(self.allocator, c);
        }
        try out.appendSlice(self.allocator, "';\n" ++
            "  var style = document.querySelector('style[data-wu-css=\"' + id + '\"]');\n" ++
            "  if (!style) {\n" ++
            "    style = document.createElement('style');\n" ++
            "    style.setAttribute('data-wu-css', id);\n" ++
            "    document.head.appendChild(style);\n" ++
            "  }\n" ++
            "  style.textContent = ");

        // JSON-encode the CSS content (handle quotes, newlines, etc.)
        try appendJsString(self.allocator, &out, css);

        try out.appendSlice(self.allocator,
            \\;
            \\})();
            \\
        );

        return sendResponse(stream, 200, "application/javascript; charset=utf-8", out.items);
    }

    /// Encode a string as a JavaScript string literal (double-quoted, escaped).
    fn appendJsString(allocator: Allocator, out: *std.ArrayList(u8), str: []const u8) !void {
        try out.append(allocator, '"');
        for (str) |c| {
            switch (c) {
                '"' => try out.appendSlice(allocator, "\\\""),
                '\\' => try out.appendSlice(allocator, "\\\\"),
                '\n' => try out.appendSlice(allocator, "\\n"),
                '\r' => try out.appendSlice(allocator, "\\r"),
                '\t' => try out.appendSlice(allocator, "\\t"),
                else => {
                    if (c < 0x20) {
                        // Control characters → \xHH
                        var hex_buf: [4]u8 = undefined;
                        _ = std.fmt.bufPrint(&hex_buf, "\\x{x:0>2}", .{c}) catch unreachable;
                        try out.appendSlice(allocator, &hex_buf);
                    } else {
                        try out.append(allocator, c);
                    }
                },
            }
        }
        try out.append(allocator, '"');
    }

    // ── Module Resolution (native Zig — no esbuild, no Node.js) ────────────

    fn handleModuleRequest(self: *DevServer, stream: std.net.Stream, module_name: []const u8) !void {
        if (module_name.len == 0) {
            return sendResponse(stream, 400, "text/plain", "Empty module name");
        }

        // Build search directories: all app dirs + shell dir + project root
        var search_dirs_buf: [32][]const u8 = undefined;
        var search_count: usize = 0;
        for (self.getApps()) |app| {
            if (search_count < search_dirs_buf.len) {
                search_dirs_buf[search_count] = app.dir;
                search_count += 1;
            }
        }
        if (self.config.shell_dir.len > 0 and search_count < search_dirs_buf.len) {
            search_dirs_buf[search_count] = self.config.shell_dir;
            search_count += 1;
        }
        if (search_count < search_dirs_buf.len) {
            search_dirs_buf[search_count] = ".";
            search_count += 1;
        }
        // Workspace root: allows resolving sibling packages (e.g. ../../wu-framework)
        if (search_count < search_dirs_buf.len) {
            search_dirs_buf[search_count] = "../..";
            search_count += 1;
        }
        const search_dirs = search_dirs_buf[0..search_count];

        // Resolve the module to an actual file on disk
        const resolved = resolve_mod.resolveModule(self.allocator, module_name, search_dirs) catch {
            var err_buf: [512]u8 = undefined;
            const err_js = std.fmt.bufPrint(&err_buf,
                "console.error('[wu] Error resolving \"{s}\"');",
                .{module_name},
            ) catch return sendResponse(stream, 500, "text/plain", "Resolve error");
            return sendResponse(stream, 200, "application/javascript; charset=utf-8", err_js);
        } orelse {
            var err_buf: [512]u8 = undefined;
            const err_js = std.fmt.bufPrint(&err_buf,
                "console.error('[wu] Module \"{s}\" not found in any node_modules');",
                .{module_name},
            ) catch return sendResponse(stream, 404, "text/plain", "Module not found");
            return sendResponse(stream, 200, "application/javascript; charset=utf-8", err_js);
        };
        defer self.allocator.free(resolved.file_path);
        defer self.allocator.free(resolved.package_dir);

        // Read the resolved file
        const file = std.fs.cwd().openFile(resolved.file_path, .{}) catch {
            var err_buf: [512]u8 = undefined;
            const err_js = std.fmt.bufPrint(&err_buf,
                "console.error('[wu] Cannot read \"{s}\"');",
                .{module_name},
            ) catch return sendResponse(stream, 500, "text/plain", "Read error");
            return sendResponse(stream, 200, "application/javascript; charset=utf-8", err_js);
        };
        defer file.close();

        // Stat for cache key — enables persistent cache across restarts
        const stat = file.stat() catch {
            return sendResponse(stream, 500, "text/plain", "Stat error");
        };
        const mtime = stat.mtime;

        // Cache hit? Skip the entire read+CJS+transform pipeline
        if (self.compile_cache.get(resolved.file_path, mtime)) |cached| {
            defer self.allocator.free(cached);
            return sendModuleResponse(stream, cached);
        }

        const max_size = 4 * 1024 * 1024; // 4MB
        const source = file.readToEndAlloc(self.allocator, max_size) catch {
            return sendResponse(stream, 500, "text/plain", "File too large");
        };
        defer self.allocator.free(source);

        // Compute file's directory relative to package root.
        // e.g. file_path="x/node_modules/@lit/reactive-element/reactive-element.js"
        //      pkg_dir="x/node_modules/@lit/reactive-element"
        //      → file_rel="reactive-element.js", file_dir_in_pkg=""
        const pkg_name = resolve_mod.extractPackageName(module_name);
        const file_rel = if (resolved.file_path.len > resolved.package_dir.len + 1)
            resolved.file_path[resolved.package_dir.len + 1 ..]
        else
            "";
        const file_dir_in_pkg = if (std.mem.lastIndexOfScalar(u8, file_rel, '/')) |ls|
            file_rel[0..ls]
        else
            "";

        // CJS detection: if the file uses require()/module.exports and has no ESM syntax,
        // wrap it in a synthetic ESM module so browsers can import it.
        if (isCjsModule(source)) {
            const wrapper = self.wrapCjsAsEsm(source, module_name, search_dirs) catch {
                return sendResponse(stream, 200, "application/javascript; charset=utf-8", source);
            };
            defer self.allocator.free(wrapper);
            self.compile_cache.put(resolved.file_path, mtime, wrapper);
            return sendModuleResponse(stream, wrapper);
        }

        // Phase 1: TS stripping + bare import rewriting (react → /@modules/react)
        const ext = std.fs.path.extension(resolved.file_path);
        const phase1 = if (needsTransform(ext))
            transform.transformSource(self.allocator, source, resolved.file_path) catch source
        else
            source;
        const p1_owned = phase1.ptr != source.ptr;
        defer if (p1_owned) self.allocator.free(phase1);

        // Phase 2: Rewrite relative imports to absolute /@modules/ paths.
        // Without this, `import "./css-tag.js"` inside @lit/reactive-element
        // resolves to /@modules/@lit/css-tag.js (wrong) instead of
        // /@modules/@lit/reactive-element/css-tag.js (correct).
        const phase2 = rewriteRelativeModuleImports(self.allocator, phase1, pkg_name, file_dir_in_pkg) catch phase1;
        const p2_owned = phase2.ptr != phase1.ptr;
        defer if (p2_owned) self.allocator.free(phase2);

        // Phase 3: Replace process.env.NODE_ENV with "development".
        // Vue, React-DOM, and many ESM packages reference process.env.NODE_ENV
        // which throws ReferenceError in the browser. Vite does the same replacement.
        const phase3 = replaceProcessEnv(self.allocator, phase2) catch phase2;
        const p3_owned = phase3.ptr != phase2.ptr;
        defer if (p3_owned) self.allocator.free(phase3);

        // Phase 4: Resolve Node.js package #imports (e.g. Svelte's #client/constants).
        // These are defined in package.json "imports" field and are private to the package.
        const phase4 = resolveHashImports(self.allocator, phase3, pkg_name, resolved.package_dir) catch phase3;
        const p4_owned = phase4.ptr != phase3.ptr;
        defer if (p4_owned) self.allocator.free(phase4);

        self.compile_cache.put(resolved.file_path, mtime, phase4);
        return sendModuleResponse(stream, phase4);
    }

    // ── CJS → ESM Wrapping ───────────────────────────────────────────────

    fn wrapCjsAsEsm(self: *DevServer, source: []const u8, module_name: []const u8, search_dirs: []const []const u8) ![]const u8 {
        // Generic CJS → ESM wrapper. Zero hardcoded package names or exports.
        //
        // 1. Scans source for require('./...development...') → follows it
        // 2. Scans the inlined source for require('bare-pkg') → adds ESM imports
        // 3. Generates a require() that returns the imported modules
        // 4. Scans for exports.NAME patterns → generates named re-exports
        //
        // Works for React, ReactDOM, scheduler, or ANY future CJS package
        // without knowing anything about their internal structure.

        // Determine the actual CJS source to inline.
        // Many CJS packages (React, scheduler, etc.) have an index.js that does:
        //   if (process.env.NODE_ENV === 'production') require('./cjs/pkg.production.min.js');
        //   else require('./cjs/pkg.development.js');
        // We scan for require('./...') and prefer the "development" path.
        var actual_source = source;
        var actual_source_owned = false;
        defer if (actual_source_owned) self.allocator.free(actual_source);

        if (findRequireDevPath(source)) |dev_rel_path| {
            const pkg_name = resolve_mod.extractPackageName(module_name);
            var spec_buf: [512]u8 = undefined;
            if (std.fmt.bufPrint(&spec_buf, "{s}/{s}", .{ pkg_name, dev_rel_path })) |dev_spec| {
                if (resolve_mod.resolveModule(self.allocator, dev_spec, search_dirs) catch null) |dev_resolved| {
                    defer self.allocator.free(dev_resolved.file_path);
                    defer self.allocator.free(dev_resolved.package_dir);
                    if (std.fs.cwd().openFile(dev_resolved.file_path, .{})) |dev_file| {
                        defer dev_file.close();
                        if (dev_file.readToEndAlloc(self.allocator, 4 * 1024 * 1024)) |ds| {
                            actual_source = ds;
                            actual_source_owned = true;
                        } else |_| {}
                    } else |_| {}
                }
            } else |_| {}
        }

        // Scan the CJS source for require('bare-pkg') calls to external packages.
        // We'll generate static ESM imports for them so the browser resolves deps.
        var deps_buf: [32][]const u8 = undefined;
        var dep_count: usize = 0;
        {
            var pos: usize = 0;
            while (pos + 10 < actual_source.len and dep_count < deps_buf.len) {
                if (std.mem.startsWith(u8, actual_source[pos..], "require(")) {
                    const q = pos + 8; // after "require("
                    if (q < actual_source.len and (actual_source[q] == '\'' or actual_source[q] == '"')) {
                        const quote = actual_source[q];
                        const spec_start = q + 1;
                        if (std.mem.indexOfScalar(u8, actual_source[spec_start..], quote)) |spec_len| {
                            const spec = actual_source[spec_start .. spec_start + spec_len];
                            // Only bare specifiers (not ./relative), and not self-requires
                            if (spec.len > 0 and spec[0] != '.' and spec[0] != '/') {
                                // Deduplicate
                                var dupe = false;
                                for (deps_buf[0..dep_count]) |existing| {
                                    if (std.mem.eql(u8, existing, spec)) {
                                        dupe = true;
                                        break;
                                    }
                                }
                                if (!dupe) {
                                    deps_buf[dep_count] = spec;
                                    dep_count += 1;
                                }
                            }
                            pos = spec_start + spec_len;
                            continue;
                        }
                    }
                }
                pos += 1;
            }
        }

        // Build the wrapper
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        const w = out.writer(self.allocator);

        try w.writeAll("// [wu] CJS → ESM wrapper for \"");
        try w.writeAll(module_name);
        try w.writeAll("\"\n");

        // Static ESM imports for each dependency found via require() scanning
        for (deps_buf[0..dep_count], 0..) |dep, i| {
            try w.print("import __dep{d} from '/@modules/{s}';\n", .{ i, dep });
        }

        try w.writeAll("var process = { env: { NODE_ENV: \"development\" } };\nvar global = globalThis;\nvar module = { exports: {} };\nvar exports = module.exports;\n");

        // Generate require() that returns the imported modules
        try w.writeAll("function require(id) {\n");
        for (deps_buf[0..dep_count], 0..) |dep, i| {
            try w.print("  if (id === '{s}') return __dep{d};\n", .{ dep, i });
        }
        try w.writeAll("  console.warn('[wu] require(' + id + ')');\n");
        try w.writeAll("  return {};\n}\n\n");

        // Inline the CJS source
        try w.writeAll(actual_source);
        try w.writeAll("\n\nexport default module.exports;\n");

        // Auto-detect and re-export named exports by scanning for exports.NAME patterns
        try appendGenericExports(self.allocator, &out, actual_source);

        return out.toOwnedSlice(self.allocator);
    }

    // ── HMR (Server-Sent Events) ───────────────────────────────────────────

    fn handleHmr(self: *DevServer, stream: std.net.Stream) !void {
        // SSE headers
        try platformWrite(stream,
            "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: text/event-stream\r\n" ++
                "Cache-Control: no-cache\r\n" ++
                "Connection: keep-alive\r\n" ++
                "Access-Control-Allow-Origin: *\r\n" ++
                "\r\n",
        );

        // Send connected event
        try platformWrite(stream, "data: {\"type\":\"connected\"}\n\n");

        var last_seen: u64 = self.reload_counter.load(.acquire);
        var ping_ticks: u32 = 0;

        // Poll every 100ms — changes reach the browser in <400ms
        while (self.running.load(.acquire)) {
            const current = self.reload_counter.load(.acquire);
            if (current != last_seen) {
                last_seen = current;

                // Read the pre-formatted event from watcher thread
                var local_event: [512]u8 = undefined;
                var local_len: usize = 0;
                self.hmr_mutex.lock();
                local_len = self.hmr_event_len;
                if (local_len > 0 and local_len <= local_event.len) {
                    @memcpy(local_event[0..local_len], self.hmr_event_buf[0..local_len]);
                }
                self.hmr_mutex.unlock();

                if (local_len > 0) {
                    platformWrite(stream, local_event[0..local_len]) catch return;
                } else {
                    platformWrite(stream, "data: {\"type\":\"full-reload\"}\n\n") catch return;
                }
            }

            // Keepalive ping every ~30s (300 * 100ms)
            ping_ticks += 1;
            if (ping_ticks >= 300) {
                platformWrite(stream, ": ping\n\n") catch return;
                ping_ticks = 0;
            }

            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }

    // ── WebSocket HMR ────────────────────────────────────────────────────────

    fn handleWsHmr(self: *DevServer, stream: std.net.Stream, ws_key: []const u8) void {
        // Send 101 Switching Protocols
        var resp_buf: [256]u8 = undefined;
        const resp = ws_proto.Handshake.buildResponse(ws_key, &resp_buf);
        platformWrite(stream, resp) catch return;

        // Send connected message
        var frame_buf: [256]u8 = undefined;
        const connected_msg = "{\"type\":\"connected\"}";
        const connected_frame = ws_proto.FrameBuilder.text(connected_msg, &frame_buf) catch return;
        platformWrite(stream, connected_frame) catch return;

        var last_seen = self.reload_counter.load(.acquire);
        var ping_ticks: u32 = 0;
        var recv_buf: [1024]u8 = undefined;

        while (self.running.load(.acquire)) {
            const current = self.reload_counter.load(.acquire);
            if (current != last_seen) {
                last_seen = current;

                // Read the pre-formatted event from watcher thread
                var local_event: [512]u8 = undefined;
                var local_len: usize = 0;
                self.hmr_mutex.lock();
                local_len = self.hmr_event_len;
                if (local_len > 0 and local_len <= local_event.len) {
                    @memcpy(local_event[0..local_len], self.hmr_event_buf[0..local_len]);
                }
                self.hmr_mutex.unlock();

                // Extract the JSON from "data: {...}\n\n" SSE format
                const event_data = blk: {
                    if (local_len > 6) {
                        const ev_slice = local_event[0..local_len];
                        if (std.mem.startsWith(u8, ev_slice, "data: ")) {
                            // Find the JSON payload (between "data: " and "\n")
                            const json_start: usize = 6;
                            var json_end = local_len;
                            while (json_end > json_start and (local_event[json_end - 1] == '\n')) json_end -= 1;
                            break :blk local_event[json_start..json_end];
                        }
                    }
                    break :blk @as([]const u8, "{\"type\":\"full-reload\"}");
                };

                var ws_buf: [1024]u8 = undefined;
                const ws_frame = ws_proto.FrameBuilder.text(event_data, &ws_buf) catch return;
                platformWrite(stream, ws_frame) catch return;
            }

            // Handle incoming WS frames (ping, close, messages from browser)
            if (platformReadNonBlocking(stream, &recv_buf)) |rn| {
                if (rn > 0) {
                    var parser = ws_proto.FrameParser{};
                    var payload_buf: [1024]u8 = undefined;
                    const parse_result = parser.parse(recv_buf[0..rn], &payload_buf);
                    switch (parse_result.result) {
                        .frame => |frame| {
                            if (frame.header.opcode == .close) return;
                            if (frame.header.opcode == .ping) {
                                var pong_buf: [256]u8 = undefined;
                                const pong = ws_proto.FrameBuilder.pong(frame.payload, &pong_buf) catch return;
                                platformWrite(stream, pong) catch return;
                            }
                        },
                        else => {},
                    }
                }
            } else |_| {}

            // WS ping every ~30s
            ping_ticks += 1;
            if (ping_ticks >= 300) {
                var ping_buf: [32]u8 = undefined;
                const ping_frame = ws_proto.FrameBuilder.ping("wu", &ping_buf) catch return;
                platformWrite(stream, ping_frame) catch return;
                ping_ticks = 0;
            }

            std.Thread.sleep(100 * std.time.ns_per_ms);
        }

        // Send close frame
        var close_buf: [32]u8 = undefined;
        const close_frame = ws_proto.FrameBuilder.close(.going_away, "shutdown", &close_buf) catch return;
        platformWrite(stream, close_frame) catch {};
    }

    fn injectHmrScript(self: *DevServer, html: []const u8) ![]const u8 {
        const script = "\n<script type=\"module\" src=\"/@wu/client.js\"></script>\n";

        // Inject before </head> if present
        if (std.mem.indexOf(u8, html, "</head>")) |idx| {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(self.allocator);
            try out.appendSlice(self.allocator, html[0..idx]);
            try out.appendSlice(self.allocator, script);
            try out.appendSlice(self.allocator, html[idx..]);
            return out.toOwnedSlice(self.allocator);
        }

        // Inject before </body> if present
        if (std.mem.indexOf(u8, html, "</body>")) |idx| {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(self.allocator);
            try out.appendSlice(self.allocator, html[0..idx]);
            try out.appendSlice(self.allocator, script);
            try out.appendSlice(self.allocator, html[idx..]);
            return out.toOwnedSlice(self.allocator);
        }

        // Prepend if no head/body found
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, script);
        try out.appendSlice(self.allocator, html);
        return out.toOwnedSlice(self.allocator);
    }

    /// Inject window.__wu_apps JSON into HTML so main.js doesn't need fetch()
    fn injectAppsData(self: *DevServer, html: []const u8) ![]const u8 {
        // Build JSON array of apps
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.allocator);
        const jw = json.writer(self.allocator);
        try jw.writeAll("\n<script>window.__wu_apps=");
        try jw.writeAll("[");
        const live = self.getApps();
        for (live, 0..) |app, i| {
            if (i > 0) try jw.writeAll(",");
            const color = fwColor(app.framework);
            const ext = mainExt(app.framework);
            try jw.print(
                \\{{"name":"{s}","dir":"{s}","framework":"{s}","color":"{s}","ext":"{s}"}}
            , .{ app.name, app.dir, app.framework, color, ext });
        }
        try jw.writeAll("];</script>\n");

        // Inject before </head> or before first <script
        const anchor = std.mem.indexOf(u8, html, "</head>") orelse
            std.mem.indexOf(u8, html, "<script") orelse
            return error.NoInjectionPoint;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, html[0..anchor]);
        try out.appendSlice(self.allocator, json.items);
        try out.appendSlice(self.allocator, html[anchor..]);
        return out.toOwnedSlice(self.allocator);
    }

    // ── File Watcher ────────────────────────────────────────────────────────

    fn watcherThread(self: *DevServer) void {
        // Fixed-size mtime cache: hash(path) → mtime + generation
        const MAX_ENTRIES = 4096;
        var entries: [MAX_ENTRIES]WatchEntry = undefined;
        var entry_count: usize = 0;
        var generation: u32 = 0;

        // Track wu.config.json mtime for live config changes
        var config_mtime: i128 = 0;
        var first_scan = true;
        // Debounce: wait for config to stabilize before reading
        // (wu add writes config + runs npm install — file may be written in stages)
        var config_pending_reload = false;
        var config_debounce: u8 = 0;

        // Delay first scan to let server start
        std.Thread.sleep(500 * std.time.ns_per_ms);

        while (self.running.load(.acquire)) {
            generation +%= 1;
            var apps_changed: usize = 0;
            var shell_changed = false;
            var files_deleted = false;
            var last_app_name: []const u8 = "";
            var last_app_dir: []const u8 = "";
            var last_app_fw: []const u8 = "";
            var changed_ext: [16]u8 = undefined;
            var changed_ext_len: usize = 0;

            // Check if wu.config.json changed (app added/removed)
            {
                const stat = std.fs.cwd().statFile("wu.config.json") catch null;
                if (stat) |s| {
                    if (s.mtime != config_mtime) {
                        config_mtime = s.mtime;
                        if (!first_scan) {
                            // Config changed — start debounce (wait for file to stabilize)
                            config_pending_reload = true;
                            config_debounce = 0;
                        }
                    } else if (config_pending_reload) {
                        // mtime stable this cycle — count debounce ticks
                        config_debounce += 1;
                        if (config_debounce >= 5) { // 5 cycles × 100ms = 500ms stable
                            config_pending_reload = false;
                            self.reloadApps(); // re-read config, swap live app list
                            shell_changed = true; // trigger full reload
                            std.debug.print("  {s}[hmr]{s} wu.config.json changed → full reload\n", .{
                                ansi.cyan, ansi.reset,
                            });
                        }
                    }
                }
            }

            // Scan each app directory (use live list — may have been updated by reloadApps)
            for (self.getApps()) |app| {
                var ext_buf: [16]u8 = undefined;
                var ext_len: usize = 0;
                if (scanDir(app.dir, &entries, &entry_count, MAX_ENTRIES, &ext_buf, &ext_len, generation)) {
                    apps_changed += 1;
                    last_app_name = app.name;
                    last_app_dir = app.dir;
                    last_app_fw = app.framework;
                    if (ext_len > 0) {
                        @memcpy(changed_ext[0..ext_len], ext_buf[0..ext_len]);
                        changed_ext_len = ext_len;
                    }
                }
            }
            // Scan shell directory
            if (self.config.shell_dir.len > 0) {
                var ext_buf: [16]u8 = undefined;
                var ext_len: usize = 0;
                if (scanDir(self.config.shell_dir, &entries, &entry_count, MAX_ENTRIES, &ext_buf, &ext_len, generation)) {
                    shell_changed = true;
                }
            }

            // Detect deleted files: entries with stale generation were not seen this cycle
            {
                var i: usize = 0;
                while (i < entry_count) {
                    if (entries[i].generation != generation) {
                        // File was deleted — remove entry by swapping with last
                        files_deleted = true;
                        entry_count -= 1;
                        if (i < entry_count) {
                            entries[i] = entries[entry_count];
                        }
                        // don't increment i — check the swapped entry
                    } else {
                        i += 1;
                    }
                }
                if (files_deleted) {
                    std.debug.print("  {s}[hmr]{s} file(s) deleted → full reload\n", .{
                        ansi.cyan, ansi.reset,
                    });
                }
            }

            if (apps_changed > 0 or shell_changed or files_deleted) {
                // Format the SSE event for the HMR handler
                var event_buf: [512]u8 = undefined;
                var event_len: usize = 0;

                if (!shell_changed and !files_deleted and apps_changed == 1) {
                    const ext_slice = changed_ext[0..changed_ext_len];
                    if (std.mem.eql(u8, ext_slice, ".css")) {
                        // CSS-only change → hot inject (no page reload)
                        const ev = std.fmt.bufPrint(&event_buf,
                            "data: {{\"type\":\"css-update\",\"app\":\"{s}\"}}\n\n",
                            .{last_app_name},
                        ) catch null;
                        if (ev) |e| event_len = e.len;
                        std.debug.print("  {s}[hmr]{s} css update → {s}{s}{s}\n", .{
                            ansi.cyan, ansi.reset, ansi.bold, last_app_name, ansi.reset,
                        });
                    } else {
                        // Single app changed → targeted app reload
                        const ev = std.fmt.bufPrint(&event_buf,
                            "data: {{\"type\":\"app-update\",\"app\":\"{s}\",\"dir\":\"{s}\",\"fw\":\"{s}\"}}\n\n",
                            .{ last_app_name, last_app_dir, last_app_fw },
                        ) catch null;
                        if (ev) |e| event_len = e.len;
                        std.debug.print("  {s}[hmr]{s} update → {s}{s}{s}\n", .{
                            ansi.cyan, ansi.reset, ansi.bold, last_app_name, ansi.reset,
                        });
                    }
                } else {
                    // Multiple apps or shell changed → full reload
                    event_len = 0; // handler will send full-reload
                    std.debug.print("  {s}[hmr]{s} full reload\n", .{ ansi.cyan, ansi.reset });
                }

                self.hmr_mutex.lock();
                if (event_len > 0) {
                    @memcpy(self.hmr_event_buf[0..event_len], event_buf[0..event_len]);
                }
                self.hmr_event_len = event_len;
                self.hmr_mutex.unlock();

                _ = self.reload_counter.fetchAdd(1, .release);
            }

            first_scan = false;
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }

    fn scanDir(dir_name: []const u8, entries: []WatchEntry, count: *usize, max: usize, ext_out: *[16]u8, ext_out_len: *usize, generation: u32) bool {
        var changed = false;

        // Stack-based recursive traversal (no allocator needed)
        const max_depth = 16;
        var stack: [max_depth]std.fs.Dir = undefined;
        var stack_iters: [max_depth]std.fs.Dir.Iterator = undefined;
        var stack_paths: [max_depth][512]u8 = undefined;
        var stack_path_lens: [max_depth]usize = undefined;
        var depth: usize = 0;

        // Push root directory
        stack[0] = std.fs.cwd().openDir(dir_name, .{ .iterate = true }) catch return false;
        stack_iters[0] = stack[0].iterate();
        const root_len = @min(dir_name.len, stack_paths[0].len);
        @memcpy(stack_paths[0][0..root_len], dir_name[0..root_len]);
        stack_path_lens[0] = root_len;

        while (true) {
            // Try to get next entry at current depth
            const entry_opt = stack_iters[depth].next() catch null;

            if (entry_opt) |entry| {
                if (entry.kind == .directory) {
                    // Skip known non-source directories
                    if (isSkippedDir(entry.name)) continue;
                    if (depth + 1 >= max_depth) continue;

                    // Build path for subdirectory
                    const parent_len = stack_path_lens[depth];
                    const name_len = entry.name.len;
                    const child_len = parent_len + 1 + name_len;
                    if (child_len > stack_paths[0].len) continue;

                    var child_path: *[512]u8 = &stack_paths[depth + 1];
                    @memcpy(child_path[0..parent_len], stack_paths[depth][0..parent_len]);
                    child_path[parent_len] = '/';
                    @memcpy(child_path[parent_len + 1 .. child_len], entry.name);
                    stack_path_lens[depth + 1] = child_len;

                    // Open subdirectory and push onto stack
                    const sub_dir = stack[depth].openDir(entry.name, .{ .iterate = true }) catch continue;
                    depth += 1;
                    stack[depth] = sub_dir;
                    stack_iters[depth] = stack[depth].iterate();
                    continue;
                }

                if (entry.kind != .file) continue;

                // Only watch source files
                const ext = std.fs.path.extension(entry.name);
                if (!isWatchedExtension(ext)) continue;

                // Get mtime via stat (no file handle — faster on Windows)
                const stat = stack[depth].statFile(entry.name) catch continue;
                const mtime = stat.mtime;

                // Build full path for hashing
                const parent_len = stack_path_lens[depth];
                const name_len = entry.name.len;
                const full_len = parent_len + 1 + name_len;
                var full_path_buf: [1024]u8 = undefined;
                if (full_len > full_path_buf.len) continue;
                @memcpy(full_path_buf[0..parent_len], stack_paths[depth][0..parent_len]);
                full_path_buf[parent_len] = '/';
                @memcpy(full_path_buf[parent_len + 1 .. full_len], entry.name);
                const hash = std.hash.Wyhash.hash(0, full_path_buf[0..full_len]);

                // Check if mtime changed
                var found = false;
                for (entries[0..count.*]) |*e| {
                    if (e.hash == hash) {
                        e.generation = generation;
                        if (e.mtime != mtime) {
                            e.mtime = mtime;
                            changed = true;
                            // Track the extension of the changed file
                            const el = @min(ext.len, ext_out.len);
                            @memcpy(ext_out[0..el], ext[0..el]);
                            ext_out_len.* = el;
                        }
                        found = true;
                        break;
                    }
                }

                if (!found and count.* < max) {
                    entries[count.*] = .{ .hash = hash, .mtime = mtime, .generation = generation };
                    count.* += 1;
                }
            } else {
                // No more entries at this depth — pop
                stack[depth].close();
                if (depth == 0) break;
                depth -= 1;
            }
        }

        return changed;
    }

    fn isWatchedExtension(ext: []const u8) bool {
        const eql = std.mem.eql;
        return eql(u8, ext, ".js") or eql(u8, ext, ".ts") or eql(u8, ext, ".jsx") or
            eql(u8, ext, ".tsx") or eql(u8, ext, ".html") or eql(u8, ext, ".css") or
            eql(u8, ext, ".json") or eql(u8, ext, ".svelte") or eql(u8, ext, ".vue") or
            eql(u8, ext, ".astro") or eql(u8, ext, ".mjs");
    }

    fn isSkippedDir(name: []const u8) bool {
        const eql = std.mem.eql;
        return eql(u8, name, "node_modules") or eql(u8, name, "dist") or
            eql(u8, name, ".git") or eql(u8, name, ".svelte-kit") or
            eql(u8, name, ".next") or eql(u8, name, ".nuxt") or
            eql(u8, name, "build") or eql(u8, name, "coverage") or
            eql(u8, name, ".claude");
    }

    // ── HTTP Helpers ────────────────────────────────────────────────────────

    fn sendResponse(stream: std.net.Stream, status: u16, content_type: []const u8, body: []const u8) !void {
        const phrase = statusPhrase(status);
        var resp_buf: [4096]u8 = undefined;
        const header = std.fmt.bufPrint(&resp_buf,
            "HTTP/1.1 {d} {s}\r\n" ++
                "Content-Type: {s}\r\n" ++
                "Content-Length: {d}\r\n" ++
                "Cache-Control: no-store\r\n" ++
                "Access-Control-Allow-Origin: *\r\n" ++
                "Access-Control-Allow-Methods: GET, OPTIONS\r\n" ++
                "Access-Control-Allow-Headers: *\r\n" ++
                "Connection: keep-alive\r\n" ++
                "\r\n",
            .{ status, phrase, content_type, body.len },
        ) catch return error.Overflow;

        try platformWrite(stream, header);
        if (body.len > 0) {
            try platformWrite(stream, body);
        }
    }

    /// Like sendResponse but with Cache-Control for npm modules.
    /// Browser caches /@modules/ for 24h — avoids 100+ re-requests on F5.
    fn sendModuleResponse(stream: std.net.Stream, body: []const u8) !void {
        var resp_buf: [4096]u8 = undefined;
        const header = std.fmt.bufPrint(&resp_buf,
            "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: application/javascript; charset=utf-8\r\n" ++
                "Content-Length: {d}\r\n" ++
                "Cache-Control: max-age=86400\r\n" ++
                "Access-Control-Allow-Origin: *\r\n" ++
                "Connection: keep-alive\r\n" ++
                "\r\n",
            .{body.len},
        ) catch return error.Overflow;

        try platformWrite(stream, header);
        if (body.len > 0) {
            try platformWrite(stream, body);
        }
    }

    fn statusPhrase(status: u16) []const u8 {
        return switch (status) {
            200 => "OK",
            204 => "No Content",
            304 => "Not Modified",
            400 => "Bad Request",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            500 => "Internal Server Error",
            501 => "Not Implemented",
            else => "OK",
        };
    }
};

// ── Framework Helpers ───────────────────────────────────────────────────────

/// Map framework name to its main entry-point extension (mirrors create.zig mainExt).
fn fwMainExt(framework: []const u8) []const u8 {
    const eql = std.mem.eql;
    if (eql(u8, framework, "react") or eql(u8, framework, "solid") or eql(u8, framework, "preact") or eql(u8, framework, "qwik")) return "jsx";
    if (eql(u8, framework, "angular")) return "ts";
    return "js";
}

// ── CJS Detection Helpers ───────────────────────────────────────────────────

/// Detect if source is a CommonJS module (has require/module.exports, no ESM syntax).
fn isCjsModule(source: []const u8) bool {
    // Quick heuristic: if the file has `module.exports` or starts with `'use strict'`
    // followed by require() patterns, and has no `export` or `import` ESM keywords.
    const has_cjs = std.mem.indexOf(u8, source, "module.exports") != null or
        std.mem.indexOf(u8, source, "exports.") != null or
        (std.mem.indexOf(u8, source, "require(") != null and
        std.mem.indexOf(u8, source, "module.exports") != null);

    if (!has_cjs) return false;

    // Check that it doesn't have ESM syntax (export/import at start of line)
    const has_esm = std.mem.indexOf(u8, source, "\nexport ") != null or
        std.mem.indexOf(u8, source, "\nimport ") != null or
        (source.len > 7 and std.mem.eql(u8, source[0..7], "export ")) or
        (source.len > 7 and std.mem.eql(u8, source[0..7], "import "));

    return !has_esm;
}

/// Scan CJS source for require('./...') calls. Prefer paths containing "development".
/// Returns the relative path (stripped of "./" prefix) or null if none found.
///
/// This is fully generic — works for React, ReactDOM, scheduler, or any CJS package
/// that uses require('./subpath') without hardcoding any package names.
fn findRequireDevPath(source: []const u8) ?[]const u8 {
    var dev_path: ?[]const u8 = null;
    var any_path: ?[]const u8 = null;
    var pos: usize = 0;

    while (pos + 10 < source.len) {
        if (pos + 8 <= source.len and std.mem.eql(u8, source[pos .. pos + 8], "require(")) {
            var q = pos + 8;
            while (q < source.len and (source[q] == ' ' or source[q] == '\t')) : (q += 1) {}
            if (q < source.len and (source[q] == '\'' or source[q] == '"')) {
                const quote = source[q];
                const start = q + 1;
                var end = start;
                while (end < source.len and source[end] != quote) : (end += 1) {}
                if (end < source.len) {
                    const req_path = source[start..end];
                    if (std.mem.startsWith(u8, req_path, "./")) {
                        const clean = req_path[2..]; // strip "./"
                        if (std.mem.indexOf(u8, clean, "development") != null) {
                            dev_path = clean;
                        }
                        any_path = clean;
                    }
                }
            }
        }
        pos += 1;
    }

    return dev_path orelse any_path;
}

/// Scan CJS source for `exports.NAME` patterns and append ESM re-exports.
/// Fully generic — no hardcoded export names. Detects patterns like:
///   exports.useState = ...
///   exports.Fragment = ...
fn appendGenericExports(allocator: Allocator, out: *std.ArrayList(u8), source: []const u8) !void {
    var names_buf: [128][]const u8 = undefined;
    var count: usize = 0;
    var pos: usize = 0;

    while (pos + 9 < source.len and count < names_buf.len) {
        if (std.mem.startsWith(u8, source[pos..], "exports.")) {
            // Check word boundary
            if (pos == 0 or !std.ascii.isAlphanumeric(source[pos - 1])) {
                const name_start = pos + 8;
                var name_end = name_start;
                while (name_end < source.len and
                    (std.ascii.isAlphanumeric(source[name_end]) or
                    source[name_end] == '_' or source[name_end] == '$'))
                {
                    name_end += 1;
                }
                if (name_end > name_start) {
                    const name = source[name_start..name_end];
                    // Skip internal/private names
                    if (!std.mem.eql(u8, name, "__esModule") and
                        name.len > 0 and name[0] != '_')
                    {
                        // Deduplicate
                        var dupe = false;
                        for (names_buf[0..count]) |existing| {
                            if (std.mem.eql(u8, existing, name)) {
                                dupe = true;
                                break;
                            }
                        }
                        if (!dupe) {
                            names_buf[count] = name;
                            count += 1;
                        }
                    }
                }
            }
        }
        pos += 1;
    }

    if (count == 0) return;

    const w = out.writer(allocator);
    try w.writeAll("var __e = module.exports;\nexport var ");
    for (names_buf[0..count], 0..) |name, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(name);
        try w.writeAll(" = __e.");
        try w.writeAll(name);
    }
    try w.writeAll(";\n");
}

// ── Phase 3: process.env.NODE_ENV replacement ───────────────────────────────
//
// Many ESM packages (Vue, React-DOM) reference process.env.NODE_ENV directly.
// In Node.js this is fine, but in the browser `process` is undefined → ReferenceError.
// We replace all occurrences with the string literal "development".
// This is exactly what Vite and esbuild do during dev serving.

fn replaceProcessEnv(allocator: Allocator, source: []const u8) ![]const u8 {
    // Replacements: process.env.NODE_ENV and Vue/framework compile-time feature flags.
    // Vue's ESM bundler build uses __VUE_OPTIONS_API__ etc. as bare global references.
    // Without defining them, the browser throws ReferenceError and the entire module fails.
    // This is exactly what Vite does with its `define` plugin.
    const replacements = [_]struct { needle: []const u8, value: []const u8 }{
        .{ .needle = "process.env.NODE_ENV", .value = "\"development\"" },
        .{ .needle = "__VUE_OPTIONS_API__", .value = "true" },
        .{ .needle = "__VUE_PROD_DEVTOOLS__", .value = "false" },
        .{ .needle = "__VUE_PROD_HYDRATION_MISMATCH_DETAILS__", .value = "false" },
    };

    // Quick check: if none of the needles are present, return as-is
    var any_found = false;
    for (replacements) |r| {
        if (std.mem.indexOf(u8, source, r.needle) != null) {
            any_found = true;
            break;
        }
    }
    if (!any_found) return source;

    // Apply replacements sequentially. Each pass produces a new buffer.
    var current = source;
    var owned = false;

    for (replacements) |r| {
        if (std.mem.indexOf(u8, current, r.needle) == null) continue;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var remaining = current;
        while (std.mem.indexOf(u8, remaining, r.needle)) |idx| {
            // For feature flags: make sure we're not matching a substring of a longer identifier.
            // e.g. __VUE_OPTIONS_API__ should not match __VUE_OPTIONS_API__X
            const abs_pos = @intFromPtr(remaining.ptr) - @intFromPtr(current.ptr) + idx;
            const after = abs_pos + r.needle.len;
            _ = after;
            const end_pos = idx + r.needle.len;
            if (end_pos < remaining.len and (std.ascii.isAlphanumeric(remaining[end_pos]) or remaining[end_pos] == '_')) {
                // Part of a longer identifier — don't replace
                try out.appendSlice(allocator, remaining[0 .. idx + r.needle.len]);
                remaining = remaining[idx + r.needle.len ..];
                continue;
            }
            // Also check before: if preceded by alphanumeric or _, it's a longer ident
            if (idx > 0 and (std.ascii.isAlphanumeric(remaining[idx - 1]) or remaining[idx - 1] == '_')) {
                try out.appendSlice(allocator, remaining[0 .. idx + r.needle.len]);
                remaining = remaining[idx + r.needle.len ..];
                continue;
            }

            try out.appendSlice(allocator, remaining[0..idx]);
            try out.appendSlice(allocator, r.value);
            remaining = remaining[idx + r.needle.len ..];
        }
        try out.appendSlice(allocator, remaining);

        if (owned) allocator.free(current);
        current = try out.toOwnedSlice(allocator);
        owned = true;
    }

    return current;
}

// ── Phase 4: Node.js package #imports resolution ────────────────────────────
//
// Node.js supports private package imports via the "imports" field in package.json.
// Svelte 5 uses this heavily: `import { X } from '#client/constants'` maps to
// `./src/internal/client/constants.js` via its package.json imports field.
//
// Our transform pipeline doesn't handle `#` specifiers (not bare, not relative),
// so they pass through to the browser which can't resolve them.
//
// This function reads the package's package.json "imports" field and rewrites
// `#specifier` → `/@modules/{pkg}/{resolved_path}`.

fn resolveHashImports(
    allocator: Allocator,
    source: []const u8,
    pkg_name: []const u8,
    package_dir: []const u8,
) ![]const u8 {
    // Quick check: if no '#' in import context, skip
    if (std.mem.indexOf(u8, source, "'#") == null and
        std.mem.indexOf(u8, source, "\"#") == null)
        return source;

    // Read the package.json to get the "imports" field
    var pkg_path_buf: [2048]u8 = undefined;
    const pkg_json_path = std.fmt.bufPrint(&pkg_path_buf, "{s}/package.json", .{package_dir}) catch return source;

    const pkg_file = std.fs.cwd().openFile(pkg_json_path, .{}) catch return source;
    defer pkg_file.close();

    const pkg_json = pkg_file.readToEndAlloc(allocator, 512 * 1024) catch return source;
    defer allocator.free(pkg_json);

    // Find the "imports" field
    const imports_region = resolve_mod.findFieldRegion(pkg_json, "imports") orelse return source;
    if (imports_region.len == 0 or imports_region[0] != '{') return source;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var remaining = source;
    var found_any = false;

    // Scan for from '#...' and from "#..." patterns
    while (remaining.len > 0) {
        // Find next `from` keyword
        const from_idx = findFromKeyword(remaining) orelse break;

        // Skip whitespace after 'from'
        var q = from_idx + 4;
        while (q < remaining.len and (remaining[q] == ' ' or remaining[q] == '\t')) : (q += 1) {}
        if (q >= remaining.len) break;

        const quote = remaining[q];
        if (quote != '"' and quote != '\'') {
            // Not a string literal, advance past "from" and continue
            try out.appendSlice(allocator, remaining[0 .. from_idx + 4]);
            remaining = remaining[from_idx + 4 ..];
            continue;
        }

        const spec_start = q + 1;
        const spec_end_rel = std.mem.indexOfScalar(u8, remaining[spec_start..], quote) orelse break;
        const specifier = remaining[spec_start .. spec_start + spec_end_rel];

        // Only handle #-prefixed specifiers
        if (specifier.len == 0 or specifier[0] != '#') {
            // Not a hash import, advance past this from+specifier
            try out.appendSlice(allocator, remaining[0 .. spec_start + spec_end_rel + 1]);
            remaining = remaining[spec_start + spec_end_rel + 1 ..];
            continue;
        }

        // Look up this #specifier in the imports field
        if (resolveHashSpecifier(imports_region, specifier)) |resolved_path| {
            // Strip leading "./" from the resolved path
            const clean_path = if (std.mem.startsWith(u8, resolved_path, "./"))
                resolved_path[2..]
            else
                resolved_path;

            // Write everything up to the specifier, then the rewritten path
            try out.appendSlice(allocator, remaining[0..spec_start]);
            try out.appendSlice(allocator, "/@modules/");
            try out.appendSlice(allocator, pkg_name);
            try out.appendSlice(allocator, "/");
            try out.appendSlice(allocator, clean_path);
            remaining = remaining[spec_start + spec_end_rel ..];
            found_any = true;
        } else {
            // Could not resolve — leave as-is
            try out.appendSlice(allocator, remaining[0 .. spec_start + spec_end_rel + 1]);
            remaining = remaining[spec_start + spec_end_rel + 1 ..];
        }
    }

    if (!found_any) {
        out.deinit(allocator);
        return source;
    }

    try out.appendSlice(allocator, remaining);
    return out.toOwnedSlice(allocator);
}

/// Find the next 'from' keyword in source that's not part of another identifier.
fn findFromKeyword(source: []const u8) ?usize {
    var pos: usize = 0;
    while (pos + 4 <= source.len) {
        if (std.mem.eql(u8, source[pos .. pos + 4], "from")) {
            // Make sure it's not part of a larger identifier
            const before_ok = (pos == 0 or !std.ascii.isAlphanumeric(source[pos - 1]) and source[pos - 1] != '_');
            const after_ok = (pos + 4 >= source.len or !std.ascii.isAlphanumeric(source[pos + 4]) and source[pos + 4] != '_');
            if (before_ok and after_ok) return pos;
        }
        pos += 1;
    }
    return null;
}

/// Look up a #specifier in the imports field region of package.json.
/// The imports field looks like: { "#client/constants": "./src/internal/client/constants.js", ... }
/// Also handles condition objects: { "#client": { "types": "...", "default": "..." } }
fn resolveHashSpecifier(imports_region: []const u8, specifier: []const u8) ?[]const u8 {
    // Look for the specifier as a key in the imports object
    const field_region = resolve_mod.findFieldRegion(imports_region, specifier) orelse return null;

    // If the value is a string, return it directly
    if (resolve_mod.extractQuotedString(field_region)) |path| return path;

    // If it's a condition object, try our condition priority
    if (field_region.len > 0 and field_region[0] == '{') {
        // Try conditions in order: import, browser, default
        const conditions = [_][]const u8{ "import", "browser", "default" };
        for (conditions) |cond| {
            if (resolve_mod.findFieldRegion(field_region, cond)) |cond_region| {
                if (resolve_mod.extractQuotedString(cond_region)) |path| return path;
            }
        }
    }

    return null;
}

// ── Relative Import Rewriting for /@modules/ ────────────────────────────────
//
// When serving a file from node_modules via /@modules/pkg, the browser URL
// doesn't match the file's location on disk. Relative imports like "./css-tag.js"
// get resolved by the browser relative to the URL path, not the file path.
//
// Example: /@modules/@lit/reactive-element serves reactive-element.js which has
// `import "./css-tag.js"`. The browser resolves this as /@modules/@lit/css-tag.js
// (wrong). We rewrite it to /@modules/@lit/reactive-element/css-tag.js (correct).
//
// This function scans for from"./..." / import"./..." and rewrites them to
// absolute /@modules/{pkg_name}/{resolved_path} URLs.

fn rewriteRelativeModuleImports(
    allocator: Allocator,
    source: []const u8,
    pkg_name: []const u8,
    file_dir_in_pkg: []const u8,
) ![]const u8 {
    // Quick check: if no relative imports, skip the full scan
    if (std.mem.indexOf(u8, source, "./") == null) return source;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var src = source;
    var pos: usize = 0;
    var found_any = false;

    while (pos < src.len) {
        // Look for "from" keyword followed by a relative specifier
        if (pos + 4 < src.len and std.mem.eql(u8, src[pos .. pos + 4], "from")) {
            if (pos == 0 or !std.ascii.isAlphanumeric(src[pos - 1])) {
                if (tryRewriteRelativeSpec(allocator, &out, &src, &pos, pos + 4, pkg_name, file_dir_in_pkg)) |rewrote| {
                    if (rewrote) {
                        found_any = true;
                        continue;
                    }
                } else |_| {}
            }
        }

        // Look for import"./..." or import './...'
        if (pos + 6 < src.len and std.mem.eql(u8, src[pos .. pos + 6], "import")) {
            if (pos == 0 or !std.ascii.isAlphanumeric(src[pos - 1])) {
                if (tryRewriteRelativeSpec(allocator, &out, &src, &pos, pos + 6, pkg_name, file_dir_in_pkg)) |rewrote| {
                    if (rewrote) {
                        found_any = true;
                        continue;
                    }
                } else |_| {}
            }
        }

        pos += 1;
    }

    if (!found_any) {
        out.deinit(allocator);
        return source;
    }

    try out.appendSlice(allocator, src);
    return out.toOwnedSlice(allocator);
}

/// Try to find and rewrite a relative specifier starting from `after_keyword`.
/// Returns true if a rewrite was performed, false otherwise.
fn tryRewriteRelativeSpec(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    src: *[]const u8,
    pos: *usize,
    after_keyword: usize,
    pkg_name: []const u8,
    file_dir_in_pkg: []const u8,
) !bool {
    var q = after_keyword;
    while (q < src.len and (src.*[q] == ' ' or src.*[q] == '\t')) : (q += 1) {}
    if (q >= src.len) return false;
    if (src.*[q] != '"' and src.*[q] != '\'') return false;

    const quote = src.*[q];
    const spec_start = q + 1;
    const spec_end = std.mem.indexOfScalar(u8, src.*[spec_start..], quote) orelse return false;
    const specifier = src.*[spec_start .. spec_start + spec_end];

    if (!isRelativeSpecifier(specifier)) return false;

    // Resolve the relative path within the package
    var resolved_buf: [2048]u8 = undefined;
    const resolved_path = resolveRelativeInPkg(&resolved_buf, file_dir_in_pkg, specifier);

    try out.appendSlice(allocator, src.*[0..spec_start]);
    try out.appendSlice(allocator, "/@modules/");
    try out.appendSlice(allocator, pkg_name);
    try out.appendSlice(allocator, "/");
    try out.appendSlice(allocator, resolved_path);
    src.* = src.*[spec_start + spec_end ..];
    pos.* = 0;
    return true;
}

/// Check if a specifier is a relative path (starts with ./ or ../).
fn isRelativeSpecifier(specifier: []const u8) bool {
    return std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../");
}

/// Resolve a relative specifier against a directory path within a package.
/// e.g. dir="development", spec="./css-tag.js" → "development/css-tag.js"
/// e.g. dir="", spec="./css-tag.js" → "css-tag.js"
/// e.g. dir="src/lib", spec="../utils.js" → "src/utils.js"
fn resolveRelativeInPkg(buf: *[2048]u8, dir: []const u8, specifier: []const u8) []const u8 {
    var spec = specifier;
    var current_dir = dir;

    // Handle "../" by walking up the directory
    while (std.mem.startsWith(u8, spec, "../")) {
        spec = spec[3..];
        if (std.mem.lastIndexOfScalar(u8, current_dir, '/')) |last_slash| {
            current_dir = current_dir[0..last_slash];
        } else {
            current_dir = ""; // Can't go above package root
        }
    }

    // Strip "./" prefix
    if (std.mem.startsWith(u8, spec, "./")) spec = spec[2..];

    // Combine: current_dir/spec
    if (current_dir.len > 0) {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ current_dir, spec }) catch spec;
    }
    return spec;
}

// ── Platform I/O (Windows ws2_32 safe) ──────────────────────────────────────

fn platformRead(stream: std.net.Stream, buf: []u8) !usize {
    if (builtin.os.tag == .windows) {
        const rc = std.os.windows.ws2_32.recv(stream.handle, buf.ptr, @intCast(buf.len), 0);
        if (rc == std.os.windows.ws2_32.SOCKET_ERROR) {
            return error.ConnectionResetByPeer;
        }
        return @intCast(rc);
    } else {
        return stream.read(buf);
    }
}

/// Non-blocking read for WebSocket polling. Returns 0 if no data available.
fn platformReadNonBlocking(stream: std.net.Stream, buf: []u8) !usize {
    if (builtin.os.tag == .windows) {
        // Set socket to non-blocking temporarily via ioctlsocket
        var mode: c_ulong = 1; // non-blocking
        _ = std.os.windows.ws2_32.ioctlsocket(stream.handle, @bitCast(@as(i32, std.os.windows.ws2_32.FIONBIO)), &mode);
        defer {
            mode = 0; // restore blocking
            _ = std.os.windows.ws2_32.ioctlsocket(stream.handle, @bitCast(@as(i32, std.os.windows.ws2_32.FIONBIO)), &mode);
        }
        const rc = std.os.windows.ws2_32.recv(stream.handle, buf.ptr, @intCast(buf.len), 0);
        if (rc == std.os.windows.ws2_32.SOCKET_ERROR) {
            // WSAEWOULDBLOCK means no data available (not an error)
            return 0;
        }
        return @intCast(rc);
    } else {
        // Use MSG_DONTWAIT on POSIX
        const flags: u32 = 0x40; // MSG_DONTWAIT
        const rc = std.posix.system.recvfrom(stream.handle, buf.ptr, buf.len, flags, null, null);
        if (rc < 0) return 0; // EAGAIN/EWOULDBLOCK
        return @intCast(rc);
    }
}

fn platformWrite(stream: std.net.Stream, data: []const u8) !void {
    if (builtin.os.tag == .windows) {
        var sent: usize = 0;
        while (sent < data.len) {
            const remaining = data[sent..];
            const rc = std.os.windows.ws2_32.send(stream.handle, remaining.ptr, @intCast(remaining.len), 0);
            if (rc == std.os.windows.ws2_32.SOCKET_ERROR) {
                return error.BrokenPipe;
            }
            sent += @intCast(rc);
        }
    } else {
        var sent: usize = 0;
        while (sent < data.len) {
            sent += try stream.write(data[sent..]);
        }
    }
}

// ── Signal handler ──────────────────────────────────────────────────────────

fn shutdownSignal() void {
    if (g_server) |server| {
        server.shutdown();
        std.process.exit(0);
    }
}

// ── HMR Client Script ──────────────────────────────────────────────────────

const wu_hmr_client =
    \\// WU HMR Client — WebSocket first, SSE fallback
    \\(function() {
    \\  var connected = false;
    \\  var fwExts = {svelte:'svelte',react:'jsx',vue:'js',solid:'jsx',preact:'jsx',lit:'js',vanilla:'js',angular:'ts',alpine:'js',qwik:'jsx',stencil:'js',htmx:'js',stimulus:'js'};
    \\
    \\  function onMessage(data) {
    \\    if (data.type === 'connected') {
    \\      connected = true;
    \\      console.log('%c[wu] connected (ws)', 'color: #7c3aed');
    \\    }
    \\    if (data.type === 'css-update') hotCSS(data.app);
    \\    if (data.type === 'app-update') hotApp(data.app, data.dir, data.fw);
    \\    if (data.type === 'full-reload') {
    \\      console.log('%c[wu] full reload', 'color: #7c3aed');
    \\      location.reload();
    \\    }
    \\  }
    \\
    \\  // Try WebSocket first (bidirectional, lower overhead)
    \\  function connectWS() {
    \\    try {
    \\      var ws = new WebSocket('ws://' + location.host + '/__wu_ws');
    \\      ws.onmessage = function(e) {
    \\        try { onMessage(JSON.parse(e.data)); } catch(err) {}
    \\      };
    \\      ws.onclose = function() {
    \\        if (connected) {
    \\          console.log('%c[wu] disconnected, retrying...', 'color: #ef4444');
    \\          connected = false;
    \\        }
    \\        setTimeout(function() { connectWS(); }, 1000);
    \\      };
    \\      ws.onerror = function() { ws.close(); };
    \\    } catch(err) {
    \\      // WebSocket failed → fall back to SSE
    \\      connectSSE();
    \\    }
    \\  }
    \\
    \\  // SSE fallback
    \\  function connectSSE() {
    \\    var es = new EventSource('/__wu_hmr');
    \\    es.onmessage = function(e) {
    \\      try { onMessage(JSON.parse(e.data)); } catch(err) {}
    \\    };
    \\    es.onerror = function() {
    \\      if (connected) {
    \\        console.log('%c[wu] disconnected, retrying...', 'color: #ef4444');
    \\        connected = false;
    \\      }
    \\      setTimeout(function() {
    \\        if (es.readyState === EventSource.CLOSED) location.reload();
    \\      }, 2000);
    \\    };
    \\  }
    \\
    \\  connectWS();
    \\
    \\  function hotCSS(appName) {
    \\    var t = '?t=' + Date.now();
    \\    document.querySelectorAll('link[rel="stylesheet"]').forEach(function(l) {
    \\      l.href = l.href.split('?')[0] + t;
    \\    });
    \\    document.querySelectorAll('[data-wu-app]').forEach(function(el) {
    \\      var s = el.shadowRoot;
    \\      if (s) s.querySelectorAll('link[rel="stylesheet"]').forEach(function(l) {
    \\        l.href = l.href.split('?')[0] + t;
    \\      });
    \\    });
    \\    document.querySelectorAll('style[data-wu-css]').forEach(function(s) {
    \\      var p = s.getAttribute('data-wu-css');
    \\      fetch('/' + p + '?raw&t=' + Date.now()).then(function(r) {
    \\        return r.text();
    \\      }).then(function(css) {
    \\        s.textContent = css;
    \\      });
    \\    });
    \\    console.log('%c[wu] css updated → ' + appName, 'color: #7c3aed');
    \\  }
    \\
    \\  function hotApp(appName, dir, fw) {
    \\    var wu = window.wu;
    \\    var entry = window.__wu_entries && window.__wu_entries[appName];
    \\    if (!entry && dir && fw) {
    \\      entry = '/' + dir + '/src/main.' + (fwExts[fw] || 'js');
    \\    }
    \\    if (!wu || !entry) { location.reload(); return; }
    \\    if (typeof wu.unmount === 'function') {
    \\      Promise.resolve()
    \\        .then(function() { return wu.unmount(appName, { force: true }); })
    \\        .catch(function() {})
    \\        .then(function() {
    \\          wu.definitions.delete(appName);
    \\          if (wu.sandbox && wu.sandbox.sandboxes) wu.sandbox.sandboxes.delete(appName);
    \\          wu.mounted.delete(appName);
    \\          return import(entry + '?t=' + Date.now());
    \\        })
    \\        .then(function() {
    \\          return wu.mount(appName, '#wu-app-' + appName);
    \\        })
    \\        .then(function() {
    \\          console.log('%c[wu] ' + appName + ' hot-reloaded', 'color: #7c3aed');
    \\        })
    \\        .catch(function(err) {
    \\          console.warn('[wu] hot-reload failed for ' + appName + ', falling back', err);
    \\          var container = document.getElementById('wu-app-' + appName);
    \\          var def = wu.definitions && wu.definitions.get(appName);
    \\          if (def && def.mount && container) {
    \\            container.innerHTML = '';
    \\            def.mount(container);
    \\          } else {
    \\            location.reload();
    \\          }
    \\        });
    \\    } else {
    \\      var container = document.getElementById('wu-app-' + appName);
    \\      var oldDef = wu.definitions && wu.definitions.get(appName);
    \\      var oldUnmount = (oldDef && oldDef.unmount) ? oldDef.unmount : null;
    \\      import(entry + '?t=' + Date.now()).then(function() {
    \\        if (oldUnmount && container) {
    \\          try { oldUnmount(container); } catch(e) {}
    \\        }
    \\        if (container) container.innerHTML = '';
    \\        var newDef = wu.definitions && wu.definitions.get(appName);
    \\        if (newDef && newDef.mount && container) {
    \\          newDef.mount(container);
    \\          console.log('%c[wu] ' + appName + ' hot-reloaded', 'color: #7c3aed');
    \\        }
    \\      }).catch(function(err) {
    \\        console.warn('[wu] hot-reload failed for ' + appName, err);
    \\        location.reload();
    \\      });
    \\    }
    \\  }
    \\})();
;

// ── Import Version Stamping (module cache busting) ─────────────────────────

/// Append ?t=<version> to relative import specifiers to bust the browser's
/// ES module cache. Without this, `import './App.jsx'` inside a hot-reloaded
/// entry resolves to the same URL and the browser reuses the stale module.
/// Only modifies relative imports (./  ../) that don't already have a query.
fn versionRelativeImports(allocator: Allocator, source: []const u8, version: u64) ![]const u8 {
    // No version yet → return original slice (no allocation)
    if (version == 0) return source;

    // Format version suffix once
    var vbuf: [32]u8 = undefined;
    const vsuffix = std.fmt.bufPrint(&vbuf, "?t={d}", .{version}) catch return source;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var src = source;
    var pos: usize = 0;
    var found_any = false;

    while (pos < src.len) {
        // Look for 'from' keyword: from './path' or from "../path"
        if (pos + 4 < src.len and std.mem.eql(u8, src[pos .. pos + 4], "from")) {
            if (pos == 0 or !std.ascii.isAlphanumeric(src[pos - 1])) {
                if (tryStampImport(allocator, &out, src, pos + 4, vsuffix)) |rest| {
                    src = rest;
                    pos = 0;
                    found_any = true;
                    continue;
                }
            }
        }

        // Look for 'import' keyword: import './path' or import('./path')
        if (pos + 6 < src.len and std.mem.eql(u8, src[pos .. pos + 6], "import")) {
            if (pos == 0 or !std.ascii.isAlphanumeric(src[pos - 1])) {
                var q = pos + 6;
                while (q < src.len and (src[q] == ' ' or src[q] == '\t')) : (q += 1) {}

                if (q < src.len and (src[q] == '"' or src[q] == '\'')) {
                    // Static side-effect import: import './path'
                    if (tryStampImport(allocator, &out, src, pos + 6, vsuffix)) |rest| {
                        src = rest;
                        pos = 0;
                        found_any = true;
                        continue;
                    }
                } else if (q < src.len and src[q] == '(') {
                    // Dynamic import: import('./path')
                    if (tryStampImport(allocator, &out, src, q + 1, vsuffix)) |rest| {
                        src = rest;
                        pos = 0;
                        found_any = true;
                        continue;
                    }
                }
            }
        }

        pos += 1;
    }

    if (!found_any) {
        out.deinit(allocator);
        return source; // No relative imports found — return original (no allocation)
    }

    try out.appendSlice(allocator, src);
    return out.toOwnedSlice(allocator);
}

/// Helper: given a position after 'from'/'import'/import(, skip whitespace,
/// find a quoted relative specifier without existing query, and stamp it.
/// Returns remaining source after the specifier, or null if not applicable.
fn tryStampImport(allocator: Allocator, out: *std.ArrayList(u8), src: []const u8, after: usize, vsuffix: []const u8) ?[]const u8 {
    var q = after;
    while (q < src.len and (src[q] == ' ' or src[q] == '\t')) : (q += 1) {}
    if (q >= src.len) return null;
    const quote = src[q];
    if (quote != '"' and quote != '\'') return null;
    const spec_start = q + 1;
    const spec_end_rel = std.mem.indexOfScalar(u8, src[spec_start..], quote) orelse return null;
    const specifier = src[spec_start .. spec_start + spec_end_rel];

    // Only stamp relative imports without existing query params
    if (!std.mem.startsWith(u8, specifier, "./") and !std.mem.startsWith(u8, specifier, "../")) return null;
    if (std.mem.indexOfScalar(u8, specifier, '?') != null) return null;

    // Emit everything up to end of specifier, then append version
    out.appendSlice(allocator, src[0 .. spec_start + spec_end_rel]) catch return null;
    out.appendSlice(allocator, vsuffix) catch return null;

    return src[spec_start + spec_end_rel ..];
}

// ── Struct type for file watcher (must be at module scope) ──────────────────

const WatchEntry = struct {
    hash: u64,
    mtime: i128,
    generation: u32 = 0,
};

// ── URL Decoding ────────────────────────────────────────────────────────────

/// Decode %XX sequences in a URL path. Returns a slice into `buf`.
fn urlDecode(input: []const u8, buf: *[4096]u8) []const u8 {
    var i: usize = 0;
    var o: usize = 0;
    while (i < input.len and o < buf.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = hexVal(input[i + 1]);
            const lo = hexVal(input[i + 2]);
            if (hi != null and lo != null) {
                buf[o] = (@as(u8, hi.?) << 4) | @as(u8, lo.?);
                o += 1;
                i += 3;
                continue;
            }
        }
        buf[o] = input[i];
        o += 1;
        i += 1;
    }
    return buf[0..o];
}

fn hexVal(c: u8) ?u4 {
    if (c >= '0' and c <= '9') return @intCast(c - '0');
    if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
    return null;
}
