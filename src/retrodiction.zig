//! GF(3) Retrodiction Calculus
//!
//! Multiple realizability of pasts: given a present state s, the fiber
//! f^-1(s) = {histories h : h ~> s} may contain many trajectories.
//!
//! This module implements:
//!   - TritTrajectory: variable-length GF(3) trit sequences with conservation check
//!   - Bisimulation quotient: fiber computation over equivalence classes
//!   - 5 computable invariants: mult, entropy, pi_1 proxy, Wasserstein diameter, p-adic depth
//!   - Transfer operator on quotient graph (spectral analysis)
//!   - Retrodiction difficulty index R([s])
//!   - Decoherence functional D(alpha, beta) for consistent-history classification
//!
//! Integration points:
//!   - Trit arithmetic mirrors entangle.zig GF(3) qutrit
//!   - CellValue lattice (Nothing < Value < Contradiction) from propagator.zig
//!   - Conservation sum(t_i) = 0 (mod 3) is the Past Hypothesis that narrows fibers

const std = @import("std");

// =============================================================================
// GF(3) Trit (local definition, isomorphic to entangle.zig Trit)
// =============================================================================

pub const Trit = enum(i8) {
    minus = -1,
    zero = 0,
    plus = 1,

    pub fn add(a: Trit, b: Trit) Trit {
        const table = [3]Trit{ .zero, .plus, .minus };
        const av: u8 = @intCast(@mod(@as(i16, @intFromEnum(a)) + 3, 3));
        const bv: u8 = @intCast(@mod(@as(i16, @intFromEnum(b)) + 3, 3));
        return table[(av + bv) % 3];
    }

    pub fn neg(self: Trit) Trit {
        return switch (self) {
            .minus => .plus,
            .zero => .zero,
            .plus => .minus,
        };
    }

    pub fn fromInt(i: i8) ?Trit {
        return switch (i) {
            -1 => .minus,
            0 => .zero,
            1 => .plus,
            else => null,
        };
    }
};

// =============================================================================
// GF(9) = GF(3)[i]/(i²+1): Nonet (ego-locale.jl §14)
// =============================================================================

pub const Nonet = struct {
    real: Trit,
    imag: Trit,

    pub fn coarsen(self: Nonet) Trit {
        return self.real;
    }

    pub fn frobenius(self: Nonet) Nonet {
        return .{ .real = self.real, .imag = Trit.neg(self.imag) };
    }

    pub fn isGf3Fixed(self: Nonet) bool {
        return self.imag == .zero;
    }
};

// =============================================================================
// GF(27) = GF(3)[α]/(α³+2α+1): Tribble (ego-locale.jl §14)
// =============================================================================

pub const Tribble = struct {
    a: Trit,
    b: Trit,
    c: Trit,

    pub fn coarsen(self: Tribble) Trit {
        return self.a;
    }

    pub fn frobenius(self: Tribble) Tribble {
        return .{ .a = self.c, .b = self.a, .c = self.b };
    }

    pub fn isGf3Fixed(self: Tribble) bool {
        return self.b == .zero and self.c == .zero;
    }
};

/// Tower level: which extension field is needed to distinguish this position.
pub const TowerLevel = enum(u8) {
    gf3 = 1,  // trit alone suffices
    gf9 = 2,  // need pair context (nonet)
    gf27 = 3, // need triple context (tribble)
};

/// Classify a position in a trit sequence by its tower depth.
/// Consecutive identical trits need higher extension fields to disambiguate.
pub fn towerClassify(trits: []const Trit, idx: usize) TowerLevel {
    if (trits.len == 0) return .gf3;
    const t = trits[idx];

    var has_same_neighbor = false;
    if (idx > 0 and trits[idx - 1] == t) has_same_neighbor = true;
    if (idx + 1 < trits.len and trits[idx + 1] == t) has_same_neighbor = true;
    if (!has_same_neighbor) return .gf3;

    // Check for triple run
    if (idx > 1 and trits[idx - 2] == t and trits[idx - 1] == t) return .gf27;
    if (idx + 2 < trits.len and trits[idx + 1] == t and trits[idx + 2] == t) return .gf27;
    return .gf9;
}

/// Verify tower conservation: GF(3) balance ⟹ GF(9)/GF(27) balance
/// when using the canonical embedding trit ↦ Nonet(trit, 0) / Tribble(trit, 0, 0).
pub fn verifyTowerConservation(trits: []const Trit) struct { base: bool, gf9: bool, gf27: bool, coherent: bool } {
    var base_sum: Trit = .zero;
    for (trits) |t| base_sum = Trit.add(base_sum, t);
    const base_balanced = base_sum == .zero;

    // Embedding then coarsening is identity, so these are tautologically equal.
    // But we verify explicitly to match ego-locale.jl verify_tower_conservation.
    var gf9_sum: Trit = .zero;
    for (trits) |t| gf9_sum = Trit.add(gf9_sum, (Nonet{ .real = t, .imag = .zero }).coarsen());

    var gf27_sum: Trit = .zero;
    for (trits) |t| gf27_sum = Trit.add(gf27_sum, (Tribble{ .a = t, .b = .zero, .c = .zero }).coarsen());

    return .{
        .base = base_balanced,
        .gf9 = gf9_sum == .zero,
        .gf27 = gf27_sum == .zero,
        .coherent = base_balanced == (gf9_sum == .zero) and (gf9_sum == .zero) == (gf27_sum == .zero),
    };
}

// =============================================================================
// TritTrajectory: a history through GF(3) state space
// =============================================================================

pub const MAX_TRAJECTORY_LEN: usize = 256;

pub const TritTrajectory = struct {
    trits: []const Trit,
    len: usize,

    /// Compute GF(3) sum of all trits.
    pub fn checksum(self: TritTrajectory) Trit {
        var sum: Trit = .zero;
        for (self.trits[0..self.len]) |t| {
            sum = Trit.add(sum, t);
        }
        return sum;
    }

    /// Conservation check: sum(t_i) = 0 (mod 3) -- the Past Hypothesis.
    pub fn isConserving(self: TritTrajectory) bool {
        return self.checksum() == .zero;
    }

    /// Terminal state: last trit (the present).
    pub fn terminal(self: TritTrajectory) ?Trit {
        if (self.len == 0) return null;
        return self.trits[self.len - 1];
    }

    /// p-adic depth: length of longest suffix of identical trits.
    /// Measures how long the system has been in its current regime.
    pub fn padicDepth(self: TritTrajectory) u32 {
        if (self.len == 0) return 0;
        const last = self.trits[self.len - 1];
        var depth: u32 = 1;
        var i: usize = self.len - 1;
        while (i > 0) {
            i -= 1;
            if (self.trits[i] == last) {
                depth += 1;
            } else break;
        }
        return depth;
    }
};

// =============================================================================
// Partial Information Lattice (mirrors propagator.zig CellValue)
// =============================================================================

pub fn RetroCell(comptime T: type) type {
    return union(enum) {
        nothing: void,
        value: T,
        contradiction: struct { a: T, b: T },

        const Self = @This();

        pub fn isNothing(self: Self) bool {
            return self == .nothing;
        }

        pub fn hasValue(self: Self) ?T {
            return switch (self) {
                .value => |v| v,
                else => null,
            };
        }

        pub fn isContradiction(self: Self) bool {
            return self == .contradiction;
        }
    };
}

/// Lattice merge: monotonic. Nothing < Value < Contradiction.
pub fn retroMerge(comptime T: type) *const fn (RetroCell(T), RetroCell(T)) RetroCell(T) {
    return struct {
        fn merge(existing: RetroCell(T), incoming: RetroCell(T)) RetroCell(T) {
            return switch (existing) {
                .nothing => incoming,
                .contradiction => existing,
                .value => |a| switch (incoming) {
                    .nothing => existing,
                    .value => |b| if (std.meta.eql(a, b))
                        existing
                    else
                        RetroCell(T){ .contradiction = .{ .a = a, .b = b } },
                    .contradiction => incoming,
                },
            };
        }
    }.merge;
}

// =============================================================================
// Fiber: the set of trajectories arriving at the same present state
// =============================================================================

pub const Fiber = struct {
    terminal: Trit,
    trajectories: std.ArrayListUnmanaged(TritTrajectory),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, term: Trit) Fiber {
        return .{
            .terminal = term,
            .trajectories = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Fiber) void {
        self.trajectories.deinit(self.allocator);
    }

    pub fn addTrajectory(self: *Fiber, traj: TritTrajectory) !void {
        try self.trajectories.append(self.allocator, traj);
    }

    /// Invariant 1: fiber cardinality |f^-1(s)|
    pub fn mult(self: *const Fiber) usize {
        return self.trajectories.items.len;
    }

    /// Invariant 2: trit-entropy S([s]) = -sum(p_i * log3(p_i)) over trit distribution
    pub fn entropy(self: *const Fiber) f64 {
        if (self.trajectories.items.len == 0) return 0.0;

        var counts = [3]u64{ 0, 0, 0 };
        var total: u64 = 0;
        for (self.trajectories.items) |traj| {
            for (traj.trits[0..traj.len]) |t| {
                const idx: usize = @intCast(@mod(@as(i16, @intFromEnum(t)) + 3, 3));
                counts[idx] += 1;
                total += 1;
            }
        }
        if (total == 0) return 0.0;

        var s: f64 = 0.0;
        const ftotal: f64 = @floatFromInt(total);
        for (counts) |c| {
            if (c > 0) {
                const p: f64 = @as(f64, @floatFromInt(c)) / ftotal;
                s -= p * @log(p) / @log(3.0);
            }
        }
        return s;
    }

    /// Invariant 3: fundamental group proxy -- number of distinct trit bigrams.
    /// pi_1 approximation: counts distinct consecutive trit pairs (edge types in LTS).
    pub fn fundamentalGroupProxy(self: *const Fiber) u32 {
        var seen = [_]bool{false} ** 9;
        for (self.trajectories.items) |traj| {
            if (traj.len < 2) continue;
            var i: usize = 0;
            while (i + 1 < traj.len) : (i += 1) {
                const a: usize = @intCast(@mod(@as(i16, @intFromEnum(traj.trits[i])) + 3, 3));
                const bv: usize = @intCast(@mod(@as(i16, @intFromEnum(traj.trits[i + 1])) + 3, 3));
                seen[a * 3 + bv] = true;
            }
        }
        var count: u32 = 0;
        for (seen) |sv| {
            if (sv) count += 1;
        }
        return count;
    }

    /// Invariant 4: Wasserstein diameter -- max L1 distance between trajectory
    /// trit distributions within the fiber.
    pub fn wassersteinDiameter(self: *const Fiber) f64 {
        const items = self.trajectories.items;
        if (items.len < 2) return 0.0;

        var max_dist: f64 = 0.0;

        for (items, 0..) |traj_a, i| {
            for (items[i + 1 ..]) |traj_b| {
                const dist = tritDistributionL1(traj_a, traj_b);
                if (dist > max_dist) max_dist = dist;
            }
        }
        return max_dist;
    }

    /// Invariant 5: p-adic depth -- minimum p-adic depth across fiber.
    pub fn minPadicDepth(self: *const Fiber) u32 {
        if (self.trajectories.items.len == 0) return 0;
        var min_d: u32 = std.math.maxInt(u32);
        for (self.trajectories.items) |traj| {
            const d = traj.padicDepth();
            if (d < min_d) min_d = d;
        }
        return min_d;
    }

    /// Retrodiction Difficulty Index: R([s]) = S * diam_W / depth
    pub fn retrodictionDifficulty(self: *const Fiber) f64 {
        const s = self.entropy();
        const dw = self.wassersteinDiameter();
        const depth = self.minPadicDepth();
        if (depth == 0) return std.math.inf(f64);
        return s * dw / @as(f64, @floatFromInt(depth));
    }

    /// Count conserving trajectories (Past Hypothesis filter).
    pub fn conservingCount(self: *const Fiber) usize {
        var count: usize = 0;
        for (self.trajectories.items) |traj| {
            if (traj.isConserving()) count += 1;
        }
        return count;
    }
};

/// L1 distance between trit distributions of two trajectories.
fn tritDistributionL1(a: TritTrajectory, b: TritTrajectory) f64 {
    var ca = [3]u64{ 0, 0, 0 };
    var cb = [3]u64{ 0, 0, 0 };
    for (a.trits[0..a.len]) |t| {
        ca[@intCast(@mod(@as(i16, @intFromEnum(t)) + 3, 3))] += 1;
    }
    for (b.trits[0..b.len]) |t| {
        cb[@intCast(@mod(@as(i16, @intFromEnum(t)) + 3, 3))] += 1;
    }
    const ta: f64 = @floatFromInt(a.len);
    const tb: f64 = @floatFromInt(b.len);
    if (ta == 0.0 or tb == 0.0) return 0.0;

    var dist: f64 = 0.0;
    for (0..3) |i| {
        const pa: f64 = @as(f64, @floatFromInt(ca[i])) / ta;
        const pb: f64 = @as(f64, @floatFromInt(cb[i])) / tb;
        dist += @abs(pa - pb);
    }
    return dist;
}

// =============================================================================
// Transfer Operator on Quotient Graph
// =============================================================================

/// 3x3 transfer matrix L on the GF(3) state space.
/// L[i][j] = count of transitions from trit i to trit j across all trajectories.
pub const TransferOperator = struct {
    matrix: [3][3]f64,

    pub fn init() TransferOperator {
        return .{ .matrix = [_][3]f64{[_]f64{ 0, 0, 0 }} ** 3 };
    }

    /// Accumulate transitions from a fiber's trajectories.
    pub fn accumulate(self: *TransferOperator, fiber: *const Fiber) void {
        for (fiber.trajectories.items) |traj| {
            var i: usize = 0;
            while (i + 1 < traj.len) : (i += 1) {
                const from: usize = @intCast(@mod(@as(i16, @intFromEnum(traj.trits[i])) + 3, 3));
                const to: usize = @intCast(@mod(@as(i16, @intFromEnum(traj.trits[i + 1])) + 3, 3));
                self.matrix[from][to] += 1.0;
            }
        }
    }

    /// Normalize rows to get transition probabilities.
    pub fn normalize(self: *TransferOperator) void {
        for (&self.matrix) |*row| {
            var sum: f64 = 0;
            for (row.*) |v| sum += v;
            if (sum > 0) {
                for (row) |*v| v.* /= sum;
            }
        }
    }

    /// Spectral gap estimate: 1 - |lambda_2| via power iteration on L - uniform.
    /// Larger gap = faster mixing = harder retrodiction (pasts become indistinguishable).
    pub fn spectralGapEstimate(self: *const TransferOperator) f64 {
        var v = [3]f64{ 1.0, -1.0, 0.0 };
        var iter: u32 = 0;
        while (iter < 20) : (iter += 1) {
            var nv = [3]f64{ 0, 0, 0 };
            for (0..3) |r| {
                for (0..3) |c| {
                    nv[r] += self.matrix[r][c] * v[c];
                }
            }
            // Subtract projection onto uniform (1/3, 1/3, 1/3)
            var mean: f64 = 0;
            for (nv) |x| mean += x;
            mean /= 3.0;
            for (&nv) |*x| x.* -= mean;
            // Normalize
            var norm: f64 = 0;
            for (nv) |x| norm += x * x;
            norm = @sqrt(norm);
            if (norm < 1e-15) return 1.0; // Fully mixed
            for (&nv) |*x| x.* /= norm;
            v = nv;
        }
        // Rayleigh quotient
        var lv = [3]f64{ 0, 0, 0 };
        for (0..3) |r| {
            for (0..3) |c| {
                lv[r] += self.matrix[r][c] * v[c];
            }
        }
        var lambda2: f64 = 0;
        for (0..3) |r| lambda2 += lv[r] * v[r];
        return 1.0 - @abs(lambda2);
    }
};

// =============================================================================
// Decoherence Functional D(alpha, beta)
// =============================================================================

/// Decoherence functional on trit trajectories.
/// D(alpha, beta) = sum_i alpha_i * beta_i  (GF(3) inner product).
/// If D = 0, histories alpha and beta are decoherent (consistent).
pub fn decoherenceFunctional(alpha: TritTrajectory, beta: TritTrajectory) Trit {
    const min_len = @min(alpha.len, beta.len);
    var sum: Trit = .zero;
    for (0..min_len) |i| {
        // GF(3) multiplication: (a_int * b_int) mod 3
        const av: i16 = @intFromEnum(alpha.trits[i]);
        const bv: i16 = @intFromEnum(beta.trits[i]);
        const prod_val = @mod(av * bv + 9, 3); // +9 to stay positive
        const prod_trit: Trit = switch (@as(u2, @intCast(prod_val))) {
            0 => .zero,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
        sum = Trit.add(sum, prod_trit);
    }
    return sum;
}

/// Check if two histories are decoherent (consistent): D(alpha, beta) = 0.
pub fn areDecoherent(alpha: TritTrajectory, beta: TritTrajectory) bool {
    return decoherenceFunctional(alpha, beta) == .zero;
}

// =============================================================================
// Retrodiction Summary
// =============================================================================

pub const RetrodictionSummary = struct {
    terminal: Trit,
    fiber_cardinality: usize,
    conserving_count: usize,
    trit_entropy: f64,
    fundamental_group_proxy: u32,
    wasserstein_diameter: f64,
    min_padic_depth: u32,
    retrodiction_difficulty: f64,
    spectral_gap: f64,
};

/// Compute full retrodiction summary for a fiber.
pub fn summarize(fiber: *const Fiber, transfer: *const TransferOperator) RetrodictionSummary {
    return .{
        .terminal = fiber.terminal,
        .fiber_cardinality = fiber.mult(),
        .conserving_count = fiber.conservingCount(),
        .trit_entropy = fiber.entropy(),
        .fundamental_group_proxy = fiber.fundamentalGroupProxy(),
        .wasserstein_diameter = fiber.wassersteinDiameter(),
        .min_padic_depth = fiber.minPadicDepth(),
        .retrodiction_difficulty = fiber.retrodictionDifficulty(),
        .spectral_gap = transfer.spectralGapEstimate(),
    };
}

// =============================================================================
// Retrodiction Propagator Cell
// =============================================================================

/// A propagator cell whose content is a RetrodictionSummary.
/// Evidence (new trajectories) flows in, invariants propagate out.
/// Merge = lattice join: higher mult, higher entropy, wider diameter wins.
/// Contradiction if two summaries claim different terminals.
pub const RetroSummaryCell = struct {
    content: RetroCell(RetrodictionSummary),
    name: []const u8,

    pub fn init(name: []const u8) RetroSummaryCell {
        return .{
            .content = .{ .nothing = {} },
            .name = name,
        };
    }

    /// Merge incoming summary. Contradiction if terminals differ.
    pub fn merge(self: *RetroSummaryCell, incoming: RetrodictionSummary) void {
        switch (self.content) {
            .nothing => {
                self.content = .{ .value = incoming };
            },
            .value => |existing| {
                if (existing.terminal != incoming.terminal) {
                    self.content = .{ .contradiction = .{ .a = existing, .b = incoming } };
                } else {
                    // Join: take the wider/richer summary
                    self.content = .{
                        .value = .{
                            .terminal = existing.terminal,
                            .fiber_cardinality = @max(existing.fiber_cardinality, incoming.fiber_cardinality),
                            .conserving_count = @max(existing.conserving_count, incoming.conserving_count),
                            .trit_entropy = @max(existing.trit_entropy, incoming.trit_entropy),
                            .fundamental_group_proxy = @max(existing.fundamental_group_proxy, incoming.fundamental_group_proxy),
                            .wasserstein_diameter = @max(existing.wasserstein_diameter, incoming.wasserstein_diameter),
                            .min_padic_depth = @min(existing.min_padic_depth, incoming.min_padic_depth),
                            .retrodiction_difficulty = @max(existing.retrodiction_difficulty, incoming.retrodiction_difficulty),
                            .spectral_gap = @min(existing.spectral_gap, incoming.spectral_gap),
                        },
                    };
                }
            },
            .contradiction => {}, // absorbs
        }
    }

    pub fn getSummary(self: *const RetroSummaryCell) ?RetrodictionSummary {
        return self.content.hasValue();
    }
};

// =============================================================================
// Tower-Enriched Summary
// =============================================================================

pub const TowerProfile = struct {
    gf3_count: u32,
    gf9_count: u32,
    gf27_count: u32,

    /// Fraction of positions needing extension fields beyond GF(3).
    pub fn extensionFraction(self: TowerProfile) f64 {
        const total = self.gf3_count + self.gf9_count + self.gf27_count;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.gf9_count + self.gf27_count)) / @as(f64, @floatFromInt(total));
    }
};

/// Compute tower depth distribution across all trajectories in a fiber.
pub fn towerProfile(fiber: *const Fiber) TowerProfile {
    var profile = TowerProfile{ .gf3_count = 0, .gf9_count = 0, .gf27_count = 0 };
    for (fiber.trajectories.items) |traj| {
        for (0..traj.len) |idx| {
            switch (towerClassify(traj.trits[0..traj.len], idx)) {
                .gf3 => profile.gf3_count += 1,
                .gf9 => profile.gf9_count += 1,
                .gf27 => profile.gf27_count += 1,
            }
        }
    }
    return profile;
}

/// Partition fiber trajectories into decoherence classes.
/// Two trajectories are in the same class iff D(a,b) = 0.
/// Returns number of classes (1 = fully decoherent fiber, n = n consistent families).
pub fn decoherenceClasses(fiber: *const Fiber, allocator: std.mem.Allocator) !u32 {
    const n = fiber.trajectories.items.len;
    if (n == 0) return 0;

    // Union-find via parent array
    var parent = try allocator.alloc(u32, n);
    defer allocator.free(parent);
    for (0..n) |i| parent[i] = @intCast(i);

    const find = struct {
        fn f(p: []u32, x: u32) u32 {
            var cur = x;
            while (p[cur] != cur) {
                p[cur] = p[p[cur]]; // path compression
                cur = p[cur];
            }
            return cur;
        }
    }.f;

    for (0..n) |i| {
        for (i + 1..n) |j| {
            if (areDecoherent(fiber.trajectories.items[i], fiber.trajectories.items[j])) {
                const ri = find(parent, @intCast(i));
                const rj = find(parent, @intCast(j));
                if (ri != rj) parent[ri] = rj;
            }
        }
    }

    // Count distinct roots
    var class_count: u32 = 0;
    for (0..n) |i| {
        if (find(parent, @intCast(i)) == @as(u32, @intCast(i))) class_count += 1;
    }
    return class_count;
}

// =============================================================================
// Retrodiction Gate: automated capability approval via fiber analysis
// =============================================================================

/// A capability grant request, analogous to NemoClaw's operator TUI blocked-request.
/// Instead of manual approve/deny, the gate computes the decision from the fiber.
pub const GrantRequest = struct {
    /// The agent's history as a trit trajectory
    agent_trajectory: TritTrajectory,
    /// The proposed capability's trit signature (role + mode + polarity)
    cap_role: Trit,
    cap_mode: Trit,
    cap_polarity: Trit,
};

/// Decision from the retrodiction gate.
pub const GrantDecision = enum {
    /// Grant: trajectory is conserving, cap is balanced, fiber is consistent
    approve,
    /// Deny: conservation violated or decoherence detected
    deny,
    /// Contradict: fiber analysis reveals incompatible histories
    contradict,
};

/// Detailed result from the gate.
pub const GateResult = struct {
    decision: GrantDecision,
    /// Is the agent's trajectory GF(3)-conserving?
    trajectory_conserving: bool,
    /// Is the proposed capability GF(3)-balanced (role+mode+polarity=0)?
    capability_balanced: bool,
    /// Would granting extend the trajectory conservingly?
    extended_conserving: bool,
    /// Tower level needed to disambiguate the grant point
    tower_level: TowerLevel,
    /// Retrodiction difficulty at the current fiber
    difficulty: f64,
};

/// The retrodiction gate: replaces NemoClaw's manual operator approval TUI.
///
/// Decision logic:
///   1. Check agent trajectory is GF(3)-conserving (Past Hypothesis)
///   2. Check proposed capability is GF(3)-balanced (role+mode+polarity=0)
///   3. Simulate extending trajectory with cap_role and check conservation
///   4. Compute tower level at the extension point
///   5. If all pass and difficulty < threshold: approve
///   6. If conservation breaks: deny
///   7. If fiber shows contradiction: contradict
pub fn retrodictionGate(request: GrantRequest, fiber: ?*const Fiber, difficulty_threshold: f64) GateResult {
    // 1. Agent trajectory conservation
    const traj_conserving = request.agent_trajectory.isConserving();

    // 2. Capability GF(3) balance
    const cap_sum = Trit.add(Trit.add(request.cap_role, request.cap_mode), request.cap_polarity);
    const cap_balanced = cap_sum == .zero;

    // 3. Simulate extension: append cap_role to trajectory, check conservation
    // The extended trajectory's checksum = old_checksum + cap_role
    const old_checksum = request.agent_trajectory.checksum();
    const extended_checksum = Trit.add(old_checksum, request.cap_role);
    const ext_conserving = extended_checksum == .zero;

    // 4. Tower level at the junction point
    var tower_level: TowerLevel = .gf3;
    if (request.agent_trajectory.len > 0) {
        const last = request.agent_trajectory.trits[request.agent_trajectory.len - 1];
        if (last == request.cap_role) {
            tower_level = .gf9; // same trit = need extension field
            if (request.agent_trajectory.len > 1) {
                const penult = request.agent_trajectory.trits[request.agent_trajectory.len - 2];
                if (penult == request.cap_role) {
                    tower_level = .gf27; // triple run
                }
            }
        }
    }

    // 5. Difficulty from fiber (if available)
    var difficulty: f64 = 0.0;
    if (fiber) |f| {
        difficulty = f.retrodictionDifficulty();

        // Check for contradiction in fiber
        if (f.trajectories.items.len > 0) {
            // If fiber has contradicting summaries, contradict
            const conserving_ratio = @as(f64, @floatFromInt(f.conservingCount())) /
                @as(f64, @floatFromInt(f.mult()));
            if (conserving_ratio == 0.0) {
                return .{
                    .decision = .contradict,
                    .trajectory_conserving = traj_conserving,
                    .capability_balanced = cap_balanced,
                    .extended_conserving = ext_conserving,
                    .tower_level = tower_level,
                    .difficulty = difficulty,
                };
            }
        }
    }

    // 6. Decision
    const decision: GrantDecision = if (!traj_conserving or !cap_balanced)
        .deny
    else if (!ext_conserving and tower_level == .gf27)
        .deny // deep run + non-conserving extension = too risky
    else if (difficulty > difficulty_threshold and difficulty_threshold > 0.0)
        .deny // fiber too hard to retrodict = too much ambiguity
    else
        .approve;

    return .{
        .decision = decision,
        .trajectory_conserving = traj_conserving,
        .capability_balanced = cap_balanced,
        .extended_conserving = ext_conserving,
        .tower_level = tower_level,
        .difficulty = difficulty,
    };
}

// =============================================================================
// OpenShell Bridge: policy concepts → GF(3) trit space
// =============================================================================

/// OpenShell access level → trit mapping.
/// read-only = -1 (validator/observer), full = 0 (coordinator), read-write = +1 (generator/mutator)
pub const AccessLevel = enum {
    read_only,
    read_write,
    full,

    pub fn toTrit(self: AccessLevel) Trit {
        return switch (self) {
            .read_only => .minus, // observe only
            .read_write => .plus, // can mutate
            .full => .zero, // coordinator: all methods, ergodic
        };
    }

    pub fn fromString(s: []const u8) ?AccessLevel {
        if (std.mem.eql(u8, s, "read-only") or std.mem.eql(u8, s, "read_only")) return .read_only;
        if (std.mem.eql(u8, s, "read-write") or std.mem.eql(u8, s, "read_write")) return .read_write;
        if (std.mem.eql(u8, s, "full")) return .full;
        return null;
    }
};

/// OpenShell enforcement mode → trit mapping.
/// enforce = +1 (active), audit = 0 (passive/logging), off = -1 (withdrawn)
pub const EnforcementMode = enum {
    enforce,
    audit,
    off,

    pub fn toTrit(self: EnforcementMode) Trit {
        return switch (self) {
            .enforce => .plus,
            .audit => .zero,
            .off => .minus,
        };
    }
};

/// OpenShell TLS mode → trit mapping.
/// terminate = +1 (MITM L7 inspection), passthrough = 0 (tunnel), none = -1 (plaintext)
pub const TlsMode = enum {
    terminate,
    passthrough,
    none,

    pub fn toTrit(self: TlsMode) Trit {
        return switch (self) {
            .terminate => .plus,
            .passthrough => .zero,
            .none => .minus,
        };
    }
};

/// An OpenShell network policy endpoint mapped to GF(3) trit space.
/// Three trits: access × enforcement × tls = one step in the trajectory.
pub const PolicyEndpoint = struct {
    host: []const u8,
    port: u16,
    access: AccessLevel,
    enforcement: EnforcementMode,
    tls: TlsMode,

    /// The endpoint's trit signature: access_trit.
    /// For trajectory construction, each endpoint access becomes one trit in the agent's history.
    pub fn accessTrit(self: PolicyEndpoint) Trit {
        return self.access.toTrit();
    }

    /// Full 3-trit word for this endpoint: (access, enforcement, tls).
    /// Conservation: access + enforcement + tls = 0 iff the endpoint is "self-balancing".
    pub fn tritWord(self: PolicyEndpoint) [3]Trit {
        return .{ self.access.toTrit(), self.enforcement.toTrit(), self.tls.toTrit() };
    }

    /// Is this endpoint self-balancing in GF(3)?
    pub fn isBalanced(self: PolicyEndpoint) bool {
        const tw = self.tritWord();
        return Trit.add(Trit.add(tw[0], tw[1]), tw[2]) == .zero;
    }
};

/// Map a sequence of OpenShell policy endpoint accesses into a TritTrajectory.
/// Each endpoint access becomes one trit (its access level).
/// This is the agent's "policy history" — the fiber of all access patterns
/// that arrive at the current state.
pub fn policyToTrajectory(endpoints: []const PolicyEndpoint, buf: []Trit) TritTrajectory {
    const len = @min(endpoints.len, buf.len);
    for (0..len) |i| {
        buf[i] = endpoints[i].accessTrit();
    }
    return .{ .trits = buf[0..len], .len = len };
}

/// Evaluate an OpenShell-style policy request through the retrodiction gate.
/// Maps: DenialEvent(host, port, binary, access) → GrantRequest → GateResult.
pub fn evaluatePolicyRequest(
    history: []const PolicyEndpoint,
    proposed: PolicyEndpoint,
    fiber: ?*const Fiber,
    difficulty_threshold: f64,
    trit_buf: []Trit,
) GateResult {
    const traj = policyToTrajectory(history, trit_buf);
    const tw = proposed.tritWord();
    return retrodictionGate(.{
        .agent_trajectory = traj,
        .cap_role = tw[0], // access level
        .cap_mode = tw[1], // enforcement mode
        .cap_polarity = tw[2], // TLS mode
    }, fiber, difficulty_threshold);
}

// =============================================================================
// Tests
// =============================================================================

test "TritTrajectory conservation" {
    const trits = [_]Trit{ .plus, .minus, .zero };
    const traj = TritTrajectory{ .trits = &trits, .len = 3 };
    try std.testing.expect(traj.isConserving());
    try std.testing.expectEqual(Trit.zero, traj.terminal().?);
}

test "TritTrajectory non-conserving" {
    const trits = [_]Trit{ .plus, .plus, .zero };
    const traj = TritTrajectory{ .trits = &trits, .len = 3 };
    try std.testing.expect(!traj.isConserving());
}

test "TritTrajectory p-adic depth" {
    const trits = [_]Trit{ .minus, .zero, .plus, .plus, .plus };
    const traj = TritTrajectory{ .trits = &trits, .len = 5 };
    try std.testing.expectEqual(@as(u32, 3), traj.padicDepth());
}

test "TritTrajectory p-adic depth single" {
    const trits = [_]Trit{.zero};
    const traj = TritTrajectory{ .trits = &trits, .len = 1 };
    try std.testing.expectEqual(@as(u32, 1), traj.padicDepth());
}

test "Fiber invariants" {
    const allocator = std.testing.allocator;
    var fiber = Fiber.init(allocator, .zero);
    defer fiber.deinit();

    const t1 = [_]Trit{ .plus, .minus, .zero };
    const t2 = [_]Trit{ .minus, .plus, .zero };
    const t3 = [_]Trit{ .zero, .zero, .zero };

    try fiber.addTrajectory(.{ .trits = &t1, .len = 3 });
    try fiber.addTrajectory(.{ .trits = &t2, .len = 3 });
    try fiber.addTrajectory(.{ .trits = &t3, .len = 3 });

    try std.testing.expectEqual(@as(usize, 3), fiber.mult());
    try std.testing.expectEqual(@as(usize, 3), fiber.conservingCount());
    try std.testing.expect(fiber.entropy() > 0.0);
    try std.testing.expect(fiber.fundamentalGroupProxy() > 0);
    try std.testing.expect(fiber.wassersteinDiameter() >= 0.0);
}

test "RetroCell lattice merge" {
    const merge = retroMerge(f32);
    const nothing = RetroCell(f32){ .nothing = {} };
    const v1 = RetroCell(f32){ .value = 1.0 };
    const v2 = RetroCell(f32){ .value = 2.0 };

    try std.testing.expectEqual(v1, merge(nothing, v1));
    try std.testing.expectEqual(v1, merge(v1, nothing));
    try std.testing.expectEqual(v1, merge(v1, v1));
    try std.testing.expect(merge(v1, v2).isContradiction());
}

test "TransferOperator accumulate and normalize" {
    const allocator = std.testing.allocator;
    var fiber = Fiber.init(allocator, .zero);
    defer fiber.deinit();

    const t1 = [_]Trit{ .plus, .minus, .zero };
    const t2 = [_]Trit{ .zero, .plus, .zero };
    try fiber.addTrajectory(.{ .trits = &t1, .len = 3 });
    try fiber.addTrajectory(.{ .trits = &t2, .len = 3 });

    var L = TransferOperator.init();
    L.accumulate(&fiber);
    L.normalize();

    for (L.matrix) |row| {
        var sum: f64 = 0;
        for (row) |v| sum += v;
        if (sum > 0) {
            try std.testing.expectApproxEqAbs(@as(f64, 1.0), sum, 0.001);
        }
    }
}

test "decoherence functional" {
    const t1 = [_]Trit{ .zero, .zero, .zero };
    const t2 = [_]Trit{ .zero, .zero, .zero };
    try std.testing.expect(areDecoherent(
        .{ .trits = &t1, .len = 3 },
        .{ .trits = &t2, .len = 3 },
    ));

    // +1,+1,+1 vs +1,+1,+1: D = 1+1+1 = 0 (mod 3) -> decoherent
    const t3 = [_]Trit{ .plus, .plus, .plus };
    const t4 = [_]Trit{ .plus, .plus, .plus };
    try std.testing.expect(areDecoherent(
        .{ .trits = &t3, .len = 3 },
        .{ .trits = &t4, .len = 3 },
    ));
}

test "decoherence functional non-decoherent" {
    // +1,0,0 vs +1,0,0: D = 1+0+0 = +1 -> NOT decoherent
    const t1 = [_]Trit{ .plus, .zero, .zero };
    const t2 = [_]Trit{ .plus, .zero, .zero };
    try std.testing.expect(!areDecoherent(
        .{ .trits = &t1, .len = 3 },
        .{ .trits = &t2, .len = 3 },
    ));
}

test "retrodiction summary" {
    const allocator = std.testing.allocator;
    var fiber = Fiber.init(allocator, .plus);
    defer fiber.deinit();

    const t1 = [_]Trit{ .minus, .zero, .plus };
    const t2 = [_]Trit{ .zero, .minus, .plus };
    try fiber.addTrajectory(.{ .trits = &t1, .len = 3 });
    try fiber.addTrajectory(.{ .trits = &t2, .len = 3 });

    var L = TransferOperator.init();
    L.accumulate(&fiber);
    L.normalize();

    const summary = summarize(&fiber, &L);
    try std.testing.expectEqual(Trit.plus, summary.terminal);
    try std.testing.expectEqual(@as(usize, 2), summary.fiber_cardinality);
    try std.testing.expect(summary.trit_entropy > 0.0);
    try std.testing.expect(summary.spectral_gap >= 0.0);
    try std.testing.expect(summary.spectral_gap <= 1.0);
}

test "GF(9) Frobenius involution" {
    const n = Nonet{ .real = .plus, .imag = .minus };
    const f1 = n.frobenius();
    const f2 = f1.frobenius();
    // Frobenius² = id on GF(9)
    try std.testing.expectEqual(n.real, f2.real);
    try std.testing.expectEqual(n.imag, f2.imag);
}

test "GF(27) Frobenius order 3" {
    const t = Tribble{ .a = .plus, .b = .minus, .c = .zero };
    const f3 = t.frobenius().frobenius().frobenius();
    try std.testing.expectEqual(t.a, f3.a);
    try std.testing.expectEqual(t.b, f3.b);
    try std.testing.expectEqual(t.c, f3.c);
}

test "tower conservation balanced" {
    const trits = [_]Trit{ .plus, .zero, .minus };
    const result = verifyTowerConservation(&trits);
    try std.testing.expect(result.base);
    try std.testing.expect(result.coherent);
}

test "tower conservation unbalanced coherent" {
    // +,+ sums to -1 in GF(3) (1+1=2≡-1)
    const trits = [_]Trit{ .plus, .plus };
    const result = verifyTowerConservation(&trits);
    try std.testing.expect(!result.base);
    try std.testing.expect(result.coherent); // all levels agree: unbalanced
}

test "tower classify levels" {
    const trits = [_]Trit{ .plus, .zero, .minus, .plus, .plus, .plus };
    try std.testing.expectEqual(TowerLevel.gf3, towerClassify(&trits, 0));
    try std.testing.expectEqual(TowerLevel.gf9, towerClassify(&trits, 4));
    try std.testing.expectEqual(TowerLevel.gf27, towerClassify(&trits, 5));
}

test "RetroSummaryCell merge join" {
    var cell = RetroSummaryCell.init("test_cell");

    const s1 = RetrodictionSummary{
        .terminal = .plus,
        .fiber_cardinality = 3,
        .conserving_count = 2,
        .trit_entropy = 0.8,
        .fundamental_group_proxy = 4,
        .wasserstein_diameter = 0.5,
        .min_padic_depth = 2,
        .retrodiction_difficulty = 0.2,
        .spectral_gap = 0.7,
    };
    cell.merge(s1);
    try std.testing.expect(cell.getSummary() != null);
    try std.testing.expectEqual(@as(usize, 3), cell.getSummary().?.fiber_cardinality);

    // Merge richer summary with same terminal -> join
    const s2 = RetrodictionSummary{
        .terminal = .plus,
        .fiber_cardinality = 5,
        .conserving_count = 4,
        .trit_entropy = 0.9,
        .fundamental_group_proxy = 6,
        .wasserstein_diameter = 0.8,
        .min_padic_depth = 1,
        .retrodiction_difficulty = 0.5,
        .spectral_gap = 0.4,
    };
    cell.merge(s2);
    const joined = cell.getSummary().?;
    try std.testing.expectEqual(@as(usize, 5), joined.fiber_cardinality); // max
    try std.testing.expectEqual(@as(u32, 1), joined.min_padic_depth); // min
    try std.testing.expectApproxEqAbs(@as(f64, 0.4), joined.spectral_gap, 0.001); // min
}

test "RetroSummaryCell contradiction on different terminals" {
    var cell = RetroSummaryCell.init("contra");
    cell.merge(.{
        .terminal = .plus,
        .fiber_cardinality = 1,
        .conserving_count = 1,
        .trit_entropy = 0.0,
        .fundamental_group_proxy = 0,
        .wasserstein_diameter = 0.0,
        .min_padic_depth = 1,
        .retrodiction_difficulty = 0.0,
        .spectral_gap = 1.0,
    });
    cell.merge(.{
        .terminal = .minus, // different!
        .fiber_cardinality = 1,
        .conserving_count = 1,
        .trit_entropy = 0.0,
        .fundamental_group_proxy = 0,
        .wasserstein_diameter = 0.0,
        .min_padic_depth = 1,
        .retrodiction_difficulty = 0.0,
        .spectral_gap = 1.0,
    });
    try std.testing.expect(cell.content.isContradiction());
}

test "tower profile" {
    const allocator = std.testing.allocator;
    var fiber = Fiber.init(allocator, .plus);
    defer fiber.deinit();

    const t1 = [_]Trit{ .plus, .minus, .plus }; // all distinct neighbors -> gf3
    const t2 = [_]Trit{ .plus, .plus, .plus }; // triple run -> gf27
    try fiber.addTrajectory(.{ .trits = &t1, .len = 3 });
    try fiber.addTrajectory(.{ .trits = &t2, .len = 3 });

    const profile = towerProfile(&fiber);
    try std.testing.expect(profile.gf3_count > 0);
    try std.testing.expect(profile.gf27_count > 0);
    try std.testing.expect(profile.extensionFraction() > 0.0);
}

test "decoherence classes" {
    const allocator = std.testing.allocator;
    var fiber = Fiber.init(allocator, .zero);
    defer fiber.deinit();

    // All-zero trajectories are trivially decoherent with each other
    const t1 = [_]Trit{ .zero, .zero, .zero };
    const t2 = [_]Trit{ .zero, .zero, .zero };
    try fiber.addTrajectory(.{ .trits = &t1, .len = 3 });
    try fiber.addTrajectory(.{ .trits = &t2, .len = 3 });

    const classes = try decoherenceClasses(&fiber, allocator);
    try std.testing.expectEqual(@as(u32, 1), classes); // one class (all decoherent)
}

test "retrodiction gate approve: balanced cap on conserving trajectory" {
    // Trajectory: +1, -1, 0 (conserving, sum=0)
    const trits = [_]Trit{ .plus, .minus, .zero };
    const result = retrodictionGate(.{
        .agent_trajectory = .{ .trits = &trits, .len = 3 },
        .cap_role = .plus, // generate
        .cap_mode = .minus, // filter
        .cap_polarity = .zero, // -(+1 + -1) = 0 -> balanced
    }, null, 0.0);

    try std.testing.expectEqual(GrantDecision.approve, result.decision);
    try std.testing.expect(result.trajectory_conserving);
    try std.testing.expect(result.capability_balanced);
}

test "retrodiction gate deny: unbalanced capability" {
    const trits = [_]Trit{ .plus, .minus, .zero };
    const result = retrodictionGate(.{
        .agent_trajectory = .{ .trits = &trits, .len = 3 },
        .cap_role = .plus,
        .cap_mode = .plus,
        .cap_polarity = .plus, // +1+1+1 = 0 mod 3... actually balanced!
    }, null, 0.0);
    // All plus: 1+1+1 = 3 = 0 mod 3, so balanced. Let's make an actually unbalanced one:
    const result2 = retrodictionGate(.{
        .agent_trajectory = .{ .trits = &trits, .len = 3 },
        .cap_role = .plus,
        .cap_mode = .plus,
        .cap_polarity = .minus, // +1+1-1 = 1 != 0 -> unbalanced
    }, null, 0.0);
    try std.testing.expectEqual(GrantDecision.deny, result2.decision);
    try std.testing.expect(!result2.capability_balanced);
    _ = result;
}

test "retrodiction gate deny: non-conserving trajectory" {
    // Trajectory: +1, +1, 0 (sum = -1, not conserving)
    const trits = [_]Trit{ .plus, .plus, .zero };
    const result = retrodictionGate(.{
        .agent_trajectory = .{ .trits = &trits, .len = 3 },
        .cap_role = .zero,
        .cap_mode = .zero,
        .cap_polarity = .zero,
    }, null, 0.0);
    try std.testing.expectEqual(GrantDecision.deny, result.decision);
    try std.testing.expect(!result.trajectory_conserving);
}

test "retrodiction gate tower level detection" {
    // Trajectory ending in +1,+1 -> extending with +1 = triple run = gf27
    const trits = [_]Trit{ .minus, .plus, .plus };
    const result = retrodictionGate(.{
        .agent_trajectory = .{ .trits = &trits, .len = 3 },
        .cap_role = .plus, // same as last two -> triple run
        .cap_mode = .zero,
        .cap_polarity = .minus,
    }, null, 0.0);
    try std.testing.expectEqual(TowerLevel.gf27, result.tower_level);
}

test "retrodiction gate with fiber: contradict on zero conserving ratio" {
    const allocator = std.testing.allocator;
    var fiber = Fiber.init(allocator, .plus);
    defer fiber.deinit();

    // Add only non-conserving trajectories
    const t1 = [_]Trit{ .plus, .plus, .plus }; // sum = 0 mod 3, actually conserving
    const t2 = [_]Trit{ .plus, .plus, .zero }; // sum = -1, not conserving
    const t3 = [_]Trit{ .plus, .zero, .zero }; // sum = +1, not conserving
    try fiber.addTrajectory(.{ .trits = &t2, .len = 3 });
    try fiber.addTrajectory(.{ .trits = &t3, .len = 3 });

    const trits = [_]Trit{ .plus, .minus, .zero };
    const result = retrodictionGate(.{
        .agent_trajectory = .{ .trits = &trits, .len = 3 },
        .cap_role = .zero,
        .cap_mode = .zero,
        .cap_polarity = .zero,
    }, &fiber, 0.0);
    try std.testing.expectEqual(GrantDecision.contradict, result.decision);
    _ = t1;
}

test "OpenShell bridge: PolicyEndpoint trit mapping" {
    const ep_ro = PolicyEndpoint{
        .host = "docs.example.com",
        .port = 443,
        .access = .read_only,
        .enforcement = .enforce,
        .tls = .passthrough,
    };
    try std.testing.expectEqual(Trit.minus, ep_ro.accessTrit());
    // read_only(-1) + enforce(+1) + passthrough(0) = 0 -> balanced
    try std.testing.expect(ep_ro.isBalanced());

    const ep_rw = PolicyEndpoint{
        .host = "api.example.com",
        .port = 443,
        .access = .read_write,
        .enforcement = .enforce,
        .tls = .terminate,
    };
    // read_write(+1) + enforce(+1) + terminate(+1) = 3 = 0 mod 3 -> balanced
    try std.testing.expect(ep_rw.isBalanced());

    const ep_unbal = PolicyEndpoint{
        .host = "bad.example.com",
        .port = 80,
        .access = .read_write,
        .enforcement = .audit,
        .tls = .none,
    };
    // read_write(+1) + audit(0) + none(-1) = 0 -> actually balanced too!
    try std.testing.expect(ep_unbal.isBalanced());
}

test "OpenShell bridge: policy trajectory conservation" {
    // Simulate agent accessing: read_only, read_write, full -> trits: -1, +1, 0 -> conserving
    const endpoints = [_]PolicyEndpoint{
        .{ .host = "docs.api.com", .port = 443, .access = .read_only, .enforcement = .enforce, .tls = .passthrough },
        .{ .host = "api.github.com", .port = 443, .access = .read_write, .enforcement = .enforce, .tls = .terminate },
        .{ .host = "registry.npmjs.org", .port = 443, .access = .full, .enforcement = .audit, .tls = .passthrough },
    };
    var buf: [16]Trit = undefined;
    const traj = policyToTrajectory(&endpoints, &buf);
    try std.testing.expect(traj.isConserving()); // -1 + 1 + 0 = 0
}

test "OpenShell bridge: evaluatePolicyRequest approve" {
    // History: read_only, read_write, full (conserving)
    const history = [_]PolicyEndpoint{
        .{ .host = "a", .port = 443, .access = .read_only, .enforcement = .enforce, .tls = .passthrough },
        .{ .host = "b", .port = 443, .access = .read_write, .enforcement = .enforce, .tls = .terminate },
        .{ .host = "c", .port = 443, .access = .full, .enforcement = .audit, .tls = .passthrough },
    };
    // Proposed: balanced endpoint
    const proposed = PolicyEndpoint{
        .host = "new.api.com",
        .port = 443,
        .access = .read_only, // -1
        .enforcement = .enforce, // +1
        .tls = .passthrough, // 0
    };
    var buf: [16]Trit = undefined;
    const result = evaluatePolicyRequest(&history, proposed, null, 0.0, &buf);
    try std.testing.expectEqual(GrantDecision.approve, result.decision);
    try std.testing.expect(result.capability_balanced);
}

test "OpenShell bridge: evaluatePolicyRequest deny unbalanced" {
    const history = [_]PolicyEndpoint{
        .{ .host = "a", .port = 443, .access = .read_only, .enforcement = .enforce, .tls = .passthrough },
        .{ .host = "b", .port = 443, .access = .read_write, .enforcement = .enforce, .tls = .terminate },
        .{ .host = "c", .port = 443, .access = .full, .enforcement = .audit, .tls = .passthrough },
    };
    // Proposed: unbalanced endpoint (rw + enforce + none = +1+1-1 = +1 != 0)
    const proposed = PolicyEndpoint{
        .host = "danger.com",
        .port = 80,
        .access = .read_write, // +1
        .enforcement = .enforce, // +1
        .tls = .none, // -1 -> sum = +1, unbalanced
    };
    var buf: [16]Trit = undefined;
    const result = evaluatePolicyRequest(&history, proposed, null, 0.0, &buf);
    try std.testing.expectEqual(GrantDecision.deny, result.decision);
    try std.testing.expect(!result.capability_balanced);
}
