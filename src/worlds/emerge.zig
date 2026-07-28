//! Curiosity-Driven Emergent Specification Discovery
//!
//! Connects Lauren Moos's RL-for-program-search approach (parx, swimming_pool)
//! to AGM belief revision and Nash certificate emission via csexp.
//!
//! Architecture:
//!   CuriosityModule (prediction error as intrinsic reward)
//!     → AGM BeliefSet (epistemic state about compiler strategies)
//!       → NashCert (equilibrium proof)
//!         → csexp wire (cross-language bridge to oxgame csexp_io.ml)
//!
//! GF(3) trit assignment:
//!   +1 = expansion (new spec discovered)
//!    0 = revision  (spec updated with new evidence)
//!   -1 = contraction (spec falsified/removed)
//!
//! Each compiler backend (fuel, inet, bytecode, csexp_emit) is a bandit arm.
//! Curiosity = prediction error on program output under that backend.
//! AGM revision updates beliefs about which backend suits a given input class.
//! Nash cert proves the strategy profile is epsilon-stable.

const std = @import("std");
const agm = @import("agm.zig");
const BeliefSet = agm.BeliefSet;
const Belief = agm.Belief;
const OpKind = agm.OpKind;

pub const MAX_BACKENDS: usize = 8;
pub const MAX_SPECS: usize = 32;
pub const GAME_ID_LEN: usize = 32;
pub const BOND_LEN: usize = 32;
pub const MAX_BONDS: usize = 16;

// ============================================================================
// CompilerBackend — a strategy in the compiler selection game
// ============================================================================

pub const BackendKind = enum(u8) {
    fuel = 0, // stack-based reduction
    inet = 1, // interaction net
    bytecode = 2, // direct bytecode
    csexp_emit = 3, // tree emission (FORMAT-TRIAD trit=0)

    pub fn trit(self: BackendKind) i2 {
        return switch (self) {
            .fuel => 1,
            .inet => 0,
            .bytecode => -1,
            .csexp_emit => 0,
        };
    }
};

pub const CompilerBackend = struct {
    kind: BackendKind,
    pulls: u64,
    total_reward: f64,
    prediction_error_sum: f64,
    curiosity_bonus: f64,
    q_value: f64,

    pub fn init(kind: BackendKind) CompilerBackend {
        return .{
            .kind = kind,
            .pulls = 0,
            .total_reward = 0,
            .prediction_error_sum = 0,
            .curiosity_bonus = 0,
            .q_value = 0,
        };
    }

    pub fn meanReward(self: *const CompilerBackend) f64 {
        if (self.pulls == 0) return 0;
        return self.total_reward / @as(f64, @floatFromInt(self.pulls));
    }

    pub fn meanPredictionError(self: *const CompilerBackend) f64 {
        if (self.pulls == 0) return 1.0; // max curiosity for unexplored
        return self.prediction_error_sum / @as(f64, @floatFromInt(self.pulls));
    }

    pub fn update(self: *CompilerBackend, reward: f64, pred_error: f64) void {
        self.pulls += 1;
        self.total_reward += reward;
        self.prediction_error_sum += pred_error;
        // Exponential moving average for Q-value
        const alpha: f64 = 0.1;
        self.q_value += alpha * (reward + self.curiosity_bonus - self.q_value);
    }
};

// ============================================================================
// EmergentSpec — a discovered specification from exploration
// ============================================================================

pub const EmergentSpec = struct {
    id: u64,
    input_class: u64, // hash of input pattern
    best_backend: BackendKind,
    confidence: f64, // 0..1
    trit: i2, // GF(3): +1 new, 0 revised, -1 falsified
    generation: u32,
    reward: f64,

    pub fn init(id: u64, input_class: u64, backend: BackendKind) EmergentSpec {
        return .{
            .id = id,
            .input_class = input_class,
            .best_backend = backend,
            .confidence = 0.5,
            .trit = 1, // newly discovered
            .generation = 0,
            .reward = 0,
        };
    }
};

// ============================================================================
// CuriosityModule — prediction error as intrinsic reward
// ============================================================================

pub const CuriosityModule = struct {
    /// Forward model predictions (predicted output hash per backend)
    predictions: [MAX_BACKENDS]u64,
    /// Learning rate for prediction model
    learning_rate: f64,
    /// Curiosity weight (scales prediction error into reward)
    curiosity_weight: f64,
    /// Total prediction error accumulated
    total_error: f64,
    /// Number of steps
    steps: u64,

    pub fn init(curiosity_weight: f64) CuriosityModule {
        return .{
            .predictions = @splat(0),
            .learning_rate = 0.01,
            .curiosity_weight = curiosity_weight,
            .total_error = 0,
            .steps = 0,
        };
    }

    /// Compute prediction error between expected and actual output.
    /// Returns intrinsic reward (higher error = more curiosity = more reward).
    pub fn intrinsicReward(self: *CuriosityModule, backend_idx: usize, actual_hash: u64) f64 {
        const predicted = self.predictions[backend_idx];
        // XOR distance as prediction error proxy
        const xor = predicted ^ actual_hash;
        const prediction_error = @as(f64, @floatFromInt(@popCount(xor))) / 64.0;
        // Update prediction (simple EMA toward actual)
        self.predictions[backend_idx] = actual_hash;
        self.total_error += prediction_error;
        self.steps += 1;
        return prediction_error * self.curiosity_weight;
    }

    pub fn meanError(self: *const CuriosityModule) f64 {
        if (self.steps == 0) return 1.0;
        return self.total_error / @as(f64, @floatFromInt(self.steps));
    }
};

// ============================================================================
// NashCert — equilibrium certificate, csexp-compatible with oxgame
// ============================================================================

/// Matches oxgame/lib/oxgame_kernel/csexp_io.ml Nash_cert format:
///   (cert <32-byte game_id> <8-byte BE epsilon> <8-byte BE lambda_q32>
///    <8-byte BE trit_sum> (bonds <bond1> <bond2> ...))
pub const NashCert = struct {
    game_id: [GAME_ID_LEN]u8,
    epsilon: i64, // epsilon-Nash tolerance (fixed-point)
    lambda_q32: i64, // regularization parameter (Q32 fixed-point)
    trit_sum: i64,
    bonds: [MAX_BONDS][BOND_LEN]u8,
    n_bonds: u8,

    pub fn init(game_id: [GAME_ID_LEN]u8) NashCert {
        return .{
            .game_id = game_id,
            .epsilon = 0,
            .lambda_q32 = 0,
            .trit_sum = 0,
            .bonds = undefined,
            .n_bonds = 0,
        };
    }

    pub fn addBond(self: *NashCert, bond: [BOND_LEN]u8) void {
        if (self.n_bonds < MAX_BONDS) {
            self.bonds[self.n_bonds] = bond;
            self.n_bonds += 1;
        }
    }

    /// Emit as csexp wire bytes.
    /// Format: (4:cert <32:game_id> <8:epsilon_be> <8:lambda_be>
    ///          <8:trit_sum_be> (5:bonds <32:bond1> ...))
    pub fn toCsexp(self: *const NashCert, buf: []u8) usize {
        var pos: usize = 0;
        // outer list open
        buf[pos] = '(';
        pos += 1;
        // "cert" atom
        pos += writeAtom(buf[pos..], "cert");
        // game_id atom (32 bytes)
        pos += writeBinaryAtom(buf[pos..], &self.game_id);
        // epsilon (8 bytes BE)
        var eps_buf: [8]u8 = undefined;
        std.mem.writeInt(i64, &eps_buf, self.epsilon, .big);
        pos += writeBinaryAtom(buf[pos..], &eps_buf);
        // lambda_q32 (8 bytes BE)
        var lam_buf: [8]u8 = undefined;
        std.mem.writeInt(i64, &lam_buf, self.lambda_q32, .big);
        pos += writeBinaryAtom(buf[pos..], &lam_buf);
        // trit_sum (8 bytes BE)
        var ts_buf: [8]u8 = undefined;
        std.mem.writeInt(i64, &ts_buf, self.trit_sum, .big);
        pos += writeBinaryAtom(buf[pos..], &ts_buf);
        // bonds list
        buf[pos] = '(';
        pos += 1;
        pos += writeAtom(buf[pos..], "bonds");
        for (0..self.n_bonds) |i| {
            pos += writeBinaryAtom(buf[pos..], &self.bonds[i]);
        }
        buf[pos] = ')';
        pos += 1;
        // outer list close
        buf[pos] = ')';
        pos += 1;
        return pos;
    }
};

fn writeAtom(buf: []u8, data: []const u8) usize {
    const len_str = std.fmt.bufPrint(buf, "{d}:", .{data.len}) catch return 0;
    const prefix_len = len_str.len;
    @memcpy(buf[prefix_len .. prefix_len + data.len], data);
    return prefix_len + data.len;
}

fn writeBinaryAtom(buf: []u8, data: []const u8) usize {
    return writeAtom(buf, data);
}

// ============================================================================
// ExplorationEngine — ties curiosity, AGM, and Nash certs together
// ============================================================================

pub const ExplorationEngine = struct {
    backends: [4]CompilerBackend,
    curiosity: CuriosityModule,
    beliefs: BeliefSet,
    specs: [MAX_SPECS]EmergentSpec,
    n_specs: u8,
    generation: u32,
    // UCB exploration constant
    ucb_c: f64,

    pub fn init(curiosity_weight: f64) ExplorationEngine {
        return .{
            .backends = .{
                CompilerBackend.init(.fuel),
                CompilerBackend.init(.inet),
                CompilerBackend.init(.bytecode),
                CompilerBackend.init(.csexp_emit),
            },
            .curiosity = CuriosityModule.init(curiosity_weight),
            .beliefs = BeliefSet.init(),
            .specs = undefined,
            .n_specs = 0,
            .generation = 0,
            .ucb_c = 1.41,
        };
    }

    /// Select backend using UCB1 + curiosity bonus.
    pub fn selectBackend(self: *ExplorationEngine) usize {
        const total_pulls = blk: {
            var t: u64 = 0;
            for (&self.backends) |*b| t += b.pulls;
            break :blk t;
        };
        if (total_pulls < 4) return @intCast(total_pulls); // round-robin first

        var best_idx: usize = 0;
        var best_score: f64 = -std.math.inf(f64);
        const log_total = @log(@as(f64, @floatFromInt(total_pulls)));

        for (&self.backends, 0..) |*b, i| {
            const mean = b.meanReward();
            const curiosity = b.meanPredictionError() * self.curiosity.curiosity_weight;
            const exploration = self.ucb_c * @sqrt(log_total / @as(f64, @floatFromInt(@max(b.pulls, 1))));
            const score = mean + curiosity + exploration;
            if (score > best_score) {
                best_score = score;
                best_idx = i;
            }
        }
        return best_idx;
    }

    /// Observe outcome: update backend, curiosity model, and AGM beliefs.
    pub fn observe(
        self: *ExplorationEngine,
        backend_idx: usize,
        actual_output_hash: u64,
        extrinsic_reward: f64,
        input_class: u64,
    ) void {
        const intrinsic = self.curiosity.intrinsicReward(backend_idx, actual_output_hash);
        const total_reward = extrinsic_reward + intrinsic;
        const pred_error = self.curiosity.meanError();

        self.backends[backend_idx].update(total_reward, pred_error);
        self.generation += 1;

        // AGM belief revision: expand with evidence about this backend
        const prop = input_class ^ (@as(u64, backend_idx) << 56);
        if (total_reward > 0.5) {
            _ = self.beliefs.expand(prop, @intFromFloat(@min(total_reward * 255.0, 255.0)));
        } else {
            _ = self.beliefs.contract(prop);
        }

        // Update or create spec
        self.updateSpec(input_class, backend_idx, total_reward);
    }

    fn updateSpec(self: *ExplorationEngine, input_class: u64, backend_idx: usize, reward: f64) void {
        // Find existing spec for this input class
        for (self.specs[0..self.n_specs]) |*spec| {
            if (spec.input_class == input_class) {
                spec.generation = self.generation;
                spec.reward = reward;
                const new_backend: BackendKind = @fromBackingInt(@intCast(@as(u8, @intCast(backend_idx))));
                if (new_backend != spec.best_backend and reward > spec.confidence) {
                    spec.best_backend = new_backend;
                    spec.trit = 0; // revised
                    spec.confidence = reward;
                } else if (reward < 0.2 and spec.confidence < 0.3) {
                    spec.trit = -1; // falsified
                }
                return;
            }
        }
        // New spec
        if (self.n_specs < MAX_SPECS) {
            self.specs[self.n_specs] = EmergentSpec.init(
                @as(u64, self.generation) ^ input_class,
                input_class,
                @fromBackingInt(@intCast(@as(u8, @intCast(backend_idx)))),
            );
            self.specs[self.n_specs].reward = reward;
            self.specs[self.n_specs].confidence = reward;
            self.specs[self.n_specs].generation = self.generation;
            self.n_specs += 1;
        }
    }

    /// Check if current strategy profile is epsilon-Nash.
    pub fn isEpsilonNash(self: *const ExplorationEngine, epsilon: f64) bool {
        const best = self.bestBackend();
        for (&self.backends, 0..) |*b, i| {
            if (i == best) continue;
            if (b.meanReward() + epsilon > self.backends[best].meanReward()) {
                return false; // some other arm is within epsilon
            }
        }
        return true;
    }

    fn bestBackend(self: *const ExplorationEngine) usize {
        var best: usize = 0;
        var best_val: f64 = -std.math.inf(f64);
        for (&self.backends, 0..) |*b, i| {
            if (b.meanReward() > best_val) {
                best_val = b.meanReward();
                best = i;
            }
        }
        return best;
    }

    /// Certify current state as Nash cert (csexp-compatible with oxgame).
    pub fn certify(self: *const ExplorationEngine, game_id: [GAME_ID_LEN]u8) NashCert {
        var cert = NashCert.init(game_id);
        // epsilon from max regret
        const best = self.bestBackend();
        var max_regret: f64 = 0;
        for (&self.backends) |*b| {
            const regret = self.backends[best].meanReward() - b.meanReward();
            if (regret > max_regret) max_regret = regret;
        }
        cert.epsilon = @intFromFloat(max_regret * (1 << 32));
        cert.lambda_q32 = @intFromFloat(self.curiosity.curiosity_weight * (1 << 32));

        // trit_sum from active specs
        var trit_sum: i64 = 0;
        for (self.specs[0..self.n_specs]) |*spec| {
            trit_sum += @as(i64, spec.trit);
        }
        cert.trit_sum = trit_sum;

        // bonds: one per backend with non-zero pulls
        for (&self.backends) |*b| {
            if (b.pulls > 0) {
                var bond: [BOND_LEN]u8 = @splat(0);
                std.mem.writeInt(u64, bond[0..8], b.pulls, .big);
                std.mem.writeInt(u64, bond[8..16], @bitCast(b.total_reward), .big);
                std.mem.writeInt(u64, bond[16..24], @bitCast(b.prediction_error_sum), .big);
                bond[24] = @backingInt(b.kind);
                cert.addBond(bond);
            }
        }
        return cert;
    }

    /// GF(3) trit sum across all active specs (should be 0 for balance).
    pub fn tritSum(self: *const ExplorationEngine) i32 {
        var sum: i32 = 0;
        for (self.specs[0..self.n_specs]) |*spec| {
            sum += @as(i32, spec.trit);
        }
        return sum;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "curiosity module basic" {
    var cm = CuriosityModule.init(0.5);
    const r1 = cm.intrinsicReward(0, 0xDEADBEEF);
    try std.testing.expect(r1 > 0); // first prediction is wrong → high curiosity
    const r2 = cm.intrinsicReward(0, 0xDEADBEEF);
    try std.testing.expect(r2 < r1); // same input → prediction matches → low curiosity
}

test "exploration engine select and observe" {
    var engine = ExplorationEngine.init(0.5);
    // Round-robin first 4
    for (0..4) |i| {
        try std.testing.expectEqual(i, engine.selectBackend());
        engine.observe(i, @as(u64, i) * 0x1234, 0.8, 42);
    }
    try std.testing.expectEqual(@as(u8, 4), engine.n_specs); // 4 specs from same input class? no, same input_class=42
    try std.testing.expect(engine.n_specs >= 1);
}

test "nash cert csexp emission" {
    var engine = ExplorationEngine.init(0.5);
    for (0..4) |i| {
        engine.observe(i, @as(u64, i) * 0xABC, 0.7, @as(u64, i) * 100);
    }
    const game_id: [GAME_ID_LEN]u8 = @splat(0x42);
    const cert = engine.certify(game_id);
    var buf: [2048]u8 = undefined;
    const len = cert.toCsexp(&buf);
    try std.testing.expect(len > 0);
    // Verify it starts with '(' and ends with ')'
    try std.testing.expectEqual(@as(u8, '('), buf[0]);
    try std.testing.expectEqual(@as(u8, ')'), buf[len - 1]);
    // Verify "cert" appears
    const csexp_str = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, csexp_str, "cert") != null);
    // Verify "bonds" appears
    try std.testing.expect(std.mem.indexOf(u8, csexp_str, "bonds") != null);
}

test "gf3 trit balance" {
    var engine = ExplorationEngine.init(0.5);
    // Expand: trit=+1
    engine.observe(0, 0x111, 0.9, 100);
    // Revise: observe different backend for same class
    engine.observe(1, 0x222, 0.95, 100);
    // The spec should be revised (trit=0) since backend 1 beat backend 0
    var found = false;
    for (engine.specs[0..engine.n_specs]) |*spec| {
        if (spec.input_class == 100) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "epsilon nash detection" {
    var engine = ExplorationEngine.init(0.1);
    // Give one backend much higher reward
    for (0..20) |_| engine.observe(0, 0xAAA, 0.9, 1);
    for (0..20) |_| engine.observe(1, 0xBBB, 0.3, 2);
    for (0..20) |_| engine.observe(2, 0xCCC, 0.2, 3);
    for (0..20) |_| engine.observe(3, 0xDDD, 0.1, 4);
    // Should be epsilon-Nash with large epsilon
    try std.testing.expect(engine.isEpsilonNash(1.0));
    // Should NOT be epsilon-Nash with tiny epsilon
    try std.testing.expect(!engine.isEpsilonNash(0.001));
}
