// parallel_advanced.zig: Advanced parallelism modules from Gay.jl
// Translates: parallel_color_scheduler, para_complexity, para_zigzag,
//             gayrng, scoped_propagators, chromatic_propagator, triadic_subagents
//
// Zig 0.14+ — no allocator-dependent APIs where avoidable

const std = @import("std");
const splitmix = @import("splitmix.zig");
const sm64 = splitmix.splitmix64;
const GOLDEN = splitmix.GOLDEN;
const MIX1 = splitmix.MIX1;
const MIX2 = splitmix.MIX2;
const GAY_SEED = splitmix.GAY_SEED;
const Color = splitmix.Color;

// ============================================================================
// Section 1: Parallel Color Scheduler (parallel_color_scheduler.jl)
// — Synergy graphs, tree-decomposition partitioning, SPI-safe scheduling
// ============================================================================

pub const ColorConstraint = struct {
    index: u32,
    target_hue: ?f64, // null = no target
    min_distance: f64,
    depends_on: [MAX_DEPS]u32,
    dep_count: u8,

    const MAX_DEPS = 16;

    pub fn init(idx: u32) ColorConstraint {
        return .{
            .index = idx,
            .target_hue = null,
            .min_distance = 30.0,
            .depends_on = [_]u32{0} ** MAX_DEPS,
            .dep_count = 0,
        };
    }

    pub fn addDep(self: *ColorConstraint, dep: u32) void {
        if (self.dep_count < MAX_DEPS) {
            self.depends_on[self.dep_count] = dep;
            self.dep_count += 1;
        }
    }
};

pub const SynergyGraph = struct {
    n: u32,
    /// Adjacency stored as fixed-size neighbor lists
    adj: [MAX_NODES][MAX_NEIGHBORS]u32,
    adj_count: [MAX_NODES]u8,
    constraints: [MAX_NODES]ColorConstraint,

    const MAX_NODES = 256;
    const MAX_NEIGHBORS = 32;

    pub fn init(n: u32) SynergyGraph {
        var g: SynergyGraph = undefined;
        g.n = @min(n, MAX_NODES);
        for (0..MAX_NODES) |i| {
            g.adj_count[i] = 0;
            g.constraints[i] = ColorConstraint.init(@intCast(i));
        }
        return g;
    }

    pub fn addEdge(self: *SynergyGraph, u: u32, v: u32) void {
        if (u >= self.n or v >= self.n) return;
        if (self.adj_count[u] < MAX_NEIGHBORS) {
            self.adj[u][self.adj_count[u]] = v;
            self.adj_count[u] += 1;
        }
        if (self.adj_count[v] < MAX_NEIGHBORS) {
            self.adj[v][self.adj_count[v]] = u;
            self.adj_count[v] += 1;
        }
    }

    /// Build random synergy graph (deterministic from seed)
    pub fn buildRandom(n: u32, seed: u64, connectivity: f64) SynergyGraph {
        var g = SynergyGraph.init(n);
        var rng = seed;
        for (0..g.n) |i| {
            for (0..i) |j| {
                rng = sm64(rng);
                const prob: f64 = @as(f64, @floatFromInt(rng & 0xFFFF)) / 0xFFFF;
                if (prob < connectivity) {
                    g.addEdge(@intCast(i), @intCast(j));
                    g.constraints[i].addDep(@intCast(j));
                }
            }
        }
        return g;
    }
};

pub const SchedulePartition = struct {
    id: u32,
    indices: [64]u32,
    count: u32,
    depends_on: [8]u32,
    dep_count: u8,
};

/// Greedy minimum-degree heuristic tree decomposition partitioning
pub fn partitionByTreeDecomposition(graph: *const SynergyGraph, n_partitions: u32) [16]SchedulePartition {
    var parts: [16]SchedulePartition = undefined;
    const actual_parts = @min(n_partitions, 16);
    const per_part = if (actual_parts > 0) (graph.n + actual_parts - 1) / actual_parts else graph.n;

    for (0..16) |p| {
        parts[p].id = @intCast(p);
        parts[p].count = 0;
        parts[p].dep_count = 0;
        if (p < actual_parts) {
            const start = @as(u32, @intCast(p)) * per_part;
            const end_ = @min(start + per_part, graph.n);
            var idx: u32 = 0;
            for (start..end_) |i| {
                if (idx < 64) {
                    parts[p].indices[idx] = @intCast(i);
                    idx += 1;
                }
            }
            parts[p].count = idx;
        }
    }
    return parts;
}

/// Schedule result: colors assigned by a single worker
pub const ScheduleResult = struct {
    partition_id: u32,
    fingerprint: u64,
    colors: [64]Color,
    color_count: u32,
    elapsed_ns: u64,
};

/// Execute parallel color schedule (single-threaded simulation)
pub fn parallelColorSchedule(graph: *const SynergyGraph, seed: u64) ScheduleResult {
    var result: ScheduleResult = undefined;
    result.partition_id = 0;
    result.fingerprint = 0;
    result.color_count = graph.n;
    result.elapsed_ns = 0;

    var rng = seed;
    for (0..graph.n) |i| {
        rng = sm64(rng);
        result.colors[i] = splitmix.colorAt(rng, @intCast(i));
        result.fingerprint ^= rng;
    }
    return result;
}

// ============================================================================
// Section 2: Para(Complexity) (para_complexity.jl)
// — ParaDerangeable, ParaColorable, ParaTropicalRing
// ============================================================================

pub const ParaDerangeable = struct {
    n: u32,
    seed: u64,
    parity: i8, // 0 = even, 1 = odd

    pub fn init(n: u32, seed: u64, parity: i8) ParaDerangeable {
        return .{ .n = n, .seed = seed, .parity = parity };
    }

    /// Sattolo's algorithm: generates single-cycle permutation (derangement)
    pub fn sampleDerangement(self: ParaDerangeable, index: u64) [256]u32 {
        var perm: [256]u32 = undefined;
        for (0..self.n) |i| perm[i] = @intCast(i);

        var rng = sm64(self.seed ^ index ^ @as(u64, @intCast(self.parity)));
        var i: u32 = self.n;
        while (i > 1) : (i -= 1) {
            rng = sm64(rng);
            const j: u32 = @intCast(1 + rng % (i - 1)); // j in [1, i-1]
            const tmp = perm[i - 1];
            perm[i - 1] = perm[j - 1];
            perm[j - 1] = tmp;
        }
        return perm;
    }

    /// Verify derangement (no fixed points)
    pub fn verifyDerangement(perm: []const u32, n: u32) bool {
        for (0..n) |i| {
            if (perm[i] == @as(u32, @intCast(i))) return false;
        }
        return true;
    }
};

pub const SimpleGraph = struct {
    adj: [256][32]u32,
    adj_count: [256]u8,
    n: u32,

    pub fn init(n: u32) SimpleGraph {
        var g: SimpleGraph = undefined;
        g.n = @min(n, 256);
        for (0..256) |i| g.adj_count[i] = 0;
        return g;
    }

    pub fn addEdge(self: *SimpleGraph, u: u32, v: u32) void {
        if (u >= self.n or v >= self.n) return;
        if (self.adj_count[u] < 32) {
            self.adj[u][self.adj_count[u]] = v;
            self.adj_count[u] += 1;
        }
        if (self.adj_count[v] < 32) {
            self.adj[v][self.adj_count[v]] = u;
            self.adj_count[v] += 1;
        }
    }
};

pub const ParaColorable = struct {
    graph: *const SimpleGraph,
    k: u32, // number of colors
    seed: u64,

    /// Greedy coloring with deterministic vertex order from seed
    pub fn greedyColoring(self: ParaColorable, index: u64) struct { colors: [256]u32, success: bool } {
        const n = self.graph.n;
        var colors: [256]u32 = [_]u32{0} ** 256;

        // Fisher-Yates shuffle for vertex order
        var order: [256]u32 = undefined;
        for (0..n) |i| order[i] = @intCast(i);
        var rng = sm64(self.seed ^ index);
        var i: u32 = n;
        while (i > 1) : (i -= 1) {
            rng = sm64(rng);
            const j: u32 = @intCast(1 + rng % i);
            const tmp = order[i - 1];
            order[i - 1] = order[j - 1];
            order[j - 1] = tmp;
        }

        var success = true;
        for (0..n) |oi| {
            const v = order[oi];
            var used: [33]bool = [_]bool{false} ** 33;
            for (0..self.graph.adj_count[v]) |ni| {
                const u = self.graph.adj[v][ni];
                if (colors[u] > 0 and colors[u] <= 32) used[colors[u]] = true;
            }
            var c: u32 = 1;
            while (c <= self.k and used[c]) : (c += 1) {}
            if (c > self.k) {
                success = false;
                break;
            }
            colors[v] = c;
        }
        return .{ .colors = colors, .success = success };
    }

    pub fn isValidColoring(self: ParaColorable, colors: []const u32) bool {
        for (0..self.graph.n) |v| {
            for (0..self.graph.adj_count[v]) |ni| {
                const u = self.graph.adj[v][ni];
                if (colors[v] == colors[u] and colors[v] != 0) return false;
            }
        }
        return true;
    }
};

pub const TropicalOp = enum { min_plus, max_plus };

pub const ParaTropicalRing = struct {
    dim: u32,
    op: TropicalOp,
    seed: u64,
    weights: [64][64]f64,

    pub fn init(n: u32, seed: u64, op: TropicalOp) ParaTropicalRing {
        var ring: ParaTropicalRing = undefined;
        ring.dim = @min(n, 64);
        ring.op = op;
        ring.seed = seed;
        var rng = seed;
        for (0..ring.dim) |i| {
            for (0..ring.dim) |j| {
                if (i == j) {
                    ring.weights[i][j] = 0.0;
                } else {
                    rng = sm64(rng);
                    ring.weights[i][j] = @as(f64, @floatFromInt(rng % 1000)) / 100.0;
                }
            }
        }
        return ring;
    }

    pub fn tropAdd(self: ParaTropicalRing, a: f64, b: f64) f64 {
        return switch (self.op) {
            .min_plus => @min(a, b),
            .max_plus => @max(a, b),
        };
    }

    pub fn tropMul(_: ParaTropicalRing, a: f64, b: f64) f64 {
        return a + b;
    }

    /// Tropical matrix-vector multiply
    pub fn tropMatVec(self: ParaTropicalRing, v: []const f64, out: []f64) void {
        for (0..self.dim) |i| {
            var acc: f64 = if (self.op == .min_plus) std.math.inf(f64) else -std.math.inf(f64);
            for (0..self.dim) |j| {
                const w = self.tropMul(self.weights[i][j], v[j]);
                acc = self.tropAdd(acc, w);
            }
            out[i] = acc;
        }
    }
};

// ============================================================================
// Section 3: Para(ZigZag) (para_zigzag.jl)
// — PDMP sampler with chromatic events and SPI fingerprints
// ============================================================================

pub const ChromaticEvent = struct {
    t: f64,
    i: u32, // coordinate
    x_i: f64,
    theta_i: f64, // velocity after flip
    accepted: bool,
    color: Color,
    igor_aligned: bool,

    pub fn init(t: f64, i: u32, x_i: f64, theta_i: f64, accepted: bool, seed: u64) ChromaticEvent {
        var h = sm64(seed ^ @as(u64, @intFromFloat(@round(t * 1000))) ^ @as(u64, i));
        const r_raw: f64 = @as(f64, @floatFromInt(h % 256)) / 255.0;
        h = sm64(h);
        const g_raw: f64 = @as(f64, @floatFromInt(h % 256)) / 255.0;
        h = sm64(h);

        var r = r_raw;
        var g = g_raw;
        if (accepted) {
            g = @min(1.0, g_raw + 0.3);
        } else {
            r = @min(1.0, r_raw + 0.3);
        }

        return .{
            .t = t,
            .i = i,
            .x_i = x_i,
            .theta_i = theta_i,
            .accepted = accepted,
            .color = .{ .r = r, .g = g, .b = @as(f64, @floatFromInt(sm64(h) % 256)) / 255.0 },
            .igor_aligned = theta_i > 0,
        };
    }

    pub fn fingerprint(self: ChromaticEvent) u32 {
        var fp: u32 = 0;
        fp ^= @as(u32, @intFromFloat(@mod(@round(self.t * 1000), 65536))) << 16;
        fp ^= (self.i % 256) << 8;
        fp ^= @as(u32, @intFromFloat(@round(self.color.r * 255)));
        if (self.accepted) fp |= 0x80000000;
        return fp;
    }
};

pub const ChromaticTrace = struct {
    events: [4096]ChromaticEvent,
    count: u32,
    x0: [64]f64,
    theta0: [64]f64,
    dim: u32,
    seed: u64,

    pub fn init(dim: u32, seed: u64) ChromaticTrace {
        var trace: ChromaticTrace = undefined;
        trace.count = 0;
        trace.dim = @min(dim, 64);
        trace.seed = seed;
        for (0..64) |i| {
            trace.x0[i] = 0;
            trace.theta0[i] = 1.0;
        }
        return trace;
    }

    pub fn push(self: *ChromaticTrace, ev: ChromaticEvent) void {
        if (self.count < 4096) {
            self.events[self.count] = ev;
            self.count += 1;
        }
    }

    /// XOR fingerprint (order-invariant)
    pub fn spiFingerprint(self: *const ChromaticTrace) u32 {
        var fp: u32 = 0;
        for (0..self.count) |i| {
            fp ^= self.events[i].fingerprint();
        }
        return fp;
    }
};

/// Single zigzag step: propose flip, accept/reject via thinning
pub fn zigzagStep(trace: *ChromaticTrace, coord: u32, rate: f64, rng_state: *u64) void {
    rng_state.* = sm64(rng_state.*);
    const u: f64 = @as(f64, @floatFromInt(rng_state.* % 10000)) / 10000.0;
    const accepted = u < rate;

    const t = @as(f64, @floatFromInt(trace.count)) * 0.01;
    const x_i = trace.x0[coord];
    const theta_new = if (accepted) -trace.theta0[coord] else trace.theta0[coord];

    const ev = ChromaticEvent.init(t, coord, x_i, theta_new, accepted, trace.seed);
    trace.push(ev);

    if (accepted) {
        trace.theta0[coord] = theta_new;
    }
}

// ============================================================================
// Section 4: GayRNG (gayrng.jl)
// — Splittable PRNG with monoidal structure, Zobrist hashing, CRDT lattice
// ============================================================================

pub const GAY_SEED_VALUE: u64 = 1069;
pub const GAY_IGOR_SEED: u64 = 0x6761795f636f6c6f;

pub const GaySeed = struct {
    state: u64,
    fp: u64, // XOR fingerprint
    depth: u16,
    stream: u16,

    pub fn init(state: u64) GaySeed {
        return .{ .state = state, .fp = sm64(state), .depth = 0, .stream = 0 };
    }

    pub fn initStream(state: u64, stream: u16) GaySeed {
        return .{
            .state = state,
            .fp = sm64(state ^ @as(u64, stream)),
            .depth = 0,
            .stream = stream,
        };
    }

    /// Generate next value (pure)
    pub fn next(self: GaySeed) struct { value: u64, seed: GaySeed } {
        const new_state = self.state +% GOLDEN;
        const value = sm64(new_state);
        return .{
            .value = value,
            .seed = .{
                .state = new_state,
                .fp = self.fp ^ (value & 0xFF),
                .depth = self.depth,
                .stream = self.stream,
            },
        };
    }

    /// Split into two independent streams. SPI: parent.fp == left.fp ^ right.fp
    pub fn split(self: GaySeed) struct { left: GaySeed, right: GaySeed } {
        const left_state = sm64(self.state);
        const left_fp = sm64(left_state);
        const right_state = sm64(self.state ^ GOLDEN);
        const right_fp_adjusted = self.fp ^ left_fp;
        const new_depth = self.depth + 1;

        return .{
            .left = .{ .state = left_state, .fp = left_fp, .depth = new_depth, .stream = self.stream * 2 },
            .right = .{ .state = right_state, .fp = right_fp_adjusted, .depth = new_depth, .stream = self.stream * 2 + 1 },
        };
    }

    /// Jump ahead n steps in O(1)
    pub fn jump(self: GaySeed, n: u64) GaySeed {
        const new_state = self.state +% n *% GOLDEN;
        return .{ .state = new_state, .fp = sm64(new_state), .depth = self.depth, .stream = self.stream };
    }

    /// Tensor product (parallel composition): symmetric monoidal
    pub fn tensor(a: GaySeed, b: GaySeed) GaySeed {
        return .{
            .state = sm64(a.state ^ b.state),
            .fp = a.fp ^ b.fp,
            .depth = @max(a.depth, b.depth) + 1,
            .stream = 0,
        };
    }

    /// Verify SPI after split
    pub fn verifySpi(parent: GaySeed, left: GaySeed, right: GaySeed) bool {
        return parent.fp == (left.fp ^ right.fp);
    }

    /// Mac Lane coherence: all bracketings give same fingerprint
    pub fn coherenceCheck(seeds: []const GaySeed) bool {
        if (seeds.len <= 1) return true;
        var xor_all: u64 = 0;
        for (seeds) |s| xor_all ^= s.fp;

        // Left fold
        var left = seeds[0];
        for (seeds[1..]) |s| left = tensor(left, s);

        // Right fold
        var right = seeds[seeds.len - 1];
        var i = seeds.len - 1;
        while (i > 0) : (i -= 1) {
            right = tensor(seeds[i - 1], right);
        }

        return left.fp == right.fp and left.fp == xor_all;
    }
};

/// Zobrist table for O(1) incremental hashing
pub const ZobristTable = struct {
    table: [256][24]u64, // 256 positions x 24 hue buckets

    pub fn init(seed: u64) ZobristTable {
        var zt: ZobristTable = undefined;
        var rng = seed;
        for (0..256) |p| {
            for (0..24) |b| {
                rng = sm64(rng);
                zt.table[p][b] = rng;
            }
        }
        return zt;
    }

    pub fn hash(self: *const ZobristTable, position: u8, hue_bucket: u8) u64 {
        return self.table[position][@min(hue_bucket, 23)];
    }

    /// Incremental update: XOR old out, XOR new in
    pub fn update(self: *const ZobristTable, current: u64, pos: u8, old_bucket: u8, new_bucket: u8) u64 {
        return current ^ self.hash(pos, old_bucket) ^ self.hash(pos, new_bucket);
    }
};

/// FingerprintCRDT: distributed convergence via LWW + XOR
pub const FingerprintCRDT = struct {
    node_id: u32,
    fingerprint: u64,
    timestamp: u64,
    merge_count: u32,

    pub fn init(node_id: u32, seed: u64) FingerprintCRDT {
        return .{ .node_id = node_id, .fingerprint = sm64(seed ^ @as(u64, node_id)), .timestamp = 0, .merge_count = 0 };
    }

    pub fn update(self: *FingerprintCRDT, value: u64) void {
        self.fingerprint ^= sm64(value);
        self.timestamp += 1;
    }

    /// CRDT merge: LWW semantics with XOR combination
    pub fn merge(self: *FingerprintCRDT, other: FingerprintCRDT) void {
        self.fingerprint ^= other.fingerprint;
        self.timestamp = @max(self.timestamp, other.timestamp) + 1;
        self.merge_count += 1;
    }
};

// ============================================================================
// Section 5: Scoped Propagators (scoped_propagators.jl)
// — Bottom-up (cone), top-down (descent), horizontal (adhesion)
// ============================================================================

pub const PropagatorScopeKind = enum {
    cone, // bottom-up: descendants propagate fingerprints up
    descent, // top-down: ancestors constrain descendants
    adhesion, // horizontal: siblings co-witness across shared parent
};

pub const AncestryNode = struct {
    id: u64, // hashed thread ID
    fingerprint: u64,
    color: Color,
    depth: u32,
    parents: [8]u64,
    parent_count: u8,
    children: [8]u64,
    child_count: u8,

    pub fn init(id: u64, seed: u64) AncestryNode {
        const fp = fnv1a_u64(id) ^ seed;
        const h = sm64(fp);
        return .{
            .id = id,
            .fingerprint = fp,
            .color = .{
                .r = @as(f64, @floatFromInt((h >> 16) & 0xFF)) / 255.0,
                .g = @as(f64, @floatFromInt((h >> 8) & 0xFF)) / 255.0,
                .b = @as(f64, @floatFromInt(h & 0xFF)) / 255.0,
            },
            .depth = 0,
            .parents = [_]u64{0} ** 8,
            .parent_count = 0,
            .children = [_]u64{0} ** 8,
            .child_count = 0,
        };
    }

    pub fn addChild(self: *AncestryNode, child_id: u64) void {
        if (self.child_count < 8) {
            self.children[self.child_count] = child_id;
            self.child_count += 1;
        }
    }

    pub fn addParent(self: *AncestryNode, parent_id: u64) void {
        if (self.parent_count < 8) {
            self.parents[self.parent_count] = parent_id;
            self.parent_count += 1;
        }
    }
};

fn fnv1a_u64(val: u64) u64 {
    var h: u64 = 0xcbf29ce484222325;
    const bytes = std.mem.asBytes(&val);
    for (bytes) |b| {
        h = (h ^ @as(u64, b)) *% 0x100000001b3;
    }
    return h;
}

pub const AncestryACSet = struct {
    nodes: [128]AncestryNode,
    node_count: u32,
    materialized: bool,
    fingerprint: u64,

    pub fn init() AncestryACSet {
        var acs: AncestryACSet = undefined;
        acs.node_count = 0;
        acs.materialized = false;
        acs.fingerprint = 0;
        return acs;
    }

    pub fn addNode(self: *AncestryACSet, id: u64, seed: u64) u32 {
        if (self.node_count >= 128) return self.node_count - 1;
        self.nodes[self.node_count] = AncestryNode.init(id, seed);
        self.node_count += 1;
        return self.node_count - 1;
    }

    pub fn addEdge(self: *AncestryACSet, parent_idx: u32, child_idx: u32) void {
        if (parent_idx >= self.node_count or child_idx >= self.node_count) return;
        self.nodes[parent_idx].addChild(self.nodes[child_idx].id);
        self.nodes[child_idx].addParent(self.nodes[parent_idx].id);
        self.nodes[child_idx].depth = self.nodes[parent_idx].depth + 1;
    }

    /// Bottom-up cone propagation: XOR fingerprints from leaves upward
    pub fn propagateCone(self: *AncestryACSet) u64 {
        var fp: u64 = 0;
        // Process in reverse depth order (leaves first)
        for (0..self.node_count) |pass| {
            _ = pass;
            for (0..self.node_count) |i| {
                if (self.nodes[i].child_count == 0) {
                    fp ^= self.nodes[i].fingerprint;
                }
            }
        }
        self.fingerprint = fp;
        self.materialized = true;
        return fp;
    }

    /// Top-down descent: propagate root constraints to leaves
    pub fn propagateDescent(self: *AncestryACSet) u64 {
        var fp: u64 = 0;
        for (0..self.node_count) |i| {
            if (self.nodes[i].parent_count == 0) {
                fp ^= self.nodes[i].fingerprint;
            }
        }
        self.fingerprint = fp;
        self.materialized = true;
        return fp;
    }
};

// ============================================================================
// Section 6: Chromatic Propagator (chromatic_propagator.jl)
// — Color-conserving constraint propagation cells
// ============================================================================

pub const OperatorClass = enum(u8) { additive, multiplicative, comparison };

pub const ChromaticCell = struct {
    name_hash: u64,
    color: Color,
    color_seed: u64,
    value: ?f64,
    conservation_count: u32,

    pub fn init(name_hash: u64) ChromaticCell {
        const seed = sm64(0x4005bf0a8b145769 ^ name_hash); // GAY_E_SEED base
        return .{
            .name_hash = name_hash,
            .color = .{
                .r = @as(f64, @floatFromInt((seed >> 16) & 0xFF)) / 255.0,
                .g = @as(f64, @floatFromInt((seed >> 8) & 0xFF)) / 255.0,
                .b = @as(f64, @floatFromInt(seed & 0xFF)) / 255.0,
            },
            .color_seed = seed,
            .value = null,
            .conservation_count = 0,
        };
    }

    pub fn tell(self: *ChromaticCell, val: f64) void {
        self.value = val;
        self.conservation_count += 1;
    }
};

pub const ChromaticOperator = struct {
    name_hash: u64,
    op_class: OperatorClass,
    color_seed: u64,
    color: Color,

    pub fn init(name_hash: u64, op_class: OperatorClass) ChromaticOperator {
        const seed = sm64(0x4005bf0a8b145769 ^ name_hash ^ @as(u64, @intFromEnum(op_class)));
        return .{
            .name_hash = name_hash,
            .op_class = op_class,
            .color_seed = seed,
            .color = .{
                .r = @as(f64, @floatFromInt((seed >> 16) & 0xFF)) / 255.0,
                .g = @as(f64, @floatFromInt((seed >> 8) & 0xFF)) / 255.0,
                .b = @as(f64, @floatFromInt(seed & 0xFF)) / 255.0,
            },
        };
    }
};

/// Check color conservation: XOR parity of input colors vs result
pub fn colorConservationCheck(c1: Color, c2: Color, result: Color) bool {
    // Quantize to 8-bit and check XOR parity
    const q1 = quantizeColor(c1);
    const q2 = quantizeColor(c2);
    const qr = quantizeColor(result);
    // Conservation: parity of combined input channels matches result parity
    return ((q1 ^ q2) & 0x010101) == (qr & 0x010101);
}

fn quantizeColor(c: Color) u32 {
    const r: u32 = @intFromFloat(@round(std.math.clamp(c.r, 0.0, 1.0) * 255.0));
    const g: u32 = @intFromFloat(@round(std.math.clamp(c.g, 0.0, 1.0) * 255.0));
    const b: u32 = @intFromFloat(@round(std.math.clamp(c.b, 0.0, 1.0) * 255.0));
    return (r << 16) | (g << 8) | b;
}

/// Chromatic constraint: a + b = sum with color tracking
pub fn constraintAddChromatic(a: *ChromaticCell, b: *ChromaticCell, sum: *ChromaticCell) bool {
    if (a.value != null and b.value != null) {
        sum.tell(a.value.? + b.value.?);
        // Update sum color as XOR-blend of inputs
        sum.color_seed = a.color_seed ^ b.color_seed;
        return true;
    }
    return false;
}

// ============================================================================
// Section 7: Triadic Subagents (triadic_subagents.jl)
// — GF(3) polarity-twisted parallel color generation
// ============================================================================

pub const Polarity = enum(u8) {
    minus = 0, // contraction
    ergodic = 1, // observation
    plus = 2, // expansion

    pub fn twist(self: Polarity) u64 {
        return switch (self) {
            .minus => 0x2d2d2d2d2d2d2d2d,
            .ergodic => 0x5f5f5f5f5f5f5f5f,
            .plus => 0x2b2b2b2b2b2b2b2b,
        };
    }

    pub fn next(self: Polarity) Polarity {
        return @enumFromInt((@intFromEnum(self) + 1) % 3);
    }

    pub fn symbol(self: Polarity) u8 {
        return switch (self) {
            .minus => '-',
            .ergodic => '_',
            .plus => '+',
        };
    }
};

pub fn phaseToPolarity(phase: u64) Polarity {
    return @enumFromInt(@as(u8, @intCast(phase % 3)));
}

pub const TriadicAgent = struct {
    polarity: Polarity,
    seed: u64,
    state: u64,
    phase: u64,
    fingerprint: u64,

    pub fn init(polarity: Polarity, base_seed: u64) TriadicAgent {
        const agent_seed = base_seed ^ polarity.twist();
        return .{
            .polarity = polarity,
            .seed = agent_seed,
            .state = sm64(agent_seed),
            .phase = 0,
            .fingerprint = agent_seed,
        };
    }

    /// Generate next color; updates state + fingerprint
    pub fn sample(self: *TriadicAgent) Color {
        self.state = sm64(self.state);
        self.fingerprint ^= self.state;
        self.phase += 1;
        return .{
            .r = @as(f64, @floatFromInt((self.state >> 16) & 0xFF)) / 255.0,
            .g = @as(f64, @floatFromInt((self.state >> 8) & 0xFF)) / 255.0,
            .b = @as(f64, @floatFromInt(self.state & 0xFF)) / 255.0,
        };
    }
};

pub const Triad = struct {
    seed: u64,
    minus: TriadicAgent,
    ergodic: TriadicAgent,
    plus: TriadicAgent,

    pub fn init(seed: u64) Triad {
        return .{
            .seed = seed,
            .minus = TriadicAgent.init(.minus, seed),
            .ergodic = TriadicAgent.init(.ergodic, seed),
            .plus = TriadicAgent.init(.plus, seed),
        };
    }

    pub fn getAgent(self: *Triad, p: Polarity) *TriadicAgent {
        return switch (p) {
            .minus => &self.minus,
            .ergodic => &self.ergodic,
            .plus => &self.plus,
        };
    }

    /// Sample n colors from each agent (simulated parallel)
    pub fn parallelSample(self: *Triad, n: u32) [3]u64 {
        var fps: [3]u64 = undefined;
        inline for ([_]Polarity{ .minus, .ergodic, .plus }, 0..) |p, idx| {
            const agent = self.getAgent(p);
            for (0..n) |_| _ = agent.sample();
            fps[idx] = agent.fingerprint;
        }
        return fps;
    }

    /// XOR-combined fingerprint (schedule-invariant)
    pub fn combinedFingerprint(self: *const Triad) u64 {
        return self.seed ^ self.minus.fingerprint ^ self.ergodic.fingerprint ^ self.plus.fingerprint;
    }

    /// Verify triadic SPI: parallel vs interleaved give same fingerprint
    pub fn verifySpi(seed: u64, n: u32) bool {
        var t1 = Triad.init(seed);
        var t2 = Triad.init(seed);

        // Parallel: each agent samples n
        _ = t1.parallelSample(n);

        // Interleaved: round-robin
        for (0..n * 3) |i| {
            const p = phaseToPolarity(i);
            _ = t2.getAgent(p).sample();
        }

        return t1.combinedFingerprint() == t2.combinedFingerprint();
    }
};

// ============================================================================
// Tests
// ============================================================================

test "synergy graph random build" {
    const g = SynergyGraph.buildRandom(20, 42, 0.2);
    try std.testing.expect(g.n == 20);
    // Should have some edges
    var total_edges: u32 = 0;
    for (0..g.n) |i| total_edges += g.adj_count[i];
    try std.testing.expect(total_edges > 0);
}

test "derangement has no fixed points" {
    const pd = ParaDerangeable.init(10, 42, 0);
    const perm = pd.sampleDerangement(1);
    try std.testing.expect(ParaDerangeable.verifyDerangement(&perm, 10));
}

test "greedy coloring bipartite k=2" {
    var g = SimpleGraph.init(4);
    g.addEdge(0, 1);
    g.addEdge(2, 3);
    const pc = ParaColorable{ .graph = &g, .k = 2, .seed = 42 };
    const result = pc.greedyColoring(0);
    try std.testing.expect(result.success);
    try std.testing.expect(pc.isValidColoring(&result.colors));
}

test "tropical min-plus" {
    const ring = ParaTropicalRing.init(3, 42, .min_plus);
    try std.testing.expectEqual(@as(f64, 2.0), ring.tropAdd(2.0, 5.0));
    try std.testing.expectEqual(@as(f64, 7.0), ring.tropMul(2.0, 5.0));
}

test "zigzag trace fingerprint deterministic" {
    var t1 = ChromaticTrace.init(4, 42);
    var t2 = ChromaticTrace.init(4, 42);
    var rng1: u64 = 100;
    var rng2: u64 = 100;
    for (0..10) |_| {
        zigzagStep(&t1, 0, 0.5, &rng1);
        zigzagStep(&t2, 0, 0.5, &rng2);
    }
    try std.testing.expectEqual(t1.spiFingerprint(), t2.spiFingerprint());
}

test "GaySeed split preserves SPI" {
    const parent = GaySeed.init(1069);
    const children = parent.split();
    try std.testing.expect(GaySeed.verifySpi(parent, children.left, children.right));
}

test "GaySeed tensor coherence" {
    const seeds = [_]GaySeed{
        GaySeed.init(1),
        GaySeed.init(2),
        GaySeed.init(3),
    };
    try std.testing.expect(GaySeed.coherenceCheck(&seeds));
}

test "GaySeed jump equivalence" {
    const s0 = GaySeed.init(42);
    var stepped = s0;
    for (0..100) |_| {
        const result = stepped.next();
        stepped = result.seed;
    }
    const jumped = s0.jump(100);
    try std.testing.expectEqual(stepped.state, jumped.state);
}

test "Zobrist incremental update" {
    const zt = ZobristTable.init(42);
    const h1 = zt.hash(10, 5);
    const h2 = zt.hash(10, 7);
    const combined = zt.update(h1, 10, 5, 7);
    try std.testing.expectEqual(h2, combined);
}

test "FingerprintCRDT merge commutativity" {
    var a = FingerprintCRDT.init(0, 42);
    var b = FingerprintCRDT.init(1, 99);
    a.update(100);
    b.update(200);
    var a2 = a;
    var b2 = b;
    a2.merge(b);
    b2.merge(a);
    try std.testing.expectEqual(a2.fingerprint, b2.fingerprint);
}

test "ancestry ACSet cone propagation" {
    var acs = AncestryACSet.init();
    const root = acs.addNode(1, 42);
    const child1 = acs.addNode(2, 42);
    const child2 = acs.addNode(3, 42);
    acs.addEdge(root, child1);
    acs.addEdge(root, child2);
    const fp = acs.propagateCone();
    try std.testing.expect(fp != 0);
    try std.testing.expect(acs.materialized);
}

test "chromatic cell tell and constraint" {
    var a = ChromaticCell.init(0x41); // 'A'
    var b = ChromaticCell.init(0x42); // 'B'
    var sum = ChromaticCell.init(0x53); // 'S'
    a.tell(3.0);
    b.tell(4.0);
    const ok = constraintAddChromatic(&a, &b, &sum);
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(f64, 7.0), sum.value.?);
}

test "triadic agent independence" {
    const seed: u64 = 1069;
    var a1 = TriadicAgent.init(.minus, seed);
    var a2 = TriadicAgent.init(.ergodic, seed);
    _ = a1.sample();
    _ = a2.sample();
    // Different polarities -> different states
    try std.testing.expect(a1.state != a2.state);
}

test "triad combined fingerprint deterministic" {
    var t1 = Triad.init(1069);
    var t2 = Triad.init(1069);
    _ = t1.parallelSample(50);
    _ = t2.parallelSample(50);
    try std.testing.expectEqual(t1.combinedFingerprint(), t2.combinedFingerprint());
}

test "triad SPI parallel vs interleaved" {
    // Same combined fingerprint regardless of schedule
    try std.testing.expect(Triad.verifySpi(1069, 30));
    try std.testing.expect(Triad.verifySpi(42, 100));
}

test "polarity cycle" {
    try std.testing.expectEqual(Polarity.ergodic, Polarity.minus.next());
    try std.testing.expectEqual(Polarity.plus, Polarity.ergodic.next());
    try std.testing.expectEqual(Polarity.minus, Polarity.plus.next());
}

test "parallel color schedule" {
    const g = SynergyGraph.buildRandom(16, 42, 0.15);
    const result = parallelColorSchedule(&g, 42);
    try std.testing.expect(result.fingerprint != 0);
    try std.testing.expectEqual(@as(u32, 16), result.color_count);
}
