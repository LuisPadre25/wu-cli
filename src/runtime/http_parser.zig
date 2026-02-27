// WU Runtime — SIMD-Accelerated HTTP Parser
//
// Zero-copy HTTP/1.1 parser using Zig's @Vector for SIMD operations.
// Ported from ZigStorm framework, adapted for wu-cli dev server.
//
// Performance: 16 bytes/cycle for delimiter searches vs 1 byte/cycle scalar.
// Zero allocations during parsing (operates on input buffer slices).

const std = @import("std");
const mem = std.mem;

// ── SIMD Types ──────────────────────────────────────────────────────────────

const V16 = @Vector(16, u8);

// ── HTTP Method ─────────────────────────────────────────────────────────────

pub const Method = enum(u8) {
    GET = 0,
    POST = 1,
    PUT = 2,
    DELETE = 3,
    PATCH = 4,
    HEAD = 5,
    OPTIONS = 6,
    CONNECT = 7,
    TRACE = 8,

    pub fn fromString(str: []const u8) ?Method {
        if (str.len < 3 or str.len > 7) return null;
        return switch (str.len) {
            3 => if (mem.eql(u8, str, "GET")) .GET else null,
            4 => if (mem.eql(u8, str, "POST")) .POST else if (mem.eql(u8, str, "HEAD")) .HEAD else null,
            5 => if (mem.eql(u8, str, "PATCH")) .PATCH else if (mem.eql(u8, str, "TRACE")) .TRACE else null,
            6 => if (mem.eql(u8, str, "DELETE")) .DELETE else null,
            7 => if (mem.eql(u8, str, "OPTIONS")) .OPTIONS else if (mem.eql(u8, str, "CONNECT")) .CONNECT else null,
            else => null,
        };
    }

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .PATCH => "PATCH",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
            .CONNECT => "CONNECT",
            .TRACE => "TRACE",
        };
    }
};

// ── Parsed Request (Zero-Copy) ──────────────────────────────────────────────

pub const Request = struct {
    method: Method,
    path: []const u8,
    query: ?[]const u8,
    version: HttpVersion,
    headers: Headers,
    body: []const u8,
    bytes_parsed: usize,

    pub const HttpVersion = enum {
        http_1_0,
        http_1_1,
    };

    pub fn getHeader(self: *const Request, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Headers = struct {
    items: [MAX_HEADERS]Header,
    len: usize,

    pub const MAX_HEADERS = 64;

    pub fn get(self: *const Headers, name: []const u8) ?[]const u8 {
        for (self.items[0..self.len]) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) {
                return h.value;
            }
        }
        return null;
    }

    pub fn iterator(self: *const Headers) []const Header {
        return self.items[0..self.len];
    }
};

// ── Parser Errors ───────────────────────────────────────────────────────────

pub const ParseError = error{
    InvalidMethod,
    InvalidPath,
    InvalidVersion,
    InvalidHeader,
    HeadersTooLarge,
    TooManyHeaders,
    IncompleteRequest,
    InvalidCharacter,
};

// ── SIMD HTTP Parser ────────────────────────────────────────────────────────

pub const HttpParser = struct {
    const CR_MASK: V16 = @splat('\r');
    const COLON_MASK: V16 = @splat(':');

    /// Parse an HTTP request from raw bytes (zero-copy).
    pub fn parse(data: []const u8) ParseError!Request {
        if (data.len < 14) return error.IncompleteRequest;

        var pos: usize = 0;

        // 1. Parse method
        const method_result = parseMethod(data) orelse return error.InvalidMethod;
        const method = method_result.method;
        pos = method_result.end;

        if (pos >= data.len or data[pos] != ' ') return error.InvalidMethod;
        pos += 1;

        // 2. Parse path + query
        const path_start = pos;
        const path_end = findCharSimd(data[pos..], ' ', '?') orelse return error.InvalidPath;
        pos += path_end;

        var path = data[path_start..pos];
        var query: ?[]const u8 = null;

        if (pos < data.len and data[pos] == '?') {
            path = data[path_start..pos];
            pos += 1;
            const query_start = pos;
            const query_end = findCharSimd(data[pos..], ' ', ' ') orelse return error.InvalidPath;
            query = data[query_start .. query_start + query_end];
            pos += query_end;
        }

        if (pos >= data.len or data[pos] != ' ') return error.InvalidPath;
        pos += 1;

        // 3. Parse HTTP version
        const version = parseVersion(data[pos..]) orelse return error.InvalidVersion;
        pos += 8;

        if (pos + 1 >= data.len or data[pos] != '\r' or data[pos + 1] != '\n') {
            return error.InvalidVersion;
        }
        pos += 2;

        // 4. Parse headers
        var headers = Headers{ .items = undefined, .len = 0 };
        const headers_end = try parseHeaders(data[pos..], &headers);
        pos += headers_end;

        // 5. Body is everything after headers
        const body = if (pos < data.len) data[pos..] else "";

        return Request{
            .method = method,
            .path = path,
            .query = query,
            .version = version,
            .headers = headers,
            .body = body,
            .bytes_parsed = pos,
        };
    }

    fn parseMethod(data: []const u8) ?struct { method: Method, end: usize } {
        if (data.len < 3) return null;

        if (data.len >= 4 and data[3] == ' ') {
            if (data[0] == 'G' and data[1] == 'E' and data[2] == 'T') {
                return .{ .method = .GET, .end = 3 };
            }
            if (data[0] == 'P' and data[1] == 'U' and data[2] == 'T') {
                return .{ .method = .PUT, .end = 3 };
            }
        }

        if (data.len >= 5 and data[4] == ' ') {
            const word = mem.readInt(u32, data[0..4], .big);
            return switch (word) {
                0x504F5354 => .{ .method = .POST, .end = 4 },
                0x48454144 => .{ .method = .HEAD, .end = 4 },
                else => null,
            };
        }

        if (data.len >= 6 and data[5] == ' ') {
            if (mem.eql(u8, data[0..5], "PATCH")) return .{ .method = .PATCH, .end = 5 };
            if (mem.eql(u8, data[0..5], "TRACE")) return .{ .method = .TRACE, .end = 5 };
        }

        if (data.len >= 7 and data[6] == ' ') {
            if (mem.eql(u8, data[0..6], "DELETE")) return .{ .method = .DELETE, .end = 6 };
        }

        if (data.len >= 8 and data[7] == ' ') {
            if (mem.eql(u8, data[0..7], "OPTIONS")) return .{ .method = .OPTIONS, .end = 7 };
            if (mem.eql(u8, data[0..7], "CONNECT")) return .{ .method = .CONNECT, .end = 7 };
        }

        return null;
    }

    fn parseVersion(data: []const u8) ?Request.HttpVersion {
        if (data.len < 8) return null;
        if (data[0] == 'H' and data[1] == 'T' and data[2] == 'T' and data[3] == 'P' and
            data[4] == '/' and data[5] == '1' and data[6] == '.')
        {
            return switch (data[7]) {
                '1' => .http_1_1,
                '0' => .http_1_0,
                else => null,
            };
        }
        return null;
    }

    fn parseHeaders(data: []const u8, headers: *Headers) ParseError!usize {
        var pos: usize = 0;

        while (pos < data.len) {
            if (pos + 1 < data.len and data[pos] == '\r' and data[pos + 1] == '\n') {
                return pos + 2;
            }

            const name_end = findColonSimd(data[pos..]) orelse return error.InvalidHeader;
            const name = mem.trim(u8, data[pos .. pos + name_end], " \t");
            if (name.len == 0) return error.InvalidHeader;

            pos += name_end + 1;

            while (pos < data.len and (data[pos] == ' ' or data[pos] == '\t')) {
                pos += 1;
            }

            const value_start = pos;
            const value_end = findCrlfSimd(data[pos..]) orelse return error.IncompleteRequest;
            const value = mem.trim(u8, data[value_start .. value_start + value_end], " \t");

            pos += value_end + 2;

            if (headers.len >= Headers.MAX_HEADERS) {
                return error.TooManyHeaders;
            }

            headers.items[headers.len] = .{ .name = name, .value = value };
            headers.len += 1;
        }

        return error.IncompleteRequest;
    }

    // ── SIMD Search Functions ───────────────────────────────────────────────

    /// Find first occurrence of char1 or char2 using SIMD (16 bytes at a time).
    fn findCharSimd(data: []const u8, char1: u8, char2: u8) ?usize {
        const mask1: V16 = @splat(char1);
        const mask2: V16 = @splat(char2);
        var pos: usize = 0;

        while (pos + 16 <= data.len) {
            const chunk: V16 = data[pos..][0..16].*;
            const match1 = chunk == mask1;
            const match2 = chunk == mask2;
            const combined = @as(u16, @bitCast(match1)) | @as(u16, @bitCast(match2));

            if (combined != 0) {
                return pos + @ctz(combined);
            }
            pos += 16;
        }

        // Scalar fallback
        while (pos < data.len) : (pos += 1) {
            if (data[pos] == char1 or data[pos] == char2) return pos;
        }
        return null;
    }

    /// Find CRLF (\r\n) using SIMD.
    fn findCrlfSimd(data: []const u8) ?usize {
        var pos: usize = 0;

        while (pos + 16 <= data.len) {
            const chunk: V16 = data[pos..][0..16].*;
            const cr_matches = chunk == CR_MASK;
            var cr_mask = @as(u16, @bitCast(cr_matches));

            while (cr_mask != 0) {
                const offset = @ctz(cr_mask);
                const idx = pos + offset;
                if (idx + 1 < data.len and data[idx + 1] == '\n') {
                    return idx;
                }
                cr_mask &= cr_mask - 1;
            }
            pos += 16;
        }

        // Scalar fallback
        while (pos + 1 < data.len) : (pos += 1) {
            if (data[pos] == '\r' and data[pos + 1] == '\n') return pos;
        }
        return null;
    }

    /// Find ':' using SIMD (for header name parsing).
    fn findColonSimd(data: []const u8) ?usize {
        var pos: usize = 0;

        while (pos + 16 <= data.len) {
            const chunk: V16 = data[pos..][0..16].*;
            const matches = chunk == COLON_MASK;
            const mask = @as(u16, @bitCast(matches));

            if (mask != 0) {
                return pos + @ctz(mask);
            }
            pos += 16;
        }

        // Scalar fallback
        while (pos < data.len) : (pos += 1) {
            if (data[pos] == ':') return pos;
        }
        return null;
    }

    /// Find end of header section (double CRLF: \r\n\r\n).
    pub fn findHeaderEnd(data: []const u8) ?usize {
        var pos: usize = 0;
        while (pos + 4 <= data.len) {
            if (data[pos] == '\r' and data[pos + 1] == '\n' and
                data[pos + 2] == '\r' and data[pos + 3] == '\n')
            {
                return pos + 4;
            }
            pos += 1;
        }
        return null;
    }
};
