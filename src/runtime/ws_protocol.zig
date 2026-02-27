// WU Runtime — WebSocket Protocol (RFC 6455)
//
// Frame parsing, building, masking, and handshake for WebSocket HMR.
// Ported from ZigStorm framework, adapted for wu-cli dev server.
//
// Used for bidirectional HMR: server pushes updates, browser can
// report cached modules, request specific reloads, etc.

const std = @import("std");
const mem = std.mem;
const crypto = std.crypto;
const base64 = std.base64;

// ── Opcodes ─────────────────────────────────────────────────────────────────

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,

    pub fn isControl(self: Opcode) bool {
        return @intFromEnum(self) >= 0x8;
    }
};

// ── Close Codes ─────────────────────────────────────────────────────────────

pub const CloseCode = enum(u16) {
    normal = 1000,
    going_away = 1001,
    protocol_error = 1002,
    unsupported_data = 1003,
    no_status = 1005,
    abnormal = 1006,
    invalid_payload = 1007,
    policy_violation = 1008,
    message_too_big = 1009,
    mandatory_extension = 1010,
    internal_error = 1011,
    _,

    pub fn fromInt(val: u16) CloseCode {
        return @enumFromInt(val);
    }
};

// ── Frame Header ────────────────────────────────────────────────────────────

pub const FrameHeader = struct {
    fin: bool,
    rsv1: bool = false,
    rsv2: bool = false,
    rsv3: bool = false,
    opcode: Opcode,
    masked: bool,
    payload_len: u64,
    mask_key: ?[4]u8,

    pub fn headerSize(self: FrameHeader) usize {
        var size: usize = 2;
        if (self.payload_len > 125) {
            if (self.payload_len <= 65535) {
                size += 2;
            } else {
                size += 8;
            }
        }
        if (self.masked) size += 4;
        return size;
    }
};

// ── Frame ───────────────────────────────────────────────────────────────────

pub const Frame = struct {
    header: FrameHeader,
    payload: []const u8,

    pub fn isText(self: Frame) bool {
        return self.header.opcode == .text;
    }

    pub fn isBinary(self: Frame) bool {
        return self.header.opcode == .binary;
    }

    pub fn isControl(self: Frame) bool {
        return self.header.opcode.isControl();
    }

    pub fn isFinal(self: Frame) bool {
        return self.header.fin;
    }
};

// ── Frame Parser ────────────────────────────────────────────────────────────

pub const FrameParser = struct {
    state: State = .header,
    header: FrameHeader = undefined,
    payload_received: usize = 0,
    header_bytes: [14]u8 = undefined,
    header_pos: usize = 0,

    const State = enum {
        header,
        extended_length_16,
        extended_length_64,
        mask_key,
        payload,
        complete,
    };

    pub const ParseResult = union(enum) {
        need_more: usize,
        frame: Frame,
        err: ParseError,
    };

    pub const ParseError = error{
        InvalidOpcode,
        ReservedBitsSet,
        ControlFrameTooLarge,
        ControlFrameFragmented,
        InvalidUtf8,
    };

    pub fn parse(self: *FrameParser, data: []const u8, payload_buf: []u8) struct { result: ParseResult, consumed: usize } {
        var pos: usize = 0;

        while (pos < data.len) {
            switch (self.state) {
                .header => {
                    if (pos + 2 > data.len) {
                        return .{ .result = .{ .need_more = 2 - (data.len - pos) }, .consumed = pos };
                    }

                    const b0 = data[pos];
                    const b1 = data[pos + 1];
                    pos += 2;

                    self.header.fin = (b0 & 0x80) != 0;
                    self.header.rsv1 = (b0 & 0x40) != 0;
                    self.header.rsv2 = (b0 & 0x20) != 0;
                    self.header.rsv3 = (b0 & 0x10) != 0;

                    if (self.header.rsv1 or self.header.rsv2 or self.header.rsv3) {
                        return .{ .result = .{ .err = error.ReservedBitsSet }, .consumed = pos };
                    }

                    const opcode_val = b0 & 0x0F;
                    self.header.opcode = std.meta.intToEnum(Opcode, opcode_val) catch {
                        return .{ .result = .{ .err = error.InvalidOpcode }, .consumed = pos };
                    };

                    self.header.masked = (b1 & 0x80) != 0;
                    const len7 = b1 & 0x7F;

                    if (self.header.opcode.isControl()) {
                        if (!self.header.fin) {
                            return .{ .result = .{ .err = error.ControlFrameFragmented }, .consumed = pos };
                        }
                        if (len7 > 125) {
                            return .{ .result = .{ .err = error.ControlFrameTooLarge }, .consumed = pos };
                        }
                    }

                    if (len7 < 126) {
                        self.header.payload_len = len7;
                        self.state = if (self.header.masked) .mask_key else .payload;
                    } else if (len7 == 126) {
                        self.state = .extended_length_16;
                    } else {
                        self.state = .extended_length_64;
                    }
                },

                .extended_length_16 => {
                    if (pos + 2 > data.len) {
                        return .{ .result = .{ .need_more = 2 - (data.len - pos) }, .consumed = pos };
                    }
                    self.header.payload_len = mem.readInt(u16, data[pos..][0..2], .big);
                    pos += 2;
                    self.state = if (self.header.masked) .mask_key else .payload;
                },

                .extended_length_64 => {
                    if (pos + 8 > data.len) {
                        return .{ .result = .{ .need_more = 8 - (data.len - pos) }, .consumed = pos };
                    }
                    self.header.payload_len = mem.readInt(u64, data[pos..][0..8], .big);
                    pos += 8;
                    self.state = if (self.header.masked) .mask_key else .payload;
                },

                .mask_key => {
                    if (pos + 4 > data.len) {
                        return .{ .result = .{ .need_more = 4 - (data.len - pos) }, .consumed = pos };
                    }
                    self.header.mask_key = data[pos..][0..4].*;
                    pos += 4;
                    self.state = .payload;
                },

                .payload => {
                    const remaining = self.header.payload_len - self.payload_received;
                    const available = data.len - pos;
                    const to_copy = @min(remaining, available);

                    if (to_copy > 0) {
                        const dest_start = self.payload_received;
                        const dest_end = dest_start + to_copy;

                        if (dest_end > payload_buf.len) {
                            return .{ .result = .{ .err = error.ControlFrameTooLarge }, .consumed = pos };
                        }

                        @memcpy(payload_buf[dest_start..dest_end], data[pos..][0..to_copy]);
                        self.payload_received += to_copy;
                        pos += to_copy;
                    }

                    if (self.payload_received >= self.header.payload_len) {
                        if (self.header.masked) {
                            if (self.header.mask_key) |key| {
                                unmaskPayload(payload_buf[0..self.header.payload_len], key);
                            }
                        }

                        self.state = .complete;
                        const frame = Frame{
                            .header = self.header,
                            .payload = payload_buf[0..self.header.payload_len],
                        };

                        self.reset();
                        return .{ .result = .{ .frame = frame }, .consumed = pos };
                    }

                    return .{ .result = .{ .need_more = remaining - to_copy }, .consumed = pos };
                },

                .complete => {
                    self.reset();
                },
            }
        }

        return .{ .result = .{ .need_more = 1 }, .consumed = pos };
    }

    pub fn reset(self: *FrameParser) void {
        self.state = .header;
        self.payload_received = 0;
        self.header_pos = 0;
    }
};

// ── Frame Builder ───────────────────────────────────────────────────────────

pub const FrameBuilder = struct {
    pub fn build(
        opcode: Opcode,
        payload: []const u8,
        fin: bool,
        mask: bool,
        buf: []u8,
    ) ![]u8 {
        var pos: usize = 0;

        buf[pos] = (@as(u8, if (fin) 0x80 else 0x00)) | @intFromEnum(opcode);
        pos += 1;

        const mask_bit: u8 = if (mask) 0x80 else 0x00;

        if (payload.len < 126) {
            buf[pos] = mask_bit | @as(u8, @intCast(payload.len));
            pos += 1;
        } else if (payload.len <= 65535) {
            buf[pos] = mask_bit | 126;
            pos += 1;
            mem.writeInt(u16, buf[pos..][0..2], @intCast(payload.len), .big);
            pos += 2;
        } else {
            buf[pos] = mask_bit | 127;
            pos += 1;
            mem.writeInt(u64, buf[pos..][0..8], payload.len, .big);
            pos += 8;
        }

        if (mask) {
            var mask_key: [4]u8 = undefined;
            crypto.random.bytes(&mask_key);
            @memcpy(buf[pos..][0..4], &mask_key);
            pos += 4;
            @memcpy(buf[pos..][0..payload.len], payload);
            maskPayload(buf[pos..][0..payload.len], mask_key);
        } else {
            @memcpy(buf[pos..][0..payload.len], payload);
        }

        pos += payload.len;
        return buf[0..pos];
    }

    pub fn text(payload: []const u8, buf: []u8) ![]u8 {
        return build(.text, payload, true, false, buf);
    }

    pub fn binary(payload: []const u8, buf: []u8) ![]u8 {
        return build(.binary, payload, true, false, buf);
    }

    pub fn ping(payload: []const u8, buf: []u8) ![]u8 {
        return build(.ping, payload, true, false, buf);
    }

    pub fn pong(payload: []const u8, buf: []u8) ![]u8 {
        return build(.pong, payload, true, false, buf);
    }

    pub fn close(code: CloseCode, reason: []const u8, buf: []u8) ![]u8 {
        var payload_buf: [127]u8 = undefined;
        mem.writeInt(u16, payload_buf[0..2], @intFromEnum(code), .big);
        const reason_len = @min(reason.len, 123);
        @memcpy(payload_buf[2..][0..reason_len], reason[0..reason_len]);
        return build(.close, payload_buf[0 .. 2 + reason_len], true, false, buf);
    }
};

// ── Masking (SIMD-optimized XOR) ────────────────────────────────────────────

pub fn maskPayload(data: []u8, key: [4]u8) void {
    if (data.len >= 16) {
        const V = @Vector(16, u8);
        var key_vec: V = undefined;
        for (0..4) |i| {
            key_vec[i * 4 + 0] = key[0];
            key_vec[i * 4 + 1] = key[1];
            key_vec[i * 4 + 2] = key[2];
            key_vec[i * 4 + 3] = key[3];
        }

        var pos: usize = 0;
        while (pos + 16 <= data.len) : (pos += 16) {
            const chunk: *V = @ptrCast(@alignCast(data[pos..].ptr));
            chunk.* ^= key_vec;
        }

        for (data[pos..], pos..) |*byte, i| {
            byte.* ^= key[i % 4];
        }
    } else {
        for (data, 0..) |*byte, i| {
            byte.* ^= key[i % 4];
        }
    }
}

pub fn unmaskPayload(data: []u8, key: [4]u8) void {
    maskPayload(data, key); // XOR is its own inverse
}

// ── Handshake ───────────────────────────────────────────────────────────────

pub const Handshake = struct {
    const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

    /// Generate Sec-WebSocket-Accept from Sec-WebSocket-Key.
    pub fn acceptKey(key: []const u8) [28]u8 {
        var hasher = crypto.hash.Sha1.init(.{});
        hasher.update(key);
        hasher.update(WS_GUID);
        const hash = hasher.finalResult();

        var accept: [28]u8 = undefined;
        _ = base64.standard.Encoder.encode(&accept, &hash);
        return accept;
    }

    /// Validate WebSocket upgrade request. Returns the key if valid.
    pub fn validateUpgrade(getHeader: anytype) ?[]const u8 {
        const upgrade = getHeader.get("Upgrade") orelse return null;
        if (!std.ascii.eqlIgnoreCase(upgrade, "websocket")) return null;

        const connection = getHeader.get("Connection") orelse return null;
        if (std.mem.indexOf(u8, connection, "Upgrade") == null and
            std.mem.indexOf(u8, connection, "upgrade") == null)
        {
            return null;
        }

        const version = getHeader.get("Sec-WebSocket-Version") orelse return null;
        if (!std.mem.eql(u8, version, "13")) return null;

        return getHeader.get("Sec-WebSocket-Key");
    }

    /// Build the 101 Switching Protocols response.
    pub fn buildResponse(key: []const u8, buf: []u8) []u8 {
        const accept = acceptKey(key);
        var pos: usize = 0;

        const header =
            "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: ";

        @memcpy(buf[pos..][0..header.len], header);
        pos += header.len;

        @memcpy(buf[pos..][0..28], &accept);
        pos += 28;

        @memcpy(buf[pos..][0..4], "\r\n\r\n");
        pos += 4;

        return buf[0..pos];
    }
};
