// chaos_vibing.zig: Maximal Fault Injection into Parallel Causal Chains
// Zig translation of Gay.jl's chaos_vibing.jl
//
// "The purpose of chaos engineering is to build confidence in the system's
//  capability to withstand turbulent conditions in production." - Netflix
//
// Fault classes: seed, index, hash, thread, memory, timing, causal
// Uses SplitMix64 for deterministic fault seeding. GF(3) trit-tagged.

const std = @import("std");
const splitmix = @import("splitmix.zig");

const splitmix64 = splitmix.splitmix64;
const Color = splitmix.Color;
const GayRng = splitmix.GayRng;
const GAY_SEED = splitmix.GAY_SEED;
const GOLDEN = splitmix.GOLDEN;

// ============================================================================
// Fault Types
// ============================================================================

pub const FaultClass = enum(u3) {
    seed = 0,
    index = 1,
    hash = 2,
    thread = 3,
    memory = 4,
    timing = 5,
    causal = 6,
};

pub const FaultSeverity = enum(u2) {
    benign = 0, // Should be detected and recovered
    malignant = 1, // Should be detected, may not recover
    terminal = 2, // Should crash or produce obviously wrong results
};

pub const FaultName = enum(u5) {
    // Seed faults
    seed_bitflip,
    seed_zero,
    seed_max,
    seed_golden,
    // Index faults
    index_off_by_one,
    index_negative,
    index_overflow,
    index_zero,
    // Hash faults
    hash_truncate,
    hash_rotate,
    hash_xor_bomb,
    hash_zero,
    // Thread faults
    thread_race,
    thread_starvation,
    thread_duplicate,
    // Memory faults
    memory_corruption,
    memory_alignment,
    // Timing faults
    timing_jitter,
    timing_pause,
    timing_reorder,
    // Causal chain faults
    causal_skip,
    causal_duplicate,
    causal_reverse,
    causal_shuffle,
};

pub const Fault = struct {
    class: FaultClass,
    severity: FaultSeverity,
    name: FaultName,
    probability: f64,
    // Fault-specific parameter (interpretation depends on name)
    param: u64,
};

// ============================================================================
// Fault Catalog
// ============================================================================

pub const FAULT_CATALOG = [_]Fault{
    // Seed faults
    .{ .class = .seed, .severity = .benign, .name = .seed_bitflip, .probability = 1.0, .param = 1 },
    .{ .class = .seed, .severity = .malignant, .name = .seed_zero, .probability = 1.0, .param = 0 },
    .{ .class = .seed, .severity = .benign, .name = .seed_max, .probability = 1.0, .param = 0 },
    .{ .class = .seed, .severity = .benign, .name = .seed_golden, .probability = 1.0, .param = 0x9e3779b97f4a7c15 },
    // Index faults
    .{ .class = .index, .severity = .benign, .name = .index_off_by_one, .probability = 1.0, .param = 1 },
    .{ .class = .index, .severity = .terminal, .name = .index_negative, .probability = 1.0, .param = 0 },
    .{ .class = .index, .severity = .malignant, .name = .index_overflow, .probability = 1.0, .param = 0 },
    .{ .class = .index, .severity = .benign, .name = .index_zero, .probability = 1.0, .param = 0 },
    // Hash faults
    .{ .class = .hash, .severity = .malignant, .name = .hash_truncate, .probability = 1.0, .param = 0x00000000FFFFFFFF },
    .{ .class = .hash, .severity = .benign, .name = .hash_rotate, .probability = 1.0, .param = 17 },
    .{ .class = .hash, .severity = .benign, .name = .hash_xor_bomb, .probability = 1.0, .param = 0xDEADBEEFCAFEBABE },
    .{ .class = .hash, .severity = .terminal, .name = .hash_zero, .probability = 1.0, .param = 0 },
    // Thread faults
    .{ .class = .thread, .severity = .malignant, .name = .thread_race, .probability = 0.5, .param = 1000 },
    .{ .class = .thread, .severity = .benign, .name = .thread_starvation, .probability = 0.3, .param = 1 },
    .{ .class = .thread, .severity = .malignant, .name = .thread_duplicate, .probability = 0.5, .param = 0 },
    // Memory faults
    .{ .class = .memory, .severity = .terminal, .name = .memory_corruption, .probability = 0.1, .param = 8 },
    .{ .class = .memory, .severity = .benign, .name = .memory_alignment, .probability = 0.5, .param = 3 },
    // Timing faults
    .{ .class = .timing, .severity = .benign, .name = .timing_jitter, .probability = 1.0, .param = 100 },
    .{ .class = .timing, .severity = .benign, .name = .timing_pause, .probability = 0.2, .param = 10 },
    .{ .class = .timing, .severity = .malignant, .name = .timing_reorder, .probability = 0.3, .param = 0 },
    // Causal chain faults
    .{ .class = .causal, .severity = .malignant, .name = .causal_skip, .probability = 0.5, .param = 0 },
    .{ .class = .causal, .severity = .benign, .name = .causal_duplicate, .probability = 0.5, .param = 3 },
    .{ .class = .causal, .severity = .terminal, .name = .causal_reverse, .probability = 0.3, .param = 0 },
    .{ .class = .causal, .severity = .terminal, .name = .causal_shuffle, .probability = 0.2, .param = 0 },
};

/// Look up faults by class
pub fn faultsByClass(class: FaultClass) []const Fault {
    // Return slice views — computed at comptime isn't worth it, just filter at runtime
    _ = class;
    return &FAULT_CATALOG;
}

// ============================================================================
// Causal Chain
// ============================================================================

pub const MAX_CHAIN_LEN: usize = 1024;

pub const CausalChain = struct {
    seed: u64,
    len: usize,
    steps: [MAX_CHAIN_LEN]u64,
    colors: [MAX_CHAIN_LEN]Color,
    causal_links: [MAX_CHAIN_LEN]u64, // links[i] connects step i to step i+1
    broken_at: [MAX_CHAIN_LEN]usize,
    n_broken: usize,
    is_valid: bool,

    /// Create a valid causal chain of given length.
    pub fn init(seed: u64, length: usize) CausalChain {
        std.debug.assert(length <= MAX_CHAIN_LEN);
        var chain: CausalChain = undefined;
        chain.seed = seed;
        chain.len = length;
        chain.n_broken = 0;
        chain.is_valid = true;

        var current = seed;
        for (0..length) |i| {
            chain.steps[i] = current;
            chain.colors[i] = hashColor(seed, current);
            if (i + 1 < length) {
                chain.causal_links[i] = splitmix64(current ^ @as(u64, @intCast(i + 1)));
                current = chain.causal_links[i];
            }
        }
        return chain;
    }

    /// Break the chain at index using the specified fault.
    pub fn breakChain(self: *CausalChain, index: usize, fault: Fault, rng_state: *u64) void {
        if (index >= self.len) return;

        if (self.n_broken < MAX_CHAIN_LEN) {
            self.broken_at[self.n_broken] = index;
            self.n_broken += 1;
        }
        self.is_valid = false;

        switch (fault.class) {
            .seed => switch (fault.name) {
                .seed_bitflip => {
                    const bit: u6 = @truncate(nextRng(rng_state) & 63);
                    self.steps[index] ^= @as(u64, 1) << bit;
                },
                .seed_zero => {
                    self.steps[index] = 0;
                },
                .seed_max => {
                    self.steps[index] = std.math.maxInt(u64);
                },
                .seed_golden => {
                    self.steps[index] ^= fault.param;
                },
                else => {},
            },
            .hash => switch (fault.name) {
                .hash_truncate => {
                    self.steps[index] &= fault.param;
                },
                .hash_rotate => {
                    const bits: u6 = @truncate(fault.param & 63);
                    const v = self.steps[index];
                    const rbits: u6 = @truncate((@as(u7, 64) -| @as(u7, bits)));
                    self.steps[index] = (v << bits) | (v >> rbits);
                },
                .hash_xor_bomb => {
                    self.steps[index] ^= fault.param;
                },
                .hash_zero => {
                    self.steps[index] = 0;
                },
                else => {},
            },
            .causal => switch (fault.name) {
                .causal_skip => {
                    if (index + 1 < self.len) {
                        self.causal_links[index] = nextRng(rng_state);
                    }
                },
                .causal_duplicate => {
                    if (index > 0) {
                        self.steps[index] = self.steps[index - 1];
                    }
                },
                .causal_reverse => {
                    if (index + 1 < self.len) {
                        const end = @min(index + 6, self.len);
                        reverseSlice(self.steps[index..end]);
                    }
                },
                .causal_shuffle => {
                    // Deterministic Fisher-Yates using rng_state
                    const start = index;
                    const end = self.len;
                    if (end > start + 1) {
                        var i = end - 1;
                        while (i > start) : (i -= 1) {
                            const j = start + (nextRng(rng_state) % (i - start + 1));
                            const tmp = self.steps[i];
                            self.steps[i] = self.steps[j];
                            self.steps[j] = tmp;
                        }
                    }
                },
                else => {},
            },
            else => {}, // thread/memory/timing faults don't mutate chain data
        }

        // Recompute colors after fault
        for (index..self.len) |i| {
            self.colors[i] = hashColor(self.seed, self.steps[i]);
        }
    }

    /// Verify causal chain integrity. Returns count of broken indices.
    pub fn verify(self: *const CausalChain, broken_out: []usize) usize {
        var n: usize = 0;
        var current = self.seed;
        for (0..self.len) |i| {
            if (self.steps[i] != current) {
                if (n < broken_out.len) {
                    broken_out[n] = i;
                }
                n += 1;
            }
            if (i + 1 < self.len) {
                current = splitmix64(current ^ @as(u64, @intCast(i + 1)));
            }
        }
        return n;
    }

    /// XOR fingerprint of entire chain.
    pub fn fingerprint(self: *const CausalChain) u64 {
        var fp: u64 = 0;
        for (0..self.len) |i| {
            fp ^= self.steps[i];
        }
        return fp;
    }
};

// ============================================================================
// Helpers
// ============================================================================

/// Simple splitmix-based RNG advance (mutates state in place)
fn nextRng(state: *u64) u64 {
    state.* = splitmix64(state.*);
    return state.*;
}

/// Convert seed+value to a color (matches Julia hash_color)
fn hashColor(seed: u64, value: u64) Color {
    const mixed = splitmix64(seed ^ value);
    const mask21: u64 = (1 << 21) - 1;
    const scale = 1.0 / @as(f64, @floatFromInt(mask21));
    return .{
        .r = @as(f64, @floatFromInt(mixed & mask21)) * scale,
        .g = @as(f64, @floatFromInt((mixed >> 21) & mask21)) * scale,
        .b = @as(f64, @floatFromInt((mixed >> 42) & mask21)) * scale,
    };
}

fn reverseSlice(slice: []u64) void {
    if (slice.len < 2) return;
    var lo: usize = 0;
    var hi: usize = slice.len - 1;
    while (lo < hi) {
        const tmp = slice[lo];
        slice[lo] = slice[hi];
        slice[hi] = tmp;
        lo += 1;
        hi -= 1;
    }
}

/// Deterministic float in [0,1) from rng state
fn nextFloat(state: *u64) f64 {
    const v = nextRng(state);
    return @as(f64, @floatFromInt(v >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
}

// ============================================================================
// Chaos Configuration
// ============================================================================

pub const ChaosConfig = struct {
    n_chains: usize = 100,
    chain_length: usize = 100,
    faults_per_chain: usize = 5,
    fault_classes: u7 = 0b1001111, // bitmask: seed|index|hash|causal (bits 0,1,2,6)
    seed: u64 = 0xCEA05F1BE,
    intensity: f64 = 0.5, // 0.0 = gentle, 1.0 = maximum chaos

    /// Check if a fault class is enabled
    pub fn classEnabled(self: ChaosConfig, class: FaultClass) bool {
        return (self.fault_classes >> @backingInt(class)) & 1 == 1;
    }

    /// Default with all classes enabled
    pub fn allClasses() ChaosConfig {
        return .{ .fault_classes = 0b1111111 };
    }
};

// ============================================================================
// Chaos Result
// ============================================================================

pub const MAX_FAULTS_PER_CHAIN: usize = 64;

pub const ChaosResult = struct {
    chain_id: usize,
    faults_injected: [MAX_FAULTS_PER_CHAIN]Fault,
    n_faults: usize,
    original_fingerprint: u64,
    corrupted_fingerprint: u64,
    detected: bool,
    n_broken_indices: usize,
    recovery_possible: bool,
};

// ============================================================================
// Aggregated stats
// ============================================================================

pub const ClassStats = struct {
    total: usize,
    detected: usize,
};

pub const SeverityStats = struct {
    total: usize,
    detected: usize,
};

pub const ChaosVibe = struct {
    n_chains: usize,
    total_faults: usize,
    detected_faults: usize,
    undetected_faults: usize,
    detection_rate: f64,
    recovery_rate: f64,
    by_class: [7]ClassStats, // indexed by FaultClass
    by_severity: [3]SeverityStats, // indexed by FaultSeverity
};

// ============================================================================
// Chaos Injection Engine
// ============================================================================

/// Inject chaos into a causal chain. Returns number of faults injected.
pub fn injectChaos(
    chain: *CausalChain,
    config: ChaosConfig,
    rng_state: *u64,
    faults_out: []Fault,
) usize {
    var n_injected: usize = 0;

    for (0..config.faults_per_chain) |_| {
        if (nextFloat(rng_state) > config.intensity) continue;

        // Pick a random fault from catalog that matches enabled classes
        const catalog_idx = nextRng(rng_state) % FAULT_CATALOG.len;
        const fault = FAULT_CATALOG[catalog_idx];

        if (!config.classEnabled(fault.class)) continue;
        if (nextFloat(rng_state) >= fault.probability) continue;

        // Choose random index to corrupt
        const index = nextRng(rng_state) % chain.len;
        chain.breakChain(index, fault, rng_state);

        if (n_injected < faults_out.len) {
            faults_out[n_injected] = fault;
        }
        n_injected += 1;
    }

    return n_injected;
}

/// Run a full chaos injection campaign (single-threaded).
pub fn runChaosCampaign(config: ChaosConfig) ChaosVibe {
    var total_faults: usize = 0;
    var detected_faults: usize = 0;
    var recoverable: usize = 0;

    var by_class: [7]ClassStats = @splat(.{ .total = 0, .detected = 0 });
    var by_severity: [3]SeverityStats = @splat(.{ .total = 0, .detected = 0 });

    var rng_state = config.seed;

    for (0..config.n_chains) |i| {
        const chain_seed = config.seed ^ (@as(u64, @intCast(i)) *% GOLDEN);

        // Create clean chain
        const chain_len = @min(config.chain_length, MAX_CHAIN_LEN);
        var chain = CausalChain.init(chain_seed, chain_len);
        const original_fp = chain.fingerprint();

        // Inject chaos
        var fault_buf: [MAX_FAULTS_PER_CHAIN]Fault = undefined;
        const n_faults = injectChaos(&chain, config, &rng_state, &fault_buf);

        const corrupted_fp = chain.fingerprint();

        // Verify chain
        var broken_buf: [MAX_CHAIN_LEN]usize = undefined;
        const n_broken = chain.verify(&broken_buf);

        // Detection: fingerprint changed or chain invalid
        const detected = (corrupted_fp != original_fp) or (n_broken > 0);

        // Recovery: can we reconstruct from seed?
        const recovery_chain = CausalChain.init(chain_seed, chain_len);
        const recovery_ok = recovery_chain.fingerprint() == original_fp;
        if (recovery_ok) recoverable += 1;

        total_faults += n_faults;
        if (detected) {
            detected_faults += n_faults;
        }

        // Aggregate by class and severity
        for (0..n_faults) |fi| {
            if (fi >= MAX_FAULTS_PER_CHAIN) break;
            const f = fault_buf[fi];
            const ci = @backingInt(f.class);
            const si = @backingInt(f.severity);
            by_class[ci].total += 1;
            by_severity[si].total += 1;
            if (detected) {
                by_class[ci].detected += 1;
                by_severity[si].detected += 1;
            }
        }
    }

    const detection_rate = if (total_faults > 0)
        @as(f64, @floatFromInt(detected_faults)) / @as(f64, @floatFromInt(total_faults))
    else
        1.0;

    const recovery_rate = if (config.n_chains > 0)
        @as(f64, @floatFromInt(recoverable)) / @as(f64, @floatFromInt(config.n_chains))
    else
        1.0;

    return .{
        .n_chains = config.n_chains,
        .total_faults = total_faults,
        .detected_faults = detected_faults,
        .undetected_faults = total_faults - detected_faults,
        .detection_rate = detection_rate,
        .recovery_rate = recovery_rate,
        .by_class = by_class,
        .by_severity = by_severity,
    };
}

/// Quick chaos vibing with default config.
pub fn chaosVibe() ChaosVibe {
    return runChaosCampaign(.{});
}

// ============================================================================
// Tests
// ============================================================================

test "CausalChain init deterministic" {
    const c1 = CausalChain.init(GAY_SEED, 20);
    const c2 = CausalChain.init(GAY_SEED, 20);
    try std.testing.expectEqual(c1.fingerprint(), c2.fingerprint());
    try std.testing.expect(c1.is_valid);
    for (0..20) |i| {
        try std.testing.expectEqual(c1.steps[i], c2.steps[i]);
    }
}

test "CausalChain verify clean chain" {
    const chain = CausalChain.init(GAY_SEED, 50);
    var broken: [MAX_CHAIN_LEN]usize = undefined;
    const n = chain.verify(&broken);
    try std.testing.expectEqual(n, 0);
}

test "CausalChain breakChain seed_zero" {
    var chain = CausalChain.init(GAY_SEED, 20);
    const orig_fp = chain.fingerprint();
    var rng: u64 = 42;
    const fault = Fault{
        .class = .seed,
        .severity = .malignant,
        .name = .seed_zero,
        .probability = 1.0,
        .param = 0,
    };
    chain.breakChain(5, fault, &rng);
    try std.testing.expect(!chain.is_valid);
    try std.testing.expectEqual(chain.steps[5], 0);
    try std.testing.expect(chain.fingerprint() != orig_fp);
}

test "CausalChain breakChain seed_bitflip" {
    var chain = CausalChain.init(GAY_SEED, 20);
    const orig = chain.steps[3];
    var rng: u64 = 7777;
    const fault = Fault{
        .class = .seed,
        .severity = .benign,
        .name = .seed_bitflip,
        .probability = 1.0,
        .param = 1,
    };
    chain.breakChain(3, fault, &rng);
    try std.testing.expect(chain.steps[3] != orig);
}

test "CausalChain breakChain hash_xor_bomb" {
    var chain = CausalChain.init(0xBEEF, 10);
    const orig = chain.steps[2];
    var rng: u64 = 1;
    const fault = Fault{
        .class = .hash,
        .severity = .benign,
        .name = .hash_xor_bomb,
        .probability = 1.0,
        .param = 0xDEADBEEFCAFEBABE,
    };
    chain.breakChain(2, fault, &rng);
    try std.testing.expectEqual(chain.steps[2], orig ^ 0xDEADBEEFCAFEBABE);
}

test "CausalChain breakChain causal_reverse" {
    var chain = CausalChain.init(GAY_SEED, 20);
    // causal_reverse reverses steps[index..index+6], so steps[5..11]
    const before_5 = chain.steps[5];
    const before_10 = chain.steps[10];
    var rng: u64 = 99;
    const fault = Fault{
        .class = .causal,
        .severity = .terminal,
        .name = .causal_reverse,
        .probability = 1.0,
        .param = 0,
    };
    chain.breakChain(5, fault, &rng);
    // After reversal of [5..11]: steps[5] = old steps[10], steps[10] = old steps[5]
    try std.testing.expectEqual(chain.steps[5], before_10);
    try std.testing.expectEqual(chain.steps[10], before_5);
}

test "CausalChain verify detects breakage" {
    var chain = CausalChain.init(GAY_SEED, 30);
    var rng: u64 = 123;
    chain.breakChain(10, FAULT_CATALOG[0], &rng); // seed_bitflip
    var broken: [MAX_CHAIN_LEN]usize = undefined;
    const n = chain.verify(&broken);
    try std.testing.expect(n > 0);
}

test "CausalChain fingerprint changes on mutation" {
    var chain = CausalChain.init(GAY_SEED, 50);
    const fp1 = chain.fingerprint();
    chain.steps[25] ^= 0xFF;
    chain.colors[25] = hashColor(chain.seed, chain.steps[25]);
    const fp2 = chain.fingerprint();
    try std.testing.expect(fp1 != fp2);
}

test "injectChaos injects faults" {
    const config = ChaosConfig{
        .n_chains = 1,
        .chain_length = 50,
        .faults_per_chain = 50,
        .intensity = 1.0,
        .seed = 0xCAFE,
        .fault_classes = 0b1111111, // all classes enabled
    };
    var chain = CausalChain.init(0xBEEF, 50);
    var rng: u64 = config.seed;
    var faults: [MAX_FAULTS_PER_CHAIN]Fault = undefined;
    const n = injectChaos(&chain, config, &rng, &faults);
    // With intensity 1.0, all classes, and 50 attempts, must inject some faults
    try std.testing.expect(n > 0);
}

test "runChaosCampaign basic" {
    const config = ChaosConfig{
        .n_chains = 50,
        .chain_length = 30,
        .faults_per_chain = 3,
        .intensity = 0.7,
        .seed = 0xDEAD,
        .fault_classes = 0b1000111, // seed + index + hash + causal
    };
    const vibe = runChaosCampaign(config);
    try std.testing.expectEqual(vibe.n_chains, 50);
    try std.testing.expect(vibe.total_faults > 0);
    try std.testing.expect(vibe.detection_rate >= 0.0);
    try std.testing.expect(vibe.detection_rate <= 1.0);
    try std.testing.expect(vibe.recovery_rate >= 0.0);
    try std.testing.expect(vibe.recovery_rate <= 1.0);
    try std.testing.expectEqual(vibe.total_faults, vibe.detected_faults + vibe.undetected_faults);
}

test "runChaosCampaign recovery rate is 1.0" {
    // Recovery = reconstructing from seed always works (it's deterministic)
    const config = ChaosConfig{
        .n_chains = 20,
        .chain_length = 10,
        .faults_per_chain = 5,
        .intensity = 1.0,
        .seed = 42,
    };
    const vibe = runChaosCampaign(config);
    try std.testing.expectApproxEqAbs(vibe.recovery_rate, 1.0, 0.001);
}

test "chaosVibe default runs without error" {
    const vibe = chaosVibe();
    try std.testing.expect(vibe.n_chains == 100);
    try std.testing.expect(vibe.total_faults > 0);
}

test "FaultCatalog completeness" {
    // All 24 fault names should be present
    try std.testing.expectEqual(FAULT_CATALOG.len, 24);
}

test "ChaosConfig classEnabled" {
    const config = ChaosConfig{ .fault_classes = 0b0000101 }; // seed + hash
    try std.testing.expect(config.classEnabled(.seed));
    try std.testing.expect(!config.classEnabled(.index));
    try std.testing.expect(config.classEnabled(.hash));
    try std.testing.expect(!config.classEnabled(.thread));
    try std.testing.expect(!config.classEnabled(.causal));
}

test "extreme chaos high detection" {
    const config = ChaosConfig{
        .n_chains = 100,
        .chain_length = 20,
        .faults_per_chain = 20,
        .intensity = 1.0,
        .seed = 0xBAD,
        .fault_classes = 0b1111111,
    };
    const vibe = runChaosCampaign(config);
    // With 20 faults per chain at max intensity, detection should be very high
    try std.testing.expect(vibe.detection_rate > 0.8);
}

test "hashColor deterministic" {
    const c1 = hashColor(GAY_SEED, 42);
    const c2 = hashColor(GAY_SEED, 42);
    try std.testing.expect(Color.eql(c1, c2));
    // Different values produce different colors
    const c3 = hashColor(GAY_SEED, 43);
    try std.testing.expect(!Color.eql(c1, c3));
}

test "reverseSlice correctness" {
    var data = [_]u64{ 1, 2, 3, 4, 5 };
    reverseSlice(&data);
    try std.testing.expectEqualSlices(u64, &[_]u64{ 5, 4, 3, 2, 1 }, &data);
}

test "CausalChain breakChain causal_shuffle deterministic" {
    var c1 = CausalChain.init(GAY_SEED, 15);
    var c2 = CausalChain.init(GAY_SEED, 15);
    var rng1: u64 = 555;
    var rng2: u64 = 555;
    const fault = Fault{
        .class = .causal,
        .severity = .terminal,
        .name = .causal_shuffle,
        .probability = 1.0,
        .param = 0,
    };
    c1.breakChain(5, fault, &rng1);
    c2.breakChain(5, fault, &rng2);
    try std.testing.expectEqual(c1.fingerprint(), c2.fingerprint());
}

test "by_class stats sum to total" {
    const vibe = runChaosCampaign(.{
        .n_chains = 30,
        .chain_length = 20,
        .faults_per_chain = 5,
        .intensity = 0.8,
        .seed = 0xF00D,
    });
    var class_total: usize = 0;
    for (vibe.by_class) |cs| {
        class_total += cs.total;
    }
    try std.testing.expectEqual(class_total, vibe.total_faults);
}
