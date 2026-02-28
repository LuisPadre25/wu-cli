// WU Runtime — Framework Compilation
//
// Three-tier compilation strategy:
//   1. Native Zig (fastest): pure-Zig JSX transform + TS strip, ~0-2ms per file
//   2. Compiler Daemon (fast): persistent Node.js process, ~10-50ms per file
//   3. Fallback node -e (slow): spawns new process, ~200-400ms per file
//
// Tier 1 handles .jsx/.tsx for React and Preact natively — zero Node.js needed.
// Tiers 2-3 handle .svelte, .vue, and Solid (which needs babel-preset-solid).
//
// The daemon stays alive for the entire wu dev session. On first compile,
// it writes .wu-cache/wu-compiler.cjs and spawns `node` once. All subsequent
// compilations reuse that process — no Node startup overhead.

const std = @import("std");
const Allocator = std.mem.Allocator;
const jsx_transform = @import("jsx_transform.zig");

pub const CompileError = error{
    CompilerNotFound,
    CompileFailed,
    OutOfMemory,
    PathTooLong,
    SpawnFailed,
};

/// Check if a file extension needs framework compilation.
pub fn needsCompile(ext: []const u8) bool {
    const eql = std.mem.eql;
    return eql(u8, ext, ".jsx") or eql(u8, ext, ".tsx") or
        eql(u8, ext, ".svelte") or eql(u8, ext, ".vue") or
        eql(u8, ext, ".ts");
}

/// Compile a source file using the framework's own compiler.
/// Tries the persistent daemon first (fast), falls back to node -e (slow).
/// Returns allocator-owned compiled JavaScript.
pub fn compileFile(
    allocator: Allocator,
    source: []const u8,
    file_path: []const u8,
    app_dir: []const u8,
    framework: []const u8,
) CompileError![]const u8 {
    const ext = std.fs.path.extension(file_path);
    const eql = std.mem.eql;
    const filename = std.fs.path.basename(file_path);

    // Determine daemon compile type and options
    if (eql(u8, ext, ".svelte")) {
        return daemonCompile(allocator, "svelte", filename, "", "", source) catch
            compileSvelteFallback(allocator, source, file_path, app_dir);
    }
    if (eql(u8, ext, ".vue")) {
        return daemonCompile(allocator, "vue", filename, "", "", source) catch
            compileVueFallback(allocator, source, file_path, app_dir);
    }
    if (eql(u8, ext, ".ts")) {
        if (eql(u8, framework, "angular")) {
            // Angular needs full bundling (esbuild bundle) to resolve circular deps
            // between @angular/compiler and @angular/core. Pass file directory as
            // resolveDir so esbuild can find node_modules and local imports.
            const file_dir = std.fs.path.dirname(file_path) orelse app_dir;
            return daemonCompile(allocator, "angular-bundle", filename, "ts", file_dir, source) catch
                compileJsxFallback(allocator, source, ext, app_dir, framework);
        }
        // Regular TypeScript files (decorators need esbuild transform)
        return daemonCompile(allocator, "ts", filename, "ts", "", source) catch
            compileJsxFallback(allocator, source, ext, app_dir, framework);
    }
    if (eql(u8, ext, ".jsx") or eql(u8, ext, ".tsx")) {
        const is_tsx = eql(u8, ext, ".tsx");
        const loader = if (is_tsx) "tsx" else "jsx";

        // Solid needs babel-preset-solid → must use daemon/node
        if (eql(u8, framework, "solid")) {
            return daemonCompile(allocator, "solid", filename, loader, "", source) catch
                compileJsxFallback(allocator, source, ext, app_dir, framework);
        }

        // Qwik needs its optimizer to transform $() into QRLs — type 'qwik'
        if (eql(u8, framework, "qwik")) {
            return daemonCompile(allocator, "qwik", filename, loader, "", source) catch
                compileJsxFallback(allocator, source, ext, app_dir, framework);
        }

        // React & Preact: try native Zig JSX transform first (zero Node.js!)
        if (jsx_transform.compileJsxNative(allocator, source, framework, is_tsx)) |native_result| {
            return native_result;
        } else |_| {
            // Native failed → fall back to daemon → node -e
            if (eql(u8, framework, "preact")) {
                return daemonCompile(allocator, "jsx", filename, loader, "preact", source) catch
                    compileJsxFallback(allocator, source, ext, app_dir, framework);
            }
            return daemonCompile(allocator, "jsx", filename, loader, "", source) catch
                compileJsxFallback(allocator, source, ext, app_dir, framework);
        }
    }

    return allocator.dupe(u8, source) catch return CompileError.OutOfMemory;
}

/// Shutdown the compiler daemon (call on server exit).
pub fn shutdownDaemon() void {
    g_daemon_mutex.lock();
    defer g_daemon_mutex.unlock();
    killDaemonLocked();
}

// ── Compiler Daemon ─────────────────────────────────────────────────────────
//
// Protocol (binary, tab-delimited header + raw source bytes):
//   Request:  COMPILE\t{type}\t{filename}\t{loader}\t{jsxSource}\t{sourceLen}\n{rawSource}
//   Response: OK\t{codeLen}\n{rawCode}   or   ERR\t{message}\n

const daemon_script = @embedFile("compiler_daemon.js");

const DaemonState = struct {
    stdin: std.fs.File,
    stdout: std.fs.File,
    child: std.process.Child,
};

var g_daemon: ?DaemonState = null;
var g_daemon_mutex: std.Thread.Mutex = .{};

fn daemonCompile(
    allocator: Allocator,
    compile_type: []const u8,
    filename: []const u8,
    loader: []const u8,
    jsx_source: []const u8,
    source: []const u8,
) CompileError![]const u8 {
    g_daemon_mutex.lock();
    defer g_daemon_mutex.unlock();

    // Lazy spawn
    if (g_daemon == null) {
        if (!spawnDaemon(allocator)) return CompileError.SpawnFailed;
    }

    const d = &(g_daemon orelse return CompileError.SpawnFailed);

    // Send: COMPILE\t{type}\t{filename}\t{loader}\t{jsxSource}\t{sourceLen}\n
    var header_buf: [1024]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "COMPILE\t{s}\t{s}\t{s}\t{s}\t{d}\n", .{
        compile_type, filename, loader, jsx_source, source.len,
    }) catch return CompileError.PathTooLong;

    d.stdin.writeAll(header) catch {
        killDaemonLocked();
        return CompileError.CompileFailed;
    };
    d.stdin.writeAll(source) catch {
        killDaemonLocked();
        return CompileError.CompileFailed;
    };

    // Read response header line: "OK\t{len}\n" or "ERR\t{msg}\n"
    var resp_buf: [256]u8 = undefined;
    var resp_pos: usize = 0;
    while (resp_pos < resp_buf.len) {
        var byte_buf: [1]u8 = undefined;
        const n = d.stdout.read(&byte_buf) catch {
            killDaemonLocked();
            return CompileError.CompileFailed;
        };
        if (n == 0) {
            killDaemonLocked();
            return CompileError.CompileFailed;
        }
        if (byte_buf[0] == '\n') break;
        resp_buf[resp_pos] = byte_buf[0];
        resp_pos += 1;
    }
    const resp_line = resp_buf[0..resp_pos];

    if (std.mem.startsWith(u8, resp_line, "OK\t")) {
        const code_len = std.fmt.parseInt(usize, resp_line[3..], 10) catch {
            killDaemonLocked();
            return CompileError.CompileFailed;
        };
        if (code_len == 0) return CompileError.CompileFailed;

        const code = allocator.alloc(u8, code_len) catch return CompileError.OutOfMemory;
        var total: usize = 0;
        while (total < code_len) {
            const n = d.stdout.read(code[total..]) catch {
                allocator.free(code);
                killDaemonLocked();
                return CompileError.CompileFailed;
            };
            if (n == 0) {
                allocator.free(code);
                killDaemonLocked();
                return CompileError.CompileFailed;
            }
            total += n;
        }
        return code;
    }

    // ERR or unexpected response
    return CompileError.CompileFailed;
}

fn spawnDaemon(allocator: Allocator) bool {
    // Write daemon script to .wu-cache/
    std.fs.cwd().makePath(".wu-cache") catch {};
    if (std.fs.cwd().createFile(".wu-cache/wu-compiler.cjs", .{})) |file| {
        file.writeAll(daemon_script) catch {};
        file.close();
    } else |_| {}

    const argv = [_][]const u8{ "node", ".wu-cache/wu-compiler.cjs" };

    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch return false;

    const stdin = child.stdin orelse {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return false;
    };
    const stdout = child.stdout orelse {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return false;
    };

    g_daemon = .{
        .stdin = stdin,
        .stdout = stdout,
        .child = child,
    };

    std.debug.print("  \x1b[2mcompiler daemon started (persistent node process)\x1b[0m\n", .{});
    return true;
}

fn killDaemonLocked() void {
    if (g_daemon) |*d| {
        // Kill the child — don't manually close stdin because wait()
        // calls cleanupStreams() which closes all pipes. Closing twice
        // panics on Windows (CloseHandle asserts on invalid handle).
        _ = d.child.kill() catch {};
        _ = d.child.wait() catch {};
    }
    g_daemon = null;
}

// ── Fallback: node -e (used when daemon is unavailable) ─────────────────────

fn compileJsxFallback(
    allocator: Allocator,
    source: []const u8,
    ext: []const u8,
    app_dir: []const u8,
    framework: []const u8,
) CompileError![]const u8 {
    const loader = if (std.mem.eql(u8, ext, ".tsx")) "tsx" else "jsx";
    const eql = std.mem.eql;

    var script_buf: [1024]u8 = undefined;

    const script = if (eql(u8, framework, "preact"))
        std.fmt.bufPrint(&script_buf,
            "const s=require('fs').readFileSync(0,'utf8');" ++
                "const r=require('esbuild').transformSync(s,{{loader:'{s}',jsx:'automatic',jsxImportSource:'preact',format:'esm'}});" ++
                "process.stdout.write(r.code)",
            .{loader},
        ) catch return CompileError.PathTooLong
    else if (eql(u8, framework, "solid"))
        std.fmt.bufPrint(&script_buf,
            "const s=require('fs').readFileSync(0,'utf8');" ++
                "const r=require('@babel/core').transformSync(s,{{presets:['babel-preset-solid'],filename:'App.{s}'}});" ++
                "process.stdout.write(r.code)",
            .{loader},
        ) catch return CompileError.PathTooLong
    else
        std.fmt.bufPrint(&script_buf,
            "const s=require('fs').readFileSync(0,'utf8');" ++
                "const r=require('esbuild').transformSync(s,{{loader:'{s}',jsx:'automatic',format:'esm'}});" ++
                "process.stdout.write(r.code)",
            .{loader},
        ) catch return CompileError.PathTooLong;

    return runNodeTransform(allocator, script, source, app_dir);
}

fn compileSvelteFallback(
    allocator: Allocator,
    source: []const u8,
    file_path: []const u8,
    app_dir: []const u8,
) CompileError![]const u8 {
    const filename = std.fs.path.basename(file_path);

    var script_buf: [1024]u8 = undefined;
    const script = std.fmt.bufPrint(&script_buf,
        "const s=require('fs').readFileSync(0,'utf8');" ++
            "const r=require('svelte/compiler').compile(s,{{generate:'client',filename:'{s}'}});" ++
            "process.stdout.write(r.js.code)",
        .{filename},
    ) catch return CompileError.PathTooLong;

    return runNodeTransform(allocator, script, source, app_dir);
}

fn compileVueFallback(
    allocator: Allocator,
    source: []const u8,
    file_path: []const u8,
    app_dir: []const u8,
) CompileError![]const u8 {
    const filename = std.fs.path.basename(file_path);

    var script_buf: [2048]u8 = undefined;
    const script = std.fmt.bufPrint(&script_buf,
        "const s=require('fs').readFileSync(0,'utf8');" ++
            "const C=require('@vue/compiler-sfc');" ++
            "const{{descriptor:d}}=C.parse(s,{{filename:'{s}'}});" ++
            "let sc='',tp='',bindings={{}};" ++
            "if(d.scriptSetup||d.script){{const r=C.compileScript(d,{{id:'wu'}});sc=r.content.replace(/export\\s+default\\s+/,'const __sfc__=');bindings=r.bindings||{{}};}}" ++
            "if(d.template){{tp=C.compileTemplate({{source:d.template.content,filename:'{s}',id:'wu',compilerOptions:{{bindingMetadata:bindings}}}}).code;}}" ++
            "let o=sc+'\\n'+tp+'\\n';" ++
            "o+=sc?'__sfc__.render=render;\\nexport default __sfc__;':'export default{{render}};';" ++
            "process.stdout.write(o)",
        .{ filename, filename },
    ) catch return CompileError.PathTooLong;

    return runNodeTransform(allocator, script, source, app_dir);
}

fn runNodeTransform(
    allocator: Allocator,
    script: []const u8,
    source: []const u8,
    cwd: []const u8,
) CompileError![]const u8 {
    const argv = [_][]const u8{ "node", "-e", script };

    var child = std.process.Child.init(&argv, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch return CompileError.SpawnFailed;

    // Write source to stdin, then close (signals EOF to child)
    if (child.stdin) |stdin| {
        stdin.writeAll(source) catch {};
        stdin.close();
    }
    child.stdin = null;

    // Read compiled output from stdout
    const max_output = 8 * 1024 * 1024;
    const output = if (child.stdout) |stdout|
        stdout.readToEndAlloc(allocator, max_output) catch {
            _ = child.wait() catch {};
            return CompileError.CompileFailed;
        }
    else {
        _ = child.wait() catch {};
        return CompileError.CompilerNotFound;
    };

    _ = child.wait() catch {};

    if (output.len == 0) {
        allocator.free(output);
        return CompileError.CompileFailed;
    }

    return output;
}
