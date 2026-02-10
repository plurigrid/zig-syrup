//! QRTP Transport: Screen↔Camera Air-Gapped Transport
//!
//! Provides send/recv interface parallel to tcp_transport.zig but using
//! QR codes as the physical layer. Platform provides render/scan callbacks
//! via C ABI; Zig handles fountain coding, framing, and reassembly.
//!
//! Inspired by Orion Reed's QR Transfer Protocols:
//!   https://www.orionreed.com/posts/qrtp/
//!
//! Architecture:
//!   Sender:   payload → fountain.Encoder → qrtp_frame → renderQR (C ABI)
//!   Receiver: scanQR (C ABI) → qrtp_frame → fountain.Decoder → payload
//!
//! No internet required. No centralized hardware (unlike WorldID Orb).
//! passport.gay proof-of-brain proofs (~2KB) encode into ~20 QR frames.
//!
//! GF(3) trit: -1 (MINUS) — verifies/receives identity proofs

const std = @import("std");
const fountain = @import("fountain.zig");
const qrtp_frame = @import("qrtp_frame.zig");

// =============================================================================
// C ABI Callbacks (platform provides these)
// =============================================================================

/// Callback: render a QR code from raw bytes.
/// Platform converts `data[0..data_len]` into a QR code and displays it.
/// Returns 0 on success, nonzero on failure.
pub const RenderQRFn = *const fn (
    data: [*]const u8,
    data_len: usize,
    context: ?*anyopaque,
) callconv(.c) c_int;

/// Callback: scan a QR code from camera.
/// Platform captures camera frame and decodes any QR code present.
/// Writes decoded bytes into `buf[0..buf_len]`, returns actual length.
/// Returns 0 if no QR code was detected in this frame.
pub const ScanQRFn = *const fn (
    buf: [*]u8,
    buf_len: usize,
    context: ?*anyopaque,
) callconv(.c) usize;

/// Callback: delay between QR frame renders (milliseconds).
/// Platform should sleep/wait this duration between displaying QR codes.
pub const DelayFn = *const fn (
    milliseconds: u32,
    context: ?*anyopaque,
) callconv(.c) void;

// =============================================================================
// Transport Configuration
// =============================================================================

pub const TransportConfig = struct {
    /// C ABI callback to render a QR code on screen
    render_qr: RenderQRFn,
    /// C ABI callback to scan a QR code from camera
    scan_qr: ScanQRFn,
    /// C ABI callback for inter-frame delay
    delay: DelayFn,
    /// Opaque platform context passed to all callbacks
    context: ?*anyopaque = null,
    /// Delay between QR frames in milliseconds (default 100ms = 10 fps)
    frame_delay_ms: u32 = 100,
    /// Maximum receive attempts before timeout
    max_receive_attempts: u32 = 5000,
    /// How many extra encoded blocks to send beyond K (overhead)
    overhead_blocks: u32 = 5,
};

// =============================================================================
// Sender
// =============================================================================

pub const SendError = error{
    PayloadTooLarge,
    RenderFailed,
    EncoderFull,
};

pub const SendResult = struct {
    /// Number of QR frames rendered
    frames_sent: u32,
    /// Number of source blocks
    source_blocks: u16,
    /// Session seed used
    seed: u64,
};

/// Send a payload via fountain-coded QR stream.
/// Renders QR codes on screen via the render callback.
/// Returns after sending K + overhead encoded blocks.
pub fn send(config: *const TransportConfig, seed: u64, payload: []const u8) SendError!SendResult {
    if (payload.len > fountain.MAX_SOURCE_BLOCKS * fountain.DEFAULT_BLOCK_SIZE) {
        return SendError.PayloadTooLarge;
    }

    var enc = fountain.Encoder.init(seed, payload);
    const k = enc.sourceCount();

    // First: send session announcement frame
    const session = qrtp_frame.SessionFrame{
        .seed = seed,
        .num_source_blocks = @intCast(k),
        .total_payload_size = @intCast(payload.len),
        .block_size = fountain.DEFAULT_BLOCK_SIZE,
    };
    const session_frame = qrtp_frame.encodeSessionFrame(&session);
    const session_result = config.render_qr(
        @ptrCast(session_frame.bytes().ptr),
        session_frame.len,
        config.context,
    );
    if (session_result != 0) return SendError.RenderFailed;
    config.delay(config.frame_delay_ms, config.context);

    // Then: send K + overhead encoded blocks
    const total_blocks: u32 = @as(u32, @intCast(k)) + config.overhead_blocks;
    var frames_sent: u32 = 0;

    while (frames_sent < total_blocks) : (frames_sent += 1) {
        // Generate fountain block
        const fblock = enc.nextBlock();

        // Serialize to QRTP frame
        const frame = qrtp_frame.encodeFrame(&fblock);

        // Render QR code via platform callback
        const result = config.render_qr(
            @ptrCast(frame.bytes().ptr),
            frame.len,
            config.context,
        );
        if (result != 0) return SendError.RenderFailed;

        // Inter-frame delay
        config.delay(config.frame_delay_ms, config.context);
    }

    return .{
        .frames_sent = frames_sent,
        .source_blocks = @intCast(k),
        .seed = seed,
    };
}

// =============================================================================
// Receiver
// =============================================================================

pub const RecvError = error{
    Timeout,
    ScanFailed,
    FrameDecodeError,
    SessionMismatch,
    ReassemblyFailed,
};

pub const RecvResult = struct {
    /// Number of QR frames scanned
    frames_received: u32,
    /// Number of source blocks recovered
    blocks_recovered: u16,
    /// Actual payload length
    payload_len: usize,
    /// Session seed
    seed: u64,
};

/// Receive a payload via fountain-coded QR stream.
/// Scans QR codes from camera via the scan callback.
/// Returns when all source blocks are recovered or timeout.
pub fn recv(
    config: *const TransportConfig,
    out: []u8,
    result: *RecvResult,
) RecvError!usize {
    var scan_buf: [qrtp_frame.MAX_FRAME_SIZE]u8 = undefined;
    var attempts: u32 = 0;
    var decoder: ?fountain.Decoder = null;
    var session_seed: u64 = 0;
    var frames_received: u32 = 0;

    while (attempts < config.max_receive_attempts) : (attempts += 1) {
        // Scan for QR code
        const scan_len = config.scan_qr(
            @ptrCast(&scan_buf),
            scan_buf.len,
            config.context,
        );

        if (scan_len == 0) {
            // No QR code detected this frame
            config.delay(config.frame_delay_ms / 2, config.context);
            continue;
        }

        const data = scan_buf[0..scan_len];

        // Try session frame first
        if (scan_len >= 4 and std.mem.eql(u8, data[0..4], qrtp_frame.SESSION_TAG)) {
            const session = qrtp_frame.decodeSessionFrame(data) catch continue;
            session_seed = session.seed;
            decoder = fountain.Decoder.init(session.seed, session.num_source_blocks);
            frames_received += 1;
            continue;
        }

        // Try data frame
        if (scan_len >= 4 and std.mem.eql(u8, data[0..4], qrtp_frame.FRAME_TAG)) {
            var block = qrtp_frame.decodeFrame(data) catch continue;

            // Auto-init decoder from first data frame if no session frame seen
            if (decoder == null) {
                session_seed = block.seed;
                decoder = fountain.Decoder.init(block.seed, block.num_source_blocks);
            }

            if (decoder) |*dec| {
                _ = dec.processBlock(&block);
                frames_received += 1;

                if (dec.isComplete()) {
                    // Reassemble
                    const payload_len = dec.reassemble(out) orelse
                        return RecvError.ReassemblyFailed;

                    result.* = .{
                        .frames_received = frames_received,
                        .blocks_recovered = @intCast(dec.recoveredCount()),
                        .payload_len = payload_len,
                        .seed = session_seed,
                    };
                    return payload_len;
                }
            }
        }
    }

    return RecvError.Timeout;
}

// =============================================================================
// C ABI Exports
// =============================================================================

/// C ABI: Send payload via QRTP fountain codes.
/// Returns number of frames sent, or -1 on error.
export fn qrtp_send(
    render_qr: RenderQRFn,
    delay_fn: DelayFn,
    context: ?*anyopaque,
    seed: u64,
    payload: [*]const u8,
    payload_len: usize,
    frame_delay_ms: u32,
) callconv(.c) c_int {
    const config = TransportConfig{
        .render_qr = render_qr,
        .scan_qr = undefined, // Not needed for send
        .delay = delay_fn,
        .context = context,
        .frame_delay_ms = frame_delay_ms,
    };

    const result = send(&config, seed, payload[0..payload_len]) catch return -1;
    return @intCast(result.frames_sent);
}

/// C ABI: Receive payload via QRTP fountain codes.
/// Returns payload length, or -1 on timeout/error.
export fn qrtp_recv(
    scan_qr: ScanQRFn,
    delay_fn: DelayFn,
    context: ?*anyopaque,
    out: [*]u8,
    out_len: usize,
    frame_delay_ms: u32,
    max_attempts: u32,
) callconv(.c) c_int {
    const config = TransportConfig{
        .render_qr = undefined, // Not needed for recv
        .scan_qr = scan_qr,
        .delay = delay_fn,
        .context = context,
        .frame_delay_ms = frame_delay_ms,
        .max_receive_attempts = max_attempts,
    };

    var result: RecvResult = undefined;
    const len = recv(&config, out[0..out_len], &result) catch return -1;
    return @intCast(len);
}

// =============================================================================
// Tests (using mock callbacks)
// =============================================================================

/// Test state for mock QR transport
const MockTransport = struct {
    /// Rendered frames (sender writes here)
    frames: [256]qrtp_frame.QrtpFrame = undefined,
    frame_count: usize = 0,
    /// Read cursor (receiver reads from here)
    read_cursor: usize = 0,
};

fn mockRender(data: [*]const u8, data_len: usize, context: ?*anyopaque) callconv(.c) c_int {
    const mock: *MockTransport = @ptrCast(@alignCast(context.?));
    if (mock.frame_count >= mock.frames.len) return -1;
    @memcpy(mock.frames[mock.frame_count].data[0..data_len], data[0..data_len]);
    mock.frames[mock.frame_count].len = data_len;
    mock.frame_count += 1;
    return 0;
}

fn mockScan(buf: [*]u8, buf_len: usize, context: ?*anyopaque) callconv(.c) usize {
    const mock: *MockTransport = @ptrCast(@alignCast(context.?));
    if (mock.read_cursor >= mock.frame_count) return 0;
    const frame = &mock.frames[mock.read_cursor];
    if (frame.len > buf_len) return 0;
    @memcpy(buf[0..frame.len], frame.data[0..frame.len]);
    mock.read_cursor += 1;
    return frame.len;
}

fn mockDelay(_: u32, _: ?*anyopaque) callconv(.c) void {
    // No-op in tests
}

test "mock send-recv round trip" {
    var mock = MockTransport{};
    const config = TransportConfig{
        .render_qr = mockRender,
        .scan_qr = mockScan,
        .delay = mockDelay,
        .context = @ptrCast(&mock),
        .frame_delay_ms = 0,
        .overhead_blocks = 3,
    };

    const payload = "proof-of-brain identity commitment via air-gapped QRTP";
    const seed: u64 = 0xCAFE;

    // Send
    const send_result = try send(&config, seed, payload);
    try std.testing.expect(send_result.frames_sent > 0);
    try std.testing.expectEqual(seed, send_result.seed);

    // Receive
    var out: [1024]u8 = undefined;
    var recv_result: RecvResult = undefined;
    const len = try recv(&config, &out, &recv_result);
    try std.testing.expectEqualSlices(u8, payload, out[0..len]);
    try std.testing.expectEqual(seed, recv_result.seed);
}

test "mock send-recv multi-block" {
    var mock = MockTransport{};
    const config = TransportConfig{
        .render_qr = mockRender,
        .scan_qr = mockScan,
        .delay = mockDelay,
        .context = @ptrCast(&mock),
        .frame_delay_ms = 0,
        .overhead_blocks = 10,
    };

    // Payload spanning multiple fountain blocks
    var payload: [fountain.DEFAULT_BLOCK_SIZE * 3]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast(i % 199);

    const seed: u64 = 0xBEEF;
    const send_result = try send(&config, seed, &payload);
    try std.testing.expect(send_result.frames_sent > 3);

    var out: [fountain.DEFAULT_BLOCK_SIZE * 4]u8 = undefined;
    var recv_result: RecvResult = undefined;
    const len = try recv(&config, &out, &recv_result);
    try std.testing.expectEqual(payload.len, len);
    try std.testing.expectEqualSlices(u8, &payload, out[0..len]);
}

test "recv timeout when no frames" {
    var mock = MockTransport{};
    const config = TransportConfig{
        .render_qr = mockRender,
        .scan_qr = mockScan,
        .delay = mockDelay,
        .context = @ptrCast(&mock),
        .frame_delay_ms = 0,
        .max_receive_attempts = 10,
    };

    var out: [256]u8 = undefined;
    var recv_result: RecvResult = undefined;
    const result = recv(&config, &out, &recv_result);
    try std.testing.expectError(RecvError.Timeout, result);
}
