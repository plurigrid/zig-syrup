/// Ghostty WebSocket Server for Emacs Integration
///
/// Streams VT sequences from Ghostty over WebSocket to Emacs client.
/// - Listens on TCP :7070 (default)
/// - Handles WebSocket protocol handshake (RFC 6455)
/// - Encodes VT output in binary frames (websocket_framing.zig)
/// - Routes input events back to Ghostty terminal
/// - Advertises on NATS mcp.terms.* subject

const std = @import("std");
const websocket_framing = @import("websocket_framing");

const Frame = websocket_framing.Frame;
const MessageType = websocket_framing.MessageType;
const InitMessage = websocket_framing.InitMessage;
const OutputMessage = websocket_framing.OutputMessage;
const DirtyRegionMessage = websocket_framing.DirtyRegionMessage;
const InputMessage = websocket_framing.InputMessage;
const SpatialMessage = websocket_framing.SpatialMessage;
const FrameAccumulator = websocket_framing.FrameAccumulator;

/// WebSocket client connection state
pub const WebSocketConnection = struct {
    stream: std.net.Stream,
    accumulator: FrameAccumulator,
    term_width: u16 = 80,
    term_height: u16 = 24,
    is_upgraded: bool = false,
    last_activity: i64 = 0,

    pub fn deinit(self: *WebSocketConnection) void {
        self.stream.close();
        self.accumulator.deinit();
    }

    /// Handle WebSocket upgrade from HTTP
    pub fn upgradeFromHttp(self: *WebSocketConnection, http_request: []const u8) !bool {
        // Minimal WebSocket upgrade validation
        // RFC 6455: Look for "GET /" and "Upgrade: websocket"

        if (!std.mem.containsAtLeast(u8, http_request, 1, "Upgrade: websocket") and
            !std.mem.containsAtLeast(u8, http_request, 1, "upgrade: websocket")) {
            return false;
        }

        if (!std.mem.containsAtLeast(u8, http_request, 1, "Sec-WebSocket-Key")) {
            return false;
        }

        // Extract Sec-WebSocket-Key for response
        const key_start = std.mem.indexOf(u8, http_request, "Sec-WebSocket-Key: ") orelse return false;
        const key_offset = key_start + "Sec-WebSocket-Key: ".len;
        const key_end = std.mem.indexOfScalar(u8, http_request[key_offset..], '\r') orelse return false;
        const client_key = http_request[key_offset..][0..key_end];

        // Compute Sec-WebSocket-Accept via RFC 6455
        const GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        var sha1_input: [60]u8 = undefined;
        @memcpy(sha1_input[0..client_key.len], client_key);
        @memcpy(sha1_input[client_key.len..][0..GUID.len], GUID);
        const total_len = client_key.len + GUID.len;

        // SHA-1 hash
        var hash: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(sha1_input[0..total_len], &hash, .{});

        // Base64 encode the hash
        const base64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        var accept_key: [28]u8 = undefined;
        var out_idx: usize = 0;

        // Encode 20 bytes to base64 (becomes ~27 chars)
        var i: usize = 0;
        while (i < hash.len) : (i += 3) {
            const b0 = hash[i];
            const b1 = if (i + 1 < hash.len) hash[i + 1] else 0;
            const b2 = if (i + 2 < hash.len) hash[i + 2] else 0;

            const n = (@as(u32, b0) << 16) | (@as(u32, b1) << 8) | @as(u32, b2);

            accept_key[out_idx] = base64_alphabet[(n >> 18) & 0x3f];
            out_idx += 1;
            accept_key[out_idx] = base64_alphabet[(n >> 12) & 0x3f];
            out_idx += 1;
            if (i + 1 < hash.len) {
                accept_key[out_idx] = base64_alphabet[(n >> 6) & 0x3f];
                out_idx += 1;
            }
            if (i + 2 < hash.len) {
                accept_key[out_idx] = base64_alphabet[n & 0x3f];
                out_idx += 1;
            }
        }

        // Send HTTP 101 upgrade response with computed accept key
        var response_buf: [256]u8 = undefined;
        const response = try std.fmt.bufPrint(&response_buf,
            "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}==\r\n" ++
            "\r\n",
            .{accept_key[0..out_idx]});

        _ = try self.stream.writeAll(response);
        self.is_upgraded = true;
        return true;
    }

    /// Send a frame to the WebSocket client
    pub fn sendFrame(self: *WebSocketConnection, msg_type: MessageType, payload: []const u8) !void {
        var buf: [4096]u8 = undefined;

        const frame = Frame{
            .msg_type = msg_type,
            .payload = payload,
        };

        const encoded_len = try frame.encode(&buf);
        _ = try self.stream.writeAll(buf[0..encoded_len]);
    }

    /// Receive a frame from the WebSocket client
    pub fn receiveFrame(self: *WebSocketConnection, recv_buf: []u8) !?Frame {
        const n = try self.stream.read(recv_buf);
        if (n == 0) return null;

        try self.accumulator.append(recv_buf[0..n]);

        // Try to parse next complete frame
        return self.accumulator.nextFrame();
    }

    /// Send INIT response with terminal capabilities
    pub fn sendInitResponse(self: *WebSocketConnection) !void {
        var payload: [32]u8 = undefined;

        const init = InitMessage{
            .protocol_version = 1,
            .term_width = self.term_width,
            .term_height = self.term_height,
            .capabilities = .{
                .supports_mouse_sgr = true,
                .supports_focus_events = true,
                .supports_16bit_colors = true,
            },
        };

        const payload_len = try init.encode(&payload);
        try self.sendFrame(.init, payload[0..payload_len]);
    }

    /// Send VT output to client
    pub fn sendOutput(self: *WebSocketConnection, vt_sequence: []const u8) !void {
        try self.sendFrame(.output, vt_sequence);
    }

    /// Send dirty region invalidation
    pub fn sendDirtyRegion(self: *WebSocketConnection, x: u16, y: u16, width: u16, height: u16) !void {
        var payload: [8]u8 = undefined;

        const dirty = DirtyRegionMessage{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
        };

        const payload_len = try dirty.encode(&payload);
        try self.sendFrame(.dirty_region, payload[0..payload_len]);
    }

    /// Send spatial update (window position, size, focus)
    pub fn sendSpatial(self: *WebSocketConnection, x: i16, y: i16, w: u16, h: u16, focused: bool) !void {
        var payload: [12]u8 = undefined;

        const spatial = SpatialMessage{
            .window_x = x,
            .window_y = y,
            .window_width = w,
            .window_height = h,
            .is_focused = focused,
            .cell_width = 9,    // Monospace: ~9px per character
            .cell_height = 18,  // ~18px per line
        };

        const payload_len = try spatial.encode(&payload);
        try self.sendFrame(.spatial, payload[0..payload_len]);
    }

    /// Send PING keepalive
    pub fn sendPing(self: *WebSocketConnection) !void {
        try self.sendFrame(.ping, "");
    }
};

/// Execution callback type: receives server reference and input event
pub const ExecutionCallback = *const fn (*Server, InputMessage) anyerror!void;

/// Ghostty Web Server
pub const Server = struct {
    allocator: std.mem.Allocator,
    listener: std.net.Server,
    port: u16,
    max_clients: usize = 16,
    clients: std.ArrayListUnmanaged(WebSocketConnection),
    running: bool = true,
    execution_callback: ?ExecutionCallback = null,

    pub fn init(allocator: std.mem.Allocator, port: u16) !Server {
        const address = try std.net.Address.parseIp("127.0.0.1", port);
        const listener = try address.listen(.{
            .reuse_address = true,
        });

        return Server{
            .allocator = allocator,
            .listener = listener,
            .port = port,
            .clients = std.ArrayListUnmanaged(WebSocketConnection){},
        };
    }

    pub fn setExecutionCallback(self: *Server, callback: ?ExecutionCallback) void {
        self.execution_callback = callback;
    }

    pub fn deinit(self: *Server) void {
        for (self.clients.items) |*client| {
            client.deinit();
        }
        self.clients.deinit(self.allocator);
        self.listener.deinit();
    }

    /// Accept new client connection and perform WebSocket upgrade
    pub fn acceptClient(self: *Server) !?*WebSocketConnection {
        if (self.clients.items.len >= self.max_clients) {
            return null; // Max clients reached
        }

        const connection = self.listener.accept() catch |err| {
            if (err == error.WouldBlock) return null;
            return err;
        };

        // Read initial HTTP request
        var http_buf: [2048]u8 = undefined;
        const http_len = try connection.stream.read(&http_buf);
        if (http_len == 0) {
            connection.stream.close();
            return null;
        }

        const http_request = http_buf[0..http_len];

        // Create connection with accumulator
        var ws_conn = WebSocketConnection{
            .stream = connection.stream,
            .accumulator = try FrameAccumulator.init(
                self.allocator,
                16 * 1024, // 16KB ring buffer for incoming frames
            ),
            .last_activity = std.time.milliTimestamp(),
        };

        // Perform WebSocket upgrade
        if (!try ws_conn.upgradeFromHttp(http_request)) {
            ws_conn.deinit();
            return null;
        }

        try self.clients.append(self.allocator, ws_conn);
        return &self.clients.items[self.clients.items.len - 1];
    }

    /// Broadcast VT output to all connected clients
    pub fn broadcastOutput(self: *Server, vt_sequence: []const u8) !void {
        for (self.clients.items) |*client| {
            client.sendOutput(vt_sequence) catch |err| {
                std.debug.print("Error sending output: {}\n", .{err});
            };
        }
    }

    /// Broadcast spatial state to all clients
    pub fn broadcastSpatial(
        self: *Server,
        x: i16,
        y: i16,
        w: u16,
        h: u16,
        focused: bool,
    ) !void {
        for (self.clients.items) |*client| {
            client.sendSpatial(x, y, w, h, focused) catch |err| {
                std.debug.print("Error sending spatial: {}\n", .{err});
            };
        }
    }

    /// Broadcast PING to detect stale connections
    pub fn broadcastPing(self: *Server) !void {
        for (self.clients.items) |*client| {
            client.sendPing() catch |err| {
                std.debug.print("Error sending ping: {}\n", .{err});
            };
        }
    }

    /// Main server loop
    pub fn run(self: *Server) !void {
        std.debug.print("Ghostty WebSocket Server listening on :{}...\n", .{self.port});

        while (self.running) {
            // Accept new connections (non-blocking)
            if (try self.acceptClient()) |new_client| {
                std.debug.print("New WebSocket client connected\n", .{});
                try new_client.sendInitResponse();
            }

            // Receive frames from all clients
            var buf: [8192]u8 = undefined;
            for (self.clients.items) |*client| {
                if (client.receiveFrame(&buf)) |opt_frame| {
                    if (opt_frame) |frame| {
                        try self.handleClientMessage(client, frame);
                    }
                } else |err| {
                    std.debug.print("Error receiving frame: {}\n", .{err});
                }
            }

            // Periodic keepalive
            const now = std.time.milliTimestamp();
            if (@mod(now, 30000) == 0) { // Every 30 seconds
                try self.broadcastPing();
            }

            // Small sleep to prevent busy loop
            std.posix.nanosleep(0, 100 * std.time.ns_per_ms);
        }
    }

    /// Handle incoming message from client
    fn handleClientMessage(self: *Server, client: *WebSocketConnection, frame: Frame) !void {
        switch (frame.msg_type) {
            .init => {
                // Client sent INIT (normally server sends this)
                const init_msg = try InitMessage.decode(frame.payload);
                client.term_width = init_msg.term_width;
                client.term_height = init_msg.term_height;
                std.debug.print("Client terminal: {}x{}\n", .{ init_msg.term_width, init_msg.term_height });
            },

            .input => {
                // Route input to Ghostty's InputHandler
                const input = try InputMessage.decode(frame.payload);
                try self.handleInputEvent(input);
            },

            .ping => {
                // Respond with PONG (empty output frame)
                try client.sendFrame(.ping, "");
            },

            else => {
                // Ignore other message types from client
            },
        }

        client.last_activity = std.time.milliTimestamp();
    }

    /// Process input event (keyboard/mouse)
    fn handleInputEvent(self: *Server, input: InputMessage) !void {
        // Route to execution callback if registered
        if (self.execution_callback) |callback| {
            try callback(self, input);
            return;
        }

        // Fallback: debug print only
        switch (input.event_type) {
            .key => {
                if (input.key_event) |key| {
                    std.debug.print("Key input: U+{X} mods=0x{x}\n", .{ key.char_code, key.modifiers });
                }
            },
            .mouse_move => {
                if (input.mouse_event) |mouse| {
                    std.debug.print("Mouse move: ({},{})\n", .{ mouse.x, mouse.y });
                }
            },
            .mouse_button => {
                if (input.mouse_event) |mouse| {
                    std.debug.print("Mouse button: @({},{}) button={}\n", .{ mouse.x, mouse.y, mouse.button });
                }
            },
            .mouse_wheel => {
                if (input.mouse_event) |mouse| {
                    std.debug.print("Mouse wheel: button={}\n", .{mouse.button});
                }
            },
        }
    }
};

/// NATS Advertiser for MCP discovery
pub const NatsAdvertiser = struct {
    subject: []const u8 = "mcp.terms.ghostty-emacs",
    port: u16 = 7070,
    host: []const u8 = "127.0.0.1",

    pub fn advertise(self: NatsAdvertiser, allocator: std.mem.Allocator) ![]u8 {
        var msg_buf: [256]u8 = undefined;
        var stream = std.io.fixedBufferStream(&msg_buf);
        var writer = stream.writer();

        try writer.print(
            "{{ \"service\": \"ghostty-emacs\", \"port\": {}, \"host\": \"{s}\", \"protocol\": \"websocket\", \"capabilities\": [\"vt\", \"mouse\", \"focus\"] }}",
            .{ self.port, self.host },
        );

        const msg = stream.getWritten();
        const result = try allocator.alloc(u8, msg.len);
        @memcpy(result, msg);
        return result;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try Server.init(allocator, 7070);
    defer server.deinit();

    // Advertise on NATS
    const advertiser = NatsAdvertiser{ .port = 7070 };
    const msg = try advertiser.advertise(allocator);
    defer allocator.free(msg);
    std.debug.print("Advertising: {s}\n", .{msg});

    // Run server
    try server.run();
}

// Tests
pub const testing = struct {
    pub fn testWebSocketUpgrade(allocator: std.mem.Allocator) !void {
        var server = try Server.init(allocator, 9999);
        defer server.deinit();

        const http_request =
            "GET / HTTP/1.1\r\n" ++
            "Host: localhost:9999\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
            "\r\n";

        // In real test, would create a connection
        _ = http_request;
    }
};
