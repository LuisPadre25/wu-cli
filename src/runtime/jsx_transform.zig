// WU Runtime — Native JSX Transform
//
// Pure-Zig JSX transformation: <div> → __jsx("div", ...)
// Eliminates Node.js dependency for React/Preact .jsx/.tsx files.
//
// Ported from STORM testing framework, adapted for wu-cli.
// Uses __jsx/__Fragment as intermediary names; a preamble maps them
// to the framework's actual API (React.createElement, Preact h, etc.)
//
// The import rewriting phase (transform.zig) automatically converts
// the preamble's bare specifiers to /@modules/ paths.

const std = @import("std");
const Allocator = std.mem.Allocator;
const transform = @import("transform.zig");

// ── Public API ──────────────────────────────────────────────────────────────

/// Compile a .jsx/.tsx file natively without Node.js.
/// Steps: TS strip (if .tsx) → JSX transform → prepend framework import.
/// Returns allocator-owned JavaScript that caller must free.
pub fn compileJsxNative(
    allocator: Allocator,
    source: []const u8,
    framework: []const u8,
    is_tsx: bool,
) ![]const u8 {
    // Step 1: Strip TypeScript syntax if .tsx
    const stripped = if (is_tsx)
        try transform.stripTypeScript(allocator, source)
    else
        source;
    defer if (is_tsx) allocator.free(stripped);

    // Step 2: Transform JSX to __jsx() calls
    const jsx_result = try transformJsx(allocator, stripped);
    defer allocator.free(jsx_result);

    // Step 3: Choose framework preamble
    // __jsx maps to createElement/h, __Fragment maps to Fragment
    // The import rewriting phase handles bare → /@modules/ conversion
    const eql = std.mem.eql;
    const preamble = if (eql(u8, framework, "preact"))
        "import { h as __jsx, Fragment as __Fragment } from 'preact';\n"
    else
        // React (default) — also works for frameworks using React-compatible JSX
        "import { createElement as __jsx, Fragment as __Fragment } from 'react';\n";

    // Step 4: Concatenate preamble + transformed source
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, preamble);
    try out.appendSlice(allocator, jsx_result);
    return out.toOwnedSlice(allocator);
}

// ── JSX Transform Engine ────────────────────────────────────────────────────

/// Transform all JSX syntax in source to __jsx() calls.
/// Preserves line count (every \n in input produces \n in output).
/// Returns allocator-owned slice that caller must free.
pub fn transformJsx(allocator: Allocator, source: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < source.len) {
        const ch = source[i];

        // Skip string literals (preserve verbatim)
        if (ch == '"' or ch == '\'' or ch == '`') {
            i = try copyString(&out, allocator, source, i);
            continue;
        }

        // Skip line comments
        if (ch == '/' and i + 1 < source.len and source[i + 1] == '/') {
            while (i < source.len and source[i] != '\n') {
                try out.append(allocator, source[i]);
                i += 1;
            }
            continue;
        }

        // Skip block comments
        if (ch == '/' and i + 1 < source.len and source[i + 1] == '*') {
            try out.appendSlice(allocator, "/*");
            i += 2;
            while (i < source.len) {
                if (source[i] == '*' and i + 1 < source.len and source[i + 1] == '/') {
                    try out.appendSlice(allocator, "*/");
                    i += 2;
                    break;
                }
                try out.append(allocator, source[i]);
                i += 1;
            }
            continue;
        }

        // Check for JSX opening tag
        if (ch == '<' and isJsxStart(source, i)) {
            i = try parseJsxElement(allocator, source, i, &out);
            continue;
        }

        try out.append(allocator, ch);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

// ── JSX Disambiguation ──────────────────────────────────────────────────────

/// Determine if `<` at position `pos` starts a JSX element.
/// Returns false for comparisons, generics, and TSX arrow generics.
fn isJsxStart(source: []const u8, pos: usize) bool {
    if (pos + 1 >= source.len) return false;
    const next = source[pos + 1];

    // Fragment: <>
    if (next == '>') {
        var p = pos;
        while (p > 0 and (source[p - 1] == ' ' or source[p - 1] == '\t')) p -= 1;
        if (p > 0 and isIdentChar(source[p - 1])) return false;
        return true;
    }

    // Tag name must start with a letter, _ or $
    if (!std.ascii.isAlphabetic(next) and next != '_' and next != '$') return false;

    // Check context before <
    var p = pos;
    while (p > 0 and (source[p - 1] == ' ' or source[p - 1] == '\t')) p -= 1;

    if (p > 0) {
        const prev = source[p - 1];

        // After ) or ] -> NOT JSX (comparison or end of expression)
        if (prev == ')' or prev == ']') return false;

        // After number literal -> NOT JSX (comparison)
        if (prev >= '0' and prev <= '9') return false;

        // After identifier -> check if it's a keyword that can precede JSX
        if (isIdentChar(prev)) {
            var id_start = p - 1;
            while (id_start > 0 and isIdentChar(source[id_start - 1])) id_start -= 1;
            const ident = source[id_start..p];

            const jsx_keywords = [_][]const u8{
                "return", "case", "default", "typeof", "void",
                "delete", "throw", "new",     "in",    "of",
                "else",   "yield", "await",   "export",
            };
            var is_keyword = false;
            for (jsx_keywords) |kw| {
                if (std.mem.eql(u8, ident, kw)) {
                    is_keyword = true;
                    break;
                }
            }
            if (!is_keyword) return false;
        }
    }

    // Check for TSX generic patterns
    return checkNotGeneric(source, pos);
}

/// Verify the tag after `<` isn't a TypeScript generic parameter.
fn checkNotGeneric(source: []const u8, pos: usize) bool {
    var i = pos + 1;
    while (i < source.len and (isIdentChar(source[i]) or source[i] == '.')) i += 1;

    // Skip whitespace after tag name
    while (i < source.len and (source[i] == ' ' or source[i] == '\t')) i += 1;

    // <T,> -> generic
    if (i < source.len and source[i] == ',') return false;

    // <T = default> -> generic with default type
    if (i < source.len and source[i] == '=' and (i + 1 >= source.len or source[i + 1] != '>')) return false;

    // <T extends X> -> generic constraint
    if (i + 8 <= source.len and std.mem.startsWith(u8, source[i..], "extends ")) return false;
    if (i + 8 <= source.len and std.mem.startsWith(u8, source[i..], "extends(")) return false;

    return true;
}

// ── JSX Element Parser ──────────────────────────────────────────────────────

/// Parse a JSX element starting at `<`. Returns position after the element.
fn parseJsxElement(allocator: Allocator, source: []const u8, start: usize, out: *std.ArrayList(u8)) Allocator.Error!usize {
    var i = start + 1; // skip <

    // Fragment: <>...</>
    if (i < source.len and source[i] == '>') {
        i += 1;
        try out.appendSlice(allocator, "__jsx(__Fragment, null");
        i = try parseJsxChildren(allocator, source, i, out);
        try out.append(allocator, ')');
        return i;
    }

    // Read tag name (may be dotted: Component.Sub)
    const tag_start = i;
    while (i < source.len and (isIdentChar(source[i]) or source[i] == '.')) i += 1;
    const tag_name = source[tag_start..i];

    if (tag_name.len == 0) {
        // Safety: not actually JSX
        try out.append(allocator, '<');
        return start + 1;
    }

    // Emit: __jsx(
    try out.appendSlice(allocator, "__jsx(");

    // Lowercase first char -> string "div", otherwise -> identifier Component
    if (tag_name[0] >= 'a' and tag_name[0] <= 'z') {
        try out.append(allocator, '"');
        try out.appendSlice(allocator, tag_name);
        try out.append(allocator, '"');
    } else {
        try out.appendSlice(allocator, tag_name);
    }
    try out.appendSlice(allocator, ", ");

    // Scan ahead to determine if props exist
    var j = i;
    while (j < source.len and (source[j] == ' ' or source[j] == '\t' or source[j] == '\n' or source[j] == '\r')) j += 1;

    const has_props = j < source.len and source[j] != '>' and
        !(source[j] == '/' and j + 1 < source.len and source[j + 1] == '>');

    if (has_props) {
        try out.append(allocator, '{');
        i = try parseJsxProps(allocator, source, i, out);
        try out.append(allocator, '}');
    } else {
        i = try skipWs(source, i, out, allocator);
        try out.appendSlice(allocator, "null");
    }

    // Self-closing: />
    if (i + 1 < source.len and source[i] == '/' and source[i + 1] == '>') {
        i += 2;
        try out.append(allocator, ')');
        return i;
    }

    // Opening: > with children
    if (i < source.len and source[i] == '>') {
        i += 1;
        i = try parseJsxChildren(allocator, source, i, out);
        try out.append(allocator, ')');
        return i;
    }

    // Safety fallback
    try out.append(allocator, ')');
    return i;
}

// ── Props Parser ────────────────────────────────────────────────────────────

/// Parse JSX props. Returns position at `>` or `/>`.
fn parseJsxProps(allocator: Allocator, source: []const u8, start: usize, out: *std.ArrayList(u8)) Allocator.Error!usize {
    var i = start;
    var first = true;

    while (i < source.len) {
        i = try skipWs(source, i, out, allocator);

        if (i >= source.len) break;
        if (source[i] == '>') break;
        if (source[i] == '/' and i + 1 < source.len and source[i + 1] == '>') break;

        if (!first) try out.appendSlice(allocator, ", ");
        first = false;

        // Spread: {...expr}
        if (source[i] == '{' and i + 3 < source.len and
            source[i + 1] == '.' and source[i + 2] == '.' and source[i + 3] == '.')
        {
            try out.appendSlice(allocator, "...");
            i += 4; // skip {...
            i = try copyExpressionBody(allocator, source, i, out);
            continue;
        }

        // Prop name (supports hyphenated: data-id, aria-label)
        const name_start = i;
        while (i < source.len and (isIdentChar(source[i]) or source[i] == '-')) i += 1;
        const prop_name = source[name_start..i];

        // Skip whitespace between name and =
        while (i < source.len and (source[i] == ' ' or source[i] == '\t')) i += 1;

        if (i < source.len and source[i] == '=') {
            i += 1; // skip =
            while (i < source.len and (source[i] == ' ' or source[i] == '\t')) i += 1;

            try out.appendSlice(allocator, prop_name);
            try out.appendSlice(allocator, ": ");

            if (i < source.len and (source[i] == '"' or source[i] == '\'')) {
                // String value: prop="value"
                i = try copyString(out, allocator, source, i);
            } else if (i < source.len and source[i] == '{') {
                // Expression value: prop={expr}
                i += 1;
                i = try copyExpressionBody(allocator, source, i, out);
            }
        } else {
            // Boolean shorthand: prop -> prop: true
            try out.appendSlice(allocator, prop_name);
            try out.appendSlice(allocator, ": true");
        }
    }

    return i;
}

// ── Children Parser ─────────────────────────────────────────────────────────

/// Parse JSX children until closing tag. Returns position after `</Tag>`.
fn parseJsxChildren(allocator: Allocator, source: []const u8, start: usize, out: *std.ArrayList(u8)) Allocator.Error!usize {
    var i = start;

    while (i < source.len) {
        // Closing tag: </Tag> or </>
        if (source[i] == '<' and i + 1 < source.len and source[i + 1] == '/') {
            // Emit any newlines in the closing tag
            const close_start = i;
            i += 2; // skip </
            while (i < source.len and (isIdentChar(source[i]) or source[i] == '.')) i += 1;
            while (i < source.len and (source[i] == ' ' or source[i] == '\t')) i += 1;
            if (i < source.len and source[i] == '>') i += 1;
            // Emit newlines from closing tag region
            for (source[close_start..i]) |ch| {
                if (ch == '\n') try out.append(allocator, '\n');
            }
            return i;
        }

        // Expression child: {expr}
        if (source[i] == '{') {
            try out.appendSlice(allocator, ", ");
            i += 1;
            i = try copyExpressionBody(allocator, source, i, out);
            continue;
        }

        // Nested JSX element
        if (source[i] == '<' and isJsxStart(source, i)) {
            try out.appendSlice(allocator, ", ");
            i = try parseJsxElement(allocator, source, i, out);
            continue;
        }

        // Newline -> emit for line preservation
        if (source[i] == '\n') {
            try out.append(allocator, '\n');
            i += 1;
            continue;
        }

        // Text content: collect until {, <, or \n
        const text_start = i;
        while (i < source.len and source[i] != '{' and source[i] != '<' and source[i] != '\n') i += 1;

        const raw_text = source[text_start..i];
        const text = std.mem.trim(u8, raw_text, &.{ ' ', '\t', '\r' });
        if (text.len > 0) {
            try out.appendSlice(allocator, ", ");
            try emitEscapedString(out, allocator, text);
        }
    }

    return i;
}

// ── Expression Copier ───────────────────────────────────────────────────────

/// Copy expression body from inside {}, tracking nested braces/strings/JSX.
/// `start` is position AFTER the opening `{`.
/// Returns position AFTER the closing `}`.
fn copyExpressionBody(allocator: Allocator, source: []const u8, start: usize, out: *std.ArrayList(u8)) Allocator.Error!usize {
    var i = start;
    var depth: u32 = 1;

    while (i < source.len and depth > 0) {
        const ch = source[i];

        // String literals
        if (ch == '"' or ch == '\'' or ch == '`') {
            i = try copyString(out, allocator, source, i);
            continue;
        }

        // Line comment
        if (ch == '/' and i + 1 < source.len and source[i + 1] == '/') {
            while (i < source.len and source[i] != '\n') {
                try out.append(allocator, source[i]);
                i += 1;
            }
            continue;
        }

        // Block comment
        if (ch == '/' and i + 1 < source.len and source[i + 1] == '*') {
            try out.appendSlice(allocator, "/*");
            i += 2;
            while (i < source.len) {
                if (source[i] == '*' and i + 1 < source.len and source[i + 1] == '/') {
                    try out.appendSlice(allocator, "*/");
                    i += 2;
                    break;
                }
                try out.append(allocator, source[i]);
                i += 1;
            }
            continue;
        }

        // Nested JSX inside expression
        if (ch == '<' and isJsxStart(source, i)) {
            i = try parseJsxElement(allocator, source, i, out);
            continue;
        }

        if (ch == '(') {
            try out.append(allocator, ch);
            i += 1;
            continue;
        }

        if (ch == '{') depth += 1;
        if (ch == '}') {
            depth -= 1;
            if (depth == 0) {
                i += 1;
                return i;
            }
        }

        try out.append(allocator, ch);
        i += 1;
    }

    return i;
}

// ── Helpers ─────────────────────────────────────────────────────────────────

/// Copy a string literal including quotes. Handles escapes and template literals.
fn copyString(out: *std.ArrayList(u8), allocator: Allocator, source: []const u8, start: usize) Allocator.Error!usize {
    const quote = source[start];
    try out.append(allocator, quote);
    var i = start + 1;

    while (i < source.len) {
        const ch = source[i];

        // Escape sequence
        if (ch == '\\' and i + 1 < source.len) {
            try out.append(allocator, ch);
            i += 1;
            try out.append(allocator, source[i]);
            i += 1;
            continue;
        }

        // End of string
        if (ch == quote) {
            try out.append(allocator, ch);
            i += 1;
            return i;
        }

        // Template literal interpolation: ${...}
        if (quote == '`' and ch == '$' and i + 1 < source.len and source[i + 1] == '{') {
            try out.appendSlice(allocator, "${");
            i += 2;
            var depth: u32 = 1;
            while (i < source.len and depth > 0) {
                if (source[i] == '{') depth += 1;
                if (source[i] == '}') {
                    depth -= 1;
                    if (depth == 0) {
                        try out.append(allocator, '}');
                        i += 1;
                        break;
                    }
                }
                try out.append(allocator, source[i]);
                i += 1;
            }
            continue;
        }

        try out.append(allocator, ch);
        i += 1;
    }

    return i;
}

/// Emit a JavaScript string literal with proper escaping.
fn emitEscapedString(out: *std.ArrayList(u8), allocator: Allocator, text: []const u8) !void {
    try out.append(allocator, '"');
    for (text) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
}

/// Skip whitespace, emitting newlines for line preservation.
fn skipWs(source: []const u8, start: usize, out: *std.ArrayList(u8), allocator: Allocator) Allocator.Error!usize {
    var i = start;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\n' or source[i] == '\r')) {
        if (source[i] == '\n') try out.append(allocator, '\n');
        i += 1;
    }
    return i;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}
