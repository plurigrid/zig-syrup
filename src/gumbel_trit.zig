//! Gumbel-Softmax Relaxation on Discrete Trit Space (Option B)
//!
//! Replaces the hard trit lookup with a differentiable soft trit:
//!   logits φ = {φ₋₁, φ₀, φ₊₁} per operation
//!   Gumbel-Softmax(φ, τ) → soft_trit ∈ Δ² (probability simplex)
//!   As τ → 0, soft_trit converges to hard trit (recovers exact GF(3))
//!
//! The key insight: OPERATION_TRITS in colored_parens.zig becomes learnable.
//! Instead of lookupTrit("compose") → .ergodic, we get
//! lookupSoftTrit("compose") → [0.1, 0.8, 0.1] — a distribution over trits.
//!
//! GF(3) conservation is soft during training (Lagrangian penalty) and
//! exact at convergence (τ → 0). This is the "carry-deferred" analog:
//! conservation is deferred during learning and restored at cooling.

const std = @import("std");
const lux = @import("lux_color");
const Trit = lux.Trit;

// ============================================================================
// SplitMix64 (consistent with set_game.zig, self_play_color.zig)
// ============================================================================

pub const Rng = struct {
    state: u64,

    fn init(seed: u64) Rng {
        return .{ .state = seed };
    }

    fn next(self: *Rng) u64 {
        self.state +%= 0x9E3779B97F4A7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        return z ^ (z >> 31);
    }

    fn uniform01(self: *Rng) f32 {
        return @as(f32, @floatFromInt(self.next() >> 40)) / @as(f32, @floatFromInt(@as(u64, 1) << 24));
    }
};

// ============================================================================
// Soft Trit: probability distribution over {minus, ergodic, plus}
// ============================================================================

pub const SoftTrit = struct {
    p: [3]f32, // [P(minus), P(ergodic), P(plus)], sums to 1.0

    pub fn fromHard(t: Trit) SoftTrit {
        return switch (t) {
            .minus => .{ .p = .{ 1.0, 0.0, 0.0 } },
            .ergodic => .{ .p = .{ 0.0, 1.0, 0.0 } },
            .plus => .{ .p = .{ 0.0, 0.0, 1.0 } },
        };
    }

    pub fn toHard(self: SoftTrit) Trit {
        if (self.p[0] >= self.p[1] and self.p[0] >= self.p[2]) return .minus;
        if (self.p[1] >= self.p[2]) return .ergodic;
        return .plus;
    }

    pub fn expectedValue(self: SoftTrit) f32 {
        // E[trit] = -1*p[0] + 0*p[1] + 1*p[2]
        return -self.p[0] + self.p[2];
    }

    pub fn entropy(self: SoftTrit) f32 {
        var h: f32 = 0;
        for (self.p) |pi| {
            if (pi > 1e-8) h -= pi * @log(pi);
        }
        return h;
    }
};

// ============================================================================
// Logit Table: learnable parameters for trit assignment
// ============================================================================

pub const MAX_OPS: usize = 16;

pub const LogitTable = struct {
    logits: [MAX_OPS][3]f32,
    count: usize,

    pub fn initUniform(n: usize) LogitTable {
        var tbl: LogitTable = undefined;
        tbl.count = @min(n, MAX_OPS);
        for (0..tbl.count) |i| {
            tbl.logits[i] = .{ 0.0, 0.0, 0.0 }; // uniform prior
        }
        return tbl;
    }

    pub fn initFromTrits(trits: []const Trit) LogitTable {
        var tbl: LogitTable = undefined;
        tbl.count = @min(trits.len, MAX_OPS);
        for (0..tbl.count) |i| {
            // Strong prior toward known trit (logit = 3.0 for correct, 0.0 for others)
            tbl.logits[i] = .{ 0.0, 0.0, 0.0 };
            switch (trits[i]) {
                .minus => tbl.logits[i][0] = 3.0,
                .ergodic => tbl.logits[i][1] = 3.0,
                .plus => tbl.logits[i][2] = 3.0,
            }
        }
        return tbl;
    }
};

// ============================================================================
// Gumbel-Softmax Sampling
// ============================================================================

fn gumbelNoise(rng: *Rng) f32 {
    // Gumbel(0,1) = -ln(-ln(U)), U ~ Uniform(0,1)
    const u = @max(rng.uniform01(), 1e-8);
    return -@log(-@log(u));
}

pub fn gumbelSoftmax(logits: [3]f32, temperature: f32, rng: *Rng) SoftTrit {
    var perturbed: [3]f32 = undefined;
    for (0..3) |i| {
        perturbed[i] = (logits[i] + gumbelNoise(rng)) / @max(temperature, 1e-6);
    }
    return softmax3(perturbed);
}

pub fn softmax3(x: [3]f32) SoftTrit {
    // Numerically stable softmax
    const max_val = @max(x[0], @max(x[1], x[2]));
    var exp_sum: f32 = 0;
    var result: SoftTrit = undefined;
    for (0..3) |i| {
        result.p[i] = @exp(x[i] - max_val);
        exp_sum += result.p[i];
    }
    for (0..3) |i| {
        result.p[i] /= exp_sum;
    }
    return result;
}

pub fn straightThroughHard(soft: SoftTrit) Trit {
    // Straight-through estimator: argmax in forward, gradient through soft in backward
    return soft.toHard();
}

// ============================================================================
// Temperature Schedule
// ============================================================================

pub const AnnealSchedule = struct {
    initial_temp: f32,
    final_temp: f32,
    decay_rate: f32,
    current_step: u32,

    pub fn init(initial: f32, final_val: f32, decay: f32) AnnealSchedule {
        return .{
            .initial_temp = initial,
            .final_temp = final_val,
            .decay_rate = decay,
            .current_step = 0,
        };
    }

    pub fn temperature(self: *const AnnealSchedule) f32 {
        const t = self.initial_temp * @exp(-self.decay_rate * @as(f32, @floatFromInt(self.current_step)));
        return @max(t, self.final_temp);
    }

    pub fn step(self: *AnnealSchedule) void {
        self.current_step += 1;
    }
};

// ============================================================================
// GF(3) Conservation Penalty
// ============================================================================

pub fn conservationPenalty(soft_trits: []const SoftTrit) f32 {
    // Soft conservation: sum of expected trit values should be ≈ 0 mod 3
    var total_ev: f32 = 0;
    for (soft_trits) |st| {
        total_ev += st.expectedValue();
    }
    // Penalty: distance to nearest multiple of 3
    const nearest_3 = @round(total_ev / 3.0) * 3.0;
    const diff = total_ev - nearest_3;
    return diff * diff;
}

// ============================================================================
// Training Step
// ============================================================================

pub const TrainState = struct {
    table: LogitTable,
    schedule: AnnealSchedule,
    rng: Rng,
    conservation_lambda: f32,
    step_count: u32,

    pub fn init(n_ops: usize, seed: u64) TrainState {
        return .{
            .table = LogitTable.initUniform(n_ops),
            .schedule = AnnealSchedule.init(1.0, 0.01, 0.005),
            .rng = Rng.init(seed),
            .conservation_lambda = 0.1,
            .step_count = 0,
        };
    }

    pub fn sample(self: *TrainState) [MAX_OPS]SoftTrit {
        var result: [MAX_OPS]SoftTrit = undefined;
        const temp = self.schedule.temperature();
        for (0..self.table.count) |i| {
            result[i] = gumbelSoftmax(self.table.logits[i], temp, &self.rng);
        }
        // Zero-fill unused
        for (self.table.count..MAX_OPS) |i| {
            result[i] = SoftTrit.fromHard(.ergodic);
        }
        return result;
    }

    pub fn updateLogits(self: *TrainState, reward: f32, sampled: []const SoftTrit, lr: f32) void {
        // Simple policy gradient on logits
        for (0..self.table.count) |i| {
            for (0..3) |j| {
                // Gradient: reward * (indicator - softmax_prob)
                // Approximated by: reward * softmax_prob * (1 - softmax_prob)
                const grad = reward * sampled[i].p[j] * (1.0 - sampled[i].p[j]);
                self.table.logits[i][j] += lr * grad;
            }
        }

        // Conservation penalty gradient
        const penalty = conservationPenalty(sampled[0..self.table.count]);
        if (penalty > 0.01) {
            for (0..self.table.count) |i| {
                // Push toward conservation
                const ev = sampled[i].expectedValue();
                _ = ev;
                self.table.logits[i][0] -= self.conservation_lambda * lr * penalty;
                self.table.logits[i][2] -= self.conservation_lambda * lr * penalty;
            }
        }

        self.schedule.step();
        self.step_count += 1;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "softmax3 sums to 1" {
    const result = softmax3(.{ 1.0, 2.0, 3.0 });
    const total = result.p[0] + result.p[1] + result.p[2];
    try std.testing.expect(@abs(total - 1.0) < 1e-5);
}

test "softmax3 monotonic" {
    const result = softmax3(.{ 1.0, 2.0, 3.0 });
    try std.testing.expect(result.p[2] > result.p[1]);
    try std.testing.expect(result.p[1] > result.p[0]);
}

test "gumbel softmax produces valid distribution" {
    var rng = Rng.init(1069);
    const result = gumbelSoftmax(.{ 0.0, 0.0, 0.0 }, 1.0, &rng);
    const total = result.p[0] + result.p[1] + result.p[2];
    try std.testing.expect(@abs(total - 1.0) < 1e-4);
}

test "low temperature concentrates mass" {
    var rng = Rng.init(42);
    const logits = [3]f32{ 3.0, 0.0, 0.0 };
    const result = gumbelSoftmax(logits, 0.01, &rng);
    try std.testing.expect(result.p[0] > 0.99);
}

test "hard trit roundtrip" {
    const soft = SoftTrit.fromHard(.plus);
    try std.testing.expectEqual(Trit.plus, soft.toHard());
}

test "conservation penalty zero for balanced trits" {
    const trits = [_]SoftTrit{
        SoftTrit.fromHard(.minus),
        SoftTrit.fromHard(.ergodic),
        SoftTrit.fromHard(.plus),
    };
    const penalty = conservationPenalty(&trits);
    try std.testing.expect(penalty < 1e-6);
}

test "conservation penalty nonzero for unbalanced" {
    // 2x plus + 1x ergodic → EV = 2.0, nearest multiple of 3 is 3.0, diff = -1.0, penalty = 1.0
    const trits = [_]SoftTrit{
        SoftTrit.fromHard(.plus),
        SoftTrit.fromHard(.plus),
        SoftTrit.fromHard(.ergodic),
    };
    const penalty = conservationPenalty(&trits);
    try std.testing.expect(penalty > 0.1);
}

test "anneal schedule cools down" {
    var sched = AnnealSchedule.init(1.0, 0.01, 0.1);
    const t0 = sched.temperature();
    for (0..100) |_| sched.step();
    const t100 = sched.temperature();
    try std.testing.expect(t100 < t0);
    try std.testing.expect(t100 >= 0.01);
}

test "train state samples and updates without crash" {
    var state = TrainState.init(4, 1069);
    var sampled = state.sample();
    state.updateLogits(1.0, &sampled, 0.01);
    try std.testing.expect(state.step_count == 1);
}

test "logit table from known trits" {
    const trits = [_]Trit{ .minus, .ergodic, .plus, .minus };
    const tbl = LogitTable.initFromTrits(&trits);
    try std.testing.expect(tbl.logits[0][0] > tbl.logits[0][1]); // minus has highest logit
    try std.testing.expect(tbl.logits[2][2] > tbl.logits[2][0]); // plus has highest logit
}

test "entropy maximal for uniform" {
    const uniform = SoftTrit{ .p = .{ 1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0 } };
    const h = uniform.entropy();
    try std.testing.expect(h > 1.09); // ln(3) ≈ 1.0986
}
