//! TCP Transport for OCapN CapTP
//!
//! Provides framed message exchange over TCP using message_frame.zig.
//! Handles connection lifecycle, buffered reads, and clean shutdown.
//! Designed for the C ABI boundary (libspatial_propagator dylib).

const std = @import("std");
const net = std.net;
const posix = std.posix;
const frame = @import("message_frame.zig");
const Allocator = std.mem.Allocator;

pub const TransportError = error{
    ConnectionRefused,
    ConnectionReset,
    Timeout,
    MessageTooLarge,
    BufferFull,
    NotConnected,
    AlreadyListening,
} || frame.FrameError || std.posix.ReadError || std.posix.WriteError || std.posix.ConnectError;

/// A single peer connection with framed message I/O.
pub const Connection = struct {
    stream: net.Stream,
    accumulator: frame.FrameAccumulator(65536),
    allocator: Allocator,
    connected: bool = true,

    pub fn init(allocator: Allocator, stream: net.Stream) Connection {
        return .{
            .stream = stream,
            .accumulator = .{},
            .allocator = allocator,
        };
    }

    /// Send a framed message (length-prefix + payload).
    pub fn send(self: *Connection, payload: []const u8) !void {
        if (!self.connected) return error.NotConnected;

        var header: [frame.HEADER_SIZE]u8 = undefined;
        if (payload.len > frame.MAX_MESSAGE_SIZE) return error.MessageTooLarge;
        const len_u32: u32 = @intCast(payload.len);
        header[0] = @intCast((len_u32 >> 24) & 0xFF);
        header[1] = @intCast((len_u32 >> 16) & 0xFF);
        header[2] = @intCast((len_u32 >> 8) & 0xFF);
        header[3] = @intCast(len_u32 & 0xFF);

        // Write header then payload
        _ = try self.stream.write(&header);
        _ = try self.stream.write(payload);
    }

    /// Receive the next complete framed message.
    /// Blocks until a full frame is available.
    /// Returns the payload slice (valid until next recv call).
    pub fn recv(self: *Connection) ![]const u8 {
        if (!self.connected) return error.NotConnected;

        while (true) {
            // Try to extract a complete frame from accumulated data
            if (self.accumulator.nextFrame()) |f| {
                return f.payload;
            }

            // Need more data from the network
            const write_buf = self.accumulator.writeSlice();
            if (write_buf.len == 0) return error.BufferFull;

            const n = self.stream.read(write_buf) catch |err| {
                self.connected = false;
                return err;
            };
            if (n == 0) {
                self.connected = false;
                return error.ConnectionReset;
            }
            self.accumulator.advance(n);
        }
    }

    /// Close the connection.
    pub fn close(self: *Connection) void {
        if (self.connected) {
            self.stream.close();
            self.connected = false;
        }
    }

    pub fn isConnected(self: *const Connection) bool {
        return self.connected;
    }
};

/// TCP transport: can listen for or initiate connections.
pub const TcpTransport = struct {
    allocator: Allocator,
    server: ?net.Server = null,
    address: net.Address,

    pub fn init(allocator: Allocator, address: net.Address) TcpTransport {
        return .{
            .allocator = allocator,
            .address = address,
        };
    }

    /// Start listening for incoming connections.
    pub fn listen(self: *TcpTransport) !void {
        if (self.server != null) return error.AlreadyListening;
        self.server = try self.address.listen(.{
            .reuse_address = true,
        });
    }

    /// Accept one incoming connection (blocking).
    pub fn accept(self: *TcpTransport) !Connection {
        const srv = self.server orelse return error.NotConnected;
        const accepted = try srv.accept();
        return Connection.init(self.allocator, accepted.stream);
    }

    /// Connect to a remote address (blocking).
    pub fn connect(self: *TcpTransport, remote: net.Address) !Connection {
        const stream = try net.tcpConnectToAddress(remote);
        return Connection.init(self.allocator, stream);
    }

    /// Stop listening and close the server socket.
    pub fn deinit(self: *TcpTransport) void {
        if (self.server) |*srv| {
            srv.deinit();
            self.server = null;
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "connection send and recv round-trip" {
    const allocator = std.testing.allocator;

    // Bind to a random port
    const addr = try net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const bound_addr = server.listen_address;

    // Spawn a thread that connects and sends a message
    const sender = try std.Thread.spawn(.{}, struct {
        fn run(bound: net.Address) void {
            const stream = net.tcpConnectToAddress(bound) catch return;
            var conn = Connection.init(std.testing.allocator, stream);
            defer conn.close();
            conn.send("hello from sender") catch {};
        }
    }.run, .{bound_addr});

    // Accept and receive
    const accepted = try server.accept();
    var conn = Connection.init(allocator, accepted.stream);
    defer conn.close();

    const payload = try conn.recv();
    try std.testing.expectEqualSlices(u8, "hello from sender", payload);

    sender.join();
}

test "bidirectional exchange" {
    const allocator = std.testing.allocator;

    const addr = try net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const bound_addr = server.listen_address;

    const echo_thread = try std.Thread.spawn(.{}, struct {
        fn run(bound: net.Address) void {
            const stream = net.tcpConnectToAddress(bound) catch return;
            var conn = Connection.init(std.testing.allocator, stream);
            defer conn.close();

            // Send, then receive echo
            conn.send("ping") catch return;
            const reply = conn.recv() catch return;
            std.debug.assert(std.mem.eql(u8, reply, "pong"));
        }
    }.run, .{bound_addr});

    const accepted = try server.accept();
    var conn = Connection.init(allocator, accepted.stream);
    defer conn.close();

    // Receive ping, send pong
    const msg = try conn.recv();
    try std.testing.expectEqualSlices(u8, "ping", msg);
    try conn.send("pong");

    echo_thread.join();
}
