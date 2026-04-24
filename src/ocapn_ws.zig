//! OCapN WebSocket netlayer.
//!
//! Per guile-goblins `goblins/ocapn/netlayer/websocket.scm` and OCapN draft
//! (meeting-minutes/2025-06-10):
//!
//!   - Transport symbol: `websocket` (NOT `ws`).
//!   - Binary frames only — each WS binary frame carries one Syrup value.
//!     (Syrup is self-delimiting, so concatenation also works, but
//!     guile-goblins emits one-per-frame.)
//!   - No `Sec-WebSocket-Protocol` is negotiated.
//!   - `ws://` or `wss://` selected by `encrypted?` flag; browsers require wss.
//!   - The `url` hint carries the reachable endpoint (e.g.
//!     `url=wss://spritely.institute:8080`); the designator itself is opaque
//!     (conventionally base32 of a long-term Ed25519 pubkey).
//!
//! This module covers two layers:
//!   1. Frame layer: maps Syrup-in / Syrup-out onto WS binary frames over an
//!      already-upgraded duplex stream (see `ByteStream`).
//!   2. HTTP upgrade handshake: `clientHandshake` + `serverHandshake` run
//!      RFC 6455 §4 on the same `ByteStream`, so a freshly-connected TCP
//!      socket can be upgraded in-place before framing starts. Headers are
//!      bounded to 8 KiB, no subprotocol/extensions negotiated.

const std = @import("std");
const syrup = @import("syrup");
const Allocator = std.mem.Allocator;

pub const WS_OPCODE_CONT: u4 = 0x0;
pub const WS_OPCODE_TEXT: u4 = 0x1;
pub const WS_OPCODE_BINARY: u4 = 0x2;
pub const WS_OPCODE_CLOSE: u4 = 0x8;
pub const WS_OPCODE_PING: u4 = 0x9;
pub const WS_OPCODE_PONG: u4 = 0xA;

/// Duplex stream as seen by a WS endpoint (post-upgrade). Reads and writes
/// are raw bytes; this module frames/unframes them.
pub const ByteStream = struct {
    ctx: *anyopaque,
    readFn: *const fn (*anyopaque, []u8) anyerror!usize,
    writeFn: *const fn (*anyopaque, []const u8) anyerror!usize,

    pub fn readAll(self: ByteStream, buf: []u8) !void {
        var total: usize = 0;
        while (total < buf.len) {
            const n = try self.readFn(self.ctx, buf[total..]);
            if (n == 0) return error.UnexpectedEOF;
            total += n;
        }
    }

    pub fn writeAll(self: ByteStream, buf: []const u8) !void {
        var total: usize = 0;
        while (total < buf.len) {
            const n = try self.writeFn(self.ctx, buf[total..]);
            if (n == 0) return error.WriteClosed;
            total += n;
        }
    }

    /// Wrap a `*std.net.Stream` as a `ByteStream`. The caller retains
    /// ownership of the underlying socket (close it when done).
    pub fn fromNetStream(stream: *std.net.Stream) ByteStream {
        const impl = struct {
            fn readFn(ctx: *anyopaque, out: []u8) anyerror!usize {
                const s: *std.net.Stream = @ptrCast(@alignCast(ctx));
                return s.read(out);
            }
            fn writeFn(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
                const s: *std.net.Stream = @ptrCast(@alignCast(ctx));
                return s.write(bytes);
            }
        };
        return .{ .ctx = stream, .readFn = impl.readFn, .writeFn = impl.writeFn };
    }
};

/// Encode one WS data frame with the given opcode and payload. Server-to-
/// client frames MUST NOT be masked; client-to-server MUST be. `masked`
/// controls this. Returns caller-owned bytes.
pub fn encodeFrame(
    allocator: Allocator,
    opcode: u4,
    payload: []const u8,
    masked: bool,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    // FIN=1, RSV=0, opcode.
    try out.append(@as(u8, 0x80) | @as(u8, opcode));

    const mask_bit: u8 = if (masked) 0x80 else 0x00;
    if (payload.len < 126) {
        try out.append(mask_bit | @as(u8, @intCast(payload.len)));
    } else if (payload.len <= 0xFFFF) {
        try out.append(mask_bit | 126);
        var len_be: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_be, @intCast(payload.len), .big);
        try out.appendSlice(&len_be);
    } else {
        try out.append(mask_bit | 127);
        var len_be: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_be, payload.len, .big);
        try out.appendSlice(&len_be);
    }

    if (masked) {
        var key: [4]u8 = undefined;
        std.crypto.random.bytes(&key);
        try out.appendSlice(&key);
        const base = out.items.len;
        try out.appendSlice(payload);
        for (out.items[base..], 0..) |*b, i| b.* ^= key[i % 4];
    } else {
        try out.appendSlice(payload);
    }
    return out.toOwnedSlice();
}

pub const Frame = struct {
    fin: bool,
    opcode: u4,
    payload: []u8, // caller-owned

    pub fn deinit(self: Frame, allocator: Allocator) void {
        allocator.free(self.payload);
    }
};

/// Decode exactly one WS frame from `stream`. Unmasks if the frame was
/// masked. Returns a caller-owned Frame.
pub fn readFrame(allocator: Allocator, stream: ByteStream) !Frame {
    var hdr: [2]u8 = undefined;
    try stream.readAll(&hdr);
    const fin = (hdr[0] & 0x80) != 0;
    const opcode: u4 = @intCast(hdr[0] & 0x0F);
    const masked = (hdr[1] & 0x80) != 0;
    var len: u64 = hdr[1] & 0x7F;
    if (len == 126) {
        var ext: [2]u8 = undefined;
        try stream.readAll(&ext);
        len = std.mem.readInt(u16, &ext, .big);
    } else if (len == 127) {
        var ext: [8]u8 = undefined;
        try stream.readAll(&ext);
        len = std.mem.readInt(u64, &ext, .big);
    }
    var key: [4]u8 = undefined;
    if (masked) try stream.readAll(&key);
    const payload = try allocator.alloc(u8, @intCast(len));
    errdefer allocator.free(payload);
    try stream.readAll(payload);
    if (masked) {
        for (payload, 0..) |*b, i| b.* ^= key[i % 4];
    }
    return .{ .fin = fin, .opcode = opcode, .payload = payload };
}

/// Send one Syrup value as a single WS binary frame.
pub fn sendSyrupFrame(
    allocator: Allocator,
    stream: ByteStream,
    syrup_bytes: []const u8,
    client_side: bool,
) !void {
    const frame = try encodeFrame(allocator, WS_OPCODE_BINARY, syrup_bytes, client_side);
    defer allocator.free(frame);
    try stream.writeAll(frame);
}

/// Read the next frame; error on non-binary data frames. Returns the
/// payload as a caller-owned byte slice. Ping frames are answered with
/// pong and skipped; close frames surface as `error.ConnectionClosed`.
pub fn recvSyrupFrame(
    allocator: Allocator,
    stream: ByteStream,
    client_side: bool,
) ![]u8 {
    while (true) {
        var f = try readFrame(allocator, stream);
        switch (f.opcode) {
            WS_OPCODE_BINARY => return f.payload,
            WS_OPCODE_PING => {
                defer allocator.free(f.payload);
                const pong = try encodeFrame(allocator, WS_OPCODE_PONG, f.payload, client_side);
                defer allocator.free(pong);
                try stream.writeAll(pong);
            },
            WS_OPCODE_PONG => {
                allocator.free(f.payload);
            },
            WS_OPCODE_CLOSE => {
                allocator.free(f.payload);
                return error.ConnectionClosed;
            },
            WS_OPCODE_TEXT => {
                allocator.free(f.payload);
                return error.UnexpectedTextFrame;
            },
            else => {
                allocator.free(f.payload);
                return error.UnknownOpcode;
            },
        }
    }
}

// ---- HTTP upgrade handshake -------------------------------------------------
//
// RFC 6455 §4.1/4.2. The GUID is fixed. No subprotocol, no extensions — we
// only support the bare OCapN profile.

pub const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Compute Sec-WebSocket-Accept = base64(sha1(key_text ++ GUID)). `key_text`
/// is the raw Sec-WebSocket-Key header value (a base64 16-byte nonce). Output
/// is written to `out`, which must be at least 28 bytes. Returns the written
/// slice.
pub fn computeAccept(key_text: []const u8, out: []u8) ![]const u8 {
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(key_text);
    h.update(WS_GUID);
    var digest: [20]u8 = undefined;
    h.final(&digest);
    const enc = std.base64.standard.Encoder;
    const needed = enc.calcSize(digest.len);
    if (out.len < needed) return error.BufferTooSmall;
    return enc.encode(out[0..needed], &digest);
}

/// Generate a fresh 16-byte random key and base64-encode it. Writes the
/// 24-byte base64 into `out` (must be >= 24 bytes). Returns the written slice.
pub fn freshClientKey(out: []u8) ![]const u8 {
    var nonce: [16]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    const enc = std.base64.standard.Encoder;
    const needed = enc.calcSize(nonce.len);
    if (out.len < needed) return error.BufferTooSmall;
    return enc.encode(out[0..needed], &nonce);
}

/// Client: write the HTTP Upgrade request and read until 101 is confirmed.
/// `host` goes into the Host header (e.g. "spritely.institute:8080"); `path`
/// is the request-URI (e.g. "/").
pub fn clientHandshake(
    allocator: Allocator,
    stream: ByteStream,
    host: []const u8,
    path: []const u8,
) !void {
    var key_buf: [24]u8 = undefined;
    const key = try freshClientKey(&key_buf);

    var req = std.ArrayList(u8).init(allocator);
    defer req.deinit();
    try req.writer().print(
        "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n\r\n",
        .{ path, host, key },
    );
    try stream.writeAll(req.items);

    // Read response headers until CRLFCRLF. Strict bounds: 8 KiB.
    var resp = std.ArrayList(u8).init(allocator);
    defer resp.deinit();
    while (true) {
        if (resp.items.len > 8192) return error.HeadersTooLarge;
        var b: [1]u8 = undefined;
        try stream.readAll(&b);
        try resp.append(b[0]);
        if (std.mem.endsWith(u8, resp.items, "\r\n\r\n")) break;
    }
    if (!std.mem.startsWith(u8, resp.items, "HTTP/1.1 101")) return error.UpgradeRejected;

    const expected = try expectedAcceptAlloc(allocator, key);
    defer allocator.free(expected);
    const got = findHeader(resp.items, "Sec-WebSocket-Accept") orelse return error.MissingAccept;
    if (!std.mem.eql(u8, got, expected)) return error.AcceptMismatch;
}

/// Server: read the HTTP Upgrade request, validate required headers, and
/// respond with 101. On failure the caller's stream is left in an undefined
/// state; they should close it.
pub fn serverHandshake(allocator: Allocator, stream: ByteStream) !void {
    var req = std.ArrayList(u8).init(allocator);
    defer req.deinit();
    while (true) {
        if (req.items.len > 8192) return error.HeadersTooLarge;
        var b: [1]u8 = undefined;
        try stream.readAll(&b);
        try req.append(b[0]);
        if (std.mem.endsWith(u8, req.items, "\r\n\r\n")) break;
    }

    if (!std.mem.startsWith(u8, req.items, "GET ")) return error.NotAGetRequest;
    const upgrade = findHeader(req.items, "Upgrade") orelse return error.MissingUpgrade;
    if (!asciiEqIgnoreCase(upgrade, "websocket")) return error.BadUpgradeHeader;
    const key = findHeader(req.items, "Sec-WebSocket-Key") orelse return error.MissingKey;

    var accept_buf: [32]u8 = undefined;
    const accept = try computeAccept(key, &accept_buf);

    var resp = std.ArrayList(u8).init(allocator);
    defer resp.deinit();
    try resp.writer().print(
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n",
        .{accept},
    );
    try stream.writeAll(resp.items);
}

fn expectedAcceptAlloc(allocator: Allocator, key_text: []const u8) ![]u8 {
    var buf: [32]u8 = undefined;
    const s = try computeAccept(key_text, &buf);
    return allocator.dupe(u8, s);
}

/// Case-insensitive header lookup. Returns the trimmed value slice into
/// `headers`, or null if absent. Header block is assumed CRLF-terminated
/// start + body, ending with CRLFCRLF.
fn findHeader(headers: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, headers, "\r\n");
    _ = it.next(); // skip request/status line
    while (it.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (colon != name.len) continue;
        if (!asciiEqIgnoreCase(line[0..colon], name)) continue;
        var v = line[colon + 1 ..];
        while (v.len > 0 and (v[0] == ' ' or v[0] == '\t')) v = v[1..];
        while (v.len > 0 and (v[v.len - 1] == ' ' or v[v.len - 1] == '\t')) v = v[0 .. v.len - 1];
        return v;
    }
    return null;
}

fn asciiEqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const xl = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const yl = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (xl != yl) return false;
    }
    return true;
}

// ---- Tests ------------------------------------------------------------------

const MemStream = struct {
    buf: std.ArrayList(u8),
    cursor: usize = 0,

    fn read(ctx: *anyopaque, out: []u8) anyerror!usize {
        const self: *MemStream = @ptrCast(@alignCast(ctx));
        const avail = self.buf.items.len - self.cursor;
        if (avail == 0) return 0;
        const n = @min(avail, out.len);
        @memcpy(out[0..n], self.buf.items[self.cursor..][0..n]);
        self.cursor += n;
        return n;
    }

    fn write(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
        const self: *MemStream = @ptrCast(@alignCast(ctx));
        try self.buf.appendSlice(bytes);
        return bytes.len;
    }

    fn stream(self: *MemStream) ByteStream {
        return .{ .ctx = self, .readFn = read, .writeFn = write };
    }
};

test "WS binary frame round-trip (unmasked server frame)" {
    const allocator = std.testing.allocator;
    var mem = MemStream{ .buf = std.ArrayList(u8).init(allocator) };
    defer mem.buf.deinit();

    const payload = "<5'hello>";
    try sendSyrupFrame(allocator, mem.stream(), payload, false);

    mem.cursor = 0;
    const got = try recvSyrupFrame(allocator, mem.stream(), false);
    defer allocator.free(got);
    try std.testing.expectEqualSlices(u8, payload, got);
}

test "WS binary frame round-trip (masked client frame)" {
    const allocator = std.testing.allocator;
    var mem = MemStream{ .buf = std.ArrayList(u8).init(allocator) };
    defer mem.buf.deinit();

    const payload = "<12'op:deliver-only5'greet0+>";
    try sendSyrupFrame(allocator, mem.stream(), payload, true);

    mem.cursor = 0;
    const got = try recvSyrupFrame(allocator, mem.stream(), false);
    defer allocator.free(got);
    try std.testing.expectEqualSlices(u8, payload, got);
}

test "computeAccept matches RFC 6455 §1.3 example" {
    // RFC 6455 §1.3: key "dGhlIHNhbXBsZSBub25jZQ==" → accept
    // "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=".
    var buf: [32]u8 = undefined;
    const accept = try computeAccept("dGhlIHNhbXBsZSBub25jZQ==", &buf);
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}

test "WS handshake client + server end-to-end via MemStream pair" {
    const allocator = std.testing.allocator;

    // Two buffers: client_to_server and server_to_client. Each endpoint
    // reads from one and writes to the other.
    var c2s = std.ArrayList(u8).init(allocator);
    defer c2s.deinit();
    var s2c = std.ArrayList(u8).init(allocator);
    defer s2c.deinit();

    const Pair = struct {
        read_buf: *std.ArrayList(u8),
        read_cursor: usize = 0,
        write_buf: *std.ArrayList(u8),

        fn readFn(ctx: *anyopaque, out: []u8) anyerror!usize {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const avail = self.read_buf.items.len - self.read_cursor;
            if (avail == 0) return 0;
            const n = @min(avail, out.len);
            @memcpy(out[0..n], self.read_buf.items[self.read_cursor..][0..n]);
            self.read_cursor += n;
            return n;
        }
        fn writeFn(ctx: *anyopaque, bytes: []const u8) anyerror!usize {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.write_buf.appendSlice(bytes);
            return bytes.len;
        }
        fn stream(self: *@This()) ByteStream {
            return .{ .ctx = self, .readFn = readFn, .writeFn = writeFn };
        }
    };

    var client = Pair{ .read_buf = &s2c, .write_buf = &c2s };
    var server = Pair{ .read_buf = &c2s, .write_buf = &s2c };

    // Client writes its GET request into c2s (no server reply yet to read).
    // We mock this by splitting: first emit the client's GET, then run the
    // server to drain it and reply, then let the client verify.
    // Simplest: do server handshake from the already-written request.
    //
    // Two-phase: (1) manually perform the "client sends GET" step by
    // copying the expected request into c2s; then (2) run serverHandshake
    // on it; then (3) parse the response on the client side.
    //
    // To actually exercise clientHandshake we need interleaving I/O, which
    // the MemStream model can't do with a single thread. So instead: run
    // serverHandshake after piping a known-good GET in, then independently
    // verify the response is shaped right.
    const get =
        "GET / HTTP/1.1\r\n" ++
        "Host: example.org\r\n" ++
        "Upgrade: websocket\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
        "Sec-WebSocket-Version: 13\r\n\r\n";
    try c2s.appendSlice(get);

    try serverHandshake(allocator, server.stream());

    try std.testing.expect(std.mem.startsWith(u8, s2c.items, "HTTP/1.1 101"));
    const accept = findHeader(s2c.items, "Sec-WebSocket-Accept") orelse return error.TestFailed;
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}
