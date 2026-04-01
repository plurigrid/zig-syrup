// exo_mlx.zig: Zig translation of Gay.jl's exo_mlx.jl
// SPI-based verification for exo clusters running MLX models.
// Designed for heterogeneous Apple Silicon clusters with memory-weighted
// layer partitioning.
//
// ARCHITECTURE:
//   ┌──────────────────┐         ┌──────────────────┐
//   │  MacBook Pro     │ ──────► │  MacBook Air     │
//   │  18GB / Layers 1-22       │  8GB / Layers 23-32
//   │  MLX Backend     │         │  MLX Backend     │
//   │  fp_pro = 0x...  │         │  fp_air = 0x...  │
//   └──────────────────┘         └──────────────────┘
//              │                          │
//              └──────────┬───────────────┘
//                         ▼
//              fp_total = fp_pro ⊕ fp_air
//              assert fp_total == expected_fp

const std = @import("std");
const splitmix = @import("splitmix.zig");

const splitmix64 = splitmix.splitmix64;
const GAY_SEED = splitmix.GAY_SEED;
const Color = splitmix.Color;
const GayRng = splitmix.GayRng;

// ═══════════════════════════════════════════════════════════════════════════════
// Model Configurations
// ═══════════════════════════════════════════════════════════════════════════════

pub const ModelConfig = struct {
    name: []const u8,
    n_layers: u32,
    hidden_dim: u32,
    n_heads: u32,
    vocab_size: u32,
    max_seq_len: u32,
};

pub const olmo_7b = ModelConfig{ .name = "OLMo-3-7B", .n_layers = 32, .hidden_dim = 4096, .n_heads = 32, .vocab_size = 50280, .max_seq_len = 4096 };
pub const olmo_1b = ModelConfig{ .name = "OLMo-3-1B", .n_layers = 16, .hidden_dim = 2048, .n_heads = 16, .vocab_size = 50280, .max_seq_len = 4096 };
pub const llama_3b = ModelConfig{ .name = "Llama-3.2-3B", .n_layers = 28, .hidden_dim = 3072, .n_heads = 24, .vocab_size = 128256, .max_seq_len = 8192 };
pub const llama_1b = ModelConfig{ .name = "Llama-3.2-1B", .n_layers = 16, .hidden_dim = 2048, .n_heads = 32, .vocab_size = 128256, .max_seq_len = 8192 };

pub const ModelSize = enum { @"7B", @"13B", @"70B", @"1B", @"3B" };

pub fn modelConfig(name: []const u8) ?ModelConfig {
    if (std.mem.startsWith(u8, name, "olmo") or std.mem.startsWith(u8, name, "OLMo")) {
        if (std.mem.indexOf(u8, name, "7") != null) return olmo_7b;
        return olmo_1b;
    }
    if (std.mem.startsWith(u8, name, "llama") or std.mem.startsWith(u8, name, "Llama")) {
        if (std.mem.indexOf(u8, name, "3") != null) return llama_3b;
        return llama_1b;
    }
    return null;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Backend
// ═══════════════════════════════════════════════════════════════════════════════

pub const Backend = enum { mlx, tinygrad, cpu };

// ═══════════════════════════════════════════════════════════════════════════════
// ExoDevice
// ═══════════════════════════════════════════════════════════════════════════════

pub const ExoDevice = struct {
    device_id: u32,
    name: []const u8,
    ip: []const u8,
    port: u16,
    memory_gb: f64,
    compute_tflops: f64,
    backend: Backend,
    layer_start: u32,
    layer_end: u32, // exclusive
    color: Color,

    /// Weight of this device relative to total cluster memory
    pub fn memoryWeight(self: ExoDevice, total_memory: f64) f64 {
        return self.memory_gb / total_memory;
    }

    /// Number of layers assigned
    pub fn layerCount(self: ExoDevice) u32 {
        return self.layer_end - self.layer_start;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// ExoCluster
// ═══════════════════════════════════════════════════════════════════════════════

pub const MAX_DEVICES = 16;

pub const ExoCluster = struct {
    devices: [MAX_DEVICES]ExoDevice,
    n_devices: u32,
    model: ModelConfig,
    seed: u64,

    /// Total cluster memory in GB
    pub fn totalMemory(self: *const ExoCluster) f64 {
        var total: f64 = 0;
        for (0..self.n_devices) |i| {
            total += self.devices[i].memory_gb;
        }
        return total;
    }

    /// Get device by index
    pub fn device(self: *const ExoCluster, idx: u32) *const ExoDevice {
        return &self.devices[idx];
    }
};

/// Create an ExoCluster from device specs with memory-weighted layer partitioning.
/// specs: array of (name, memory_gb, ip) tuples
pub fn createCluster(
    names: []const []const u8,
    memory_gbs: []const f64,
    ips: []const []const u8,
    model: ModelConfig,
    seed: u64,
) ExoCluster {
    std.debug.assert(names.len == memory_gbs.len);
    std.debug.assert(names.len == ips.len);
    std.debug.assert(names.len <= MAX_DEVICES);

    const n: u32 = @intCast(names.len);

    // Total memory for weight calculation
    var total_mem: f64 = 0;
    for (memory_gbs) |m| total_mem += m;

    // Assign layers proportional to memory
    var cluster: ExoCluster = undefined;
    cluster.n_devices = n;
    cluster.model = model;
    cluster.seed = seed;

    var rng = GayRng.init(seed);
    var layer_cursor: u32 = 0;

    for (0..n) |i| {
        const weight = memory_gbs[i] / total_mem;
        const raw_layers = weight * @as(f64, @floatFromInt(model.n_layers));
        var n_layers: u32 = @intFromFloat(@round(raw_layers));

        // Last device gets remaining layers
        if (i == n - 1) {
            n_layers = model.n_layers - layer_cursor;
        }

        // Clamp
        if (layer_cursor + n_layers > model.n_layers) {
            n_layers = model.n_layers - layer_cursor;
        }

        cluster.devices[i] = ExoDevice{
            .device_id = @intCast(i),
            .name = names[i],
            .ip = ips[i],
            .port = 52415,
            .memory_gb = memory_gbs[i],
            .compute_tflops = 0, // unknown until discovery
            .backend = .mlx,
            .layer_start = layer_cursor,
            .layer_end = layer_cursor + n_layers,
            .color = rng.nextColor(),
        };

        layer_cursor += n_layers;
    }

    return cluster;
}

// ═══════════════════════════════════════════════════════════════════════════════
// SPI Color Injection
// ═══════════════════════════════════════════════════════════════════════════════

/// Hash-based color for a specific (seed, token, layer, dim) coordinate.
/// Returns the red channel as f32 perturbation.
pub fn spiColorAt(seed: u64, token: u32, layer: u32, dim: u32) f32 {
    var h: u64 = seed;
    h ^= @as(u64, token) *% 0x9e3779b97f4a7c15;
    h ^= @as(u64, layer) *% 0x517cc1b727220a95;
    h ^= @as(u64, dim) *% 0xc4ceb9fe1a85ec53;
    const mixed = splitmix64(h);
    // Extract [0,1] float from upper bits
    const raw: f64 = @as(f64, @floatFromInt(mixed >> 43)) / @as(f64, @floatFromInt(@as(u64, 1) << 21));
    return @floatCast(raw);
}

/// Inject SPI colors into a hidden state buffer (row-major: [n_tokens][hidden_dim]).
/// Adds tiny perturbation (1e-7 scale) that doesn't affect model output.
pub fn injectSpiColors(
    hidden_states: []f32,
    n_tokens: u32,
    hidden_dim: u32,
    layer: u32,
    seed: u64,
) void {
    for (0..n_tokens) |t| {
        for (0..hidden_dim) |d| {
            const idx = t * hidden_dim + d;
            if (idx < hidden_states.len) {
                const r = spiColorAt(seed, @intCast(t), layer, @intCast(d));
                hidden_states[idx] += r * 1e-7;
            }
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Fingerprint Extraction
// ═══════════════════════════════════════════════════════════════════════════════

/// Extract XOR fingerprint from hidden states (treated as raw u32 bits).
pub fn extractFingerprint(hidden_states: []const f32) u32 {
    var fp: u32 = 0;
    for (hidden_states) |v| {
        fp ^= @bitCast(v);
    }
    return fp;
}

/// Compute expected fingerprint for a layer range given seed, n_tokens, hidden_dim.
pub fn expectedFingerprint(seed: u64, n_tokens: u32, hidden_dim: u32, layer: u32) u32 {
    // Simulate the color injection and extract fingerprint
    var fp: u32 = 0;
    for (0..n_tokens) |t| {
        for (0..hidden_dim) |d| {
            const r = spiColorAt(seed, @intCast(t), layer, @intCast(d));
            const bits: u32 = @bitCast(r * @as(f32, 1e-7));
            fp ^= bits;
        }
    }
    return fp;
}

// ═══════════════════════════════════════════════════════════════════════════════
// ExoVerifier
// ═══════════════════════════════════════════════════════════════════════════════

pub const ExoVerifier = struct {
    cluster: *const ExoCluster,
    expected_fps: [MAX_DEVICES]u32,
    actual_fps: [MAX_DEVICES]u32,
    device_verified: [MAX_DEVICES]bool,
    n_tokens: u32,

    /// Create a verifier with pre-computed expected fingerprints.
    pub fn init(cluster: *const ExoCluster, n_tokens: u32) ExoVerifier {
        var v = ExoVerifier{
            .cluster = cluster,
            .expected_fps = [_]u32{0} ** MAX_DEVICES,
            .actual_fps = [_]u32{0} ** MAX_DEVICES,
            .device_verified = [_]bool{false} ** MAX_DEVICES,
            .n_tokens = n_tokens,
        };

        // Pre-compute expected fingerprints per device
        for (0..cluster.n_devices) |i| {
            const dev = &cluster.devices[i];
            var fp: u32 = 0;
            for (dev.layer_start..dev.layer_end) |layer| {
                fp ^= expectedFingerprint(cluster.seed, n_tokens, cluster.model.hidden_dim, @intCast(layer));
            }
            v.expected_fps[i] = fp;
        }

        return v;
    }

    /// Record actual fingerprint for a device. Returns true if it matches expected.
    pub fn verifyDevice(self: *ExoVerifier, device_id: u32, actual_fp: u32) bool {
        self.actual_fps[device_id] = actual_fp;
        self.device_verified[device_id] = true;
        return actual_fp == self.expected_fps[device_id];
    }

    /// Check if all devices have been verified and the combined fingerprint matches.
    pub fn verifyCluster(self: *const ExoVerifier) bool {
        var actual_total: u32 = 0;
        var expected_total: u32 = 0;

        for (0..self.cluster.n_devices) |i| {
            if (!self.device_verified[i]) return false;
            actual_total ^= self.actual_fps[i];
            expected_total ^= self.expected_fps[i];
        }

        return actual_total == expected_total;
    }

    /// Get combined expected fingerprint for the whole cluster.
    pub fn clusterExpectedFp(self: *const ExoVerifier) u32 {
        var fp: u32 = 0;
        for (0..self.cluster.n_devices) |i| {
            fp ^= self.expected_fps[i];
        }
        return fp;
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Quick Verify: Two-Mac Setup
// ═══════════════════════════════════════════════════════════════════════════════

/// Quick verification for a two-MacBook exo setup.
/// Returns the cluster and verifier for further use.
pub fn quickVerifyTwoMacs(
    model_name: []const u8,
    pro_gb: f64,
    air_gb: f64,
    n_tokens: u32,
) struct { cluster: ExoCluster, verifier: ExoVerifier } {
    const config = modelConfig(model_name) orelse olmo_7b;

    const names = [_][]const u8{ "MacBook Pro", "MacBook Air" };
    const mems = [_]f64{ pro_gb, air_gb };
    const ips = [_][]const u8{ "192.168.1.10", "192.168.1.11" };

    const cluster = createCluster(&names, &mems, &ips, config, GAY_SEED);
    const verifier = ExoVerifier.init(&cluster, n_tokens);

    return .{ .cluster = cluster, .verifier = verifier };
}

// ═══════════════════════════════════════════════════════════════════════════════
// Discover Exo Cluster (stub — real discovery needs network I/O)
// ═══════════════════════════════════════════════════════════════════════════════

/// Placeholder for network discovery. In production, this would scan UDP
/// broadcast on port 52415 and query exo's /v1/models endpoint.
/// Returns a single-device cluster representing localhost.
pub fn discoverExoCluster(model_name: []const u8, seed: u64) ExoCluster {
    const config = modelConfig(model_name) orelse olmo_7b;
    const names = [_][]const u8{"localhost"};
    const mems = [_]f64{8.0};
    const ips = [_][]const u8{"127.0.0.1"};
    return createCluster(&names, &mems, &ips, config, seed);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Verification Server Port
// ═══════════════════════════════════════════════════════════════════════════════

pub const VERIFICATION_PORT: u16 = 52416;

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

test "modelConfig lookup" {
    const olmo = modelConfig("olmo-7b").?;
    try std.testing.expectEqual(@as(u32, 32), olmo.n_layers);
    try std.testing.expectEqual(@as(u32, 4096), olmo.hidden_dim);

    const llama = modelConfig("Llama-3.2-3B").?;
    try std.testing.expectEqual(@as(u32, 28), llama.n_layers);

    try std.testing.expect(modelConfig("unknown") == null);
}

test "createCluster layer partitioning" {
    const names = [_][]const u8{ "Pro", "Air" };
    const mems = [_]f64{ 18.0, 8.0 };
    const ips = [_][]const u8{ "10.0.0.1", "10.0.0.2" };

    const cluster = createCluster(&names, &mems, &ips, olmo_7b, GAY_SEED);

    try std.testing.expectEqual(@as(u32, 2), cluster.n_devices);
    // Pro gets ~69% of 32 layers = ~22, Air gets ~10
    try std.testing.expectEqual(@as(u32, 0), cluster.devices[0].layer_start);
    // All layers accounted for
    try std.testing.expectEqual(olmo_7b.n_layers, cluster.devices[1].layer_end);
    // No overlap, no gap
    try std.testing.expectEqual(cluster.devices[0].layer_end, cluster.devices[1].layer_start);
}

test "createCluster total layers equals model layers" {
    const names = [_][]const u8{ "A", "B", "C" };
    const mems = [_]f64{ 16.0, 8.0, 4.0 };
    const ips = [_][]const u8{ "1", "2", "3" };

    const cluster = createCluster(&names, &mems, &ips, olmo_7b, GAY_SEED);

    var total: u32 = 0;
    for (0..cluster.n_devices) |i| {
        total += cluster.devices[i].layerCount();
    }
    try std.testing.expectEqual(olmo_7b.n_layers, total);
}

test "createCluster devices get distinct colors" {
    const names = [_][]const u8{ "A", "B" };
    const mems = [_]f64{ 8.0, 8.0 };
    const ips = [_][]const u8{ "1", "2" };

    const cluster = createCluster(&names, &mems, &ips, olmo_7b, GAY_SEED);
    try std.testing.expect(!Color.eql(cluster.devices[0].color, cluster.devices[1].color));
}

test "spiColorAt deterministic" {
    const a = spiColorAt(GAY_SEED, 0, 0, 0);
    const b = spiColorAt(GAY_SEED, 0, 0, 0);
    try std.testing.expectEqual(a, b);
}

test "spiColorAt varies with inputs" {
    const a = spiColorAt(GAY_SEED, 0, 0, 0);
    const b = spiColorAt(GAY_SEED, 1, 0, 0);
    const c = spiColorAt(GAY_SEED, 0, 1, 0);
    const d = spiColorAt(GAY_SEED, 0, 0, 1);
    try std.testing.expect(a != b);
    try std.testing.expect(a != c);
    try std.testing.expect(a != d);
}

test "spiColorAt range" {
    // Should be in [0, 1]
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        const v = spiColorAt(GAY_SEED, i, i % 32, i % 4096);
        try std.testing.expect(v >= 0.0 and v <= 1.0);
    }
}

test "injectSpiColors modifies buffer" {
    var buf = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
    injectSpiColors(&buf, 2, 2, 0, GAY_SEED);
    // At least one element should be non-zero after injection
    var any_nonzero = false;
    for (buf) |v| {
        if (v != 0.0) any_nonzero = true;
    }
    try std.testing.expect(any_nonzero);
}

test "extractFingerprint deterministic" {
    const buf = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const fp1 = extractFingerprint(&buf);
    const fp2 = extractFingerprint(&buf);
    try std.testing.expectEqual(fp1, fp2);
}

test "extractFingerprint differs for different data" {
    const a = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const b = [_]f32{ 1.0, 2.0, 3.0, 5.0 };
    try std.testing.expect(extractFingerprint(&a) != extractFingerprint(&b));
}

test "ExoVerifier init and self-verify" {
    const names = [_][]const u8{ "Pro", "Air" };
    const mems = [_]f64{ 18.0, 8.0 };
    const ips = [_][]const u8{ "10.0.0.1", "10.0.0.2" };

    const cluster = createCluster(&names, &mems, &ips, olmo_7b, GAY_SEED);
    var verifier = ExoVerifier.init(&cluster, 4); // small token count for test speed

    // Self-verification: feed expected as actual
    for (0..cluster.n_devices) |i| {
        const ok = verifier.verifyDevice(@intCast(i), verifier.expected_fps[i]);
        try std.testing.expect(ok);
    }
    try std.testing.expect(verifier.verifyCluster());
}

test "ExoVerifier rejects wrong fingerprint" {
    const names = [_][]const u8{"Solo"};
    const mems = [_]f64{16.0};
    const ips = [_][]const u8{"127.0.0.1"};

    const cluster = createCluster(&names, &mems, &ips, olmo_1b, GAY_SEED);
    var verifier = ExoVerifier.init(&cluster, 2);

    const bad_fp = verifier.expected_fps[0] ^ 0xDEADBEEF;
    const ok = verifier.verifyDevice(0, bad_fp);
    try std.testing.expect(!ok);
    try std.testing.expect(!verifier.verifyCluster());
}

test "ExoVerifier cluster XOR consistency" {
    // Two-device cluster: combined expected FP should equal XOR of per-device FPs
    const names = [_][]const u8{ "A", "B" };
    const mems = [_]f64{ 8.0, 8.0 };
    const ips = [_][]const u8{ "1", "2" };

    const cluster = createCluster(&names, &mems, &ips, olmo_1b, GAY_SEED);
    const verifier = ExoVerifier.init(&cluster, 2);

    const combined = verifier.clusterExpectedFp();
    try std.testing.expectEqual(combined, verifier.expected_fps[0] ^ verifier.expected_fps[1]);
}

test "quickVerifyTwoMacs creates valid setup" {
    const result = quickVerifyTwoMacs("olmo-7b", 18.0, 8.0, 4);
    try std.testing.expectEqual(@as(u32, 2), result.cluster.n_devices);
    try std.testing.expectEqual(olmo_7b.n_layers, result.cluster.devices[1].layer_end);
}

test "discoverExoCluster returns single device" {
    const cluster = discoverExoCluster("olmo-7b", GAY_SEED);
    try std.testing.expectEqual(@as(u32, 1), cluster.n_devices);
    try std.testing.expectEqual(@as(u32, 0), cluster.devices[0].layer_start);
    try std.testing.expectEqual(olmo_7b.n_layers, cluster.devices[0].layer_end);
}

test "totalMemory sums correctly" {
    const names = [_][]const u8{ "A", "B" };
    const mems = [_]f64{ 18.0, 8.0 };
    const ips = [_][]const u8{ "1", "2" };

    const cluster = createCluster(&names, &mems, &ips, olmo_7b, GAY_SEED);
    try std.testing.expectApproxEqAbs(@as(f64, 26.0), cluster.totalMemory(), 1e-10);
}
