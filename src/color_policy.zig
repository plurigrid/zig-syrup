//! Tabular Color Policy (Option C: REINFORCE substrate)
//!
//! A simple policy table: one entry per (operation × depth) pair.
//! Each entry stores action probabilities for color assignment.
//! The policy is updated via REINFORCE with baseline subtraction.
//!
//! The terminal IS the MDP environment:
//!   State  = current sexp node being rendered + history
//!   Action = color assignment {trit_choice, hue_offset, chroma, lightness}
//!   Obs    = OSC query response (terminal's actual rendered color)
//!   Reward = perceptual quality score

const std = @import("std");
const lux = @import("lux_color");
const llm = @import("llamafile_reward");
const Trit = lux.Trit;

const MAX_OPERATIONS: usize = 16;
const MAX_DEPTH: usize = 16;
const NUM_ACTIONS: usize = 9; // 3 trits × 3 hue offsets

// ============================================================================
// SplitMix64
// ============================================================================

const Rng = struct {
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
// Action: what the policy outputs
// ============================================================================

pub const ColorAction = struct {
    trit: Trit,
    hue_offset: i8,    // -1, 0, +1 (× golden angle)
    chroma_scale: f32,  // 0.5 .. 1.5
    lightness_scale: f32, // 0.5 .. 1.5

    pub fn fromIndex(idx: usize) ColorAction {
        const trit_idx = idx / 3;
        const hue_idx = idx % 3;
        return .{
            .trit = switch (trit_idx) { 0 => .minus, 1 => .ergodic, else => .plus },
            .hue_offset = @as(i8, @intCast(hue_idx)) - 1,
            .chroma_scale = 1.0,
            .lightness_scale = 1.0,
        };
    }

    pub fn toIndex(self: ColorAction) usize {
        const t: usize = switch (self.trit) { .minus => 0, .ergodic => 1, .plus => 2 };
        const h: usize = @intCast(@as(i16, self.hue_offset) + 1);
        return t * 3 + h;
    }
};

// ============================================================================
// Reward function components
// ============================================================================

pub const RewardComponents = struct {
    harmony: f32,        // CIEDE2000-like perceptual distance to target palette
    semantic: f32,       // similar ops → similar colors
    conservation: f32,   // GF(3) trit-sum bonus
    distinguishability: f32, // adjacent depths are perceptually distinct

    pub fn total(self: RewardComponents) f32 {
        return self.harmony * 0.3 + self.semantic * 0.3 +
            self.conservation * 0.2 + self.distinguishability * 0.2;
    }
};

// ============================================================================
// Policy Table
// ============================================================================

pub const PolicyTable = struct {
    // logits[op][depth][action]
    logits: [MAX_OPERATIONS][MAX_DEPTH][NUM_ACTIONS]f32,
    baseline: f32, // running average reward for variance reduction
    n_ops: usize,
    n_depths: usize,

    pub fn init(n_ops: usize, n_depths: usize) PolicyTable {
        var pt: PolicyTable = undefined;
        pt.n_ops = @min(n_ops, MAX_OPERATIONS);
        pt.n_depths = @min(n_depths, MAX_DEPTH);
        pt.baseline = 0;
        for (0..MAX_OPERATIONS) |o| {
            for (0..MAX_DEPTH) |d| {
                for (0..NUM_ACTIONS) |a| {
                    pt.logits[o][d][a] = 0; // uniform
                }
            }
        }
        return pt;
    }

    pub fn actionProbs(self: *const PolicyTable, op: usize, depth: usize) [NUM_ACTIONS]f32 {
        const o = @min(op, MAX_OPERATIONS - 1);
        const d = @min(depth, MAX_DEPTH - 1);
        // Softmax over logits
        var max_l: f32 = self.logits[o][d][0];
        for (1..NUM_ACTIONS) |a| {
            if (self.logits[o][d][a] > max_l) max_l = self.logits[o][d][a];
        }
        var probs: [NUM_ACTIONS]f32 = undefined;
        var sum: f32 = 0;
        for (0..NUM_ACTIONS) |a| {
            probs[a] = @exp(self.logits[o][d][a] - max_l);
            sum += probs[a];
        }
        for (0..NUM_ACTIONS) |a| {
            probs[a] /= sum;
        }
        return probs;
    }

    pub fn sampleAction(self: *const PolicyTable, op: usize, depth: usize, rng: *Rng) ColorAction {
        const probs = self.actionProbs(op, depth);
        var u = rng.uniform01();
        for (0..NUM_ACTIONS) |a| {
            u -= probs[a];
            if (u <= 0) return ColorAction.fromIndex(a);
        }
        return ColorAction.fromIndex(NUM_ACTIONS - 1);
    }

    // REINFORCE update with baseline subtraction
    pub fn update(
        self: *PolicyTable,
        op: usize,
        depth: usize,
        action_idx: usize,
        reward: f32,
        lr: f32,
    ) void {
        const o = @min(op, MAX_OPERATIONS - 1);
        const d = @min(depth, MAX_DEPTH - 1);
        const advantage = reward - self.baseline;

        const probs = self.actionProbs(op, depth);
        for (0..NUM_ACTIONS) |a| {
            const indicator: f32 = if (a == action_idx) 1.0 else 0.0;
            // ∇ log π(a|s) = indicator - π(a|s) for softmax policy
            self.logits[o][d][a] += lr * advantage * (indicator - probs[a]);
        }

        // Update baseline (exponential moving average)
        self.baseline = 0.99 * self.baseline + 0.01 * reward;
    }
};

// ============================================================================
// Episode Rollout
// ============================================================================

pub const Transition = struct {
    op: usize,
    depth: usize,
    action: ColorAction,
    action_idx: usize,
    reward: RewardComponents,
};

pub const Rollout = struct {
    transitions: [256]Transition,
    count: usize,

    pub fn init() Rollout {
        return .{ .transitions = undefined, .count = 0 };
    }

    pub fn push(self: *Rollout, t: Transition) void {
        if (self.count < 256) {
            self.transitions[self.count] = t;
            self.count += 1;
        }
    }

    pub fn totalReward(self: *const Rollout) f32 {
        var total: f32 = 0;
        for (0..self.count) |i| {
            total += self.transitions[i].reward.total();
        }
        return total;
    }
};

// Apply REINFORCE update from a completed rollout
pub fn reinforceUpdate(policy: *PolicyTable, rollout: *const Rollout, lr: f32) void {
    const total_r = rollout.totalReward();
    for (0..rollout.count) |i| {
        const t = rollout.transitions[i];
        policy.update(t.op, t.depth, t.action_idx, total_r, lr);
    }
}

// ============================================================================
// LLM-Blended REINFORCE (llamafile integration)
// ============================================================================

pub const LlmConfig = struct {
    client: llm.Client,
    llm_weight: f32, // 0.0 = pure hardcoded, 1.0 = pure LLM
    op_names: []const []const u8, // human-readable names for palette entries

    pub fn init(op_names: []const []const u8) LlmConfig {
        return .{
            .client = llm.Client.initDefault(),
            .llm_weight = 0.3,
            .op_names = op_names,
        };
    }

    pub fn withWeight(self: LlmConfig, w: f32) LlmConfig {
        var copy = self;
        copy.llm_weight = w;
        return copy;
    }
};

const GOLDEN_ANGLE: f32 = 137.508;

fn tritToRgb(trit: Trit, hue_offset: i8) lux.RGB {
    const base_hue: f32 = switch (trit) {
        .minus => 240.0,   // blue
        .ergodic => 120.0, // green
        .plus => 0.0,      // red
    };
    const hue = @mod(base_hue + @as(f32, @floatFromInt(hue_offset)) * GOLDEN_ANGLE, 360.0);
    // Simple HSL→RGB (S=0.7, L=0.55)
    const c: f32 = 0.63; // (1 - |2*0.55 - 1|) * 0.7
    const h_prime = hue / 60.0;
    const x = c * (1.0 - @abs(@mod(h_prime, 2.0) - 1.0));
    const m: f32 = 0.55 - c / 2.0;
    var r1: f32 = 0;
    var g1: f32 = 0;
    var b1: f32 = 0;
    if (h_prime < 1) {
        r1 = c; g1 = x;
    } else if (h_prime < 2) {
        r1 = x; g1 = c;
    } else if (h_prime < 3) {
        g1 = c; b1 = x;
    } else if (h_prime < 4) {
        g1 = x; b1 = c;
    } else if (h_prime < 5) {
        r1 = x; b1 = c;
    } else {
        r1 = c; b1 = x;
    }
    return .{
        .r = @intFromFloat(@min(255.0, @max(0.0, (r1 + m) * 255.0))),
        .g = @intFromFloat(@min(255.0, @max(0.0, (g1 + m) * 255.0))),
        .b = @intFromFloat(@min(255.0, @max(0.0, (b1 + m) * 255.0))),
    };
}

/// Convert rollout transitions to palette entries for LLM scoring
pub fn rolloutToPalette(
    rollout: *const Rollout,
    op_names: []const []const u8,
    buf: []llm.PaletteEntry,
) []llm.PaletteEntry {
    const n = @min(rollout.count, @min(buf.len, op_names.len));
    for (0..n) |i| {
        const t = rollout.transitions[i];
        buf[i] = .{
            .op_name = if (t.op < op_names.len) op_names[t.op] else "unknown",
            .trit = t.action.trit,
            .color = tritToRgb(t.action.trit, t.action.hue_offset),
        };
    }
    return buf[0..n];
}

/// REINFORCE update with LLM-blended reward.
/// Falls back to pure hardcoded if llamafile is unreachable.
pub fn blendedReinforceUpdate(
    policy: *PolicyTable,
    rollout: *const Rollout,
    lr: f32,
    config: *const LlmConfig,
    allocator: std.mem.Allocator,
) void {
    const hardcoded_r = rollout.totalReward();

    // Build palette for LLM scoring
    var palette_buf: [256]llm.PaletteEntry = undefined;
    const entries = rolloutToPalette(rollout, config.op_names, &palette_buf);

    const reward = llm.blendedScore(
        &config.client,
        allocator,
        entries,
        hardcoded_r,
        config.llm_weight,
    );
    const total_r = reward.total();

    for (0..rollout.count) |i| {
        const t = rollout.transitions[i];
        policy.update(t.op, t.depth, t.action_idx, total_r, lr);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "action roundtrip" {
    for (0..NUM_ACTIONS) |i| {
        const a = ColorAction.fromIndex(i);
        try std.testing.expectEqual(i, a.toIndex());
    }
}

test "policy table uniform probs" {
    const pt = PolicyTable.init(4, 8);
    const probs = pt.actionProbs(0, 0);
    const expected = 1.0 / @as(f32, @floatFromInt(NUM_ACTIONS));
    for (probs) |p| {
        try std.testing.expect(@abs(p - expected) < 0.01);
    }
}

test "sample action produces valid action" {
    const pt = PolicyTable.init(4, 8);
    var rng = Rng.init(1069);
    const action = pt.sampleAction(0, 0, &rng);
    _ = action;
}

test "update shifts probability" {
    var pt = PolicyTable.init(4, 8);
    const before = pt.actionProbs(0, 0);
    for (0..100) |_| {
        pt.update(0, 0, 0, 1.0, 0.1); // always reward action 0
    }
    const after = pt.actionProbs(0, 0);
    try std.testing.expect(after[0] > before[0]);
}

test "rollout accumulates reward" {
    var rollout = Rollout.init();
    rollout.push(.{
        .op = 0, .depth = 0,
        .action = ColorAction.fromIndex(0),
        .action_idx = 0,
        .reward = .{ .harmony = 0.5, .semantic = 0.5, .conservation = 0.5, .distinguishability = 0.5 },
    });
    try std.testing.expect(rollout.totalReward() > 0.4);
}

test "trit to RGB produces valid colors" {
    const rgb_m = tritToRgb(.minus, 0);
    const rgb_e = tritToRgb(.ergodic, 0);
    const rgb_p = tritToRgb(.plus, 0);
    // Minus = blue channel dominant
    try std.testing.expect(rgb_m.b > rgb_m.r);
    // Ergodic = green channel dominant
    try std.testing.expect(rgb_e.g > rgb_e.b);
    // Plus = red channel dominant
    try std.testing.expect(rgb_p.r > rgb_p.b);
}

test "rollout to palette conversion" {
    var rollout = Rollout.init();
    rollout.push(.{
        .op = 0, .depth = 0,
        .action = ColorAction.fromIndex(0), // minus, hue -1
        .action_idx = 0,
        .reward = .{ .harmony = 1, .semantic = 1, .conservation = 1, .distinguishability = 1 },
    });
    rollout.push(.{
        .op = 1, .depth = 1,
        .action = ColorAction.fromIndex(8), // plus, hue +1
        .action_idx = 8,
        .reward = .{ .harmony = 1, .semantic = 1, .conservation = 1, .distinguishability = 1 },
    });
    const names = [_][]const u8{ "lambda", "apply", "quote" };
    var buf: [256]llm.PaletteEntry = undefined;
    const entries = rolloutToPalette(&rollout, &names, &buf);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("lambda", entries[0].op_name);
    try std.testing.expectEqualStrings("apply", entries[1].op_name);
    try std.testing.expect(entries[0].trit == .minus);
    try std.testing.expect(entries[1].trit == .plus);
}

test "blended reinforce update without server" {
    var pt = PolicyTable.init(4, 8);
    var rollout = Rollout.init();
    rollout.push(.{
        .op = 0, .depth = 0,
        .action = ColorAction.fromIndex(0),
        .action_idx = 0,
        .reward = .{ .harmony = 1.0, .semantic = 1.0, .conservation = 1.0, .distinguishability = 1.0 },
    });
    const names = [_][]const u8{ "lambda", "apply" };
    const config = LlmConfig.init(&names);
    blendedReinforceUpdate(&pt, &rollout, 0.01, &config, std.testing.allocator);
    // Should still update (falls back to hardcoded since no server)
    try std.testing.expect(pt.baseline > 0);
}

test "reinforce update does not crash" {
    var pt = PolicyTable.init(4, 8);
    var rollout = Rollout.init();
    rollout.push(.{
        .op = 0, .depth = 0,
        .action = ColorAction.fromIndex(0),
        .action_idx = 0,
        .reward = .{ .harmony = 1.0, .semantic = 1.0, .conservation = 1.0, .distinguishability = 1.0 },
    });
    reinforceUpdate(&pt, &rollout, 0.01);
    try std.testing.expect(pt.baseline > 0);
}
