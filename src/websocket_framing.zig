/// WebSocket Binary Framing for Ghostty-Emacs Terminal Streaming
///
/// Protocol: Length-prefixed binary frames over WebSocket
/// - Frame format: [u32 BE length][u8 msg_type][payload]
/// - Message types: INIT, OUTPUT, DIRTY_REGION, INPUT, PING, SPATIAL
/// - Enables bidirectional VT sequence streaming with minimal overhead
///
/// Matches BCI color bridge pattern (cell_sync.zig) with structured types.

const std = @import("std");

/// Message type codes for Ghostty-Emacs protocol
pub const MessageType = enum(u8) {
    init = 0x00,              // Handshake: version, window size, capabilities
    output = 0x01,            // VT sequence output to terminal
    dirty_region = 0x02,      // Dirty rectangle: (x, y, width, height)
    input = 0x03,             // Keyboard/mouse input events
    ping = 0x04,              // Keepalive (no payload)
    spatial = 0x05,           // Window position/size + focus state
};

/// Terminal capabilities negotiated during INIT
pub const Capabilities = packed struct(u32) {
    supports_sixel: bool = false,           // Sixel image protocol
    supports_kitty_graphics: bool = false,  // Kitty graphics protocol
    supports_mouse_sgr: bool = false,       // SGR 1006 mouse tracking
    supports_focus_events: bool = false,    // Focus in/out events
    supports_16bit_colors: bool = false,    // 24-bit RGB colors
    supports_italic: bool = false,          // Italic font style
    supports_strikethrough: bool = false,   // Strikethrough text
    _reserved: u25 = 0,
};

/// INIT frame: connection handshake
pub const InitMessage = struct {
    protocol_version: u16 = 1,
    term_width: u16,
    term_height: u16,
    capabilities: Capabilities = .{},

    pub fn encode(self: InitMessage, buf: []u8) !usize {
        if (buf.len < 11) return error.BufferTooSmall;

        var pos: usize = 0;
        std.mem.writeInt(u16, buf[pos..][0..2], self.protocol_version, .big);
        pos += 2;
        std.mem.writeInt(u16, buf[pos..][0..2], self.term_width, .big);
        pos += 2;
        std.mem.writeInt(u16, buf[pos..][0..2], self.term_height, .big);
        pos += 2;
        std.mem.writeInt(u32, buf[pos..][0..4], @bitCast(self.capabilities), .big);
        pos += 4;

        return pos;
    }

    pub fn decode(data: []const u8) !InitMessage {
        if (data.len < 10) return error.DataTooShort;

        return InitMessage{
            .protocol_version = std.mem.readInt(u16, data[0..2], .big),
            .term_width = std.mem.readInt(u16, data[2..4], .big),
            .term_height = std.mem.readInt(u16, data[4..6], .big),
            .capabilities = @bitCast(std.mem.readInt(u32, data[6..10], .big)),
        };
    }
};

/// OUTPUT frame: VT sequence output
pub const OutputMessage = struct {
    sequence: []const u8,  // UTF-8 encoded VT sequence or plain text

    pub fn encode(self: OutputMessage, buf: []u8) !usize {
        if (buf.len < self.sequence.len) return error.BufferTooSmall;

        @memcpy(buf[0..self.sequence.len], self.sequence);
        return self.sequence.len;
    }

    pub fn decode(data: []const u8) OutputMessage {
        return OutputMessage{ .sequence = data };
    }
};

/// DIRTY_REGION frame: invalidate rectangle on screen
pub const DirtyRegionMessage = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    pub fn encode(self: DirtyRegionMessage, buf: []u8) !usize {
        if (buf.len < 8) return error.BufferTooSmall;

        std.mem.writeInt(u16, buf[0..2], self.x, .big);
        std.mem.writeInt(u16, buf[2..4], self.y, .big);
        std.mem.writeInt(u16, buf[4..6], self.width, .big);
        std.mem.writeInt(u16, buf[6..8], self.height, .big);

        return 8;
    }

    pub fn decode(data: []const u8) !DirtyRegionMessage {
        if (data.len < 8) return error.DataTooShort;

        return DirtyRegionMessage{
            .x = std.mem.readInt(u16, data[0..2], .big),
            .y = std.mem.readInt(u16, data[2..4], .big),
            .width = std.mem.readInt(u16, data[4..6], .big),
            .height = std.mem.readInt(u16, data[6..8], .big),
        };
    }
};

/// INPUT frame: keyboard/mouse event
pub const InputMessage = struct {
    pub const EventType = enum(u8) {
        key = 0x00,
        mouse_move = 0x01,
        mouse_button = 0x02,
        mouse_wheel = 0x03,
    };

    pub const MouseButton = enum(u8) {
        left = 0x00,
        middle = 0x01,
        right = 0x02,
        wheel_up = 0x03,
        wheel_down = 0x04,
    };

    pub const KeyEvent = struct {
        char_code: u32,         // Unicode codepoint
        modifiers: u8,          // Shift(0x01) | Ctrl(0x02) | Alt(0x04) | Meta(0x08)

        pub fn encode(self: KeyEvent, buf: []u8) !usize {
            if (buf.len < 5) return error.BufferTooSmall;
            std.mem.writeInt(u32, buf[0..4], self.char_code, .big);
            buf[4] = self.modifiers;
            return 5;
        }

        pub fn decode(data: []const u8) !KeyEvent {
            if (data.len < 5) return error.DataTooShort;
            return KeyEvent{
                .char_code = std.mem.readInt(u32, data[0..4], .big),
                .modifiers = data[4],
            };
        }
    };

    pub const MouseEvent = struct {
        x: u16,
        y: u16,
        button: MouseButton,
        modifiers: u8,

        pub fn encode(self: MouseEvent, buf: []u8) !usize {
            if (buf.len < 6) return error.BufferTooSmall;
            std.mem.writeInt(u16, buf[0..2], self.x, .big);
            std.mem.writeInt(u16, buf[2..4], self.y, .big);
            buf[4] = @intFromEnum(self.button);
            buf[5] = self.modifiers;
            return 6;
        }

        pub fn decode(data: []const u8) !MouseEvent {
            if (data.len < 6) return error.DataTooShort;
            return MouseEvent{
                .x = std.mem.readInt(u16, data[0..2], .big),
                .y = std.mem.readInt(u16, data[2..4], .big),
                .button = @enumFromInt(data[4]),
                .modifiers = data[5],
            };
        }
    };

    event_type: EventType,
    key_event: ?KeyEvent = null,
    mouse_event: ?MouseEvent = null,

    pub fn encode(self: InputMessage, buf: []u8) !usize {
        if (buf.len < 1) return error.BufferTooSmall;

        buf[0] = @intFromEnum(self.event_type);
        var pos: usize = 1;

        switch (self.event_type) {
            .key => {
                const key = self.key_event orelse return error.MissingKeyEvent;
                pos += try key.encode(buf[pos..]);
            },
            .mouse_move, .mouse_button, .mouse_wheel => {
                const mouse = self.mouse_event orelse return error.MissingMouseEvent;
                pos += try mouse.encode(buf[pos..]);
            },
        }

        return pos;
    }

    pub fn decode(data: []const u8) !InputMessage {
        if (data.len < 1) return error.DataTooShort;

        const event_type: EventType = @enumFromInt(data[0]);
        var msg = InputMessage{ .event_type = event_type };

        switch (event_type) {
            .key => {
                msg.key_event = try KeyEvent.decode(data[1..]);
            },
            .mouse_move, .mouse_button, .mouse_wheel => {
                msg.mouse_event = try MouseEvent.decode(data[1..]);
            },
        }

        return msg;
    }
};

/// SPATIAL frame: window position, size, focus state
pub const SpatialMessage = struct {
    window_x: i16,
    window_y: i16,
    window_width: u16,
    window_height: u16,
    is_focused: bool,
    cell_width: u8,         // Monospace cell pixel width
    cell_height: u8,        // Monospace cell pixel height

    pub fn encode(self: SpatialMessage, buf: []u8) !usize {
        if (buf.len < 12) return error.BufferTooSmall;

        var pos: usize = 0;
        std.mem.writeInt(i16, buf[pos..][0..2], self.window_x, .big);
        pos += 2;
        std.mem.writeInt(i16, buf[pos..][0..2], self.window_y, .big);
        pos += 2;
        std.mem.writeInt(u16, buf[pos..][0..2], self.window_width, .big);
        pos += 2;
        std.mem.writeInt(u16, buf[pos..][0..2], self.window_height, .big);
        pos += 2;
        buf[pos] = if (self.is_focused) 0x01 else 0x00;
        pos += 1;
        buf[pos] = self.cell_width;
        pos += 1;
        buf[pos] = self.cell_height;
        pos += 1;

        return pos;
    }

    pub fn decode(data: []const u8) !SpatialMessage {
        if (data.len < 11) return error.DataTooShort;

        return SpatialMessage{
            .window_x = std.mem.readInt(i16, data[0..2], .big),
            .window_y = std.mem.readInt(i16, data[2..4], .big),
            .window_width = std.mem.readInt(u16, data[4..6], .big),
            .window_height = std.mem.readInt(u16, data[6..8], .big),
            .is_focused = data[8] != 0,
            .cell_width = data[9],
            .cell_height = data[10],
        };
    }
};

/// Frame envelope: [u32 BE length][u8 type][payload]
pub const Frame = struct {
    msg_type: MessageType,
    payload: []const u8,

    const HEADER_SIZE = 5; // u32 + u8

    pub fn encode(self: Frame, buf: []u8) !usize {
        const total_len = self.payload.len + 1; // +1 for msg_type
        if (buf.len < HEADER_SIZE + self.payload.len) return error.BufferTooSmall;

        std.mem.writeInt(u32, buf[0..4], @intCast(total_len), .big);
        buf[4] = @intFromEnum(self.msg_type);
        @memcpy(buf[5..][0..self.payload.len], self.payload);

        return HEADER_SIZE + self.payload.len;
    }

    pub fn decode(buf: []const u8) !struct { frame: Frame, bytes_consumed: usize } {
        if (buf.len < HEADER_SIZE) return error.BufferTooSmall;

        const length = std.mem.readInt(u32, buf[0..4], .big);
        const needed = HEADER_SIZE + length;

        if (buf.len < needed) return error.IncompleteFrame;
        if (length < 1) return error.InvalidFrameLength;

        const msg_type: MessageType = @enumFromInt(buf[4]);
        const payload = buf[5..][0..(length - 1)];

        return .{
            .frame = Frame{
                .msg_type = msg_type,
                .payload = payload,
            },
            .bytes_consumed = needed,
        };
    }
};

/// Accumulator: ring buffer for partial frames (similar to message_frame.zig)
pub const FrameAccumulator = struct {
    buffer: []u8,
    head: usize = 0,
    tail: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !FrameAccumulator {
        return FrameAccumulator{
            .buffer = try allocator.alloc(u8, capacity),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *FrameAccumulator) void {
        self.allocator.free(self.buffer);
    }

    pub fn append(self: *FrameAccumulator, data: []const u8) !void {
        if (data.len > self.available()) return error.BufferFull;

        const capacity = self.buffer.len;
        const to_write = data.len;

        if (self.tail + to_write <= capacity) {
            @memcpy(self.buffer[self.tail..][0..to_write], data);
            self.tail += to_write;
        } else {
            // Wrap around
            const part1 = capacity - self.tail;
            @memcpy(self.buffer[self.tail..], data[0..part1]);
            @memcpy(self.buffer[0..][0..(to_write - part1)], data[part1..]);
            self.tail = to_write - part1;
        }
    }

    pub fn nextFrame(self: *FrameAccumulator) !?Frame {
        if (self.pending() == 0) return null;

        const data = try self.peekAll();
        const result = Frame.decode(data) catch |err| {
            if (err == error.IncompleteFrame) return null;
            return err;
        };

        self.head = (self.head + result.bytes_consumed) % self.buffer.len;
        return result.frame;
    }

    pub fn peekAll(self: *FrameAccumulator) ![]u8 {
        if (self.head <= self.tail) {
            return self.buffer[self.head..self.tail];
        }
        // Wrapped case: need to copy to linear buffer
        return error.WrappedBuffer; // Caller should handle wrapping
    }

    pub fn pending(self: FrameAccumulator) usize {
        if (self.head <= self.tail) {
            return self.tail - self.head;
        }
        return (self.buffer.len - self.head) + self.tail;
    }

    pub fn available(self: FrameAccumulator) usize {
        return self.buffer.len - self.pending();
    }
};

// Tests
pub const testing = struct {
    pub fn testInitMessage() !void {
        var buf: [32]u8 = undefined;

        const init = InitMessage{
            .term_width = 80,
            .term_height = 24,
            .capabilities = .{ .supports_mouse_sgr = true },
        };

        const encoded = try init.encode(&buf);
        const decoded = try InitMessage.decode(buf[0..encoded]);

        try std.testing.expectEqual(decoded.term_width, 80);
        try std.testing.expectEqual(decoded.term_height, 24);
        try std.testing.expectEqual(decoded.capabilities.supports_mouse_sgr, true);
    }

    pub fn testFrameEncoding() !void {
        var buf: [512]u8 = undefined;

        const payload = "Hello, Ghostty!";
        const frame = Frame{
            .msg_type = .output,
            .payload = payload,
        };

        const encoded = try frame.encode(&buf);
        const decoded = try Frame.decode(buf[0..encoded]);

        try std.testing.expectEqual(decoded.frame.msg_type, .output);
        try std.testing.expectEqualSlices(u8, decoded.frame.payload, payload);
        try std.testing.expectEqual(decoded.bytes_consumed, encoded);
    }
};
