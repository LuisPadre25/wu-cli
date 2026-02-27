// WU Runtime — Two-Level Compilation Cache
//
// Level 1: Fixed-size (256-entry) in-memory round-robin cache.
// Level 2: Persistent disk cache in .wu-cache/ directory.
//
// Flow:
//   get() → memory hit → return
//   get() → memory miss → disk hit → promote to memory → return
//   get() → both miss → null
//   put() → write to memory + write to disk
//
// Disk format per entry: .wu-cache/{hex_hash}.dat
//   Line 1: mtime as decimal i128
//   Rest: compiled/transformed content
//
// Survives server restarts — eliminates cold-start compilation penalty.
// First restart with warm cache: ~1-5ms per module vs 200-400ms cold.
// Thread-safe via single mutex. Caller owns memory returned by get().

const std = @import("std");
const Allocator = std.mem.Allocator;

const MAX = 256;
const CACHE_DIR = ".wu-cache";

const Entry = struct {
    hash: u64,
    mtime: i128,
    compiled: []const u8,
    occupied: bool,
};

pub const CompileCache = struct {
    allocator: Allocator,
    entries: [MAX]Entry,
    next_evict: usize,
    mutex: std.Thread.Mutex,
    disk_ready: bool,

    pub fn init(allocator: Allocator) CompileCache {
        // Create disk cache directory (best-effort, non-fatal on failure)
        const disk_ok = blk: {
            std.fs.cwd().makePath(CACHE_DIR) catch break :blk false;
            break :blk true;
        };

        return .{
            .allocator = allocator,
            .entries = [_]Entry{.{
                .hash = 0,
                .mtime = 0,
                .compiled = &.{},
                .occupied = false,
            }} ** MAX,
            .next_evict = 0,
            .mutex = .{},
            .disk_ready = disk_ok,
        };
    }

    pub fn deinit(self: *CompileCache) void {
        for (&self.entries) |*entry| {
            if (entry.occupied) {
                self.allocator.free(entry.compiled);
                entry.occupied = false;
            }
        }
    }

    /// Look up a compiled result. Returns an allocator-owned dupe — caller must free.
    /// Returns null on miss or stale mtime.
    /// Checks memory first, then disk. Promotes disk hits to memory.
    pub fn get(self: *CompileCache, file_path: []const u8, mtime: i128) ?[]const u8 {
        const h = hashPath(file_path);

        self.mutex.lock();
        defer self.mutex.unlock();

        // Level 1: in-memory
        for (&self.entries) |*entry| {
            if (!entry.occupied or entry.hash != h) continue;
            if (entry.mtime != mtime) return null; // stale
            return self.allocator.dupe(u8, entry.compiled) catch null;
        }

        // Level 2: disk — survives restarts
        if (self.disk_ready) {
            if (self.diskGet(h, mtime)) |content| {
                // Promote to in-memory for subsequent hits
                self.putMemoryLocked(h, mtime, content);
                return content;
            }
        }

        return null;
    }

    /// Store a compiled result. Writes to both memory and disk.
    /// The cache dupes the slice and owns the copy.
    pub fn put(self: *CompileCache, file_path: []const u8, mtime: i128, compiled: []const u8) void {
        const h = hashPath(file_path);

        self.mutex.lock();
        defer self.mutex.unlock();

        self.putMemoryLocked(h, mtime, compiled);
        self.diskPut(h, mtime, compiled);
    }

    // ── Private: Memory ────────────────────────────────────────────────────

    /// Store in memory. Must be called with mutex held.
    fn putMemoryLocked(self: *CompileCache, h: u64, mtime: i128, compiled: []const u8) void {
        const owned = self.allocator.dupe(u8, compiled) catch return;

        // Update existing entry for this hash
        for (&self.entries) |*entry| {
            if (!entry.occupied or entry.hash != h) continue;
            self.allocator.free(entry.compiled);
            entry.mtime = mtime;
            entry.compiled = owned;
            return;
        }

        // New entry — evict round-robin slot
        const slot = &self.entries[self.next_evict];
        if (slot.occupied) {
            self.allocator.free(slot.compiled);
        }
        slot.* = .{
            .hash = h,
            .mtime = mtime,
            .compiled = owned,
            .occupied = true,
        };
        self.next_evict = (self.next_evict + 1) % MAX;
    }

    // ── Private: Disk ──────────────────────────────────────────────────────

    /// Read from disk cache. Returns allocator-owned content or null.
    fn diskGet(self: *CompileCache, h: u64, mtime: i128) ?[]const u8 {
        var name_buf: [48]u8 = undefined;
        const name = diskPath(&name_buf, h) orelse return null;

        const file = std.fs.cwd().openFile(name, .{}) catch return null;
        defer file.close();

        // Read entire file (mtime header + content)
        const data = file.readToEndAlloc(self.allocator, 16 * 1024 * 1024) catch return null;

        // Parse header: first line is mtime as decimal i128
        const newline = std.mem.indexOfScalar(u8, data, '\n') orelse {
            self.allocator.free(data);
            return null;
        };

        const stored_mtime = std.fmt.parseInt(i128, data[0..newline], 10) catch {
            self.allocator.free(data);
            return null;
        };

        if (stored_mtime != mtime) {
            self.allocator.free(data);
            return null; // stale — file changed since last cache write
        }

        // Extract content (everything after the mtime line)
        const content = self.allocator.dupe(u8, data[newline + 1 ..]) catch {
            self.allocator.free(data);
            return null;
        };
        self.allocator.free(data);
        return content;
    }

    /// Write to disk cache. Best-effort — errors silently ignored.
    fn diskPut(self: *CompileCache, h: u64, mtime: i128, compiled: []const u8) void {
        if (!self.disk_ready) return;

        var name_buf: [48]u8 = undefined;
        const name = diskPath(&name_buf, h) orelse return;

        const file = std.fs.cwd().createFile(name, .{}) catch return;
        defer file.close();

        // Write mtime header line
        var mtime_buf: [48]u8 = undefined;
        const mtime_str = std.fmt.bufPrint(&mtime_buf, "{d}\n", .{mtime}) catch return;
        file.writeAll(mtime_str) catch return;

        // Write compiled content
        file.writeAll(compiled) catch return;
    }

    /// Generate disk cache file path: .wu-cache/{hex_hash}.dat
    fn diskPath(buf: *[48]u8, h: u64) ?[]const u8 {
        const hex = "0123456789abcdef";
        const prefix = CACHE_DIR ++ "/";
        const suffix = ".dat";

        if (prefix.len + 16 + suffix.len > buf.len) return null;

        @memcpy(buf[0..prefix.len], prefix);
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            const shift: u6 = @intCast(60 - i * 4);
            const nibble: usize = @intCast((h >> shift) & 0xf);
            buf[prefix.len + i] = hex[nibble];
        }
        @memcpy(buf[prefix.len + 16 ..][0..suffix.len], suffix);
        return buf[0 .. prefix.len + 16 + suffix.len];
    }

    /// Hash a file path to a u64 using Wyhash.
    pub fn hashPath(path: []const u8) u64 {
        return std.hash.Wyhash.hash(0, path);
    }
};
