//! Tapo P15 Energy Monitor — L14: Physical Energy Layer
//!
//! Closes the loop between the computational GF(3) pipeline and the
//! actual electrons feeding it. Reads real-time wattage from a
//! TP-Link Tapo P15 smart outlet via KLAP v2 over TCP :80.
//!
//! Architecture:
//!   Tapo P15 (TCP :80) → KLAP v2 handshake → Encrypted JSON-RPC
//!     → Energy data → GF(3) trit classification → Syrup serialization
//!     → Propagator cell → BCI pipeline L14
//!
//! GF(3) classification:
//!   +1 (GENERATOR): Active charging (>30W)
//!    0 (ERGODIC):   Trickle/maintenance (5–30W)
//!   -1 (VALIDATOR): Idle/full/off (<5W)
//!
//! Conservation law: charge_in − charge_out = ΔE
//!
//! No allocator in hot path. Ring buffer for readings.
//! wasm32-freestanding compatible (except TCP transport).

const std = @import("std");
const syrup = @import("syrup");
const Allocator = std.mem.Allocator;
const net = std.net;
const crypto = std.crypto;
const Sha256 = crypto.hash.sha2.Sha256;
const Sha1 = crypto.hash.Sha1;

// ============================================================================
// CONSTANTS
// ============================================================================

/// Maximum readings in the ring buffer (bounded memory)
pub const MAX_READINGS: usize = 4096;

/// HTTP response buffer size
const HTTP_BUF_SIZE: usize = 8192;

/// KLAP seed size (bytes)
const KLAP_SEED_SIZE: usize = 16;

/// Wattage thresholds for GF(3) classification
pub const THRESHOLD_GENERATOR: f32 = 30.0; // >30W = active charging
pub const THRESHOLD_ERGODIC: f32 = 5.0; // 5-30W = trickle
// <5W = idle/validator

/// Tapo default port
pub const TAPO_PORT: u16 = 80;

/// Color mapping from Gay.jl chain (cycle references)
pub const COLOR_GENERATOR = RGB{ .r = 0x00, .g = 0xE1, .b = 0xA9 }; // cycle 91
pub const COLOR_ERGODIC = RGB{ .r = 0xFF, .g = 0xE6, .b = 0x4E }; // cycle 95
pub const COLOR_VALIDATOR = RGB{ .r = 0xF5, .g = 0x00, .b = 0x26 }; // cycle 106

// ============================================================================
// GF(3) TRIT — matches continuation.zig / passport.zig
// ============================================================================

pub const Trit = enum(i8) {
    minus = -1,
    zero = 0,
    plus = 1,

    pub fn add(a: Trit, b: Trit) Trit {
        const sum = @as(i8, @intFromEnum(a)) + @as(i8, @intFromEnum(b));
        return switch (@mod(sum + 3, 3)) {
            0 => .zero,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }

    pub fn neg(self: Trit) Trit {
        return switch (self) {
            .minus => .plus,
            .zero => .zero,
            .plus => .minus,
        };
    }

    pub fn name(self: Trit) []const u8 {
        return switch (self) {
            .minus => "VALIDATOR",
            .zero => "ERGODIC",
            .plus => "GENERATOR",
        };
    }

    pub fn symbol(self: Trit) []const u8 {
        return switch (self) {
            .minus => "\xe2\x88\x92", // −
            .zero => "\xe2\x97\x8b", // ○
            .plus => "+",
        };
    }

    pub fn toSyrup(self: Trit) syrup.Value {
        return switch (self) {
            .minus => syrup.Value{ .symbol = "-" },
            .zero => syrup.Value{ .symbol = "0" },
            .plus => syrup.Value{ .symbol = "+" },
        };
    }
};

// ============================================================================
// COLOR
// ============================================================================

pub const RGB = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn toU24(self: RGB) u24 {
        return (@as(u24, self.r) << 16) | (@as(u24, self.g) << 8) | self.b;
    }

    pub fn toHex(self: RGB, buf: *[7]u8) []const u8 {
        _ = std.fmt.bufPrint(buf, "#{X:0>2}{X:0>2}{X:0>2}", .{ self.r, self.g, self.b }) catch unreachable;
        return buf[0..7];
    }
};

// ============================================================================
// ENERGY READING
// ============================================================================

/// A single energy reading from the Tapo P15.
pub const EnergyReading = struct {
    /// Timestamp (unix epoch ms)
    timestamp_ms: u64,

    /// Real-time power draw (milliwatts from device, stored as watts)
    watts: f32,

    /// GF(3) classification
    trit: Trit,

    /// Mapped color from Gay.jl chain
    color: RGB,

    /// Cumulative energy (Wh) if available
    energy_wh: f32 = 0,

    /// Voltage (mV from device, stored as V)
    voltage: f32 = 0,

    /// Current (mA from device, stored as A)
    current_ma: f32 = 0,

    /// Classify watts → GF(3) trit + color
    pub fn classify(watts: f32) struct { trit: Trit, color: RGB } {
        if (watts > THRESHOLD_GENERATOR) {
            return .{ .trit = .plus, .color = COLOR_GENERATOR };
        } else if (watts > THRESHOLD_ERGODIC) {
            return .{ .trit = .zero, .color = COLOR_ERGODIC };
        } else {
            return .{ .trit = .minus, .color = COLOR_VALIDATOR };
        }
    }

    /// Serialize to Syrup dictionary
    pub fn toSyrup(self: EnergyReading, allocator: Allocator) !syrup.Value {
        var entries = std.ArrayListUnmanaged(syrup.Value.DictEntry){};
        defer entries.deinit(allocator);

        try entries.append(allocator, .{
            .key = syrup.Value{ .symbol = "timestamp" },
            .value = syrup.Value{ .integer = @intCast(self.timestamp_ms) },
        });
        try entries.append(allocator, .{
            .key = syrup.Value{ .symbol = "watts" },
            .value = syrup.Value{ .float32 = self.watts },
        });
        try entries.append(allocator, .{
            .key = syrup.Value{ .symbol = "trit" },
            .value = self.trit.toSyrup(),
        });
        try entries.append(allocator, .{
            .key = syrup.Value{ .symbol = "energy-wh" },
            .value = syrup.Value{ .float32 = self.energy_wh },
        });

        var hex_buf: [7]u8 = undefined;
        const hex_slice = self.color.toHex(&hex_buf);
        const hex_copy = try allocator.dupe(u8, hex_slice);
        try entries.append(allocator, .{
            .key = syrup.Value{ .symbol = "color" },
            .value = syrup.Value{ .string = hex_copy },
        });

        const owned = try allocator.dupe(syrup.Value.DictEntry, entries.items);
        return syrup.Value{ .dictionary = owned };
    }
};

// ============================================================================
// RING BUFFER — bounded-memory time series
// ============================================================================

/// Ring buffer of energy readings. Zero allocation after init.
pub const ReadingRing = struct {
    buf: [MAX_READINGS]EnergyReading = undefined,
    head: usize = 0,
    count: usize = 0,

    /// GF(3) running sum for conservation check
    trit_sum: i32 = 0,

    /// Cumulative energy (Wh)
    total_energy_wh: f64 = 0,

    pub fn push(self: *ReadingRing, reading: EnergyReading) void {
        // If overwriting, subtract old trit from sum
        if (self.count == MAX_READINGS) {
            const old = self.buf[self.head];
            self.trit_sum -= @intFromEnum(old.trit);
        }

        self.buf[self.head] = reading;
        self.trit_sum += @intFromEnum(reading.trit);
        self.head = (self.head + 1) % MAX_READINGS;
        if (self.count < MAX_READINGS) self.count += 1;
    }

    /// Get the most recent reading
    pub fn latest(self: *const ReadingRing) ?EnergyReading {
        if (self.count == 0) return null;
        const idx = if (self.head == 0) MAX_READINGS - 1 else self.head - 1;
        return self.buf[idx];
    }

    /// Average watts over the buffer
    pub fn avgWatts(self: *const ReadingRing) f32 {
        if (self.count == 0) return 0;
        var sum: f64 = 0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.head + MAX_READINGS - self.count + i) % MAX_READINGS;
            sum += self.buf[idx].watts;
        }
        return @floatCast(sum / @as(f64, @floatFromInt(self.count)));
    }

    /// GF(3) balance: 0 means perfectly balanced
    pub fn gf3Balance(self: *const ReadingRing) i32 {
        return self.trit_sum;
    }

    /// Trit distribution counts
    pub fn tritDistribution(self: *const ReadingRing) struct { plus: u32, zero: u32, minus: u32 } {
        var plus: u32 = 0;
        var zero: u32 = 0;
        var minus: u32 = 0;
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.head + MAX_READINGS - self.count + i) % MAX_READINGS;
            switch (self.buf[idx].trit) {
                .plus => plus += 1,
                .zero => zero += 1,
                .minus => minus += 1,
            }
        }
        return .{ .plus = plus, .zero = zero, .minus = minus };
    }

    /// Serialize ring summary to Syrup
    pub fn summaryToSyrup(self: *const ReadingRing, allocator: Allocator) !syrup.Value {
        const dist = self.tritDistribution();
        var entries = std.ArrayListUnmanaged(syrup.Value.DictEntry){};
        defer entries.deinit(allocator);

        try entries.append(allocator, .{
            .key = syrup.Value{ .symbol = "count" },
            .value = syrup.Value{ .integer = @intCast(self.count) },
        });
        try entries.append(allocator, .{
            .key = syrup.Value{ .symbol = "avg-watts" },
            .value = syrup.Value{ .float32 = self.avgWatts() },
        });
        try entries.append(allocator, .{
            .key = syrup.Value{ .symbol = "gf3-balance" },
            .value = syrup.Value{ .integer = self.trit_sum },
        });
        try entries.append(allocator, .{
            .key = syrup.Value{ .symbol = "generators" },
            .value = syrup.Value{ .integer = @intCast(dist.plus) },
        });
        try entries.append(allocator, .{
            .key = syrup.Value{ .symbol = "ergodic" },
            .value = syrup.Value{ .integer = @intCast(dist.zero) },
        });
        try entries.append(allocator, .{
            .key = syrup.Value{ .symbol = "validators" },
            .value = syrup.Value{ .integer = @intCast(dist.minus) },
        });

        const owned = try allocator.dupe(syrup.Value.DictEntry, entries.items);
        return syrup.Value{ .dictionary = owned };
    }
};

// ============================================================================
// KLAP v2 PROTOCOL
// ============================================================================

/// Authentication hash: SHA256(SHA1(username) + SHA1(password))
pub fn computeAuthHash(username: []const u8, password: []const u8) [32]u8 {
    var user_sha1: [Sha1.digest_length]u8 = undefined;
    Sha1.hash(username, &user_sha1, .{});

    var pass_sha1: [Sha1.digest_length]u8 = undefined;
    Sha1.hash(password, &pass_sha1, .{});

    var h = Sha256.init(.{});
    h.update(&user_sha1);
    h.update(&pass_sha1);
    return h.finalResult();
}

/// KLAP v2 session state
pub const KlapSession = struct {
    local_seed: [KLAP_SEED_SIZE]u8,
    remote_seed: [KLAP_SEED_SIZE]u8 = undefined,
    auth_hash: [32]u8,
    session_cookie: [128]u8 = undefined,
    session_cookie_len: usize = 0,
    cipher_key: [16]u8 = undefined,
    cipher_iv: [12]u8 = undefined,
    seq: i32 = 0,
    authenticated: bool = false,

    pub fn init(username: []const u8, password: []const u8) KlapSession {
        var self = KlapSession{
            .local_seed = undefined,
            .auth_hash = computeAuthHash(username, password),
        };
        crypto.random.bytes(&self.local_seed);
        return self;
    }

    /// Derive cipher key + IV from seeds (KLAP v2)
    /// key = SHA256("lsk" + local_seed + remote_seed + auth_hash)[0..16]
    /// iv  = SHA256("iv"  + local_seed + remote_seed + auth_hash)[0..12]
    pub fn deriveKeys(self: *KlapSession) void {
        // Key derivation
        var kh = Sha256.init(.{});
        kh.update("lsk");
        kh.update(&self.local_seed);
        kh.update(&self.remote_seed);
        kh.update(&self.auth_hash);
        const key_hash = kh.finalResult();
        @memcpy(&self.cipher_key, key_hash[0..16]);

        // IV derivation
        var ih = Sha256.init(.{});
        ih.update("iv");
        ih.update(&self.local_seed);
        ih.update(&self.remote_seed);
        ih.update(&self.auth_hash);
        const iv_hash = ih.finalResult();
        @memcpy(&self.cipher_iv, iv_hash[0..12]);

        // Sequence from first 4 bytes of IV hash
        self.seq = @bitCast(@as(u32, iv_hash[12]) << 24 |
            @as(u32, iv_hash[13]) << 16 |
            @as(u32, iv_hash[14]) << 8 |
            @as(u32, iv_hash[15]));
    }

    /// Compute handshake1 server verification hash
    /// expected = SHA256(local_seed + remote_seed + auth_hash)
    pub fn expectedServerHash(self: *const KlapSession) [32]u8 {
        var h = Sha256.init(.{});
        h.update(&self.local_seed);
        h.update(&self.remote_seed);
        h.update(&self.auth_hash);
        return h.finalResult();
    }

    /// Compute handshake2 client hash
    /// client_hash = SHA256(remote_seed + local_seed + auth_hash)
    pub fn clientHash(self: *const KlapSession) [32]u8 {
        var h = Sha256.init(.{});
        h.update(&self.remote_seed);
        h.update(&self.local_seed);
        h.update(&self.auth_hash);
        return h.finalResult();
    }
};

// ============================================================================
// HTTP/1.1 MINIMAL CLIENT
// ============================================================================

pub const HttpError = error{
    ConnectionFailed,
    SendFailed,
    RecvFailed,
    InvalidResponse,
    AuthFailed,
    DeviceError,
    BufferOverflow,
} || net.Stream.ReadError || net.Stream.WriteError;

/// Minimal HTTP response (parsed from raw TCP)
pub const HttpResponse = struct {
    status: u16,
    body: []const u8,
    cookie: ?[]const u8 = null,
};

/// Format and send an HTTP POST, return parsed response.
/// Uses caller-provided buffers (zero allocation).
pub fn httpPost(
    stream: net.Stream,
    path: []const u8,
    host: []const u8,
    body: []const u8,
    cookie: ?[]const u8,
    req_buf: []u8,
    resp_buf: []u8,
) HttpError!HttpResponse {
    // Build request
    var req_len: usize = 0;
    req_len += (std.fmt.bufPrint(req_buf[req_len..], "POST {s} HTTP/1.1\r\nHost: {s}\r\nContent-Length: {d}\r\nContent-Type: application/octet-stream\r\n", .{ path, host, body.len }) catch return HttpError.BufferOverflow).len;

    if (cookie) |c| {
        req_len += (std.fmt.bufPrint(req_buf[req_len..], "Cookie: {s}\r\n", .{c}) catch return HttpError.BufferOverflow).len;
    }

    req_len += (std.fmt.bufPrint(req_buf[req_len..], "\r\n", .{}) catch return HttpError.BufferOverflow).len;

    // Send header
    _ = stream.write(req_buf[0..req_len]) catch return HttpError.SendFailed;
    // Send body
    if (body.len > 0) {
        _ = stream.write(body) catch return HttpError.SendFailed;
    }

    // Read response
    var total_read: usize = 0;
    while (total_read < resp_buf.len) {
        const n = stream.read(resp_buf[total_read..]) catch return HttpError.RecvFailed;
        if (n == 0) break;
        total_read += n;

        // Check if we have complete headers + body
        if (std.mem.indexOf(u8, resp_buf[0..total_read], "\r\n\r\n")) |header_end| {
            const headers = resp_buf[0..header_end];
            const body_start = header_end + 4;

            // Parse status
            const status = parseHttpStatus(headers) orelse return HttpError.InvalidResponse;

            // Parse Content-Length
            const content_len = parseContentLength(headers) orelse 0;
            const needed = body_start + content_len;

            // Read remaining body if needed
            while (total_read < needed and total_read < resp_buf.len) {
                const m = stream.read(resp_buf[total_read..]) catch break;
                if (m == 0) break;
                total_read += m;
            }

            const resp_body_end = @min(total_read, needed);

            return HttpResponse{
                .status = status,
                .body = resp_buf[body_start..resp_body_end],
                .cookie = parseCookie(headers),
            };
        }
    }
    return HttpError.InvalidResponse;
}

fn parseHttpStatus(headers: []const u8) ?u16 {
    // "HTTP/1.1 200 OK" → 200
    if (headers.len < 12) return null;
    if (!std.mem.startsWith(u8, headers, "HTTP/1.")) return null;
    const code_start: usize = 9;
    if (code_start + 3 > headers.len) return null;
    return std.fmt.parseInt(u16, headers[code_start .. code_start + 3], 10) catch null;
}

fn parseContentLength(headers: []const u8) ?usize {
    const needle = "Content-Length: ";
    const idx = std.mem.indexOf(u8, headers, needle) orelse return null;
    const start = idx + needle.len;
    const end = std.mem.indexOfPos(u8, headers, start, "\r\n") orelse headers.len;
    return std.fmt.parseInt(usize, headers[start..end], 10) catch null;
}

fn parseCookie(headers: []const u8) ?[]const u8 {
    const needle = "Set-Cookie: ";
    const idx = std.mem.indexOf(u8, headers, needle) orelse return null;
    const start = idx + needle.len;
    const end = std.mem.indexOfPos(u8, headers, start, ";") orelse
        (std.mem.indexOfPos(u8, headers, start, "\r\n") orelse headers.len);
    return headers[start..end];
}

// ============================================================================
// TAPO DEVICE CLIENT
// ============================================================================

pub const TapoError = error{
    HandshakeFailed,
    AuthenticationFailed,
    DeviceUnreachable,
    ProtocolError,
    EnergyNotSupported,
} || HttpError;

/// Tapo P15 device handle
pub const TapoDevice = struct {
    allocator: Allocator,
    address: net.Address,
    host_str: [64]u8 = undefined,
    host_str_len: usize = 0,
    session: KlapSession,
    readings: ReadingRing = .{},

    /// Buffers (pre-allocated, no allocation in hot path)
    req_buf: [2048]u8 = undefined,
    resp_buf: [HTTP_BUF_SIZE]u8 = undefined,

    pub fn init(allocator: Allocator, ip: []const u8, port: u16, username: []const u8, password: []const u8) !TapoDevice {
        const addr = try net.Address.parseIp4(ip, port);
        var self = TapoDevice{
            .allocator = allocator,
            .address = addr,
            .session = KlapSession.init(username, password),
        };
        const written = std.fmt.bufPrint(&self.host_str, "{s}:{d}", .{ ip, port }) catch return error.BufferOverflow;
        self.host_str_len = written.len;
        return self;
    }

    fn hostStr(self: *const TapoDevice) []const u8 {
        return self.host_str[0..self.host_str_len];
    }

    /// Perform KLAP v2 handshake (handshake1 + handshake2)
    pub fn authenticate(self: *TapoDevice) TapoError!void {
        // --- Handshake 1 ---
        const stream1 = net.tcpConnectToAddress(self.address) catch return TapoError.DeviceUnreachable;
        defer stream1.close();

        const resp1 = httpPost(
            stream1,
            "/app/handshake1",
            self.hostStr(),
            &self.session.local_seed,
            null,
            &self.req_buf,
            &self.resp_buf,
        ) catch return TapoError.HandshakeFailed;

        if (resp1.status != 200) return TapoError.AuthenticationFailed;

        // Parse response: remote_seed (16 bytes) + server_hash (32 bytes)
        if (resp1.body.len < KLAP_SEED_SIZE + 32) return TapoError.ProtocolError;

        @memcpy(&self.session.remote_seed, resp1.body[0..KLAP_SEED_SIZE]);

        // Verify server hash
        const expected = self.session.expectedServerHash();
        const server_hash = resp1.body[KLAP_SEED_SIZE .. KLAP_SEED_SIZE + 32];
        if (!std.mem.eql(u8, &expected, server_hash)) return TapoError.AuthenticationFailed;

        // Extract session cookie
        if (resp1.cookie) |cookie| {
            const len = @min(cookie.len, self.session.session_cookie.len);
            @memcpy(self.session.session_cookie[0..len], cookie[0..len]);
            self.session.session_cookie_len = len;
        }

        // --- Handshake 2 ---
        const stream2 = net.tcpConnectToAddress(self.address) catch return TapoError.DeviceUnreachable;
        defer stream2.close();

        const client_hash = self.session.clientHash();
        const cookie_slice = self.session.session_cookie[0..self.session.session_cookie_len];

        const resp2 = httpPost(
            stream2,
            "/app/handshake2",
            self.hostStr(),
            &client_hash,
            cookie_slice,
            &self.req_buf,
            &self.resp_buf,
        ) catch return TapoError.HandshakeFailed;

        if (resp2.status != 200) return TapoError.AuthenticationFailed;

        self.session.deriveKeys();
        self.session.authenticated = true;
    }

    /// Query current power (returns milliwatts)
    /// Sends encrypted JSON-RPC: {"method": "get_energy_usage"}
    pub fn getCurrentPower(self: *TapoDevice) TapoError!EnergyReading {
        if (!self.session.authenticated) return TapoError.AuthenticationFailed;

        const stream = net.tcpConnectToAddress(self.address) catch return TapoError.DeviceUnreachable;
        defer stream.close();

        // Build JSON-RPC payload
        const json_payload = "{\"method\":\"get_energy_usage\"}";

        // Encrypt with KLAP cipher (XOR with key-derived stream)
        var encrypted: [256]u8 = undefined;
        const enc_len = klapEncrypt(
            json_payload,
            &self.session.cipher_key,
            &self.session.cipher_iv,
            self.session.seq,
            &encrypted,
        );
        self.session.seq +%= 1;

        // Build request path with seq
        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/app/request?seq={d}", .{self.session.seq}) catch return TapoError.ProtocolError;

        const cookie_slice = self.session.session_cookie[0..self.session.session_cookie_len];

        const resp = httpPost(
            stream,
            path,
            self.hostStr(),
            encrypted[0..enc_len],
            cookie_slice,
            &self.req_buf,
            &self.resp_buf,
        ) catch return TapoError.DeviceUnreachable;

        if (resp.status != 200) return TapoError.DeviceError;

        // Decrypt response
        var decrypted: [HTTP_BUF_SIZE]u8 = undefined;
        const dec_len = klapDecrypt(
            resp.body,
            &self.session.cipher_key,
            &self.session.cipher_iv,
            self.session.seq,
            &decrypted,
        );

        // Parse energy data from decrypted JSON
        const reading = parseEnergyResponse(decrypted[0..dec_len]);

        // Push to ring buffer
        self.readings.push(reading);

        return reading;
    }

    /// Get device info (model, firmware, MAC, on/off state)
    pub fn getDeviceInfo(self: *TapoDevice) TapoError!DeviceInfo {
        if (!self.session.authenticated) return TapoError.AuthenticationFailed;

        const stream = net.tcpConnectToAddress(self.address) catch return TapoError.DeviceUnreachable;
        defer stream.close();

        const json_payload = "{\"method\":\"get_device_info\"}";
        var encrypted: [256]u8 = undefined;
        const enc_len = klapEncrypt(
            json_payload,
            &self.session.cipher_key,
            &self.session.cipher_iv,
            self.session.seq,
            &encrypted,
        );
        self.session.seq +%= 1;

        var path_buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/app/request?seq={d}", .{self.session.seq}) catch return TapoError.ProtocolError;

        const cookie_slice = self.session.session_cookie[0..self.session.session_cookie_len];

        const resp = httpPost(
            stream,
            path,
            self.hostStr(),
            encrypted[0..enc_len],
            cookie_slice,
            &self.req_buf,
            &self.resp_buf,
        ) catch return TapoError.DeviceUnreachable;

        if (resp.status != 200) return TapoError.DeviceError;

        var decrypted: [HTTP_BUF_SIZE]u8 = undefined;
        const dec_len = klapDecrypt(
            resp.body,
            &self.session.cipher_key,
            &self.session.cipher_iv,
            self.session.seq,
            &decrypted,
        );

        return parseDeviceInfoResponse(decrypted[0..dec_len]);
    }
};

// ============================================================================
// KLAP CIPHER (XOR-based stream cipher with SHA256-derived keystream)
// ============================================================================

/// KLAP encrypt: SHA256(key + iv + seq_be) XOR'd with plaintext, chunked.
fn klapEncrypt(plaintext: []const u8, key: *const [16]u8, iv: *const [12]u8, seq: i32, out: []u8) usize {
    return klapXorStream(plaintext, key, iv, seq, out);
}

fn klapDecrypt(ciphertext: []const u8, key: *const [16]u8, iv: *const [12]u8, seq: i32, out: []u8) usize {
    return klapXorStream(ciphertext, key, iv, seq, out);
}

fn klapXorStream(input: []const u8, key: *const [16]u8, iv: *const [12]u8, seq: i32, out: []u8) usize {
    const len = @min(input.len, out.len);
    var pos: usize = 0;

    while (pos < len) {
        // Generate 32-byte keystream block from SHA256(key + iv + seq + block_idx)
        const block_idx: u32 = @intCast(pos / 32);
        var h = Sha256.init(.{});
        h.update(key);
        h.update(iv);
        const seq_bytes: [4]u8 = @bitCast(@as(u32, @bitCast(seq +% @as(i32, @intCast(block_idx)))));
        h.update(&seq_bytes);
        const keystream = h.finalResult();

        // XOR up to 32 bytes
        const chunk_end = @min(pos + 32, len);
        for (pos..chunk_end) |i| {
            out[i] = input[i] ^ keystream[i - pos];
        }
        pos = chunk_end;
    }

    return len;
}

// ============================================================================
// JSON PARSING (minimal, no allocation)
// ============================================================================

pub const DeviceInfo = struct {
    model: [32]u8 = undefined,
    model_len: usize = 0,
    fw_ver: [32]u8 = undefined,
    fw_ver_len: usize = 0,
    mac: [18]u8 = undefined,
    mac_len: usize = 0,
    device_on: bool = false,
    on_time: u32 = 0,

    pub fn modelStr(self: *const DeviceInfo) []const u8 {
        return self.model[0..self.model_len];
    }

    pub fn fwStr(self: *const DeviceInfo) []const u8 {
        return self.fw_ver[0..self.fw_ver_len];
    }

    pub fn macStr(self: *const DeviceInfo) []const u8 {
        return self.mac[0..self.mac_len];
    }
};

/// Extract "current_power" from Tapo JSON response.
/// Response format: {"error_code":0,"result":{"current_power":12345}}
/// current_power is in milliwatts.
fn parseEnergyResponse(json: []const u8) EnergyReading {
    const milliwatts = extractJsonInt(json, "current_power") orelse 0;
    const watts: f32 = @as(f32, @floatFromInt(milliwatts)) / 1000.0;
    const classified = EnergyReading.classify(watts);

    return EnergyReading{
        .timestamp_ms = @intCast(std.time.milliTimestamp()),
        .watts = watts,
        .trit = classified.trit,
        .color = classified.color,
        .energy_wh = @as(f32, @floatFromInt(extractJsonInt(json, "month_energy") orelse 0)),
        .voltage = @as(f32, @floatFromInt(extractJsonInt(json, "voltage_mv") orelse 0)) / 1000.0,
        .current_ma = @as(f32, @floatFromInt(extractJsonInt(json, "current_ma") orelse 0)),
    };
}

fn parseDeviceInfoResponse(json: []const u8) DeviceInfo {
    var info = DeviceInfo{};
    if (extractJsonString(json, "model")) |m| {
        const len = @min(m.len, info.model.len);
        @memcpy(info.model[0..len], m[0..len]);
        info.model_len = len;
    }
    if (extractJsonString(json, "fw_ver")) |f| {
        const len = @min(f.len, info.fw_ver.len);
        @memcpy(info.fw_ver[0..len], f[0..len]);
        info.fw_ver_len = len;
    }
    if (extractJsonString(json, "mac")) |m| {
        const len = @min(m.len, info.mac.len);
        @memcpy(info.mac[0..len], m[0..len]);
        info.mac_len = len;
    }
    info.device_on = (extractJsonInt(json, "device_on") orelse 0) != 0;
    info.on_time = @intCast(extractJsonInt(json, "on_time") orelse 0);
    return info;
}

/// Minimal JSON integer extractor: finds "key":value and parses the integer.
fn extractJsonInt(json: []const u8, key: []const u8) ?i64 {
    // Search for "key": or "key" :
    var search_buf: [64]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, search) orelse return null;
    var pos = key_pos + search.len;

    // Skip whitespace and colon
    while (pos < json.len and (json[pos] == ' ' or json[pos] == ':' or json[pos] == '\t')) : (pos += 1) {}

    // Handle boolean true/false as 1/0
    if (pos < json.len and json[pos] == 't') return 1; // true
    if (pos < json.len and json[pos] == 'f') return 0; // false

    // Parse integer (possibly negative)
    const start = pos;
    if (pos < json.len and json[pos] == '-') pos += 1;
    while (pos < json.len and json[pos] >= '0' and json[pos] <= '9') : (pos += 1) {}

    if (pos == start) return null;
    return std.fmt.parseInt(i64, json[start..pos], 10) catch null;
}

/// Minimal JSON string extractor: finds "key":"value" and returns the value slice.
fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [64]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = std.mem.indexOf(u8, json, search) orelse return null;
    var pos = key_pos + search.len;

    // Skip to opening quote
    while (pos < json.len and json[pos] != '"') : (pos += 1) {}
    if (pos >= json.len) return null;
    pos += 1; // skip opening quote

    const start = pos;
    while (pos < json.len and json[pos] != '"') : (pos += 1) {}

    return json[start..pos];
}

// ============================================================================
// SYRUP BRIDGE — export energy state for OCapN transport
// ============================================================================

/// Serialize full L14 layer state as Syrup record
pub fn layerToSyrup(device: *const TapoDevice, allocator: Allocator) !syrup.Value {
    var entries = std.ArrayListUnmanaged(syrup.Value.DictEntry){};
    defer entries.deinit(allocator);

    try entries.append(allocator, .{
        .key = syrup.Value{ .symbol = "layer" },
        .value = syrup.Value{ .integer = 14 },
    });
    try entries.append(allocator, .{
        .key = syrup.Value{ .symbol = "name" },
        .value = syrup.Value{ .string = "energy-monitor" },
    });
    try entries.append(allocator, .{
        .key = syrup.Value{ .symbol = "device" },
        .value = syrup.Value{ .string = "tapo-p15" },
    });

    // Current reading
    if (device.readings.latest()) |reading| {
        const reading_syrup = try reading.toSyrup(allocator);
        try entries.append(allocator, .{
            .key = syrup.Value{ .symbol = "current" },
            .value = reading_syrup,
        });
    }

    // Summary
    const summary = try device.readings.summaryToSyrup(allocator);
    try entries.append(allocator, .{
        .key = syrup.Value{ .symbol = "summary" },
        .value = summary,
    });

    // GF(3) triadic roles
    try entries.append(allocator, .{
        .key = syrup.Value{ .symbol = "plus" },
        .value = syrup.Value{ .string = "wattage signal (generation rate)" },
    });
    try entries.append(allocator, .{
        .key = syrup.Value{ .symbol = "ergodic" },
        .value = syrup.Value{ .string = "charge state coordinator" },
    });
    try entries.append(allocator, .{
        .key = syrup.Value{ .symbol = "minus" },
        .value = syrup.Value{ .string = "overcurrent validator" },
    });

    const owned = try allocator.dupe(syrup.Value.DictEntry, entries.items);
    return syrup.Value{ .dictionary = owned };
}

// ============================================================================
// TESTS
// ============================================================================

test "GF(3) trit arithmetic" {
    // Conservation: +1 + 0 + (-1) = 0
    const sum = Trit.add(Trit.add(.plus, .zero), .minus);
    try std.testing.expectEqual(Trit.zero, sum);

    // Negation
    try std.testing.expectEqual(Trit.minus, Trit.neg(.plus));
    try std.testing.expectEqual(Trit.plus, Trit.neg(.minus));
    try std.testing.expectEqual(Trit.zero, Trit.neg(.zero));

    // GF(3) group: +1 + +1 = -1 (mod 3)
    try std.testing.expectEqual(Trit.minus, Trit.add(.plus, .plus));
}

test "energy classification" {
    // Active charging
    const gen = EnergyReading.classify(65.0);
    try std.testing.expectEqual(Trit.plus, gen.trit);
    try std.testing.expectEqual(@as(u8, 0x00), gen.color.r);

    // Trickle
    const erg = EnergyReading.classify(15.0);
    try std.testing.expectEqual(Trit.zero, erg.trit);

    // Idle
    const val = EnergyReading.classify(2.0);
    try std.testing.expectEqual(Trit.minus, val.trit);
    try std.testing.expectEqual(@as(u8, 0xF5), val.color.r);
}

test "ring buffer push and stats" {
    var ring = ReadingRing{};

    // Push 3 readings: +1, 0, -1 → balance = 0
    ring.push(.{
        .timestamp_ms = 1000,
        .watts = 65.0,
        .trit = .plus,
        .color = COLOR_GENERATOR,
    });
    ring.push(.{
        .timestamp_ms = 2000,
        .watts = 15.0,
        .trit = .zero,
        .color = COLOR_ERGODIC,
    });
    ring.push(.{
        .timestamp_ms = 3000,
        .watts = 2.0,
        .trit = .minus,
        .color = COLOR_VALIDATOR,
    });

    try std.testing.expectEqual(@as(usize, 3), ring.count);
    try std.testing.expectEqual(@as(i32, 0), ring.gf3Balance());

    const dist = ring.tritDistribution();
    try std.testing.expectEqual(@as(u32, 1), dist.plus);
    try std.testing.expectEqual(@as(u32, 1), dist.zero);
    try std.testing.expectEqual(@as(u32, 1), dist.minus);

    // Latest should be the -1 reading
    const latest = ring.latest().?;
    try std.testing.expectEqual(Trit.minus, latest.trit);
}

test "auth hash computation" {
    const hash = computeAuthHash("test@example.com", "password123");
    // Verify it's deterministic
    const hash2 = computeAuthHash("test@example.com", "password123");
    try std.testing.expectEqualSlices(u8, &hash, &hash2);

    // Different inputs → different hashes
    const hash3 = computeAuthHash("other@example.com", "password123");
    try std.testing.expect(!std.mem.eql(u8, &hash, &hash3));
}

test "KLAP key derivation is deterministic" {
    var s1 = KlapSession.init("user@test.com", "pass");
    s1.local_seed = [_]u8{0} ** KLAP_SEED_SIZE;
    s1.remote_seed = [_]u8{1} ** KLAP_SEED_SIZE;
    s1.deriveKeys();

    var s2 = KlapSession.init("user@test.com", "pass");
    s2.local_seed = [_]u8{0} ** KLAP_SEED_SIZE;
    s2.remote_seed = [_]u8{1} ** KLAP_SEED_SIZE;
    s2.deriveKeys();

    try std.testing.expectEqualSlices(u8, &s1.cipher_key, &s2.cipher_key);
    try std.testing.expectEqualSlices(u8, &s1.cipher_iv, &s2.cipher_iv);
}

test "KLAP XOR cipher roundtrip" {
    const key = [_]u8{0x42} ** 16;
    const iv = [_]u8{0x13} ** 12;
    const plaintext = "get_energy_usage";

    var encrypted: [256]u8 = undefined;
    const enc_len = klapEncrypt(plaintext, &key, &iv, 0, &encrypted);

    var decrypted: [256]u8 = undefined;
    const dec_len = klapDecrypt(encrypted[0..enc_len], &key, &iv, 0, &decrypted);

    try std.testing.expectEqualSlices(u8, plaintext, decrypted[0..dec_len]);
}

test "JSON integer extraction" {
    const json = "{\"error_code\":0,\"result\":{\"current_power\":12345,\"voltage_mv\":120100}}";
    try std.testing.expectEqual(@as(i64, 0), extractJsonInt(json, "error_code").?);
    try std.testing.expectEqual(@as(i64, 12345), extractJsonInt(json, "current_power").?);
    try std.testing.expectEqual(@as(i64, 120100), extractJsonInt(json, "voltage_mv").?);
    try std.testing.expect(extractJsonInt(json, "nonexistent") == null);
}

test "JSON string extraction" {
    const json = "{\"model\":\"TP15\",\"fw_ver\":\"1.4.2\",\"mac\":\"AA:BB:CC:DD:EE:FF\"}";
    try std.testing.expectEqualSlices(u8, "TP15", extractJsonString(json, "model").?);
    try std.testing.expectEqualSlices(u8, "1.4.2", extractJsonString(json, "fw_ver").?);
    try std.testing.expectEqualSlices(u8, "AA:BB:CC:DD:EE:FF", extractJsonString(json, "mac").?);
    try std.testing.expect(extractJsonString(json, "nonexistent") == null);
}

test "energy reading to syrup" {
    const allocator = std.testing.allocator;

    const reading = EnergyReading{
        .timestamp_ms = 1707000000,
        .watts = 65.5,
        .trit = .plus,
        .color = COLOR_GENERATOR,
        .energy_wh = 1234.0,
    };

    const val = try reading.toSyrup(allocator);
    defer {
        // Free the owned dictionary entries and hex string
        if (val == .dictionary) {
            for (val.dictionary) |entry| {
                if (entry.key == .symbol and std.mem.eql(u8, entry.key.symbol, "color")) {
                    if (entry.value == .string) {
                        allocator.free(entry.value.string);
                    }
                }
            }
            allocator.free(val.dictionary);
        }
    }

    try std.testing.expect(val == .dictionary);
    try std.testing.expect(val.dictionary.len == 5);
}

test "ring buffer summary to syrup" {
    const allocator = std.testing.allocator;

    var ring = ReadingRing{};
    ring.push(.{ .timestamp_ms = 1000, .watts = 65.0, .trit = .plus, .color = COLOR_GENERATOR });
    ring.push(.{ .timestamp_ms = 2000, .watts = 15.0, .trit = .zero, .color = COLOR_ERGODIC });

    const val = try ring.summaryToSyrup(allocator);
    defer {
        if (val == .dictionary) allocator.free(val.dictionary);
    }

    try std.testing.expect(val == .dictionary);
    try std.testing.expect(val.dictionary.len == 6);
}
