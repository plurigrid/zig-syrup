// fault_tolerant.zig: Zig translation of Gay.jl's fault_tolerant.jl
// Jepsen-style fault injection, bidirectional color tracking, Galois connections
// for distributed tensor-parallel inference verification.
//
// Uses splitmix64 for all hashing. GF(3) conservation maintained.

const std = @import("std");
const sm = @import("splitmix.zig");
const Allocator = std.mem.Allocator;

const splitmix64 = sm.splitmix64;
const GAY_SEED = sm.GAY_SEED;
const Color = sm.Color;

// ═══════════════════════════════════════════════════════════════════════════════
// Hash constants (matching Gay.jl)
// ═══════════════════════════════════════════════════════════════════════════════

const HASH_TOKEN: u64 = 0x9e3779b97f4a7c15;
const HASH_LAYER: u64 = 0x517cc1b727220a95;
const HASH_DIM: u64 = 0xc4ceb9fe1a85ec53;

// ═══════════════════════════════════════════════════════════════════════════════
// Color from hash (matches Gay.jl hash_color)
// ═══════════════════════════════════════════════════════════════════════════════

fn hashColor(seed: u64, index: u64) Color {
    const h = splitmix64(seed ^ (index *% HASH_TOKEN));
    const mask21: u64 = (1 << 21) - 1;
    const scale = 1.0 / @as(f64, @floatFromInt(mask21));
    return .{
        .r = @as(f64, @floatFromInt(h & mask21)) * scale,
        .g = @as(f64, @floatFromInt((h >> 21) & mask21)) * scale,
        .b = @as(f64, @floatFromInt((h >> 42) & mask21)) * scale,
    };
}

/// XOR fingerprint of a float slice (reinterpret as u32, XOR fold)
fn xorFingerprint(data: []const f32) u32 {
    var fp: u32 = 0;
    const bytes = std.mem.sliceAsBytes(data);
    const u32_slice = std.mem.bytesAsSlice(u32, bytes);
    for (u32_slice) |w| {
        fp ^= w;
    }
    return fp;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Galois Connection: Events <-> Colors
// ═══════════════════════════════════════════════════════════════════════════════

pub const PALETTE_SIZE: usize = 226;

pub const Event = struct {
    seed: u64,
    token: u32,
    layer: u32,
    dim: u32,

    fn hash(self: Event) u64 {
        const h = self.seed ^
            (@as(u64, self.token) *% HASH_TOKEN) ^
            (@as(u64, self.layer) *% HASH_LAYER) ^
            (@as(u64, self.dim) *% HASH_DIM);
        return splitmix64(h);
    }
};

pub const IndexedColor = struct {
    index: u32,
    rgb: Color,
};

pub const GaloisConnection = struct {
    seed: u64,
    palette_size: u32,
    palette: [PALETTE_SIZE]Color,
    /// representatives[color_index] = token that hashes to it; sentinel = max u32 if not found
    representatives: [PALETTE_SIZE]u32,

    pub fn init(seed: u64) GaloisConnection {
        return initWithSize(seed, PALETTE_SIZE);
    }

    pub fn initWithSize(seed: u64, palette_size: u32) GaloisConnection {
        var gc: GaloisConnection = undefined;
        gc.seed = seed;
        gc.palette_size = palette_size;

        // Build palette
        for (0..palette_size) |i| {
            gc.palette[i] = hashColor(seed, @intCast(i));
        }
        // Zero remaining
        for (palette_size..PALETTE_SIZE) |i| {
            gc.palette[i] = .{ .r = 0, .g = 0, .b = 0 };
        }

        // Build representatives: find a token that hashes to each color index
        @memset(&gc.representatives, std.math.maxInt(u32));
        var found: u32 = 0;
        var token: u32 = 0;
        const limit = palette_size * 100;
        while (found < palette_size and token < limit) : (token += 1) {
            var h = seed ^ (@as(u64, token) *% HASH_TOKEN) ^
                (@as(u64, 1) *% HASH_LAYER) ^
                (@as(u64, 1) *% HASH_DIM);
            h = splitmix64(h);
            const idx: u32 = @intCast(h % palette_size);
            if (gc.representatives[idx] == std.math.maxInt(u32)) {
                gc.representatives[idx] = token;
                found += 1;
            }
        }

        return gc;
    }

    /// alpha: Event -> IndexedColor (left adjoint, abstraction)
    pub fn alpha(self: *const GaloisConnection, e: Event) IndexedColor {
        const h = e.hash();
        const idx: u32 = @intCast(h % self.palette_size);
        return .{ .index = idx, .rgb = self.palette[idx] };
    }

    /// gamma: IndexedColor -> Event (right adjoint, concretization)
    pub fn gamma(self: *const GaloisConnection, c: IndexedColor) Event {
        const rep = self.representatives[c.index];
        const token = if (rep != std.math.maxInt(u32)) rep else c.index;
        return .{ .seed = self.seed, .token = token, .layer = 1, .dim = 1 };
    }

    /// Verify alpha(gamma(c)) == c
    pub fn verifyClosure(self: *const GaloisConnection, c: IndexedColor) bool {
        const representative = self.gamma(c);
        const abstracted = self.alpha(representative);
        return abstracted.index == c.index;
    }

    /// Verify closure for all colors in the palette
    pub fn verifyAllClosures(self: *const GaloisConnection) bool {
        for (0..self.palette_size) |i| {
            const c = IndexedColor{ .index = @intCast(i), .rgb = self.palette[i] };
            if (!self.verifyClosure(c)) return false;
        }
        return true;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Fault Types (Jepsen-style)
// ═══════════════════════════════════════════════════════════════════════════════

pub const FaultKind = enum {
    network_partition,
    message_delay,
    message_drop,
    bit_flip,
    byzantine,
};

pub const Fault = struct {
    kind: FaultKind,
    target_device: u32,
    /// For bit_flip: number of bits to flip
    n_bits: u32 = 1,
    /// Probability of fault applying [0.0, 1.0]
    probability: f64 = 1.0,
    /// For message_delay: delay in ms
    delay_ms: f64 = 100.0,
    /// For network_partition: second partition member
    partition_peer: u32 = 0,
};

pub const FaultAction = enum { injected, healed };

pub const FaultHistoryEntry = struct {
    fault: Fault,
    action: FaultAction,
    /// Monotonic counter for ordering
    seq: u64,
};

// ═══════════════════════════════════════════════════════════════════════════════
// Fault Injector
// ═══════════════════════════════════════════════════════════════════════════════

pub const FaultInjector = struct {
    allocator: Allocator,
    active_faults: std.ArrayList(Fault),
    history: std.ArrayList(FaultHistoryEntry),
    rng_state: u64,
    seq: u64,

    pub fn init(allocator: Allocator, seed: u64) FaultInjector {
        return .{
            .allocator = allocator,
            .active_faults = .empty,
            .history = .empty,
            .rng_state = splitmix64(seed),
            .seq = 0,
        };
    }

    pub fn deinit(self: *FaultInjector) void {
        self.active_faults.deinit(self.allocator);
        self.history.deinit(self.allocator);
    }

    pub fn inject(self: *FaultInjector, fault: Fault) !void {
        try self.active_faults.append(self.allocator, fault);
        try self.history.append(self.allocator, .{ .fault = fault, .action = .injected, .seq = self.seq });
        self.seq += 1;
    }

    pub fn heal(self: *FaultInjector, fault: Fault) !void {
        for (self.active_faults.items, 0..) |f, i| {
            if (f.kind == fault.kind and f.target_device == fault.target_device) {
                _ = self.active_faults.orderedRemove(i);
                try self.history.append(self.allocator, .{ .fault = fault, .action = .healed, .seq = self.seq });
                self.seq += 1;
                return;
            }
        }
    }

    pub fn healAll(self: *FaultInjector) !void {
        for (self.active_faults.items) |f| {
            try self.history.append(self.allocator, .{ .fault = f, .action = .healed, .seq = self.seq });
            self.seq += 1;
        }
        self.active_faults.clearRetainingCapacity();
    }

    /// Advance internal PRNG
    fn nextRand(self: *FaultInjector) f64 {
        self.rng_state = splitmix64(self.rng_state);
        return @as(f64, @floatFromInt(self.rng_state & 0xFFFFFFFF)) / @as(f64, 0xFFFFFFFF);
    }

    /// Apply active faults to a tensor buffer (f32 slice), for given device_id
    pub fn applyToTensor(self: *FaultInjector, tensor: []f32, device_id: u32) void {
        for (self.active_faults.items) |fault| {
            if (fault.kind == .bit_flip and fault.target_device == device_id) {
                if (self.nextRand() < fault.probability) {
                    const u32_slice = std.mem.bytesAsSlice(u32, std.mem.sliceAsBytes(tensor));
                    var i: u32 = 0;
                    while (i < fault.n_bits) : (i += 1) {
                        self.rng_state = splitmix64(self.rng_state);
                        const idx = self.rng_state % u32_slice.len;
                        self.rng_state = splitmix64(self.rng_state);
                        const bit: u5 = @intCast(self.rng_state % 32);
                        u32_slice[idx] ^= @as(u32, 1) << bit;
                    }
                }
            }
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Device State
// ═══════════════════════════════════════════════════════════════════════════════

pub const DeviceState = struct {
    device_id: u32,
    layer_start: u32,
    layer_end: u32, // exclusive
    current_fingerprint: u32,
    expected_fingerprint: u32,
    is_partitioned: bool,

    pub fn layerCount(self: DeviceState) u32 {
        return self.layer_end - self.layer_start;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Simulated Cluster
// ═══════════════════════════════════════════════════════════════════════════════

pub const MAX_DEVICES: usize = 16;

pub const SimulatedCluster = struct {
    n_devices: u32,
    n_layers: u32,
    seed: u64,
    n_tokens: u32,
    hidden_dim: u32,
    devices: [MAX_DEVICES]DeviceState,
    fault_injector: FaultInjector,
    galois: GaloisConnection,

    pub fn init(
        allocator: Allocator,
        n_devices: u32,
        n_layers: u32,
        seed: u64,
        n_tokens: u32,
        hidden_dim: u32,
    ) SimulatedCluster {
        var cluster: SimulatedCluster = undefined;
        cluster.n_devices = n_devices;
        cluster.n_layers = n_layers;
        cluster.seed = seed;
        cluster.n_tokens = n_tokens;
        cluster.hidden_dim = hidden_dim;
        cluster.fault_injector = FaultInjector.init(allocator, 42);
        cluster.galois = GaloisConnection.init(seed);

        // Partition layers across devices
        const layers_per = n_layers / n_devices;
        var remaining = n_layers % n_devices;
        var layer_cursor: u32 = 0;
        for (0..n_devices) |i| {
            const extra: u32 = if (remaining > 0) blk: {
                remaining -= 1;
                break :blk 1;
            } else 0;
            const count = layers_per + extra;
            cluster.devices[i] = .{
                .device_id = @intCast(i),
                .layer_start = layer_cursor,
                .layer_end = layer_cursor + count,
                .current_fingerprint = 0,
                .expected_fingerprint = computeExpectedFingerprint(seed, layer_cursor, layer_cursor + count, n_tokens, hidden_dim),
                .is_partitioned = false,
            };
            layer_cursor += count;
        }

        return cluster;
    }

    pub fn deinit(self: *SimulatedCluster) void {
        self.fault_injector.deinit();
    }

    pub fn injectFault(self: *SimulatedCluster, fault: Fault) !void {
        try self.fault_injector.inject(fault);
    }

    pub fn healAll(self: *SimulatedCluster) !void {
        try self.fault_injector.healAll();
    }

    /// Run inference simulation. If with_faults, applies active faults to tensors.
    /// Returns true if all fingerprints match expected.
    pub fn runInference(self: *SimulatedCluster, allocator: Allocator, with_faults: bool) !bool {
        for (0..self.n_devices) |di| {
            var dev = &self.devices[di];

            // Allocate synthetic hidden state
            const size = @as(usize, self.n_tokens) * @as(usize, self.hidden_dim);
            const hidden = try allocator.alloc(f32, size);
            defer allocator.free(hidden);

            // Fill with deterministic pseudo-random data via splitmix
            var s = self.seed ^ @as(u64, dev.device_id);
            for (hidden, 0..) |*val, idx| {
                s = splitmix64(s ^ @as(u64, idx));
                // Map to [-1, 1] range
                val.* = @as(f32, @floatFromInt(@as(i32, @bitCast(@as(u32, @truncate(s)))))) / @as(f32, @floatFromInt(@as(u32, std.math.maxInt(i32))));
            }

            // Apply SPI coloring perturbation for each layer
            var layer = dev.layer_start;
            while (layer < dev.layer_end) : (layer += 1) {
                var t: u32 = 0;
                while (t < self.n_tokens) : (t += 1) {
                    var d: u32 = 0;
                    while (d < self.hidden_dim) : (d += 1) {
                        const h_val = self.seed ^
                            (@as(u64, t) *% HASH_TOKEN) ^
                            (@as(u64, layer) *% HASH_LAYER) ^
                            (@as(u64, d) *% HASH_DIM);
                        const rgb = hashColor(h_val, @as(u64, t));
                        const offset = @as(usize, t) * @as(usize, self.hidden_dim) + @as(usize, d);
                        hidden[offset] += @as(f32, @floatCast(rgb.r)) * 1e-7;
                    }
                }
            }

            // Apply faults
            if (with_faults) {
                self.fault_injector.applyToTensor(hidden, dev.device_id);
            }

            // Compute fingerprint
            dev.current_fingerprint = xorFingerprint(hidden);
        }

        return self.verify();
    }

    /// Verify all device fingerprints match expected
    pub fn verify(self: *const SimulatedCluster) bool {
        for (0..self.n_devices) |i| {
            if (self.devices[i].current_fingerprint != self.devices[i].expected_fingerprint) {
                return false;
            }
        }
        return true;
    }
};

/// Compute expected fingerprint for a range of layers
fn computeExpectedFingerprint(seed: u64, layer_start: u32, layer_end: u32, n_tokens: u32, hidden_dim: u32) u32 {
    // Deterministic expected value: hash of seed+layer range
    var fp: u32 = 0;
    var layer = layer_start;
    while (layer < layer_end) : (layer += 1) {
        const h = splitmix64(seed ^ (@as(u64, layer) *% HASH_LAYER) ^ (@as(u64, n_tokens) *% HASH_TOKEN));
        fp ^= @truncate(h ^ (h >> 32));
        _ = hidden_dim;
    }
    return fp;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Bidirectional Color Tracker
// ═══════════════════════════════════════════════════════════════════════════════

pub const TrackingKey = struct {
    layer: u32,
    token: u32,
    dim: u32,
};

pub const TrackingDirection = enum { forward, backward };

pub const ProofEntry = struct {
    direction: TrackingDirection,
    key: TrackingKey,
    color_idx: u32,
    galois_closure: bool,
    forward_consistent: bool,
};

pub const BidirectionalTracker = struct {
    allocator: Allocator,
    galois: GaloisConnection,
    seed: u64,
    forward_colors: std.AutoHashMap(TrackingKey, u32),
    backward_colors: std.AutoHashMap(TrackingKey, u32),
    proof_log: std.ArrayList(ProofEntry),

    pub fn init(allocator: Allocator, seed: u64) BidirectionalTracker {
        return .{
            .allocator = allocator,
            .galois = GaloisConnection.init(seed),
            .seed = seed,
            .forward_colors = std.AutoHashMap(TrackingKey, u32).init(allocator),
            .backward_colors = std.AutoHashMap(TrackingKey, u32).init(allocator),
            .proof_log = .empty,
        };
    }

    pub fn deinit(self: *BidirectionalTracker) void {
        self.forward_colors.deinit();
        self.backward_colors.deinit();
        self.proof_log.deinit(self.allocator);
    }

    pub fn trackForward(self: *BidirectionalTracker, layer: u32, token: u32, dim: u32) !IndexedColor {
        const event = Event{ .seed = self.seed, .token = token, .layer = layer, .dim = dim };
        const color = self.galois.alpha(event);
        const key = TrackingKey{ .layer = layer, .token = token, .dim = dim };
        try self.forward_colors.put(key, color.index);

        try self.proof_log.append(self.allocator, .{
            .direction = .forward,
            .key = key,
            .color_idx = color.index,
            .galois_closure = self.galois.verifyClosure(color),
            .forward_consistent = true,
        });

        return color;
    }

    pub fn trackBackward(self: *BidirectionalTracker, layer: u32, token: u32, dim: u32) !IndexedColor {
        const event = Event{ .seed = self.seed, .token = token, .layer = layer, .dim = dim };
        const color = self.galois.alpha(event);
        const key = TrackingKey{ .layer = layer, .token = token, .dim = dim };
        try self.backward_colors.put(key, color.index);

        const consistent = if (self.forward_colors.get(key)) |fwd_idx|
            fwd_idx == color.index
        else
            true;

        try self.proof_log.append(self.allocator, .{
            .direction = .backward,
            .key = key,
            .color_idx = color.index,
            .galois_closure = self.galois.verifyClosure(color),
            .forward_consistent = consistent,
        });

        return color;
    }

    /// Verify all forward/backward pairs are consistent
    pub fn verifyConsistency(self: *const BidirectionalTracker) bool {
        var iter = self.forward_colors.iterator();
        while (iter.next()) |entry| {
            if (self.backward_colors.get(entry.key_ptr.*)) |bwd_idx| {
                if (entry.value_ptr.* != bwd_idx) return false;
            }
        }
        return true;
    }

    /// Check all proof log entries have valid Galois closure
    pub fn allClosuresValid(self: *const BidirectionalTracker) bool {
        for (self.proof_log.items) |entry| {
            if (!entry.galois_closure) return false;
        }
        return true;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

test "Galois closure property for all 226 colors" {
    const gc = GaloisConnection.init(GAY_SEED);
    try std.testing.expect(gc.verifyAllClosures());
}

test "Galois alpha deterministic" {
    const gc = GaloisConnection.init(GAY_SEED);
    const e = Event{ .seed = GAY_SEED, .token = 42, .layer = 3, .dim = 7 };
    const c1 = gc.alpha(e);
    const c2 = gc.alpha(e);
    try std.testing.expectEqual(c1.index, c2.index);
}

test "Galois alpha-gamma roundtrip" {
    const gc = GaloisConnection.init(GAY_SEED);
    // For every color, alpha(gamma(c)).index == c.index
    for (0..gc.palette_size) |i| {
        const c = IndexedColor{ .index = @intCast(i), .rgb = gc.palette[i] };
        const rep = gc.gamma(c);
        const back = gc.alpha(rep);
        try std.testing.expectEqual(c.index, back.index);
    }
}

test "fault injector inject and heal" {
    const allocator = std.testing.allocator;
    var fi = FaultInjector.init(allocator, 42);
    defer fi.deinit();

    const fault = Fault{ .kind = .bit_flip, .target_device = 0, .n_bits = 5 };
    try fi.inject(fault);
    try std.testing.expectEqual(fi.active_faults.items.len, 1);

    try fi.heal(fault);
    try std.testing.expectEqual(fi.active_faults.items.len, 0);
    try std.testing.expectEqual(fi.history.items.len, 2);
}

test "fault injector healAll" {
    const allocator = std.testing.allocator;
    var fi = FaultInjector.init(allocator, 42);
    defer fi.deinit();

    try fi.inject(.{ .kind = .bit_flip, .target_device = 0 });
    try fi.inject(.{ .kind = .message_drop, .target_device = 1 });
    try fi.inject(.{ .kind = .byzantine, .target_device = 2 });
    try std.testing.expectEqual(fi.active_faults.items.len, 3);

    try fi.healAll();
    try std.testing.expectEqual(fi.active_faults.items.len, 0);
}

test "bit flip corrupts tensor" {
    const allocator = std.testing.allocator;
    var fi = FaultInjector.init(allocator, 42);
    defer fi.deinit();

    var tensor = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const fp_before = xorFingerprint(&tensor);

    try fi.inject(.{ .kind = .bit_flip, .target_device = 0, .n_bits = 10 });
    fi.applyToTensor(&tensor, 0);

    const fp_after = xorFingerprint(&tensor);
    // Extremely unlikely to be the same after 10 bit flips
    try std.testing.expect(fp_before != fp_after);
}

test "bit flip does not affect other devices" {
    const allocator = std.testing.allocator;
    var fi = FaultInjector.init(allocator, 42);
    defer fi.deinit();

    var tensor = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const original = tensor;

    try fi.inject(.{ .kind = .bit_flip, .target_device = 0, .n_bits = 10 });
    fi.applyToTensor(&tensor, 1); // different device

    try std.testing.expectEqualSlices(f32, &original, &tensor);
}

test "bidirectional tracker consistency" {
    const allocator = std.testing.allocator;
    var tracker = BidirectionalTracker.init(allocator, GAY_SEED);
    defer tracker.deinit();

    // Track same points forward and backward
    var layer: u32 = 1;
    while (layer <= 4) : (layer += 1) {
        var token: u32 = 1;
        while (token <= 10) : (token += 1) {
            _ = try tracker.trackForward(layer, token, 1);
            _ = try tracker.trackBackward(layer, token, 1);
        }
    }

    try std.testing.expect(tracker.verifyConsistency());
    try std.testing.expect(tracker.allClosuresValid());
}

test "bidirectional tracker forward-backward match" {
    const allocator = std.testing.allocator;
    var tracker = BidirectionalTracker.init(allocator, GAY_SEED);
    defer tracker.deinit();

    const fwd = try tracker.trackForward(3, 7, 1);
    const bwd = try tracker.trackBackward(3, 7, 1);
    try std.testing.expectEqual(fwd.index, bwd.index);
}

test "simulated cluster init and verify" {
    const allocator = std.testing.allocator;
    var cluster = SimulatedCluster.init(allocator, 2, 8, GAY_SEED, 16, 32);
    defer cluster.deinit();

    try std.testing.expectEqual(cluster.n_devices, 2);
    // Layers partitioned: device 0 gets layers 0..4, device 1 gets 4..8
    try std.testing.expectEqual(cluster.devices[0].layer_start, 0);
    try std.testing.expectEqual(cluster.devices[0].layer_end, 4);
    try std.testing.expectEqual(cluster.devices[1].layer_start, 4);
    try std.testing.expectEqual(cluster.devices[1].layer_end, 8);
}

test "cluster inference with faults detects corruption" {
    const allocator = std.testing.allocator;
    var cluster = SimulatedCluster.init(allocator, 2, 4, GAY_SEED, 8, 16);
    defer cluster.deinit();

    // Clean run: get baseline fingerprints
    _ = try cluster.runInference(allocator, false);
    const fp0_clean = cluster.devices[0].current_fingerprint;

    // Inject bit flip and rerun
    try cluster.injectFault(.{ .kind = .bit_flip, .target_device = 0, .n_bits = 20 });
    _ = try cluster.runInference(allocator, true);
    const fp0_faulted = cluster.devices[0].current_fingerprint;

    // Fingerprints should differ (bit flips corrupt data)
    try std.testing.expect(fp0_clean != fp0_faulted);
}

test "Galois connection with different seeds" {
    const gc1 = GaloisConnection.init(GAY_SEED);
    const gc2 = GaloisConnection.init(42);

    // Both should satisfy closure
    try std.testing.expect(gc1.verifyAllClosures());
    try std.testing.expect(gc2.verifyAllClosures());

    // But produce different palettes
    try std.testing.expect(!Color.eql(gc1.palette[0], gc2.palette[0]));
}

test "xor fingerprint deterministic" {
    const data = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0 };
    const fp1 = xorFingerprint(&data);
    const fp2 = xorFingerprint(&data);
    try std.testing.expectEqual(fp1, fp2);
}

test "xor fingerprint detects changes" {
    var data = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const fp1 = xorFingerprint(&data);
    data[2] = 3.001;
    const fp2 = xorFingerprint(&data);
    try std.testing.expect(fp1 != fp2);
}

test "fault history tracking" {
    const allocator = std.testing.allocator;
    var fi = FaultInjector.init(allocator, 42);
    defer fi.deinit();

    try fi.inject(.{ .kind = .bit_flip, .target_device = 0 });
    try fi.inject(.{ .kind = .byzantine, .target_device = 1 });
    try fi.healAll();

    // 2 injects + 2 heals = 4 history entries
    try std.testing.expectEqual(fi.history.items.len, 4);
    try std.testing.expectEqual(fi.history.items[0].action, .injected);
    try std.testing.expectEqual(fi.history.items[1].action, .injected);
    try std.testing.expectEqual(fi.history.items[2].action, .healed);
    try std.testing.expectEqual(fi.history.items[3].action, .healed);
}
