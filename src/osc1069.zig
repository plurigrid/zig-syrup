//! OSC 1069: Learnable Color Protocol Synthesis
//!
//! The three mutually exclusive options (A: Enzyme, B: Gumbel, C: REINFORCE)
//! unified under a single protocol envelope. The terminal becomes a first-class
//! participant in the learning loop.
//!
//! OSC 1069 ; action ; payload ST
//!   ?   → query: terminal reports seed 1069 color
//!   =   → assert: verify terminal matches expected
//!   ∇   → gradient: report observed-expected delta
//!   π   → policy: send policy params for evaluation
//!
//! This module wires together:
//!   osc_query.zig  — terminal communication
//!   gumbel_trit.zig — Option B learnable trits
//!   color_policy.zig — Option C REINFORCE policy
//!   lux_color.zig  — forward color pipeline (Option A substrate)

const std = @import("std");
const lux = @import("lux_color");
const osc = @import("osc_query");
const gumbel = @import("gumbel_trit");
const policy = @import("color_policy");

const Trit = lux.Trit;
const RGB = lux.RGB;
const OscColor = osc.OscColor;
const SoftTrit = gumbel.SoftTrit;
const ColorAction = policy.ColorAction;

pub const CANONICAL_SEED: u64 = 1069;

// ============================================================================
// Learning Option: exactly one of A/B/C
// ============================================================================

pub const LearningOption = enum(u2) {
    enzyme_reverse,     // A: continuous HCL params, exact gradient
    gumbel_softmax,     // B: discrete trit assignment, reparameterized gradient
    reinforce_osc,      // C: arbitrary policy, reward gradient over OSC
};

// ============================================================================
// Color Pipeline State
// ============================================================================

pub const PipelineState = struct {
    seed: u64,
    option: LearningOption,

    // Option A state: continuous parameters
    hue_offset: f32,
    chroma_scale: f32,
    lightness_scale: f32,

    // Option B state: Gumbel training
    gumbel_state: ?gumbel.TrainState,

    // Option C state: REINFORCE policy
    policy_table: ?policy.PolicyTable,

    // Observation buffer
    last_expected: OscColor,
    last_observed: OscColor,

    pub fn init(option: LearningOption, seed: u64) PipelineState {
        return .{
            .seed = seed,
            .option = option,
            .hue_offset = 0,
            .chroma_scale = 1.0,
            .lightness_scale = 1.0,
            .gumbel_state = if (option == .gumbel_softmax) gumbel.TrainState.init(12, seed) else null,
            .policy_table = if (option == .reinforce_osc) policy.PolicyTable.init(12, 16) else null,
            .last_expected = .{ .r = 0, .g = 0, .b = 0 },
            .last_observed = .{ .r = 0, .g = 0, .b = 0 },
        };
    }

    // Forward pass: compute expected color for a given trit and depth
    pub fn expectedColor(self: *const PipelineState, t: Trit, depth: u8) RGB {
        const base_hue = switch (t) {
            .minus => @as(f32, 240.0),   // blue
            .ergodic => @as(f32, 120.0), // green
            .plus => @as(f32, 0.0),      // red
        };
        const angle_step: f32 = 137.508; // golden angle
        const hue = @mod(base_hue + @as(f32, @floatFromInt(depth)) * angle_step + self.hue_offset, 360.0);
        const chroma = 0.6 * self.chroma_scale;
        const lightness = 0.55 * self.lightness_scale;
        _ = chroma;
        _ = lightness;

        // Simplified HCL→RGB (full version in lux_color.zig)
        const h_norm = hue / 360.0;
        const r: u8 = @intFromFloat(@min(255.0, @max(0.0, (0.5 + 0.5 * @cos(h_norm * 6.28318)) * 255.0)));
        const g: u8 = @intFromFloat(@min(255.0, @max(0.0, (0.5 + 0.5 * @cos((h_norm - 0.333) * 6.28318)) * 255.0)));
        const b: u8 = @intFromFloat(@min(255.0, @max(0.0, (0.5 + 0.5 * @cos((h_norm - 0.666) * 6.28318)) * 255.0)));
        return .{ .r = r, .g = g, .b = b };
    }

    // Compute observation error (loss)
    pub fn observationError(self: *const PipelineState) f64 {
        return self.last_expected.distance(self.last_observed);
    }

    // Record an observation from terminal
    pub fn recordObservation(self: *PipelineState, expected_rgb: RGB, observed: OscColor) void {
        self.last_expected = OscColor.fromRgb8(expected_rgb);
        self.last_observed = observed;
    }

    // Trit selection based on option
    pub fn selectTrit(self: *PipelineState, op_idx: usize) Trit {
        return switch (self.option) {
            .enzyme_reverse => {
                // Option A: trit is frozen (from OPERATION_TRITS)
                const fixed = [_]Trit{ .ergodic, .minus, .plus, .minus, .plus, .ergodic, .minus, .plus, .ergodic, .minus, .plus, .ergodic };
                return if (op_idx < fixed.len) fixed[op_idx] else .ergodic;
            },
            .gumbel_softmax => {
                // Option B: sample from Gumbel-Softmax
                if (self.gumbel_state) |*gs| {
                    const sampled = gs.sample();
                    return sampled[op_idx].toHard();
                }
                return .ergodic;
            },
            .reinforce_osc => {
                // Option C: sample from policy
                if (self.policy_table) |*pt| {
                    const probs = pt.actionProbs(op_idx, 0);
                    _ = probs;
                    return .ergodic; // simplified; full impl samples
                }
                return .ergodic;
            },
        };
    }
};

// ============================================================================
// Protocol Message Types
// ============================================================================

pub const ProtocolMessage = union(enum) {
    query: struct {
        seed: u64,
        trit: Trit,
        depth: u8,
    },
    assert_eq: struct {
        expected: OscColor,
        trit: Trit,
        depth: u8,
        variant: LearningOption,
    },
    gradient: union(enum) {
        enzyme: struct { dh: f32, dc: f32, dl: f32, loss: f32 },
        gumbel: struct { logits: [3]f32, temperature: f32 },
        reinforce: struct { reward: f32, baseline: f32 },
    },
    policy_params: struct {
        op_idx: usize,
        depth: u8,
        action_probs: [policy.NUM_ACTIONS]f32,
    },
};

// ============================================================================
// Carry-Deferred Correspondence (from enzyme-osc1069-learnable-color.md)
// ============================================================================

pub const CarryAnalog = struct {
    option: LearningOption,

    pub fn name(self: CarryAnalog) []const u8 {
        return switch (self.option) {
            .enzyme_reverse => "carry-lookahead (Brent-Kung): parallel exact gradients",
            .gumbel_softmax => "algebraic closure (GF(3)): softmax absorbs discontinuity",
            .reinforce_osc => "redundant representation (Avizienis): signed-digit rewards",
        };
    }

    pub fn spookyRepl(self: CarryAnalog) []const u8 {
        return switch (self.option) {
            .enzyme_reverse => "Extempore (JIT, live, exact)",
            .gumbel_softmax => "Unison (content-addressed, hash)",
            .reinforce_osc => "Hazel (holes, gradual)",
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "pipeline init for each option" {
    inline for (std.meta.fields(LearningOption)) |field| {
        const opt: LearningOption = @enumFromInt(field.value);
        const state = PipelineState.init(opt, CANONICAL_SEED);
        try std.testing.expectEqual(opt, state.option);
        try std.testing.expectEqual(CANONICAL_SEED, state.seed);
    }
}

test "expected color produces valid RGB" {
    const state = PipelineState.init(.enzyme_reverse, CANONICAL_SEED);
    const rgb = state.expectedColor(.plus, 0);
    _ = rgb; // just ensure no crash
}

test "observation error is zero for identical colors" {
    var state = PipelineState.init(.enzyme_reverse, CANONICAL_SEED);
    const rgb = RGB{ .r = 128, .g = 64, .b = 200 };
    state.recordObservation(rgb, OscColor.fromRgb8(rgb));
    try std.testing.expect(state.observationError() < 0.01);
}

test "observation error nonzero for different colors" {
    var state = PipelineState.init(.enzyme_reverse, CANONICAL_SEED);
    state.recordObservation(
        RGB{ .r = 255, .g = 0, .b = 0 },
        OscColor{ .r = 0, .g = 0xffff, .b = 0 },
    );
    try std.testing.expect(state.observationError() > 0.5);
}

test "carry analog names are distinct" {
    const a = CarryAnalog{ .option = .enzyme_reverse };
    const b = CarryAnalog{ .option = .gumbel_softmax };
    const c = CarryAnalog{ .option = .reinforce_osc };
    try std.testing.expect(!std.mem.eql(u8, a.name(), b.name()));
    try std.testing.expect(!std.mem.eql(u8, b.name(), c.name()));
}

test "spooky REPL correspondence" {
    const a = CarryAnalog{ .option = .enzyme_reverse };
    try std.testing.expect(std.mem.indexOf(u8, a.spookyRepl(), "Extempore") != null);
}

test "select trit for enzyme option uses fixed table" {
    var state = PipelineState.init(.enzyme_reverse, CANONICAL_SEED);
    const t0 = state.selectTrit(0); // compose → ergodic
    try std.testing.expectEqual(Trit.ergodic, t0);
    const t1 = state.selectTrit(1); // filter → minus
    try std.testing.expectEqual(Trit.minus, t1);
}
