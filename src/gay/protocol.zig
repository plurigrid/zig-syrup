// protocol.zig: QUIC-inspired colored protocol + semiosis (sign triads with GF(3))
// Zig translation of Gay.jl's protocol.jl, quic.jl, and semiosis.jl
// Colored packet tracking, SPI verification, sign/object/interpretant triads

const std = @import("std");
const splitmix = @import("splitmix.zig");
const splitmix64 = splitmix.splitmix64;
const GAY_SEED: u64 = splitmix.GAY_SEED;

// BoundedArray was removed from std in Zig 0.15; local drop-in replacement.
fn BoundedArray(comptime T: type, comptime buffer_capacity: usize) type {
    return struct {
        const Self = @This();
        buffer: [buffer_capacity]T = undefined,
        len: usize = 0,

        pub fn slice(self: anytype) switch (@TypeOf(&self.buffer)) {
            *[buffer_capacity]T => []T,
            *const [buffer_capacity]T => []const T,
            else => unreachable,
        } {
            return self.buffer[0..self.len];
        }

        pub fn append(self: *Self, item: T) error{Overflow}!void {
            if (self.len >= buffer_capacity) return error.Overflow;
            self.buffer[self.len] = item;
            self.len += 1;
        }

        pub fn orderedRemove(self: *Self, index: usize) T {
            const val = self.buffer[index];
            std.mem.copyForwards(T, self.buffer[index..], self.buffer[index + 1 .. self.len]);
            self.len -= 1;
            return val;
        }
    };
}

// ============================================================================
// Color helpers
// ============================================================================

pub const RGB = struct {
    r: f64,
    g: f64,
    b: f64,

    pub fn fromSeed(seed: u64) RGB {
        var s = splitmix64(seed);
        const r: f64 = @as(f64, @floatFromInt(s & 0xFFFF)) / 65535.0;
        s = splitmix64(s);
        const g: f64 = @as(f64, @floatFromInt(s & 0xFFFF)) / 65535.0;
        s = splitmix64(s);
        const b: f64 = @as(f64, @floatFromInt(s & 0xFFFF)) / 65535.0;
        return .{ .r = r, .g = g, .b = b };
    }

    pub fn eql(self: RGB, other: RGB) bool {
        return self.r == other.r and self.g == other.g and self.b == other.b;
    }
};

// ============================================================================
// QUIC Path Probe
// ============================================================================

pub const QUICPathProbe = struct {
    nonce: u64,
    connection_id: u64,
    path_id: u32,
    is_challenge: bool,
    color: RGB,
};

pub const QUICPath = struct {
    path_id: u32,
    connection_id: u64,
    validated: bool,
    active: bool,
    probes_sent: u32,
    probes_received: u32,
    color: RGB,
    pending_nonces: BoundedArray(u64, 64),
};

pub const QUICConnection = struct {
    const MAX_PATHS = 8;
    const MAX_HISTORY = 256;

    connection_id: u64,
    seed: u64,
    paths: [MAX_PATHS]?QUICPath,
    probe_history: BoundedArray(QUICPathProbe, MAX_HISTORY),
    color: RGB,

    pub fn init(connection_id: u64, seed: u64) QUICConnection {
        return .{
            .connection_id = connection_id,
            .seed = seed,
            .paths = @splat(null),
            .probe_history = .{},
            .color = connectionColor(connection_id, seed),
        };
    }

    pub fn addPath(self: *QUICConnection, path_id: u32) *QUICPath {
        const idx = path_id % MAX_PATHS;
        if (self.paths[idx] == null) {
            self.paths[idx] = .{
                .path_id = path_id,
                .connection_id = self.connection_id,
                .validated = false,
                .active = true,
                .probes_sent = 0,
                .probes_received = 0,
                .color = pathColor(self.connection_id, path_id, self.seed),
                .pending_nonces = .{},
            };
        }
        return &(self.paths[idx].?);
    }

    pub fn probeChallenge(self: *QUICConnection, path_id: u32, nonce: u64) QUICPathProbe {
        const path = self.addPath(path_id);
        const probe_color = probeColor(nonce, self.connection_id, path_id, self.seed);
        const probe = QUICPathProbe{
            .nonce = nonce,
            .connection_id = self.connection_id,
            .path_id = path_id,
            .is_challenge = true,
            .color = probe_color,
        };
        path.pending_nonces.append(nonce) catch {};
        path.probes_sent += 1;
        self.probe_history.append(probe) catch {};
        return probe;
    }

    pub fn probeResponse(self: *QUICConnection, path_id: u32, nonce: u64) ?QUICPathProbe {
        const idx = path_id % MAX_PATHS;
        if (self.paths[idx] == null) return null;
        var path = &(self.paths[idx].?);

        // Find matching nonce
        var found = false;
        for (path.pending_nonces.slice(), 0..) |n, i| {
            if (n == nonce) {
                _ = path.pending_nonces.orderedRemove(i);
                found = true;
                break;
            }
        }
        if (!found) return null;

        path.probes_received += 1;
        const response = QUICPathProbe{
            .nonce = nonce,
            .connection_id = self.connection_id,
            .path_id = path_id,
            .is_challenge = false,
            .color = probeColor(nonce, self.connection_id, path_id, self.seed),
        };
        self.probe_history.append(response) catch {};
        return response;
    }

    pub fn validatePath(self: *QUICConnection, path_id: u32) bool {
        const idx = path_id % MAX_PATHS;
        if (self.paths[idx]) |*path| {
            if (path.probes_received > 0) {
                path.validated = true;
                return true;
            }
        }
        return false;
    }
};

pub fn connectionColor(connection_id: u64, seed: u64) RGB {
    return RGB.fromSeed(seed ^ connection_id);
}

pub fn pathColor(connection_id: u64, path_id: u32, seed: u64) RGB {
    const path_seed = splitmix64(seed ^ @as(u64, path_id) ^ connection_id);
    return RGB.fromSeed(path_seed);
}

pub fn probeColor(nonce: u64, connection_id: u64, path_id: u32, seed: u64) RGB {
    const probe_seed = splitmix64(seed ^ connection_id ^ @as(u64, path_id) ^ nonce);
    return RGB.fromSeed(probe_seed);
}

// ============================================================================
// SPI Color Verification
// ============================================================================

pub fn colorFingerprint(colors: []const RGB) u64 {
    var fp: u64 = 0;
    for (colors) |c| {
        const r_bits: u32 = @bitCast(@as(f32, @floatCast(c.r)));
        const g_bits: u32 = @bitCast(@as(f32, @floatCast(c.g)));
        const b_bits: u32 = @bitCast(@as(f32, @floatCast(c.b)));
        fp ^= @as(u64, r_bits) | (@as(u64, g_bits) << 24) | (@as(u64, b_bits) << 48);
    }
    return fp;
}

/// Verify SPI: same seed + inputs => same colors.
pub fn spiVerify(connection_id: u64, path_id: u32, nonce: u64, seed: u64) bool {
    const c1 = probeColor(nonce, connection_id, path_id, seed);
    const c2 = probeColor(nonce, connection_id, path_id, seed);
    return c1.eql(c2);
}

// ============================================================================
// Semiosis: Sign/Object/Interpretant Triads with GF(3)
// ============================================================================

pub const Trit = enum(i2) {
    minus = -1,
    zero = 0,
    plus = 1,

    pub fn add(a: Trit, b: Trit) Trit {
        const sum = @as(i8, @backingInt(a)) + @as(i8, @backingInt(b));
        // Map sum in [-2,2] to trit in [-1,0,1]
        if (sum >= 2) return .minus; // 2 mod 3 = -1
        if (sum <= -2) return .plus; // -2 mod 3 = 1
        return @fromBackingInt(@intCast(@as(i2, @intCast(sum))));
    }

    pub fn negate(self: Trit) Trit {
        return @fromBackingInt(@intCast(-@as(i2, @backingInt(self))));
    }
};

pub const SignTriad = struct {
    sign: u64,
    object: u64,
    interpretant: u64,
    trit: Trit,
    color: RGB,

    pub fn init(sign: u64, object: u64, interpretant: u64, seed: u64) SignTriad {
        // GF(3) trit from XOR of components
        const combined = sign ^ object ^ interpretant;
        const trit_val: i2 = @intCast(@as(i8, @intCast(combined % 3)) - 1);
        return .{
            .sign = sign,
            .object = object,
            .interpretant = interpretant,
            .trit = @fromBackingInt(@intCast(trit_val)),
            .color = RGB.fromSeed(seed ^ combined),
        };
    }

    /// GF(3) conservation: sum of trits in a semiosis chain should be 0 mod 3.
    pub fn conserved(triads: []const SignTriad) bool {
        var sum: i8 = 0;
        for (triads) |t| {
            sum += @as(i8, @backingInt(t.trit));
        }
        // Use wider type for mod to avoid overflow
        const wide: i32 = @as(i32, sum);
        return @mod(wide + 300, 3) == 0;
    }
};

// ============================================================================
// Protocol State Machine
// ============================================================================

pub const ProtocolState = enum {
    idle,
    handshake,
    connected,
    probing,
    validated,
    closed,
};

pub const ProtocolEvent = enum {
    start_handshake,
    handshake_complete,
    send_probe,
    receive_response,
    validate,
    close,
};

pub const ProtocolStateMachine = struct {
    state: ProtocolState,
    color: RGB,
    transition_count: u32,
    fingerprint: u64,

    pub fn init(seed: u64) ProtocolStateMachine {
        return .{
            .state = .idle,
            .color = RGB.fromSeed(seed),
            .transition_count = 0,
            .fingerprint = seed,
        };
    }

    pub fn transition(self: *ProtocolStateMachine, event: ProtocolEvent) bool {
        const next: ?ProtocolState = switch (self.state) {
            .idle => if (event == .start_handshake) .handshake else null,
            .handshake => if (event == .handshake_complete) .connected else null,
            .connected => switch (event) {
                .send_probe => .probing,
                .close => .closed,
                else => null,
            },
            .probing => switch (event) {
                .receive_response => .connected,
                .validate => .validated,
                .close => .closed,
                else => null,
            },
            .validated => switch (event) {
                .send_probe => .probing,
                .close => .closed,
                else => null,
            },
            .closed => null,
        };
        if (next) |n| {
            self.state = n;
            self.transition_count += 1;
            self.fingerprint ^= splitmix64(@as(u64, self.transition_count) ^ @backingInt(n));
            self.color = RGB.fromSeed(self.fingerprint);
            return true;
        }
        return false;
    }
};

// ============================================================================
// SSE Operator (Semiosis: physical sign attachment)
// ============================================================================

pub const SSEOperatorType = enum { diagonal, offdiag_plus, offdiag_minus };

pub const SSEOperator = struct {
    bond: [4]u32,
    op_type: SSEOperatorType,
    color: RGB,
    spin: i8,
    weight: f64,
};

pub fn createSSEOperator(bond: [4]u32, op_type: SSEOperatorType, weight: f64, seed: u64) SSEOperator {
    const stream_idx: u64 = switch (op_type) {
        .diagonal => 0,
        .offdiag_plus => 1,
        .offdiag_minus => 2,
    };
    return .{
        .bond = bond,
        .op_type = op_type,
        .color = RGB.fromSeed(seed ^ stream_idx),
        .spin = if (op_type == .offdiag_minus) -1 else 1,
        .weight = weight,
    };
}

/// Magnetization: average spin of operators.
pub fn sseMagnetization(operators: []const SSEOperator) f64 {
    if (operators.len == 0) return 0.0;
    var sum: f64 = 0.0;
    for (operators) |op| {
        sum += @as(f64, @floatFromInt(op.spin));
    }
    return sum / @as(f64, @floatFromInt(operators.len));
}

// ============================================================================
// Tests
// ============================================================================

test "QUIC connection and path probe" {
    var conn = QUICConnection.init(0xABCD, GAY_SEED);
    _ = conn.addPath(0);
    const challenge = conn.probeChallenge(0, 0x12345678);
    try std.testing.expect(challenge.is_challenge);
    try std.testing.expectEqual(@as(u64, 0x12345678), challenge.nonce);

    const response = conn.probeResponse(0, 0x12345678);
    try std.testing.expect(response != null);
    try std.testing.expect(!response.?.is_challenge);
}

test "QUIC path validation" {
    var conn = QUICConnection.init(0xBEEF, GAY_SEED);
    _ = conn.probeChallenge(0, 0x1111);
    _ = conn.probeResponse(0, 0x1111);
    try std.testing.expect(conn.validatePath(0));
}

test "QUIC invalid response rejected" {
    var conn = QUICConnection.init(0xDEAD, GAY_SEED);
    _ = conn.probeChallenge(0, 0x2222);
    // Wrong nonce
    const bad = conn.probeResponse(0, 0x3333);
    try std.testing.expect(bad == null);
}

test "probe color determinism (SPI)" {
    try std.testing.expect(spiVerify(0xABCD, 0, 0x1234, GAY_SEED));
    try std.testing.expect(spiVerify(0xFFFF, 7, 0xDEADBEEF, 42));
}

test "color fingerprint order independent" {
    const c1 = RGB.fromSeed(111);
    const c2 = RGB.fromSeed(222);
    const c3 = RGB.fromSeed(333);
    const abc = [_]RGB{ c1, c2, c3 };
    const bca = [_]RGB{ c2, c3, c1 };
    try std.testing.expectEqual(colorFingerprint(&abc), colorFingerprint(&bca));
}

test "connection color determinism" {
    const c1 = connectionColor(0xABCD, GAY_SEED);
    const c2 = connectionColor(0xABCD, GAY_SEED);
    try std.testing.expect(c1.eql(c2));
}

test "GF(3) trit arithmetic" {
    try std.testing.expectEqual(Trit.zero, Trit.plus.add(.minus));
    try std.testing.expectEqual(Trit.minus, Trit.plus.negate());
    try std.testing.expectEqual(Trit.plus, Trit.minus.negate());
    try std.testing.expectEqual(Trit.zero, Trit.zero.negate());
}

test "semiosis GF(3) conservation" {
    // Create a chain of 3 triads whose trits sum to 0
    const t1 = SignTriad{ .sign = 1, .object = 2, .interpretant = 3, .trit = .plus, .color = RGB.fromSeed(1) };
    const t2 = SignTriad{ .sign = 4, .object = 5, .interpretant = 6, .trit = .minus, .color = RGB.fromSeed(2) };
    const t3 = SignTriad{ .sign = 7, .object = 8, .interpretant = 9, .trit = .zero, .color = RGB.fromSeed(3) };
    const chain = [_]SignTriad{ t1, t2, t3 };
    // +1 + (-1) + 0 = 0
    try std.testing.expect(SignTriad.conserved(&chain));
}

test "semiosis non-conservation detected" {
    const t1 = SignTriad{ .sign = 1, .object = 2, .interpretant = 3, .trit = .plus, .color = RGB.fromSeed(1) };
    const t2 = SignTriad{ .sign = 4, .object = 5, .interpretant = 6, .trit = .plus, .color = RGB.fromSeed(2) };
    const chain = [_]SignTriad{ t1, t2 };
    // +1 + 1 = 2 != 0 mod 3
    try std.testing.expect(!SignTriad.conserved(&chain));
}

test "sign triad init" {
    const t = SignTriad.init(10, 20, 30, GAY_SEED);
    // Trit should be deterministic
    const t2 = SignTriad.init(10, 20, 30, GAY_SEED);
    try std.testing.expectEqual(t.trit, t2.trit);
    try std.testing.expect(t.color.eql(t2.color));
}

test "protocol state machine valid transitions" {
    var sm = ProtocolStateMachine.init(GAY_SEED);
    try std.testing.expectEqual(ProtocolState.idle, sm.state);

    try std.testing.expect(sm.transition(.start_handshake));
    try std.testing.expectEqual(ProtocolState.handshake, sm.state);

    try std.testing.expect(sm.transition(.handshake_complete));
    try std.testing.expectEqual(ProtocolState.connected, sm.state);

    try std.testing.expect(sm.transition(.send_probe));
    try std.testing.expectEqual(ProtocolState.probing, sm.state);

    try std.testing.expect(sm.transition(.validate));
    try std.testing.expectEqual(ProtocolState.validated, sm.state);

    try std.testing.expect(sm.transition(.close));
    try std.testing.expectEqual(ProtocolState.closed, sm.state);
}

test "protocol state machine invalid transitions rejected" {
    var sm = ProtocolStateMachine.init(GAY_SEED);
    // Can't validate from idle
    try std.testing.expect(!sm.transition(.validate));
    try std.testing.expectEqual(ProtocolState.idle, sm.state);
    // Can't close from idle
    try std.testing.expect(!sm.transition(.close));
}

test "protocol color changes on transition" {
    var sm = ProtocolStateMachine.init(GAY_SEED);
    const initial_color = sm.color;
    _ = sm.transition(.start_handshake);
    // Color should change after transition
    try std.testing.expect(!sm.color.eql(initial_color));
}

test "SSE operator magnetization" {
    var ops: [3]SSEOperator = undefined;
    ops[0] = createSSEOperator(.{ 0, 0, 1, 0 }, .diagonal, 1.0, GAY_SEED);
    ops[1] = createSSEOperator(.{ 1, 0, 2, 0 }, .offdiag_plus, 0.5, GAY_SEED);
    ops[2] = createSSEOperator(.{ 2, 0, 3, 0 }, .offdiag_minus, 0.5, GAY_SEED);
    const mag = sseMagnetization(&ops);
    // 1 + 1 + (-1) = 1, /3 = 0.333...
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 3.0), mag, 1e-10);
}

test "multiple paths different colors" {
    const c0 = pathColor(0xABCD, 0, GAY_SEED);
    const c1 = pathColor(0xABCD, 1, GAY_SEED);
    // Different paths should get different colors
    try std.testing.expect(!c0.eql(c1));
}
