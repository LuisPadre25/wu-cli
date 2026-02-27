// WU CLI — Reverse Proxy Server
//
// Unified entry point for all micro-apps during development.
// Routes requests to the appropriate Vite dev server based on path prefix.
// Pattern from FORJA's HTTP server, adapted for reverse proxy.
//
// Phase 3 implementation — placeholder for now.
// When fully implemented:
//   GET /topbar/*   → localhost:5001/*
//   GET /dashboard/* → localhost:5002/*
//   WS upgrade       → forwarded to correct Vite HMR server

const std = @import("std");

pub const ProxyServer = struct {
    port: u16,
    running: bool = false,

    pub fn init(port: u16) ProxyServer {
        return .{ .port = port };
    }

    pub fn start(_: *ProxyServer) !void {
        // Phase 3: implement HTTP proxy with WebSocket forwarding
    }

    pub fn stop(self: *ProxyServer) void {
        self.running = false;
    }
};
