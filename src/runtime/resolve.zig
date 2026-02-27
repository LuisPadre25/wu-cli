// WU Runtime — Native NPM Module Resolution
//
// Replaces esbuild subprocess calls with pure Zig resolution.
// Inspired by Node.js resolution algorithm and Parcel 2's resolver.
//
// The core insight: module resolution is a tree search problem.
// Package name extraction is lexical. Exports maps are priority queues.
// File probing is directory traversal. None of this needs a bundler.
//
// Given "vue" or "@angular/core" or "wu-framework/adapters/vanilla",
// walk node_modules directories, parse package.json exports/module/main,
// and return the file path on disk. No subprocess. No JavaScript runtime.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;

// ── Public Types ────────────────────────────────────────────────────────────

pub const ResolvedModule = struct {
    /// Absolute or relative file path to the resolved entry point.
    file_path: []const u8,
    /// Path to the package directory (containing package.json).
    package_dir: []const u8,
    /// Whether the package declares itself ESM ("type": "module" or resolved via "module"/"import").
    is_esm: bool,
};

pub const ResolveError = error{
    PackageNotFound,
    EntryPointNotFound,
    PackageJsonMalformed,
    PathTooLong,
    OutOfMemory,
};

// ── Public API ──────────────────────────────────────────────────────────────

/// Resolve a bare npm specifier to a file on disk.
///
/// `specifier`   — e.g. "react", "@angular/core", "wu-framework/adapters/vanilla"
/// `search_dirs` — directories to probe for node_modules/ (e.g. app dirs, shell dir, ".")
///
/// Returns an allocator-owned ResolvedModule (caller must free both slices),
/// or null if the package cannot be found.
pub fn resolveModule(
    allocator: Allocator,
    specifier: []const u8,
    search_dirs: []const []const u8,
) ResolveError!?ResolvedModule {
    if (specifier.len == 0) return null;

    const pkg_name = extractPackageName(specifier);
    const subpath = extractSubpath(specifier, pkg_name);

    // Walk search directories looking for node_modules/{pkg_name}/package.json
    for (search_dirs) |dir| {
        var pkg_dir_buf: [1024]u8 = undefined;
        const pkg_dir = std.fmt.bufPrint(&pkg_dir_buf, "{s}/node_modules/{s}", .{ dir, pkg_name }) catch
            return ResolveError.PathTooLong;

        // Check that package.json exists and read it
        const pkg_json_content = readPackageJson(allocator, pkg_dir) orelse continue;
        defer allocator.free(pkg_json_content);

        // Detect ESM from "type" field
        const type_is_module = detectTypeModule(pkg_json_content);

        // Try to resolve the entry point
        if (resolveEntryPoint(allocator, pkg_dir, pkg_json_content, subpath)) |entry| {
            const is_esm = type_is_module or entry.resolved_via_esm;
            const full_path = entry.path;

            // Verify the resolved file actually exists on disk
            if (!fileExists(full_path)) {
                allocator.free(full_path);
                allocator.free(entry.owned_pkg_dir);
                continue;
            }

            return ResolvedModule{
                .file_path = full_path,
                .package_dir = entry.owned_pkg_dir,
                .is_esm = is_esm,
            };
        }
    }

    // Second pass: workspace resolution — try {dir}/{pkg_name}/package.json directly
    // (without the node_modules segment). This allows search_dirs like "../.."
    // to find workspace packages such as ../../wu-framework/package.json.
    for (search_dirs) |dir| {
        var pkg_dir_buf: [1024]u8 = undefined;
        const pkg_dir = std.fmt.bufPrint(&pkg_dir_buf, "{s}/{s}", .{ dir, pkg_name }) catch
            return ResolveError.PathTooLong;

        // Check that package.json exists and read it
        const pkg_json_content = readPackageJson(allocator, pkg_dir) orelse continue;
        defer allocator.free(pkg_json_content);

        // Detect ESM from "type" field
        const type_is_module = detectTypeModule(pkg_json_content);

        // Try to resolve the entry point
        if (resolveEntryPoint(allocator, pkg_dir, pkg_json_content, subpath)) |entry| {
            const is_esm = type_is_module or entry.resolved_via_esm;
            const full_path = entry.path;

            // Verify the resolved file actually exists on disk
            if (!fileExists(full_path)) {
                allocator.free(full_path);
                allocator.free(entry.owned_pkg_dir);
                continue;
            }

            return ResolvedModule{
                .file_path = full_path,
                .package_dir = entry.owned_pkg_dir,
                .is_esm = is_esm,
            };
        }
    }

    return null;
}

// ── Package Name Extraction ─────────────────────────────────────────────────

/// Extract the npm package name from a specifier.
///
/// "react"                     -> "react"
/// "react/jsx-runtime"         -> "react"
/// "@angular/core"             -> "@angular/core"
/// "@angular/core/testing"     -> "@angular/core"
/// "wu-framework/adapters/vue" -> "wu-framework"
pub fn extractPackageName(specifier: []const u8) []const u8 {
    if (specifier.len == 0) return specifier;

    if (specifier[0] == '@') {
        // Scoped package: need @scope/name, skip further slashes
        if (std.mem.indexOfScalar(u8, specifier, '/')) |first_slash| {
            const after_scope = specifier[first_slash + 1 ..];
            if (std.mem.indexOfScalar(u8, after_scope, '/')) |second_slash| {
                return specifier[0 .. first_slash + 1 + second_slash];
            }
        }
        return specifier; // @scope/name with no subpath
    }

    // Unscoped: take everything before the first slash
    if (std.mem.indexOfScalar(u8, specifier, '/')) |slash| {
        return specifier[0..slash];
    }
    return specifier;
}

/// Extract the subpath portion after the package name.
/// Returns null if there is no subpath (bare package import).
///
/// "react"                     -> null (root import)
/// "react/jsx-runtime"         -> "./jsx-runtime"
/// "@angular/core/testing"     -> "./testing"
/// "wu-framework/adapters/vue" -> "./adapters/vue"
fn extractSubpath(specifier: []const u8, pkg_name: []const u8) ?[]const u8 {
    if (specifier.len <= pkg_name.len) return null;
    // specifier = pkg_name + "/" + subpath
    const rest = specifier[pkg_name.len..];
    if (rest.len == 0 or rest[0] != '/') return null;
    return rest; // includes leading "/"
}

// ── Package.json Reading ────────────────────────────────────────────────────

/// Read package.json from a package directory. Returns owned content or null.
fn readPackageJson(allocator: Allocator, pkg_dir: []const u8) ?[]const u8 {
    var path_buf: [1088]u8 = undefined;
    const json_path = std.fmt.bufPrint(&path_buf, "{s}/package.json", .{pkg_dir}) catch return null;

    const file = fs.cwd().openFile(json_path, .{}) catch return null;
    defer file.close();

    // package.json files are rarely over 64KB
    return file.readToEndAlloc(allocator, 256 * 1024) catch null;
}

/// Detect if "type": "module" is present in package.json.
fn detectTypeModule(json: []const u8) bool {
    const val = findStringField(json, "type") orelse return false;
    return std.mem.eql(u8, val, "module");
}

// ── Entry Point Resolution ──────────────────────────────────────────────────

const EntryResult = struct {
    path: []const u8, // allocator-owned full path
    owned_pkg_dir: []const u8, // allocator-owned package dir
    resolved_via_esm: bool,
};

/// Resolve the entry point for a package, following this priority:
///   1. "exports" field (with subpath matching and condition resolution)
///   2. "module" field (ESM entry)
///   3. "main" field
///   4. Fallback to index.js
fn resolveEntryPoint(
    allocator: Allocator,
    pkg_dir: []const u8,
    pkg_json: []const u8,
    subpath: ?[]const u8,
) ?EntryResult {
    const owned_pkg_dir = allocator.dupe(u8, pkg_dir) catch return null;
    errdefer allocator.free(owned_pkg_dir);

    // 1. Try "exports" field
    if (resolveViaExports(allocator, pkg_dir, pkg_json, subpath)) |result| {
        return .{
            .path = result.path,
            .owned_pkg_dir = owned_pkg_dir,
            .resolved_via_esm = result.is_esm,
        };
    }

    // For subpath imports without an exports map, try direct file resolution
    if (subpath) |sp| {
        if (resolveDirectSubpath(allocator, pkg_dir, sp)) |path| {
            return .{
                .path = path,
                .owned_pkg_dir = owned_pkg_dir,
                .resolved_via_esm = false,
            };
        }
        // Subpath requested but no exports and no direct file - cannot resolve
        return null;
    }

    // 2. Try "module" field (ESM)
    if (findStringField(pkg_json, "module")) |module_val| {
        if (buildEntryPath(allocator, pkg_dir, module_val)) |path| {
            return .{
                .path = path,
                .owned_pkg_dir = owned_pkg_dir,
                .resolved_via_esm = true,
            };
        }
    }

    // 3. Try "main" field
    if (findStringField(pkg_json, "main")) |main_val| {
        if (buildEntryPath(allocator, pkg_dir, main_val)) |path| {
            return .{
                .path = path,
                .owned_pkg_dir = owned_pkg_dir,
                .resolved_via_esm = false,
            };
        }
    }

    // 4. Fallback: index.js
    if (buildEntryPath(allocator, pkg_dir, "index.js")) |path| {
        return .{
            .path = path,
            .owned_pkg_dir = owned_pkg_dir,
            .resolved_via_esm = false,
        };
    }

    return null;
}

/// Build a full path from package dir + relative entry, stripping leading "./"
fn buildEntryPath(allocator: Allocator, pkg_dir: []const u8, entry: []const u8) ?[]const u8 {
    const clean = if (std.mem.startsWith(u8, entry, "./"))
        entry[2..]
    else
        entry;

    var buf: [2048]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ pkg_dir, clean }) catch return null;
    return allocator.dupe(u8, full) catch null;
}

// ── Exports Field Resolution ────────────────────────────────────────────────
//
// The "exports" field in package.json is the most complex part of module
// resolution. It can be:
//
//   "exports": "./index.js"                          (string shorthand)
//   "exports": { ".": "./index.js" }                 (subpath map, string value)
//   "exports": { ".": { "import": "...", ... } }     (subpath map, condition object)
//   "exports": { ".": { "import": { "default": "..." } } }  (nested conditions, e.g. Vue)
//
// We handle all four shapes with a lightweight JSON field extractor,
// not a full JSON parser. This is deliberate: package.json files are
// well-formed (npm validates them), and we only need string values
// from specific paths in the tree.

const ExportsResult = struct {
    path: []const u8, // allocator-owned
    is_esm: bool,
};

fn resolveViaExports(
    allocator: Allocator,
    pkg_dir: []const u8,
    pkg_json: []const u8,
    subpath: ?[]const u8,
) ?ExportsResult {
    // Find the "exports" field value region
    const exports_region = findFieldRegion(pkg_json, "exports") orelse return null;

    // Determine the subpath key to look for
    // null subpath -> ".", "/jsx-runtime" -> "./jsx-runtime"
    var subpath_key_buf: [256]u8 = undefined;
    const subpath_key = if (subpath) |sp|
        std.fmt.bufPrint(&subpath_key_buf, ".{s}", .{sp}) catch return null
    else
        ".";

    // Case 1: "exports": "./index.js" (string shorthand, root import only)
    if (exports_region.len > 0 and exports_region[0] == '"') {
        if (std.mem.eql(u8, subpath_key, ".")) {
            const val = extractQuotedString(exports_region) orelse return null;
            const path = buildEntryPath(allocator, pkg_dir, val) orelse return null;
            return .{ .path = path, .is_esm = true };
        }
        return null; // String exports with subpath - no match
    }

    // Case 2+3: "exports": { ... }
    if (exports_region.len > 0 and exports_region[0] == '{') {
        return resolveExportsObject(allocator, pkg_dir, exports_region, subpath_key);
    }

    return null;
}

/// Resolve a subpath key within an exports object.
/// Handles both flat condition values and nested subpath maps.
fn resolveExportsObject(
    allocator: Allocator,
    pkg_dir: []const u8,
    exports_obj: []const u8,
    subpath_key: []const u8,
) ?ExportsResult {
    // Look for the subpath key in the exports object
    const value_region = findFieldRegion(exports_obj, subpath_key) orelse {
        // If looking for "." and didn't find it, the exports object might
        // itself be the condition object (e.g. "exports": { "import": "...", "default": "..." })
        if (std.mem.eql(u8, subpath_key, ".")) {
            return resolveConditionObject(allocator, pkg_dir, exports_obj);
        }
        return null;
    };

    // The value for this subpath can be:
    //   - A string: "./index.js"
    //   - A condition object: { "import": "...", "default": "..." }
    if (value_region.len == 0) return null;

    if (value_region[0] == '"') {
        // Direct string value
        const val = extractQuotedString(value_region) orelse return null;
        const path = buildEntryPath(allocator, pkg_dir, val) orelse return null;
        return .{ .path = path, .is_esm = true };
    }

    if (value_region[0] == '{') {
        return resolveConditionObject(allocator, pkg_dir, value_region);
    }

    return null;
}

/// Resolve a condition object to a file path.
/// Priority order for a dev server targeting the browser:
///   browser > import > module > default > require
///
/// Each condition value can itself be:
///   - A string: "./dist/index.mjs"
///   - A nested condition object: { "types": "...", "default": "..." }
///     (Vue uses this pattern: "import": { "default": "./dist/vue.runtime.esm-bundler.js" })
fn resolveConditionObject(
    allocator: Allocator,
    pkg_dir: []const u8,
    obj: []const u8,
) ?ExportsResult {
    // Condition priority for ESM dev server (matches Vite: import > module > browser > default)
    const conditions = [_]struct { key: []const u8, is_esm: bool }{
        .{ .key = "import", .is_esm = true },
        .{ .key = "module", .is_esm = true },
        .{ .key = "browser", .is_esm = true },
        .{ .key = "default", .is_esm = true },
        .{ .key = "require", .is_esm = false },
    };

    for (conditions) |cond| {
        if (findFieldRegion(obj, cond.key)) |region| {
            if (region.len == 0) continue;

            if (region[0] == '"') {
                // Direct string value
                const val = extractQuotedString(region) orelse continue;
                // Skip .d.ts files (types condition resolved as fallback)
                if (std.mem.endsWith(u8, val, ".d.ts") or std.mem.endsWith(u8, val, ".d.mts")) continue;
                const path = buildEntryPath(allocator, pkg_dir, val) orelse continue;
                return .{ .path = path, .is_esm = cond.is_esm };
            }

            if (region[0] == '{') {
                // Nested condition object (e.g. Vue's "import": { "default": "..." })
                // Recurse, but skip "types" keys in nested objects
                if (resolveConditionObject(allocator, pkg_dir, region)) |result| {
                    return .{ .path = result.path, .is_esm = cond.is_esm or result.is_esm };
                }
            }
        }
    }

    return null;
}

// ── Direct Subpath Resolution (no exports map) ──────────────────────────────

/// When there is no exports map, try to resolve a subpath directly:
///   "wu-framework/adapters/vanilla" -> node_modules/wu-framework/adapters/vanilla/index.js
///   or node_modules/wu-framework/adapters/vanilla.js etc.
fn resolveDirectSubpath(allocator: Allocator, pkg_dir: []const u8, subpath: []const u8) ?[]const u8 {
    // subpath starts with "/" (e.g. "/adapters/vanilla")
    const clean = if (subpath.len > 0 and subpath[0] == '/') subpath[1..] else subpath;

    // Try direct file with extensions
    const extensions = [_][]const u8{ ".js", ".mjs", ".ts", ".tsx", ".jsx" };
    for (extensions) |ext| {
        var buf: [2048]u8 = undefined;
        const candidate = std.fmt.bufPrint(&buf, "{s}/{s}{s}", .{ pkg_dir, clean, ext }) catch continue;
        if (fileExists(candidate)) {
            return allocator.dupe(u8, candidate) catch null;
        }
    }

    // Try as directory with index files
    const index_names = [_][]const u8{ "/index.js", "/index.mjs", "/index.ts", "/index.tsx" };
    for (index_names) |idx| {
        var buf: [2048]u8 = undefined;
        const candidate = std.fmt.bufPrint(&buf, "{s}/{s}{s}", .{ pkg_dir, clean, idx }) catch continue;
        if (fileExists(candidate)) {
            return allocator.dupe(u8, candidate) catch null;
        }
    }

    // Try exact path (already has extension)
    {
        var buf: [2048]u8 = undefined;
        const candidate = std.fmt.bufPrint(&buf, "{s}/{s}", .{ pkg_dir, clean }) catch return null;
        if (fileExists(candidate)) {
            return allocator.dupe(u8, candidate) catch null;
        }
    }

    return null;
}

// ── Lightweight JSON Field Extraction ───────────────────────────────────────
//
// Not a full JSON parser. We exploit the structure of package.json:
// well-formed, no comments, deterministic key quoting.
// We search for "fieldname" followed by : and extract the value region.
//
// This approach is O(n) in JSON size and handles nesting by tracking
// brace/bracket depth. It is correct for all npm-published package.json
// files because npm enforces valid JSON.

/// Find a string field value in JSON content.
/// Returns the unquoted string value, or null if not found.
///
/// Example: findStringField('{"main": "index.js"}', "main") -> "index.js"
pub fn findStringField(json: []const u8, field_name: []const u8) ?[]const u8 {
    const region = findFieldRegion(json, field_name) orelse return null;
    return extractQuotedString(region);
}

/// Find the value region for a field in a JSON object.
/// Returns a slice starting at the value (string, object, array, etc.)
/// and extending to the logical end of that value.
///
/// This handles nested objects by tracking brace depth — it will not
/// confuse a nested field with a top-level one.
pub fn findFieldRegion(json: []const u8, field_name: []const u8) ?[]const u8 {
    // We search for "field_name" (with quotes) at depth 1 inside the first
    // object we encounter. We stop searching when depth drops below 1
    // (i.e., we've exited the outermost object boundary). This prevents
    // matching keys from sibling objects in trailing JSON content.

    // Build the search key: "field_name"
    var key_buf: [270]u8 = undefined;
    const search_key = std.fmt.bufPrint(&key_buf, "\"{s}\"", .{field_name}) catch return null;

    var pos: usize = 0;
    var depth: i32 = 0;
    var entered_object = false;
    var in_string = false;

    while (pos < json.len) {
        const ch = json[pos];

        // Handle string literals (skip their contents)
        if (ch == '"' and !isEscaped(json, pos)) {
            if (!in_string) {
                // Check if this starts our search key at depth 1 (inside first object)
                if (entered_object and depth == 1 and pos + search_key.len <= json.len) {
                    if (std.mem.eql(u8, json[pos .. pos + search_key.len], search_key)) {
                        // Found the key. Now find the colon and value.
                        var vpos = pos + search_key.len;
                        // Skip whitespace
                        while (vpos < json.len and isJsonWhitespace(json[vpos])) : (vpos += 1) {}
                        // Expect colon
                        if (vpos < json.len and json[vpos] == ':') {
                            vpos += 1;
                            // Skip whitespace
                            while (vpos < json.len and isJsonWhitespace(json[vpos])) : (vpos += 1) {}
                            // Return the value region
                            return json[vpos..];
                        }
                    }
                }
                // Skip past this string
                in_string = true;
                pos += 1;
                continue;
            } else {
                in_string = false;
                pos += 1;
                continue;
            }
        }

        if (in_string) {
            // Skip string content, handling escapes
            if (ch == '\\') {
                pos += 2; // skip escape sequence
                continue;
            }
            pos += 1;
            continue;
        }

        if (ch == '{' or ch == '[') {
            depth += 1;
            if (!entered_object and ch == '{') entered_object = true;
        }
        if (ch == '}' or ch == ']') {
            depth -= 1;
            // Stop searching when we've exited the first object
            if (entered_object and depth < 1) return null;
        }

        pos += 1;
    }

    return null;
}

/// Extract a quoted string value from a region starting with '"'.
/// Returns the unquoted content.
pub fn extractQuotedString(region: []const u8) ?[]const u8 {
    if (region.len < 2 or region[0] != '"') return null;

    var i: usize = 1;
    while (i < region.len) : (i += 1) {
        if (region[i] == '\\') {
            i += 1; // skip escaped char
            continue;
        }
        if (region[i] == '"') {
            return region[1..i];
        }
    }
    return null;
}

/// Check if a character at position is preceded by an odd number of backslashes.
fn isEscaped(json: []const u8, pos: usize) bool {
    if (pos == 0) return false;
    var count: usize = 0;
    var i = pos - 1;
    while (true) {
        if (json[i] != '\\') break;
        count += 1;
        if (i == 0) break;
        i -= 1;
    }
    return count % 2 == 1;
}

fn isJsonWhitespace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

// ── File System Helpers ─────────────────────────────────────────────────────

fn fileExists(path: []const u8) bool {
    fs.cwd().access(path, .{}) catch return false;
    return true;
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "extractPackageName - unscoped bare" {
    try std.testing.expectEqualStrings("react", extractPackageName("react"));
}

test "extractPackageName - unscoped with subpath" {
    try std.testing.expectEqualStrings("react", extractPackageName("react/jsx-runtime"));
}

test "extractPackageName - scoped bare" {
    try std.testing.expectEqualStrings("@angular/core", extractPackageName("@angular/core"));
}

test "extractPackageName - scoped with subpath" {
    try std.testing.expectEqualStrings("@angular/core", extractPackageName("@angular/core/testing"));
}

test "extractPackageName - unscoped deep subpath" {
    try std.testing.expectEqualStrings("wu-framework", extractPackageName("wu-framework/adapters/vanilla"));
}

test "extractPackageName - empty" {
    try std.testing.expectEqualStrings("", extractPackageName(""));
}

test "extractSubpath - no subpath" {
    try std.testing.expect(extractSubpath("react", "react") == null);
}

test "extractSubpath - with subpath" {
    const sub = extractSubpath("react/jsx-runtime", "react").?;
    try std.testing.expectEqualStrings("/jsx-runtime", sub);
}

test "extractSubpath - scoped with subpath" {
    const sub = extractSubpath("@angular/core/testing", "@angular/core").?;
    try std.testing.expectEqualStrings("/testing", sub);
}

test "extractSubpath - deep subpath" {
    const sub = extractSubpath("wu-framework/adapters/vanilla", "wu-framework").?;
    try std.testing.expectEqualStrings("/adapters/vanilla", sub);
}

test "findStringField - simple main" {
    const json =
        \\{"name": "react", "main": "index.js", "version": "18.3.1"}
    ;
    const val = findStringField(json, "main").?;
    try std.testing.expectEqualStrings("index.js", val);
}

test "findStringField - module field" {
    const json =
        \\{"name": "vue", "main": "index.js", "module": "dist/vue.runtime.esm-bundler.js"}
    ;
    const val = findStringField(json, "module").?;
    try std.testing.expectEqualStrings("dist/vue.runtime.esm-bundler.js", val);
}

test "findStringField - type field" {
    const json =
        \\{"name": "lit", "type": "module", "main": "index.js"}
    ;
    const val = findStringField(json, "type").?;
    try std.testing.expectEqualStrings("module", val);
}

test "findStringField - not found" {
    const json =
        \\{"name": "react", "main": "index.js"}
    ;
    try std.testing.expect(findStringField(json, "module") == null);
}

test "findStringField - nested field not confused with top-level" {
    // "default" inside exports."." should not be returned when searching
    // at the top level for a "default" field.
    const json =
        \\{"name": "test", "exports": {".": {"default": "./index.js"}}, "main": "lib.js"}
    ;
    const main = findStringField(json, "main").?;
    try std.testing.expectEqualStrings("lib.js", main);
}

test "detectTypeModule - true" {
    const json =
        \\{"name": "lit", "type": "module"}
    ;
    try std.testing.expect(detectTypeModule(json));
}

test "detectTypeModule - false when commonjs" {
    const json =
        \\{"name": "react", "type": "commonjs"}
    ;
    try std.testing.expect(!detectTypeModule(json));
}

test "detectTypeModule - false when missing" {
    const json =
        \\{"name": "react", "main": "index.js"}
    ;
    try std.testing.expect(!detectTypeModule(json));
}

test "findFieldRegion - exports object" {
    const json =
        \\{"exports": {".": {"default": "./index.js"}}}
    ;
    const region = findFieldRegion(json, "exports").?;
    try std.testing.expect(region[0] == '{');
}

test "findFieldRegion - string value" {
    const json =
        \\{"main": "index.js"}
    ;
    const region = findFieldRegion(json, "main").?;
    try std.testing.expect(region[0] == '"');
    const val = extractQuotedString(region).?;
    try std.testing.expectEqualStrings("index.js", val);
}

test "extractQuotedString - basic" {
    const input =
        \\"hello world", "other"
    ;
    const val = extractQuotedString(input).?;
    try std.testing.expectEqualStrings("hello world", val);
}

test "extractQuotedString - with escape" {
    const input =
        \\"hello \"world\"", more
    ;
    const val = extractQuotedString(input).?;
    // The raw content between first quote and the closing unescaped quote.
    // Input bytes: "hello \"world\"", more
    // The escaped quotes are skipped, closing quote is the one after world\".
    try std.testing.expectEqualStrings("hello \\\"world\\\"", val);
}

test "resolveConditionObject - browser priority" {
    const allocator = std.testing.allocator;
    // Simulate preact-style condition object
    const obj =
        \\{"types": "./src/index.d.ts", "browser": "./dist/preact.module.js", "import": "./dist/preact.mjs", "require": "./dist/preact.js"}
    ;
    const result = resolveConditionObject(allocator, "/fake/pkg", obj).?;
    defer allocator.free(result.path);
    try std.testing.expect(result.is_esm);
    try std.testing.expect(std.mem.endsWith(u8, result.path, "dist/preact.module.js"));
}

test "resolveConditionObject - import fallback" {
    const allocator = std.testing.allocator;
    const obj =
        \\{"types": "./index.d.ts", "import": "./dist/index.mjs", "require": "./dist/index.js"}
    ;
    const result = resolveConditionObject(allocator, "/fake/pkg", obj).?;
    defer allocator.free(result.path);
    try std.testing.expect(result.is_esm);
    try std.testing.expect(std.mem.endsWith(u8, result.path, "dist/index.mjs"));
}

test "resolveConditionObject - default fallback" {
    const allocator = std.testing.allocator;
    // React-style: only "default" and custom conditions
    const obj =
        \\{"react-server": "./react.shared-subset.js", "default": "./index.js"}
    ;
    const result = resolveConditionObject(allocator, "/fake/pkg", obj).?;
    defer allocator.free(result.path);
    try std.testing.expect(result.is_esm);
    try std.testing.expect(std.mem.endsWith(u8, result.path, "index.js"));
}

test "resolveConditionObject - nested condition (vue style)" {
    const allocator = std.testing.allocator;
    // Vue's "import" is itself an object with nested conditions
    const obj =
        \\{"import": {"types": "./dist/vue.d.mts", "node": "./index.mjs", "default": "./dist/vue.runtime.esm-bundler.js"}, "require": {"default": "./index.js"}}
    ;
    const result = resolveConditionObject(allocator, "/fake/pkg", obj).?;
    defer allocator.free(result.path);
    try std.testing.expect(result.is_esm);
    try std.testing.expect(std.mem.endsWith(u8, result.path, "dist/vue.runtime.esm-bundler.js"));
}

test "resolveConditionObject - skips types-only" {
    const allocator = std.testing.allocator;
    // A condition object that only has "types" should return null
    const obj =
        \\{"types": "./types/index.d.ts"}
    ;
    const result = resolveConditionObject(allocator, "/fake/pkg", obj);
    try std.testing.expect(result == null);
}

test "resolveExportsObject - subpath key" {
    const allocator = std.testing.allocator;
    // Preact-style exports with subpath
    const exports =
        \\{".": {"import": "./dist/preact.mjs"}, "./hooks": {"import": "./hooks/dist/hooks.mjs", "require": "./hooks/dist/hooks.js"}}
    ;
    const result = resolveExportsObject(allocator, "/fake/pkg", exports, "./hooks").?;
    defer allocator.free(result.path);
    try std.testing.expect(std.mem.endsWith(u8, result.path, "hooks/dist/hooks.mjs"));
}

test "resolveViaExports - string shorthand" {
    const allocator = std.testing.allocator;
    const json =
        \\{"name": "simple", "exports": "./lib/index.mjs"}
    ;
    const result = resolveViaExports(allocator, "/fake/pkg", json, null).?;
    defer allocator.free(result.path);
    try std.testing.expect(result.is_esm);
    try std.testing.expect(std.mem.endsWith(u8, result.path, "lib/index.mjs"));
}

test "resolveViaExports - object with dot entry" {
    const allocator = std.testing.allocator;
    const json =
        \\{"name": "lit", "exports": {".": {"types": "./dev/index.d.ts", "default": "./index.js"}}}
    ;
    const result = resolveViaExports(allocator, "/fake/pkg", json, null).?;
    defer allocator.free(result.path);
    try std.testing.expect(std.mem.endsWith(u8, result.path, "index.js"));
}

test "resolveViaExports - subpath export" {
    const allocator = std.testing.allocator;
    const json =
        \\{"name": "react", "exports": {".": {"default": "./index.js"}, "./jsx-runtime": "./jsx-runtime.js"}}
    ;
    const result = resolveViaExports(allocator, "/fake/pkg", json, "/jsx-runtime").?;
    defer allocator.free(result.path);
    try std.testing.expect(std.mem.endsWith(u8, result.path, "jsx-runtime.js"));
}

test "isEscaped - not escaped" {
    const s = "hello\"world";
    try std.testing.expect(!isEscaped(s, 5));
}

test "isEscaped - single backslash" {
    const s = "hello\\\"world";
    try std.testing.expect(isEscaped(s, 6));
}

test "isEscaped - double backslash (not escaped)" {
    const s = "hello\\\\\"world";
    try std.testing.expect(!isEscaped(s, 7));
}
