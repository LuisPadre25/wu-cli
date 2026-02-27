// WU CLI — Process Supervisor
//
// Manages N child processes (Vite dev servers) simultaneously.
// Handles startup, shutdown, status reporting, and Ctrl+C graceful cleanup.
// Pattern inspired by FORJA's DAG executor.

const std = @import("std");
const Allocator = std.mem.Allocator;
const process_mod = @import("process.zig");
const ManagedProcess = process_mod.ManagedProcess;
const signals = @import("../util/signals.zig");
const ansi = @import("../util/ansi.zig");

var g_supervisor: ?*Supervisor = null;

pub const Supervisor = struct {
    processes: std.ArrayList(ManagedProcess),
    allocator: Allocator,
    running: bool = false,

    pub fn init(allocator: Allocator) Supervisor {
        return .{
            .processes = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Supervisor) void {
        self.stopAll();
        self.processes.deinit(self.allocator);
    }

    /// Add a process to be managed.
    pub fn addProcess(self: *Supervisor, proc: ManagedProcess) !void {
        try self.processes.append(self.allocator, proc);
    }

    /// Start all managed processes. Prints status table.
    pub fn startAll(self: *Supervisor) !void {
        self.running = true;

        // Install signal handler for graceful shutdown
        g_supervisor = self;
        signals.install(shutdownCallback);

        _ = .{}; // stdout replaced with std.debug.print

        std.debug.print("\n  {s}WU Dev Server{s}\n\n", .{ ansi.bold, ansi.reset });

        // Start each process
        for (self.processes.items) |*proc| {
            proc.start() catch |err| {
                std.debug.print("  {s}✗{s} {s}{s}{s} — failed to start: {}\n", .{
                    ansi.red,    ansi.reset,
                    proc.color,  proc.name,
                    ansi.reset,  err,
                });
                continue;
            };

            std.debug.print("  {s}●{s} {s}{s}{s}  {s}{s}{s}  :{d}\n", .{
                ansi.green,     ansi.reset,
                proc.color,     proc.name,
                ansi.reset,     ansi.dim,
                proc.framework, ansi.reset,
                proc.port,
            });
        }

        std.debug.print("\n  {s}Press Ctrl+C to stop all.{s}\n\n", .{
            ansi.dim, ansi.reset,
        });
    }

    /// Stop all managed processes.
    pub fn stopAll(self: *Supervisor) void {
        if (!self.running) return;
        self.running = false;

        _ = .{}; // stdout replaced with std.debug.print
        std.debug.print("\n\n  {s}Shutting down...{s}\n", .{
            ansi.yellow, ansi.reset,
        });

        for (self.processes.items) |*proc| {
            if (proc.isAlive()) {
                proc.killTree();
                std.debug.print("  {s}■{s} {s}{s}{s} stopped\n", .{
                    ansi.dim,   ansi.reset,
                    proc.color, proc.name,
                    ansi.reset,
                });
            }
        }

        std.debug.print("\n  {s}All processes stopped.{s}\n\n", .{
            ansi.green, ansi.reset,
        });
    }

    /// Block until all processes exit or Ctrl+C.
    pub fn wait(self: *Supervisor) void {
        while (self.running) {
            // Check if any process has died
            var all_dead = true;
            for (self.processes.items) |*proc| {
                if (proc.isAlive()) {
                    all_dead = false;
                }
            }
            if (all_dead and self.processes.items.len > 0) {
                self.running = false;
                break;
            }
            std.Thread.sleep(500 * std.time.ns_per_ms);
        }
    }

    /// Print a status table of all managed processes.
    pub fn printStatus(self: *const Supervisor) !void {
        _ = .{}; // stdout replaced with std.debug.print

        std.debug.print("\n  {s}App{s}              {s}Framework{s}   {s}Port{s}    {s}Status{s}\n", .{
            ansi.bold, ansi.reset,
            ansi.bold, ansi.reset,
            ansi.bold, ansi.reset,
            ansi.bold, ansi.reset,
        });
        std.debug.print("  {s}──────────────────────────────────────────────{s}\n", .{
            ansi.dim, ansi.reset,
        });

        for (self.processes.items) |*proc| {
            std.debug.print("  {s}{s}{s} {s}{s}{s} {s}:{d}{s}  {s}{s}{s}\n", .{
                proc.color, proc.name, ansi.reset,
                ansi.dim, proc.framework, ansi.reset,
                ansi.cyan, proc.port, ansi.reset,
                proc.stateColor(), proc.stateStr(), ansi.reset,
            });
        }
        std.debug.print("\n", .{});
    }
};

fn shutdownCallback() void {
    if (g_supervisor) |sup| {
        sup.stopAll();
        std.process.exit(0);
    }
}
