// WU Runtime — Source Transform Pipeline
//
// Phase 1: Line-based TypeScript erasure + bare import rewriting.
// Future phases will add JSX transform and tree-sitter AST stripping.
//
// Design: state-machine approach for TS, regex-like for imports.
// Preserves line count (every input line produces one output line).

const std = @import("std");
const Allocator = std.mem.Allocator;

// ── Public API ──────────────────────────────────────────────────────────────

/// Apply all relevant transforms to a source file based on its extension.
/// Returns allocator-owned slice (caller must free).
pub fn transformSource(allocator: Allocator, source: []const u8, file_path: []const u8) ![]const u8 {
    const ext = std.fs.path.extension(file_path);
    const eql = std.mem.eql;

    var result = source;
    var owned = false;

    // TypeScript stripping for .ts / .tsx / .mts files
    if (eql(u8, ext, ".ts") or eql(u8, ext, ".tsx") or eql(u8, ext, ".mts")) {
        const stripped = try stripTypeScript(allocator, result);
        if (owned) allocator.free(result);
        result = stripped;
        owned = true;
    }

    // Import rewriting for all JS/TS files
    if (eql(u8, ext, ".js") or eql(u8, ext, ".mjs") or eql(u8, ext, ".cjs") or
        eql(u8, ext, ".ts") or eql(u8, ext, ".tsx") or eql(u8, ext, ".mts") or
        eql(u8, ext, ".jsx"))
    {
        const rewritten = try rewriteImports(allocator, result);
        if (owned) allocator.free(result);
        result = rewritten;
        owned = true;

        // CSS import rewriting: import './style.css' → import './style.css?import'
        const css_rewritten = try rewriteCssImports(allocator, result);
        if (css_rewritten.ptr != result.ptr) {
            allocator.free(result);
            result = css_rewritten;
        }
    }

    // If no transform was applied, dupe so caller always owns the result
    if (!owned) {
        return allocator.dupe(u8, source);
    }
    return result;
}

// ── TypeScript Stripping ────────────────────────────────────────────────────

/// Strip TypeScript type annotations from source code.
/// Uses a line-based approach with brace-depth tracking for blocks.
/// Preserves line count for source map compatibility.
pub fn stripTypeScript(allocator: Allocator, source: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var skip_depth: i32 = 0; // Brace depth for multi-line type blocks
    var lines = std.mem.splitScalar(u8, source, '\n');
    var first = true;

    while (lines.next()) |line| {
        if (!first) try out.append(allocator, '\n');
        first = false;

        const trimmed = std.mem.trim(u8, line, " \t\r");

        // If we're inside a type block (interface/type with braces), skip lines
        if (skip_depth > 0) {
            for (trimmed) |ch| {
                if (ch == '{') skip_depth += 1;
                if (ch == '}') skip_depth -= 1;
            }
            // Emit empty line to preserve line count
            continue;
        }

        // Check for type-only lines that should be removed entirely
        if (isTypeOnlyLine(trimmed)) {
            // Check if this opens a multi-line block
            if (countBraces(trimmed)) |depth| {
                if (depth > 0) skip_depth = depth;
            }
            // Emit empty line to preserve line count
            continue;
        }

        // Inline stripping: remove access modifiers, as/satisfies casts
        try stripInline(allocator, &out, line);
    }

    return out.toOwnedSlice(allocator);
}

/// Check if a line is a type-only statement that can be removed entirely.
fn isTypeOnlyLine(line: []const u8) bool {
    const starts = std.mem.startsWith;
    return starts(u8, line, "interface ") or
        starts(u8, line, "export interface ") or
        starts(u8, line, "import type ") or
        starts(u8, line, "export type {") or
        starts(u8, line, "export type *") or
        isTypeAlias(line) or
        starts(u8, line, "declare ") or
        starts(u8, line, "export declare ") or
        starts(u8, line, "namespace ") or
        starts(u8, line, "export namespace ") or
        starts(u8, line, "abstract class") or
        std.mem.eql(u8, line, "};") or
        (starts(u8, line, "//") and !starts(u8, line, "//>"));
}

/// Distinguish "type X = ..." (alias, remove) from "type:" (property, keep).
fn isTypeAlias(line: []const u8) bool {
    const prefix = "type ";
    const export_prefix = "export type ";

    const after = if (std.mem.startsWith(u8, line, export_prefix))
        line[export_prefix.len..]
    else if (std.mem.startsWith(u8, line, prefix))
        line[prefix.len..]
    else
        return false;

    // "type Foo = ..." is an alias. "type:" or "type," is a property.
    // An alias starts with an identifier char.
    if (after.len == 0) return false;
    if (!std.ascii.isAlphabetic(after[0]) and after[0] != '_') return false;

    // Look for '=' after the identifier (type Foo = ...)
    var i: usize = 0;
    while (i < after.len and (std.ascii.isAlphanumeric(after[i]) or after[i] == '_' or after[i] == '<')) : (i += 1) {
        // Skip angle brackets for generics: type Foo<T> = ...
        if (after[i] == '<') {
            var depth: u32 = 1;
            i += 1;
            while (i < after.len and depth > 0) : (i += 1) {
                if (after[i] == '<') depth += 1;
                if (after[i] == '>') depth -= 1;
            }
        }
    }
    // Skip whitespace
    while (i < after.len and (after[i] == ' ' or after[i] == '\t')) : (i += 1) {}
    // Should be followed by '='
    return i < after.len and after[i] == '=';
}

/// Count unmatched opening braces in a line. Returns null if no braces.
fn countBraces(line: []const u8) ?i32 {
    var depth: i32 = 0;
    var has_braces = false;
    for (line) |ch| {
        if (ch == '{') {
            depth += 1;
            has_braces = true;
        }
        if (ch == '}') depth -= 1;
    }
    return if (has_braces) depth else null;
}

/// Strip inline TypeScript constructs from a line.
/// Handles: access modifiers, "as Type", "satisfies Type", ": Type" in params.
fn stripInline(allocator: Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    var i: usize = 0;

    while (i < line.len) {
        // Skip string literals verbatim
        if (line[i] == '"' or line[i] == '\'' or line[i] == '`') {
            const end = skipStringLiteral(line, i);
            try out.appendSlice(allocator, line[i..end]);
            i = end;
            continue;
        }

        // Skip line comments
        if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '/') {
            try out.appendSlice(allocator, line[i..]);
            return;
        }

        // Strip access modifiers at word boundaries
        if (isWordStart(line, i)) {
            if (matchAndSkipModifier(line, i)) |skip_to| {
                i = skip_to;
                continue;
            }
        }

        // Strip " as " casts (not "class" etc.)
        if (i + 4 <= line.len and std.mem.eql(u8, line[i .. i + 4], " as ")) {
            if (i == 0 or !std.ascii.isAlphanumeric(line[i - 1])) {
                // Just " as " is ambiguous, skip it only if previous char was )
            }
            if (i > 0 and (line[i - 1] == ')' or line[i - 1] == ']' or
                std.ascii.isAlphanumeric(line[i - 1]) or line[i - 1] == '_'))
            {
                i += 4;
                // Skip the type expression (identifier, generics, etc.)
                i = skipTypeExpression(line, i);
                continue;
            }
        }

        // Strip ": Type" in function parameters and variable declarations
        if (line[i] == ':' and i > 0) {
            const prev = line[i - 1];
            // After identifier, ), or ] — likely a type annotation
            if (std.ascii.isAlphanumeric(prev) or prev == '_' or prev == ')' or prev == '?' or prev == '!') {
                // Look ahead: skip whitespace + type, stop at , ) = { ; =>
                const type_end = findTypeEnd(line, i + 1);
                if (type_end > i + 1) {
                    i = type_end;
                    continue;
                }
            }
        }

        // Strip "implements X, Y" from class declarations
        if (i + 11 <= line.len and std.mem.eql(u8, line[i .. i + 11], " implements ")) {
            // Skip until { or end of line
            var j = i + 11;
            while (j < line.len and line[j] != '{') : (j += 1) {}
            i = j;
            continue;
        }

        try out.append(allocator, line[i]);
        i += 1;
    }
}

/// Skip past a string literal (single, double, or template).
fn skipStringLiteral(source: []const u8, start: usize) usize {
    const quote = source[start];
    var i = start + 1;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\\') {
            i += 1; // Skip escaped char
            continue;
        }
        if (source[i] == quote) {
            return i + 1;
        }
        // Template literals can span lines — handle in next line
        if (quote == '`' and source[i] == '\n') {
            return i; // Let next line handle continuation
        }
    }
    return source.len;
}

/// Check if position is the start of a word (not preceded by alphanumeric).
fn isWordStart(line: []const u8, i: usize) bool {
    if (i == 0) return true;
    return !std.ascii.isAlphanumeric(line[i - 1]) and line[i - 1] != '_';
}

/// Try to match access modifiers (public, private, protected, readonly, override, abstract).
/// Returns the position after the modifier + space if matched, null otherwise.
fn matchAndSkipModifier(line: []const u8, start: usize) ?usize {
    const modifiers = [_][]const u8{
        "public ", "private ", "protected ", "readonly ", "override ", "abstract ",
    };
    for (modifiers) |mod| {
        if (start + mod.len <= line.len and std.mem.eql(u8, line[start .. start + mod.len], mod)) {
            return start + mod.len;
        }
    }
    return null;
}

/// Skip a type expression: identifier, generics, union/intersection, arrays.
/// Stops at: , ) ; = { } newline
fn skipTypeExpression(source: []const u8, start: usize) usize {
    var i = start;
    var angle_depth: i32 = 0;
    var paren_depth: i32 = 0;

    while (i < source.len) : (i += 1) {
        const ch = source[i];

        if (ch == '<') {
            angle_depth += 1;
            continue;
        }
        if (ch == '>') {
            if (angle_depth > 0) {
                angle_depth -= 1;
                continue;
            }
            return i;
        }
        if (ch == '(') {
            paren_depth += 1;
            continue;
        }
        if (ch == ')') {
            if (paren_depth > 0) {
                paren_depth -= 1;
                continue;
            }
            return i;
        }

        if (angle_depth > 0 or paren_depth > 0) continue;

        // Stop characters
        if (ch == ',' or ch == ';' or ch == '=' or ch == '{' or ch == '}') return i;
        if (ch == '\n' or ch == '\r') return i;
    }
    return i;
}

/// Find where a type annotation ends after ':'.
/// Skips whitespace + type expression. Returns position to continue from.
fn findTypeEnd(source: []const u8, start: usize) usize {
    var i = start;
    // Skip whitespace
    while (i < source.len and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {}

    if (i >= source.len) return start;

    // Don't strip if this looks like an object literal or ternary
    // Object: { key: value } — the ':' is followed by space + value
    // Ternary: condition ? true : false — the ':' is part of ternary
    // Type: ident: Type = — followed by capitalized or known type keyword

    // Heuristic: if next char is not uppercase, not a primitive, skip
    const ch = source[i];
    if (!std.ascii.isAlphabetic(ch) and ch != '{' and ch != '(' and ch != '[' and ch != '\'' and ch != '"') {
        return start; // Not a type annotation
    }

    return skipTypeExpression(source, i);
}

// ── Import Rewriting ────────────────────────────────────────────────────────

/// Rewrite bare import specifiers to /@modules/ virtual paths.
/// e.g., `import React from 'react'` → `import React from '/@modules/react'`
/// Relative imports (./foo, ../bar) are left unchanged.
pub fn rewriteImports(allocator: Allocator, source: []const u8) ![]const u8 {
    // Scan the entire source for import/export specifiers and rewrite bare
    // specifiers to /@modules/ virtual paths. Handles minified code:
    //   import"pkg"       import 'pkg'       import("pkg")
    //   from"pkg"         from 'pkg'
    //   export*from"pkg"  export { x } from 'pkg'

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var src = source; // mutable copy of the slice header
    var pos: usize = 0;

    while (pos < src.len) {
        // Look for "from" keyword followed by a quote (with optional space)
        if (pos + 4 < src.len and std.mem.eql(u8, src[pos .. pos + 4], "from")) {
            var q = pos + 4;
            while (q < src.len and (src[q] == ' ' or src[q] == '\t')) : (q += 1) {}
            if (q < src.len and (src[q] == '"' or src[q] == '\'')) {
                // Check word boundary (not part of "transform" etc.)
                if (pos == 0 or !std.ascii.isAlphanumeric(src[pos - 1])) {
                    const quote = src[q];
                    const spec_start = q + 1;
                    if (std.mem.indexOfScalar(u8, src[spec_start..], quote)) |spec_len| {
                        const specifier = src[spec_start .. spec_start + spec_len];
                        if (isBareSpecifier(specifier)) {
                            try out.appendSlice(allocator, src[0..spec_start]);
                            try out.appendSlice(allocator, "/@modules/");
                            try out.appendSlice(allocator, specifier);
                            src = src[spec_start + spec_len ..];
                            pos = 0;
                            continue;
                        }
                    }
                }
            }
        }

        // Look for side-effect import: import"pkg" or import 'pkg'
        // AND dynamic import: import("pkg") or import('pkg')
        if (pos + 6 < src.len and std.mem.eql(u8, src[pos .. pos + 6], "import")) {
            var q = pos + 6;
            while (q < src.len and (src[q] == ' ' or src[q] == '\t')) : (q += 1) {}
            if (q < src.len and (src[q] == '"' or src[q] == '\'')) {
                // Side-effect import: import 'pkg'
                if (pos == 0 or !std.ascii.isAlphanumeric(src[pos - 1])) {
                    const quote = src[q];
                    const spec_start = q + 1;
                    if (std.mem.indexOfScalar(u8, src[spec_start..], quote)) |spec_len| {
                        const specifier = src[spec_start .. spec_start + spec_len];
                        if (isBareSpecifier(specifier)) {
                            try out.appendSlice(allocator, src[0..spec_start]);
                            try out.appendSlice(allocator, "/@modules/");
                            try out.appendSlice(allocator, specifier);
                            src = src[spec_start + spec_len ..];
                            pos = 0;
                            continue;
                        }
                    }
                }
            } else if (q < src.len and src[q] == '(') {
                // Dynamic import: import("pkg") or import('pkg')
                var r = q + 1;
                while (r < src.len and (src[r] == ' ' or src[r] == '\t')) : (r += 1) {}
                if (r < src.len and (src[r] == '"' or src[r] == '\'')) {
                    const quote = src[r];
                    const spec_start = r + 1;
                    if (std.mem.indexOfScalar(u8, src[spec_start..], quote)) |spec_len| {
                        const specifier = src[spec_start .. spec_start + spec_len];
                        if (isBareSpecifier(specifier)) {
                            try out.appendSlice(allocator, src[0..spec_start]);
                            try out.appendSlice(allocator, "/@modules/");
                            try out.appendSlice(allocator, specifier);
                            src = src[spec_start + spec_len ..];
                            pos = 0;
                            continue;
                        }
                    }
                }
            }
        }

        pos += 1;
    }

    // Append remaining source
    try out.appendSlice(allocator, src);
    return out.toOwnedSlice(allocator);
}

// ── CSS Import Rewriting ─────────────────────────────────────────────────────

/// Rewrite CSS imports so the server can serve them as JS modules.
/// `import './style.css'`  →  `import './style.css?import'`
/// `import "../reset.css"` →  `import "../reset.css?import"`
/// This lets the server distinguish CSS-as-module from CSS-as-stylesheet.
pub fn rewriteCssImports(allocator: Allocator, source: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var src = source;
    var pos: usize = 0;
    var found_any = false;

    while (pos < src.len) {
        // Skip string literals to avoid false matches
        if (src[pos] == '"' or src[pos] == '\'' or src[pos] == '`') {
            pos = skipStringLiteral(src, pos);
            continue;
        }

        // Skip line comments
        if (pos + 1 < src.len and src[pos] == '/' and src[pos + 1] == '/') {
            while (pos < src.len and src[pos] != '\n') : (pos += 1) {}
            continue;
        }

        // Look for: import followed by space/quote, then a .css specifier
        if (pos + 6 < src.len and std.mem.eql(u8, src[pos .. pos + 6], "import")) {
            // Word boundary check
            if (pos > 0 and std.ascii.isAlphanumeric(src[pos - 1])) {
                pos += 1;
                continue;
            }

            var q = pos + 6;
            while (q < src.len and (src[q] == ' ' or src[q] == '\t')) : (q += 1) {}

            if (q < src.len and (src[q] == '"' or src[q] == '\'')) {
                const quote = src[q];
                const spec_start = q + 1;
                if (std.mem.indexOfScalar(u8, src[spec_start..], quote)) |spec_len| {
                    const specifier = src[spec_start .. spec_start + spec_len];
                    if (std.mem.endsWith(u8, specifier, ".css")) {
                        // Found CSS import — append ?import before closing quote
                        try out.appendSlice(allocator, src[0 .. spec_start + spec_len]);
                        try out.appendSlice(allocator, "?import");
                        src = src[spec_start + spec_len ..];
                        pos = 0;
                        found_any = true;
                        continue;
                    }
                }
            }
        }

        // Also handle: from './style.css' (less common but valid)
        if (pos + 4 < src.len and std.mem.eql(u8, src[pos .. pos + 4], "from")) {
            if (pos > 0 and std.ascii.isAlphanumeric(src[pos - 1])) {
                pos += 1;
                continue;
            }

            var q = pos + 4;
            while (q < src.len and (src[q] == ' ' or src[q] == '\t')) : (q += 1) {}

            if (q < src.len and (src[q] == '"' or src[q] == '\'')) {
                const quote = src[q];
                const spec_start = q + 1;
                if (std.mem.indexOfScalar(u8, src[spec_start..], quote)) |spec_len| {
                    const specifier = src[spec_start .. spec_start + spec_len];
                    if (std.mem.endsWith(u8, specifier, ".css")) {
                        try out.appendSlice(allocator, src[0 .. spec_start + spec_len]);
                        try out.appendSlice(allocator, "?import");
                        src = src[spec_start + spec_len ..];
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
        return allocator.dupe(u8, source);
    }

    try out.appendSlice(allocator, src);
    return out.toOwnedSlice(allocator);
}

/// Check if a specifier is "bare" (should be rewritten to /@modules/).
/// Bare: "react", "@angular/core", "wu-framework/adapters/vue"
/// Not bare: "./foo", "../bar", "/abs", "https://...", ") || garbage"
fn isBareSpecifier(specifier: []const u8) bool {
    if (specifier.len == 0) return false;
    if (specifier[0] == '.' or specifier[0] == '/') return false;
    if (std.mem.startsWith(u8, specifier, "http:") or std.mem.startsWith(u8, specifier, "https:")) return false;
    if (std.mem.startsWith(u8, specifier, "data:")) return false;
    // Must start with a valid npm package name character: letter, @, or _
    // This prevents false positives from string contents like: includes('import')
    if (!std.ascii.isAlphabetic(specifier[0]) and specifier[0] != '@' and specifier[0] != '_') return false;
    // Must not contain spaces, parens, or braces (would indicate garbage match)
    for (specifier) |c| {
        if (c == ' ' or c == '\t' or c == '(' or c == ')' or c == '{' or c == '}' or c == '\n' or c == '\r') return false;
    }
    return true;
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "strip interface block" {
    const input =
        \\interface Foo {
        \\  bar: string;
        \\  baz: number;
        \\}
        \\const x = 1;
    ;
    const result = try stripTypeScript(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "interface") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "const x = 1") != null);
}

test "strip type alias" {
    const input =
        \\type Foo = string | number;
        \\const x = 1;
    ;
    const result = try stripTypeScript(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "type Foo") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "const x = 1") != null);
}

test "strip import type" {
    const input = "import type { Foo } from './types';";
    const result = try stripTypeScript(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.trim(u8, result, " \t\r\n").len == 0);
}

test "rewrite bare import" {
    const input = "import React from 'react';";
    const result = try rewriteImports(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "/@modules/react") != null);
}

test "keep relative import" {
    const input = "import { foo } from './utils';";
    const result = try rewriteImports(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "/@modules/") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "'./utils'") != null);
}

test "rewrite minified import (no spaces)" {
    const input =
        \\import"@lit/reactive-element";import"lit-html";export*from"lit-element/lit-element.js";
    ;
    const result = try rewriteImports(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "/@modules/@lit/reactive-element") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "/@modules/lit-html") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "/@modules/lit-element/lit-element.js") != null);
}

test "rewrite scoped package import" {
    const input = "import { html } from '@angular/core';";
    const result = try rewriteImports(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "/@modules/@angular/core") != null);
}

test "keep relative export" {
    const input = "export * from './local.js';";
    const result = try rewriteImports(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "/@modules/") == null);
}

test "rewrite CSS import with ?import" {
    const input = "import './style.css';";
    const result = try rewriteCssImports(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "./style.css?import") != null);
}

test "rewrite CSS import double quotes" {
    const input =
        \\import React from 'react';
        \\import "../shared/reset.css";
        \\const x = 1;
    ;
    const result = try rewriteCssImports(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "reset.css?import") != null);
    // Non-CSS imports should not be modified
    try std.testing.expect(std.mem.indexOf(u8, result, "react?import") == null);
}

test "don't modify non-CSS imports" {
    const input = "import { foo } from './utils.js';";
    const result = try rewriteCssImports(std.testing.allocator, input);
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "?import") == null);
}
