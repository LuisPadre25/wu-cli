// WU Runtime — MIME Type Detection
//
// Maps file extensions to Content-Type headers.
// Covers web-essential types for a dev server.

const std = @import("std");

/// Return the Content-Type for a given file extension (including the dot).
pub fn forExtension(ext: []const u8) []const u8 {
    const eql = std.mem.eql;

    // HTML
    if (eql(u8, ext, ".html") or eql(u8, ext, ".htm")) return "text/html; charset=utf-8";

    // Stylesheets
    if (eql(u8, ext, ".css")) return "text/css; charset=utf-8";

    // JavaScript / TypeScript (served as JS after transform)
    if (eql(u8, ext, ".js") or eql(u8, ext, ".mjs") or eql(u8, ext, ".cjs")) return "application/javascript; charset=utf-8";
    if (eql(u8, ext, ".ts") or eql(u8, ext, ".mts")) return "application/javascript; charset=utf-8";
    if (eql(u8, ext, ".jsx") or eql(u8, ext, ".tsx")) return "application/javascript; charset=utf-8";

    // Data
    if (eql(u8, ext, ".json")) return "application/json; charset=utf-8";
    if (eql(u8, ext, ".xml")) return "application/xml; charset=utf-8";
    if (eql(u8, ext, ".txt")) return "text/plain; charset=utf-8";
    if (eql(u8, ext, ".csv")) return "text/csv; charset=utf-8";

    // Images
    if (eql(u8, ext, ".svg")) return "image/svg+xml";
    if (eql(u8, ext, ".png")) return "image/png";
    if (eql(u8, ext, ".jpg") or eql(u8, ext, ".jpeg")) return "image/jpeg";
    if (eql(u8, ext, ".gif")) return "image/gif";
    if (eql(u8, ext, ".webp")) return "image/webp";
    if (eql(u8, ext, ".ico")) return "image/x-icon";
    if (eql(u8, ext, ".avif")) return "image/avif";

    // Fonts
    if (eql(u8, ext, ".woff")) return "font/woff";
    if (eql(u8, ext, ".woff2")) return "font/woff2";
    if (eql(u8, ext, ".ttf")) return "font/ttf";
    if (eql(u8, ext, ".otf")) return "font/otf";
    if (eql(u8, ext, ".eot")) return "application/vnd.ms-fontobject";

    // Media
    if (eql(u8, ext, ".mp4")) return "video/mp4";
    if (eql(u8, ext, ".webm")) return "video/webm";
    if (eql(u8, ext, ".mp3")) return "audio/mpeg";
    if (eql(u8, ext, ".ogg")) return "audio/ogg";
    if (eql(u8, ext, ".wav")) return "audio/wav";

    // Other
    if (eql(u8, ext, ".wasm")) return "application/wasm";
    if (eql(u8, ext, ".map")) return "application/json";
    if (eql(u8, ext, ".pdf")) return "application/pdf";

    return "application/octet-stream";
}
