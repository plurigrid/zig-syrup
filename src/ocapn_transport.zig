//! OCapN TCP transport: streaming Syrup, no length prefix.
//!
//! Guile Goblins and Racket Goblins TCP netlayers send unframed Syrup values
//! back-to-back over the socket. Each top-level value is self-delimiting via
//! the Syrup grammar, so the receiver just parses one value at a time from an
//! accumulating byte buffer.
//!
//! This transport is the wire-compatible sibling of `tcp_transport.zig`
//! (which uses a 4-byte big-endian length prefix — kept for zig↔zig and
//! Rosette-bridge traffic).

const std = @import("std");
const compat = @import("compat");
const net = compat;
const syrup = @import("syrup");
const Allocator = std.mem.Allocator;

pub const RECV_CHUNK: usize = 4096;
pub const DEFAULT_BUF_CAP: usize = 64 * 1024;

pub const TransportError = error{
    NotConnected,
    ConnectionClosed,
    BufferExhausted,
    ReadFailed,
    WriteFailed,
} || syrup.ParseError || Allocator.Error;

/// Streaming Syrup connection. Owns an expandable byte buffer that accumulates
/// partial reads until a complete value can be parsed.
pub const OcapnConnection = struct {
    stream: net.Stream,
    allocator: Allocator,
    buf: std.ArrayListUnmanaged(u8),
    connected: bool = true,

    pub fn init(allocator: Allocator, stream: net.Stream) OcapnConnection {
        return .{
            .stream = stream,
            .allocator = allocator,
            .buf = compat.emptyList(u8),
        };
    }

    pub fn deinit(self: *OcapnConnection) void {
        self.buf.deinit(self.allocator);
        if (self.connected) {
            self.stream.close();
            self.connected = false;
        }
    }

    /// Send a pre-encoded Syrup value as raw bytes. No prefix.
    pub fn sendBytes(self: *OcapnConnection, bytes: []const u8) !void {
        if (!self.connected) return error.NotConnected;
        var written: usize = 0;
        while (written < bytes.len) {
            const n = self.stream.write(bytes[written..]) catch {
                self.connected = false;
                return error.WriteFailed;
            };
            if (n == 0) {
                self.connected = false;
                return error.WriteFailed;
            }
            written += n;
        }
    }

    /// Encode a syrup.Value into a caller-owned buffer and send.
    pub fn sendValue(self: *OcapnConnection, value: syrup.Value) !void {
        const bytes = try value.encodeAlloc(self.allocator);
        defer self.allocator.free(bytes);
        try self.sendBytes(bytes);
    }

    /// Receive the next complete Syrup value. Reads more bytes as needed.
    /// Caller owns the returned Value and must call `.deinit(allocator)`.
    pub fn recvValue(self: *OcapnConnection) !syrup.Value {
        if (!self.connected) return error.NotConnected;

        while (true) {
            if (self.buf.items.len > 0) {
                var parser = syrup.Parser.init(self.buf.items, self.allocator);
                const parsed = parser.parse() catch |err| switch (err) {
                    error.UnexpectedEOF => {
                        try self.readMore();
                        continue;
                    },
                    else => return err,
                };
                const consumed = parser.pos;
                std.mem.copyForwards(u8, self.buf.items[0 .. self.buf.items.len - consumed], self.buf.items[consumed..]);
                self.buf.items.len -= consumed;
                return parsed;
            }
            try self.readMore();
        }
    }

    fn readMore(self: *OcapnConnection) !void {
        var scratch: [RECV_CHUNK]u8 = undefined;
        const n = self.stream.read(&scratch) catch {
            self.connected = false;
            return error.ReadFailed;
        };
        if (n == 0) {
            self.connected = false;
            return error.ConnectionClosed;
        }
        try self.buf.appendSlice(self.allocator, scratch[0..n]);
    }

    pub fn isConnected(self: *const OcapnConnection) bool {
        return self.connected;
    }
};

/// Stream-based OCapN server/client convenience.
pub const OcapnTransport = struct {
    allocator: Allocator,
    server: ?net.Server = null,
    address: net.Address,

    pub fn init(allocator: Allocator, address: net.Address) OcapnTransport {
        return .{ .allocator = allocator, .address = address };
    }

    pub fn listen(self: *OcapnTransport) !void {
        if (self.server != null) return;
        self.server = try self.address.listen(.{ .reuse_address = true });
    }

    pub fn accept(self: *OcapnTransport) !OcapnConnection {
        const srv = self.server orelse return error.NotConnected;
        const accepted = try srv.accept();
        return OcapnConnection.init(self.allocator, accepted.stream);
    }

    pub fn connect(self: *OcapnTransport, remote: net.Address) !OcapnConnection {
        const stream = try net.tcpConnectToAddress(remote);
        return OcapnConnection.init(self.allocator, stream);
    }

    pub fn deinit(self: *OcapnTransport) void {
        if (self.server) |*srv| {
            srv.deinit();
            self.server = null;
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "streaming: single value round-trip" {
    const allocator = std.testing.allocator;

    const addr = try net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const bound = server.listen_address;

    const sender = try std.Thread.spawn(.{}, struct {
        fn run(b: net.Address) void {
            const stream = net.tcpConnectToAddress(b) catch return;
            var conn = OcapnConnection.init(std.testing.allocator, stream);
            defer conn.deinit();
            // Send a plain integer 42+
            conn.sendBytes("42+") catch {};
        }
    }.run, .{bound});

    const accepted = try server.accept();
    var conn = OcapnConnection.init(allocator, accepted.stream);
    defer conn.deinit();

    var v = try conn.recvValue();
    defer v.deinitAll(allocator);
    try std.testing.expectEqual(@as(i64, 42), v.integer);

    sender.join();
}

test "streaming: back-to-back values, no framing" {
    const allocator = std.testing.allocator;

    const addr = try net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const bound = server.listen_address;

    const sender = try std.Thread.spawn(.{}, struct {
        fn run(b: net.Address) void {
            const stream = net.tcpConnectToAddress(b) catch return;
            var conn = OcapnConnection.init(std.testing.allocator, stream);
            defer conn.deinit();
            // Three values concatenated with no separators: 1+ 2+ <3'abc>
            conn.sendBytes("1+2+<3'abc>") catch {};
        }
    }.run, .{bound});

    const accepted = try server.accept();
    var conn = OcapnConnection.init(allocator, accepted.stream);
    defer conn.deinit();

    var v1 = try conn.recvValue();
    defer v1.deinitAll(allocator);
    try std.testing.expectEqual(@as(i64, 1), v1.integer);

    var v2 = try conn.recvValue();
    defer v2.deinitAll(allocator);
    try std.testing.expectEqual(@as(i64, 2), v2.integer);

    var v3 = try conn.recvValue();
    defer v3.deinitAll(allocator);
    try std.testing.expectEqualStrings("abc", v3.record.label.symbol);

    sender.join();
}

test "streaming: split value across reads" {
    const allocator = std.testing.allocator;

    const addr = try net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const bound = server.listen_address;

    const sender = try std.Thread.spawn(.{}, struct {
        fn run(b: net.Address) void {
            const stream = net.tcpConnectToAddress(b) catch return;
            var conn = OcapnConnection.init(std.testing.allocator, stream);
            defer conn.deinit();
            // Split "<5'hello>" across two writes to exercise partial-parse retry.
            conn.sendBytes("<5'he") catch {};
            std.Thread.sleep(10 * std.time.ns_per_ms);
            conn.sendBytes("llo>") catch {};
        }
    }.run, .{bound});

    const accepted = try server.accept();
    var conn = OcapnConnection.init(allocator, accepted.stream);
    defer conn.deinit();

    var v = try conn.recvValue();
    defer v.deinitAll(allocator);
    try std.testing.expectEqualStrings("hello", v.record.label.symbol);

    sender.join();
}
