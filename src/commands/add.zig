// WU CLI — `wu add` Command
//
// Add a new micro-app to an existing wu project.
// Generates framework-specific files, updates root package.json,
// and runs npm install automatically.
//
// Usage:
//   wu add react header        → creates mf-header/ with React setup
//   wu add vue sidebar          → creates mf-sidebar/ with Vue setup

const std = @import("std");
const Allocator = std.mem.Allocator;
const config_mod = @import("../config/config.zig");
const ansi = @import("../util/ansi.zig");
const create = @import("create.zig");

pub fn run(allocator: Allocator, args: *std.process.ArgIterator) !void {
    const framework = args.next() orelse {
        std.debug.print("  {s}Usage:{s} wu add {s}<framework> <name>{s}\n\n", .{
            ansi.bold, ansi.reset, ansi.cyan, ansi.reset,
        });
        std.debug.print("  {s}Frameworks:{s} react, vue, svelte, solid, preact, lit, angular, vanilla,\n             alpine, qwik, stencil, htmx, stimulus\n\n", .{
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
        "alpine", "qwik", "stencil", "htmx", "stimulus",
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
    defer cfg.deinit(allocator);
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

    // Build MicroApp and generate all framework-specific files
    var micro_app = create.MicroApp{
        .framework = framework,
        .port = next_port,
    };
    const copy_len = @min(app_name.len, micro_app.name_buf.len);
    @memcpy(micro_app.name_buf[0..copy_len], app_name[0..copy_len]);
    micro_app.name_len = copy_len;

    // Generate app in current directory (project = ".")
    create.generateApp(allocator, ".", &micro_app) catch |err| {
        std.debug.print("  {s}Error generating app: {s}{s}\n", .{
            ansi.red, @errorName(err), ansi.reset,
        });
        return;
    };

    // Update wu.config.json if it exists
    if (cfg.from_file) {
        var new_apps: std.ArrayList(config_mod.AppConfig) = .empty;
        defer new_apps.deinit(allocator);
        for (cfg.apps) |app| {
            // Skip existing entry with same directory (will be replaced)
            if (std.mem.eql(u8, app.dir, dir_name)) continue;
            try new_apps.append(allocator, app);
        }
        try new_apps.append(allocator, .{
            .name = app_name,
            .dir = dir_name,
            .framework = framework,
            .port = next_port,
        });
        if (cfg._apps_owned and cfg.apps.len > 0) {
            allocator.free(cfg.apps);
        }
        cfg.apps = try new_apps.toOwnedSlice(allocator);
        cfg._apps_owned = true;
        config_mod.writeConfig(allocator, &cfg) catch {};
    }

    // Rebuild root package.json with merged dependencies (all apps + new one)
    {
        var all_micro_apps: std.ArrayList(create.MicroApp) = .empty;
        defer all_micro_apps.deinit(allocator);

        // Convert existing config apps to MicroApp structs
        for (cfg.apps) |app| {
            var ma = create.MicroApp{
                .framework = app.framework,
                .port = app.port,
            };
            const len = @min(app.name.len, ma.name_buf.len);
            @memcpy(ma.name_buf[0..len], app.name[0..len]);
            ma.name_len = len;
            try all_micro_apps.append(allocator, ma);
        }

        // "." because wu add runs from INSIDE the project directory
        const project_name = if (cfg.name.len > 0) cfg.name else "wu-project";
        create.generateRootPackageJsonNamed(allocator, ".", project_name, all_micro_apps.items) catch {};
    }

    std.debug.print("\n  {s}✓ Created {s}/{s}\n", .{
        ansi.green, dir_name, ansi.reset,
    });

    // Install dependencies at project root
    std.debug.print("\n  {s}Installing dependencies...{s}\n", .{ ansi.dim, ansi.reset });
    create.runNpmInstall(allocator, ".", "dependencies");

    std.debug.print("\n  {s}Ready!{s} Run {s}wu dev{s} to start.\n\n", .{
        ansi.green, ansi.reset, ansi.cyan, ansi.reset,
    });
}
