// tensor_parallel.zig: Tensor-Parallel Verification with SPI Colors
// Zig translation of Gay.jl's tensor_parallel.jl
//
// Verifies correctness of distributed tensor-parallel inference by:
// 1. Assigning deterministic colors to tensor elements based on global position
// 2. Computing XOR fingerprints that are invariant to partition/gather order
// 3. Detecting bit-flip corruptions, race conditions, and AllGather errors
//
// Architecture support:
// - Data parallelism (sequence sharding)
// - Tensor parallelism (vocabulary/hidden dim sharding)
// - Pipeline parallelism (layer sharding across devices)
// - Hybrid (exo-style: memory-weighted ring partitioning)
//
// METATHEORY:
//   The XOR fingerprint forms a commutative monoid:
//     - Identity: 0
//     - Associative: (a ^ b) ^ c = a ^ (b ^ c)
//     - Commutative: a ^ b = b ^ a
//
//   This means: fp(gather(shards)) = reduce(^, map(fp, shards))
//   So we can verify distributed computation WITHOUT gathering!

const std = @import("std");
const splitmix = @import("splitmix.zig");

const splitmix64 = splitmix.splitmix64;
const GAY_SEED = splitmix.GAY_SEED;

// ═══════════════════════════════════════════════════════════════════════════════
// Hash constants (matching Gay.jl)
// ═══════════════════════════════════════════════════════════════════════════════

const HASH_MUL_1: u64 = 0x9e3779b97f4a7c15;
const HASH_MUL_2: u64 = 0x517cc1b727220a95;
const HASH_MUL_3: u64 = 0xc4ceb9fe1a85ec53;
const HASH_MUL_STAGE: u64 = 0xdeadbeefcafebabe;

// ═══════════════════════════════════════════════════════════════════════════════
// hash_color / cartesian_color (inlined from Gay.jl core)
// ═══════════════════════════════════════════════════════════════════════════════

/// Hash a u64 into (r, g, b) floats in [0,1] via splitmix64.
/// Returns the r component's bit pattern as u32 for fingerprinting.
fn hashColor(h: u64, mix: u64) struct { r: f32, g: f32, b: f32 } {
    const val = splitmix64(h ^ mix);
    const mask21: u64 = (1 << 21) - 1;
    const scale: f32 = 1.0 / @as(f32, @floatFromInt(mask21));
    return .{
        .r = @as(f32, @floatFromInt(val & mask21)) * scale,
        .g = @as(f32, @floatFromInt((val >> 21) & mask21)) * scale,
        .b = @as(f32, @floatFromInt((val >> 42) & mask21)) * scale,
    };
}

/// Cartesian color from (seed, x, y) -- for logits coloring.
fn cartesianColor(seed: u64, x: u64, y: u64) struct { r: f32, g: f32, b: f32 } {
    const h = seed ^ (x *% HASH_MUL_1) ^ (y *% HASH_MUL_2);
    return hashColor(h, x);
}

// ═══════════════════════════════════════════════════════════════════════════════
// XOR Fingerprint
// ═══════════════════════════════════════════════════════════════════════════════

/// Compute XOR fingerprint of a slice of f32 values.
/// XOR of reinterpret(u32, each element).
pub fn xorFingerprint(data: []const f32) u32 {
    var fp: u32 = 0;
    for (data) |val| {
        fp ^= @bitCast(val);
    }
    return fp;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Partition Descriptors
// ═══════════════════════════════════════════════════════════════════════════════

/// Describes how a tensor is partitioned across ranks.
pub const TensorPartition = struct {
    dim: u32, // Which dimension is sharded (0=rows, 1=cols)
    n_shards: u32, // Total number of shards
    shard_id: u32, // This rank's shard (0-indexed)
    global_size: u32, // Full size along sharded dimension
    local_size: u32, // This shard's size
    offset: u32, // Starting index in global tensor

    pub fn init(dim: u32, n_shards: u32, shard_id: u32, global_size: u32) TensorPartition {
        const base_size = (global_size + n_shards - 1) / n_shards; // cld
        const off = shard_id * base_size;
        const local = if (shard_id == n_shards - 1)
            global_size - off
        else
            base_size;
        return .{
            .dim = dim,
            .n_shards = n_shards,
            .shard_id = shard_id,
            .global_size = global_size,
            .local_size = local,
            .offset = off,
        };
    }
};

/// A tensor shard with partition metadata and fingerprint.
pub const ShardedTensor = struct {
    /// Row-major f32 data, shape = (n_tokens, hidden_dim) flattened.
    data: []f32,
    rows: u32,
    cols: u32,
    partition: TensorPartition,
    seed: u64,
    fingerprint: u32,
    colored: bool,

    pub fn init(data: []f32, rows: u32, cols: u32, partition: TensorPartition) ShardedTensor {
        return .{
            .data = data,
            .rows = rows,
            .cols = cols,
            .partition = partition,
            .seed = GAY_SEED,
            .fingerprint = 0,
            .colored = false,
        };
    }

    pub fn computeFingerprint(self: *ShardedTensor) u32 {
        self.fingerprint = xorFingerprint(self.data);
        return self.fingerprint;
    }
};

/// Context for distributed computation across multiple ranks.
pub const DistributedContext = struct {
    rank: u32,
    world_size: u32,
    seed: u64,
    layer_start: u32, // inclusive
    layer_end: u32, // inclusive

    pub fn init(rank: u32, world_size: u32, n_layers: u32) DistributedContext {
        const layers_per_rank = (n_layers + world_size - 1) / world_size;
        const start = rank * layers_per_rank;
        const end = @min((rank + 1) * layers_per_rank, n_layers);
        return .{
            .rank = rank,
            .world_size = world_size,
            .seed = GAY_SEED,
            .layer_start = start,
            .layer_end = if (end > 0) end - 1 else 0,
        };
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
// Coloring Functions
// ═══════════════════════════════════════════════════════════════════════════════

/// Color embedding lookups. Each (token_id, dim) pair gets deterministic color.
/// data is row-major (n_tokens x hidden_dim).
pub fn colorEmbeddings(data: []f32, n_tokens: u32, hidden_dim: u32, token_ids: []const u32, seed: u64) void {
    for (0..n_tokens) |t| {
        const tok = token_ids[t];
        for (0..hidden_dim) |d| {
            const h = seed ^ (@as(u64, tok) *% HASH_MUL_1) ^ (@as(u64, @intCast(d)) *% HASH_MUL_2);
            const c = hashColor(h, @as(u64, @intCast(d)));
            data[t * hidden_dim + d] += c.r * 1e-6;
        }
    }
}

/// Color hidden states after a transformer layer.
/// Position-based: (global_token_idx, layer, hidden_dim).
pub fn colorHiddenStates(data: []f32, n_tokens: u32, hidden_dim: u32, layer: u32, partition: TensorPartition, seed: u64) void {
    for (0..n_tokens) |t| {
        const global_t: u64 = @as(u64, partition.offset) + @as(u64, @intCast(t)) + 1; // 1-indexed
        for (0..hidden_dim) |d| {
            const h = seed ^ (global_t *% HASH_MUL_1) ^
                (@as(u64, layer) *% HASH_MUL_2) ^
                (@as(u64, @intCast(d + 1)) *% HASH_MUL_3);
            const c = hashColor(h, global_t);
            data[t * hidden_dim + d] += c.r * 1e-7;
        }
    }
}

/// Color LM head logits for tensor-parallel vocab sharding.
/// Position-based: (token_idx, global_vocab_idx).
pub fn colorLogits(data: []f32, n_tokens: u32, vocab_shard: u32, partition: TensorPartition, seed: u64) void {
    for (0..n_tokens) |t| {
        for (0..vocab_shard) |v| {
            const global_v: u64 = @as(u64, partition.offset) + @as(u64, @intCast(v)) + 1;
            const c = cartesianColor(seed, @as(u64, @intCast(t + 1)), global_v);
            data[t * vocab_shard + v] += c.r * 1e-7;
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Expected Fingerprint (computed ahead of time)
// ═══════════════════════════════════════════════════════════════════════════════

/// Compute expected fingerprint for hidden states colored from zero.
/// Matches colorHiddenStates: each element = 0.0 + c.r * 1e-7.
pub fn expectedFingerprint(seed: u64, n_tokens: u32, hidden_dim: u32, layer: u32) u32 {
    var fp: u32 = 0;
    for (0..n_tokens) |t| {
        const global_t: u64 = @as(u64, @intCast(t)) + 1;
        for (0..hidden_dim) |d| {
            const h = seed ^ (global_t *% HASH_MUL_1) ^
                (@as(u64, layer) *% HASH_MUL_2) ^
                (@as(u64, @intCast(d + 1)) *% HASH_MUL_3);
            const c = hashColor(h, global_t);
            const val: f32 = c.r * 1e-7;
            fp ^= @as(u32, @bitCast(val));
        }
    }
    return fp;
}

/// Combine fingerprints from multiple shards via XOR.
pub fn combinedFingerprint(fingerprints: []const u32) u32 {
    var fp: u32 = 0;
    for (fingerprints) |f| {
        fp ^= f;
    }
    return fp;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Verification Functions
// ═══════════════════════════════════════════════════════════════════════════════

/// Verify AllGather produced correct result.
pub fn verifyAllgather(gathered: []const f32, n_tokens: u32, hidden_dim: u32, seed: u64, layer: u32) bool {
    const actual_fp = xorFingerprint(gathered);
    const expected_fp = expectedFingerprint(seed, n_tokens, hidden_dim, layer);
    return actual_fp == expected_fp;
}

/// Verify AllReduce (sum) via statistical check.
/// For tensor-parallel matrix multiplies where results are summed.
pub fn verifyAllreduce(reduced: []const f32, n_ranks: u32) bool {
    if (reduced.len == 0) return true;
    var sum: f64 = 0;
    for (reduced) |val| {
        sum += @as(f64, val);
    }
    const mean = sum / @as(f64, @floatFromInt(reduced.len));
    const expected_mean = 0.5 * @as(f64, @floatFromInt(n_ranks));
    const tolerance = 0.1 * @as(f64, @floatFromInt(n_ranks));
    return @abs(mean - expected_mean) <= tolerance;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Pipeline Parallelism
// ═══════════════════════════════════════════════════════════════════════════════

/// Pipeline stage handoff color for verifying inter-stage activation transfer.
pub const StageColor = struct { r: f32, g: f32, b: f32 };

pub fn pipelineStageColor(seed: u64, layer: u32, stage: u32) StageColor {
    const h = seed ^ (@as(u64, layer) *% HASH_MUL_1) ^ (@as(u64, stage) *% HASH_MUL_STAGE);
    const c = hashColor(h, @as(u64, layer));
    return .{ .r = c.r, .g = c.g, .b = c.b };
}

/// Verify activations passed between pipeline stages are uncorrupted.
pub fn verifyPipelineHandoff(activations: []const f32, n_tokens: u32, hidden_dim: u32, layer: u32, seed: u64) bool {
    const actual_fp = xorFingerprint(activations);
    const expected_fp = expectedFingerprint(seed, n_tokens, hidden_dim, layer);
    return actual_fp == expected_fp;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Exo-Style Ring Partitioning
// ═══════════════════════════════════════════════════════════════════════════════

/// Memory-weighted ring partition for heterogeneous devices (like Exo).
pub const ExoPartition = struct {
    device_id: u32,
    memory_gb: f64,
    layer_start: u32, // inclusive
    layer_end: u32, // inclusive
    weight: f64, // fraction of total memory
};

/// Create exo-style partitions based on device memory.
/// Returns number of partitions written.
pub fn createExoPartitions(
    memories: []const f64,
    n_layers: u32,
    out: []ExoPartition,
) u32 {
    const n_devices: u32 = @intCast(memories.len);
    if (n_devices == 0) return 0;

    var total_memory: f64 = 0;
    for (memories) |m| total_memory += m;

    var current_layer: u32 = 0;
    for (0..n_devices) |i| {
        const weight = memories[i] / total_memory;
        var n_device_layers: u32 = @intFromFloat(@round(weight * @as(f64, @floatFromInt(n_layers))));

        // Last device gets remaining layers
        if (i == n_devices - 1) {
            n_device_layers = n_layers - current_layer;
        }

        out[i] = .{
            .device_id = @intCast(i),
            .memory_gb = memories[i],
            .layer_start = current_layer,
            .layer_end = current_layer + n_device_layers -| 1,
            .weight = weight,
        };
        current_layer += n_device_layers;
    }
    return n_devices;
}

/// Verify activations in exo ring topology for a given device.
pub fn verifyExoRing(
    activations: []const f32,
    n_tokens: u32,
    hidden_dim: u32,
    partition: ExoPartition,
    seed: u64,
) bool {
    var expected_fp: u32 = 0;
    var layer = partition.layer_start;
    while (layer <= partition.layer_end) : (layer += 1) {
        expected_fp ^= expectedFingerprint(seed, n_tokens, hidden_dim, layer + 1); // 1-indexed layers
    }
    const actual_fp = xorFingerprint(activations);
    return actual_fp == expected_fp;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

test "TensorPartition creation" {
    const p = TensorPartition.init(0, 4, 0, 100);
    try std.testing.expectEqual(p.local_size, 25);
    try std.testing.expectEqual(p.offset, 0);

    const p1 = TensorPartition.init(0, 4, 1, 100);
    try std.testing.expectEqual(p1.offset, 25);
    try std.testing.expectEqual(p1.local_size, 25);

    // Last shard with non-even division
    const p_last = TensorPartition.init(0, 3, 2, 100);
    try std.testing.expectEqual(p_last.offset, 68); // 34*2
    try std.testing.expectEqual(p_last.local_size, 32); // 100 - 68
}

test "TensorPartition covers full range" {
    const n_shards: u32 = 4;
    const global: u32 = 100;
    var total: u32 = 0;
    for (0..n_shards) |i| {
        const p = TensorPartition.init(0, n_shards, @intCast(i), global);
        total += p.local_size;
    }
    try std.testing.expectEqual(total, global);
}

test "XOR fingerprint identity" {
    const data = [_]f32{ 0.0, 0.0, 0.0 };
    try std.testing.expectEqual(xorFingerprint(&data), 0);
}

test "XOR fingerprint commutativity" {
    // fp(A ++ B) = fp(A) ^ fp(B)
    const a = [_]f32{ 1.0, 2.0, 3.0 };
    const b = [_]f32{ 4.0, 5.0, 6.0 };
    var ab: [6]f32 = undefined;
    @memcpy(ab[0..3], &a);
    @memcpy(ab[3..6], &b);

    const fp_ab = xorFingerprint(&ab);
    const fp_a = xorFingerprint(&a);
    const fp_b = xorFingerprint(&b);
    try std.testing.expectEqual(fp_ab, fp_a ^ fp_b);
}

test "XOR fingerprint associativity" {
    const a = [_]f32{ 1.0, 2.0 };
    const b = [_]f32{ 3.0, 4.0 };
    const c = [_]f32{ 5.0, 6.0 };
    const fp_a = xorFingerprint(&a);
    const fp_b = xorFingerprint(&b);
    const fp_c = xorFingerprint(&c);
    try std.testing.expectEqual((fp_a ^ fp_b) ^ fp_c, fp_a ^ (fp_b ^ fp_c));
}

test "combinedFingerprint matches direct XOR" {
    const fps = [_]u32{ 0xDEAD, 0xBEEF, 0xCAFE };
    try std.testing.expectEqual(combinedFingerprint(&fps), 0xDEAD ^ 0xBEEF ^ 0xCAFE);
}

test "allgather verification roundtrip" {
    // Create a small tensor, color it, then verify fingerprint matches expected
    const n_tokens: u32 = 4;
    const hidden_dim: u32 = 8;
    var data: [32]f32 = @splat(0.0);
    const partition = TensorPartition.init(0, 1, 0, n_tokens);
    colorHiddenStates(&data, n_tokens, hidden_dim, 1, partition, GAY_SEED);

    const verified = verifyAllgather(&data, n_tokens, hidden_dim, GAY_SEED, 1);
    try std.testing.expect(verified);
}

test "allgather verification detects corruption" {
    const n_tokens: u32 = 4;
    const hidden_dim: u32 = 8;
    var data: [32]f32 = @splat(0.0);
    const partition = TensorPartition.init(0, 1, 0, n_tokens);
    colorHiddenStates(&data, n_tokens, hidden_dim, 1, partition, GAY_SEED);

    // Corrupt one element
    data[7] = 999.0;
    const verified = verifyAllgather(&data, n_tokens, hidden_dim, GAY_SEED, 1);
    try std.testing.expect(!verified);
}

test "pipeline handoff verification" {
    const n_tokens: u32 = 4;
    const hidden_dim: u32 = 8;
    var data: [32]f32 = @splat(0.0);
    const partition = TensorPartition.init(0, 1, 0, n_tokens);

    // Color for layer 3
    colorHiddenStates(&data, n_tokens, hidden_dim, 3, partition, GAY_SEED);

    // Verify with correct layer
    try std.testing.expect(verifyPipelineHandoff(&data, n_tokens, hidden_dim, 3, GAY_SEED));

    // Verify with wrong layer should fail
    try std.testing.expect(!verifyPipelineHandoff(&data, n_tokens, hidden_dim, 4, GAY_SEED));
}

test "pipeline stage color determinism" {
    const c1 = pipelineStageColor(GAY_SEED, 5, 0);
    const c2 = pipelineStageColor(GAY_SEED, 5, 0);
    try std.testing.expectEqual(c1.r, c2.r);
    try std.testing.expectEqual(c1.g, c2.g);
    try std.testing.expectEqual(c1.b, c2.b);

    // Different stage -> different color
    const c3 = pipelineStageColor(GAY_SEED, 5, 1);
    try std.testing.expect(c1.r != c3.r or c1.g != c3.g or c1.b != c3.b);
}

test "ExoPartition memory-weighted" {
    const memories = [_]f64{ 18.0, 8.0 };
    var parts: [2]ExoPartition = undefined;
    const n = createExoPartitions(&memories, 32, &parts);
    try std.testing.expectEqual(n, 2);

    // First device (18GB/26GB ~ 69%) should get more layers
    try std.testing.expect(parts[0].layer_end > parts[1].layer_end - parts[1].layer_start);

    // All layers covered
    try std.testing.expectEqual(parts[0].layer_start, 0);
    try std.testing.expectEqual(parts[1].layer_end, 31);
}

test "ExoPartition weights sum to 1" {
    const memories = [_]f64{ 18.0, 8.0, 4.0 };
    var parts: [3]ExoPartition = undefined;
    const n = createExoPartitions(&memories, 32, &parts);
    var total_weight: f64 = 0;
    for (0..n) |i| total_weight += parts[i].weight;
    try std.testing.expectApproxEqAbs(total_weight, 1.0, 1e-10);
}

test "DistributedContext layer assignment" {
    const ctx = DistributedContext.init(0, 4, 32);
    try std.testing.expectEqual(ctx.layer_start, 0);
    try std.testing.expectEqual(ctx.layer_end, 7);

    const ctx3 = DistributedContext.init(3, 4, 32);
    try std.testing.expectEqual(ctx3.layer_start, 24);
    try std.testing.expectEqual(ctx3.layer_end, 31);
}

test "ShardedTensor fingerprint" {
    var data = [_]f32{ 1.0, 2.0, 3.0, 4.0 };
    const partition = TensorPartition.init(0, 1, 0, 2);
    var st = ShardedTensor.init(&data, 2, 2, partition);
    const fp = st.computeFingerprint();
    try std.testing.expect(fp != 0);
    try std.testing.expectEqual(st.fingerprint, fp);
}

test "multi-shard fingerprint equals whole" {
    // Verify: fp(shard0 ++ shard1) = fp(shard0) ^ fp(shard1)
    var all_data = [_]f32{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0 };
    const fp_all = xorFingerprint(&all_data);

    const fp_0 = xorFingerprint(all_data[0..4]);
    const fp_1 = xorFingerprint(all_data[4..8]);
    try std.testing.expectEqual(fp_all, fp_0 ^ fp_1);
}
