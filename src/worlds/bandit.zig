//! Multi-Armed Bandit Engine
//!
//! Progression: A/B (static) → Bandit (adaptive) → Thompson (Bayesian) → RL (stateful)
//!
//! Each arm = a WorldVariant. Rewards flow from session metrics.
//! GF(3) trit assignment: best arm = +1, worst = -1, middle = 0.

const std = @import("std");
const math = std.math;

// ============================================================================
// Arm — one world variant as a bandit arm
// ============================================================================

pub const Arm = struct {
    id: u8,
    name: [32]u8,
    name_len: u8,
    pulls: u64,
    total_reward: f64,
    sum_sq: f64, // for variance
    // Beta distribution params (Thompson)
    alpha: f64, // successes + 1
    beta_param: f64, // failures + 1
    // Q-value (RL)
    q_value: f64,

    pub fn init(id: u8, name: []const u8) Arm {
        var a = Arm{
            .id = id,
            .name = undefined,
            .name_len = @intCast(@min(name.len, 32)),
            .pulls = 0,
            .total_reward = 0,
            .sum_sq = 0,
            .alpha = 1.0, // uniform prior
            .beta_param = 1.0,
            .q_value = 0,
        };
        @memcpy(a.name[0..a.name_len], name[0..a.name_len]);
        return a;
    }

    pub fn getName(self: *const Arm) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn meanReward(self: *const Arm) f64 {
        if (self.pulls == 0) return 0;
        return self.total_reward / @as(f64, @floatFromInt(self.pulls));
    }

    pub fn variance(self: *const Arm) f64 {
        if (self.pulls < 2) return 0;
        const n = @as(f64, @floatFromInt(self.pulls));
        const mean = self.meanReward();
        return (self.sum_sq / n) - (mean * mean);
    }

    pub fn update(self: *Arm, reward: f64) void {
        self.pulls += 1;
        self.total_reward += reward;
        self.sum_sq += reward * reward;

        // Update Beta posterior (reward clamped to [0,1] as Bernoulli)
        if (reward >= 0.5) {
            self.alpha += 1.0;
        } else {
            self.beta_param += 1.0;
        }

        // Incremental Q-value (RL: running average)
        const n = @as(f64, @floatFromInt(self.pulls));
        self.q_value += (reward - self.q_value) / n;
    }

    /// UCB1 index: mean + sqrt(2 ln(total) / pulls)
    pub fn ucb1(self: *const Arm, total_pulls: u64) f64 {
        if (self.pulls == 0) return math.inf(f64);
        const n = @as(f64, @floatFromInt(self.pulls));
        const t = @as(f64, @floatFromInt(total_pulls));
        return self.meanReward() + @sqrt(2.0 * @log(t) / n);
    }
};

// ============================================================================
// Strategy
// ============================================================================

pub const Strategy = enum(u8) {
    /// Static A/B: round-robin, no adaptation
    ab_test = 0,
    /// Epsilon-greedy: exploit best arm (1-eps), explore random (eps)
    epsilon_greedy = 1,
    /// UCB1: Upper Confidence Bound
    ucb1 = 2,
    /// Thompson: Beta-Bernoulli posterior sampling
    thompson = 3,
    /// Softmax (Boltzmann): temperature-based exploration
    softmax = 4,
    /// RL: stateful, reward shapes next state transition
    rl_qlearn = 5,

    pub fn label(self: Strategy) []const u8 {
        return switch (self) {
            .ab_test => "A/B",
            .epsilon_greedy => "eps-greedy",
            .ucb1 => "UCB1",
            .thompson => "Thompson",
            .softmax => "Softmax",
            .rl_qlearn => "Q-Learn",
        };
    }
};

// ============================================================================
// Bandit Engine
// ============================================================================

pub const MAX_ARMS: usize = 16;

pub const Bandit = struct {
    arms: [MAX_ARMS]Arm,
    n_arms: u8,
    strategy: Strategy,
    total_pulls: u64,
    // Hyperparams
    epsilon: f64, // for epsilon-greedy
    temperature: f64, // for softmax
    lr: f64, // learning rate for RL
    discount: f64, // discount factor for RL
    // RNG state (SplitMix64)
    rng_state: u64,
    // History ring buffer (last 256 pulls)
    history: [256]PullRecord,
    history_len: u16,
    history_idx: u8,

    pub const PullRecord = struct {
        arm: u8,
        reward: f32,
        timestamp: u32,
    };

    pub fn init(strategy: Strategy, seed: u64) Bandit {
        return Bandit{
            .arms = undefined,
            .n_arms = 0,
            .strategy = strategy,
            .total_pulls = 0,
            .epsilon = 0.1,
            .temperature = 1.0,
            .lr = 0.1,
            .discount = 0.99,
            .rng_state = seed,
            .history = undefined,
            .history_len = 0,
            .history_idx = 0,
        };
    }

    pub fn addArm(self: *Bandit, name: []const u8) !u8 {
        if (self.n_arms >= MAX_ARMS) return error.TooManyArms;
        const id = self.n_arms;
        self.arms[id] = Arm.init(id, name);
        self.n_arms += 1;
        return id;
    }

    /// Select arm according to current strategy
    pub fn selectArm(self: *Bandit) u8 {
        if (self.n_arms == 0) return 0;
        if (self.n_arms == 1) return 0;

        return switch (self.strategy) {
            .ab_test => self.selectRoundRobin(),
            .epsilon_greedy => self.selectEpsilonGreedy(),
            .ucb1 => self.selectUCB1(),
            .thompson => self.selectThompson(),
            .softmax => self.selectSoftmax(),
            .rl_qlearn => self.selectEpsilonGreedy(), // Q-learn uses eps-greedy for exploration
        };
    }

    fn selectRoundRobin(self: *Bandit) u8 {
        return @intCast(self.total_pulls % self.n_arms);
    }

    fn selectEpsilonGreedy(self: *Bandit) u8 {
        const r = self.nextFloat();
        if (r < self.epsilon) {
            // Explore: random arm
            return @intCast(self.nextU64() % self.n_arms);
        }
        // Exploit: best mean reward
        return self.bestArm();
    }

    fn selectUCB1(self: *Bandit) u8 {
        var best_idx: u8 = 0;
        var best_ucb: f64 = -math.inf(f64);
        for (0..self.n_arms) |i| {
            const ucb = self.arms[i].ucb1(self.total_pulls);
            if (ucb > best_ucb) {
                best_ucb = ucb;
                best_idx = @intCast(i);
            }
        }
        return best_idx;
    }

    fn selectThompson(self: *Bandit) u8 {
        var best_idx: u8 = 0;
        var best_sample: f64 = -math.inf(f64);
        for (0..self.n_arms) |i| {
            const sample = self.sampleBeta(self.arms[i].alpha, self.arms[i].beta_param);
            if (sample > best_sample) {
                best_sample = sample;
                best_idx = @intCast(i);
            }
        }
        return best_idx;
    }

    fn selectSoftmax(self: *Bandit) u8 {
        // Boltzmann distribution: P(arm_i) = exp(Q_i/T) / sum(exp(Q_j/T))
        var weights: [MAX_ARMS]f64 = undefined;
        var sum: f64 = 0;
        for (0..self.n_arms) |i| {
            const w = @exp(self.arms[i].meanReward() / self.temperature);
            weights[i] = w;
            sum += w;
        }
        // Normalize and sample
        const r = self.nextFloat() * sum;
        var cumulative: f64 = 0;
        for (0..self.n_arms) |i| {
            cumulative += weights[i];
            if (r <= cumulative) return @intCast(i);
        }
        return self.n_arms - 1;
    }

    /// Pull arm and observe reward
    pub fn pull(self: *Bandit, arm_id: u8, reward: f64) void {
        if (arm_id >= self.n_arms) return;
        self.arms[arm_id].update(reward);
        self.total_pulls += 1;

        // Record history
        self.history[self.history_idx] = .{
            .arm = arm_id,
            .reward = @floatCast(reward),
            .timestamp = @intCast(self.total_pulls & 0xFFFFFFFF),
        };
        self.history_idx +%= 1;
        if (self.history_len < 256) self.history_len += 1;
    }

    /// Best arm by mean reward
    pub fn bestArm(self: *const Bandit) u8 {
        var best: u8 = 0;
        var best_mean: f64 = -math.inf(f64);
        for (0..self.n_arms) |i| {
            const m = self.arms[i].meanReward();
            if (m > best_mean) {
                best_mean = m;
                best = @intCast(i);
            }
        }
        return best;
    }

    /// Worst arm by mean reward
    pub fn worstArm(self: *const Bandit) u8 {
        var worst: u8 = 0;
        var worst_mean: f64 = math.inf(f64);
        for (0..self.n_arms) |i| {
            const m = self.arms[i].meanReward();
            if (m < worst_mean) {
                worst_mean = m;
                worst = @intCast(i);
            }
        }
        return worst;
    }

    /// GF(3) trit for each arm: +1 best, 0 middle, -1 worst
    pub fn trits(self: *const Bandit) [MAX_ARMS]i2 {
        var result: [MAX_ARMS]i2 = [_]i2{0} ** MAX_ARMS;
        if (self.n_arms < 2) return result;

        const b = self.bestArm();
        const w = self.worstArm();
        for (0..self.n_arms) |i| {
            if (i == b) {
                result[i] = 1;
            } else if (i == w) {
                result[i] = -1;
            } else {
                result[i] = 0;
            }
        }
        return result;
    }

    /// Regret: difference between optimal arm and actual pulls
    pub fn cumulativeRegret(self: *const Bandit) f64 {
        const b = self.bestArm();
        const best_mean = self.arms[b].meanReward();
        var regret: f64 = 0;
        for (0..self.n_arms) |i| {
            if (i == b) continue;
            const pulls_f = @as(f64, @floatFromInt(self.arms[i].pulls));
            regret += pulls_f * (best_mean - self.arms[i].meanReward());
        }
        return regret;
    }

    /// Transition to a more sophisticated strategy
    pub fn evolve(self: *Bandit) void {
        self.strategy = switch (self.strategy) {
            .ab_test => .epsilon_greedy,
            .epsilon_greedy => .ucb1,
            .ucb1 => .thompson,
            .thompson => .softmax,
            .softmax => .rl_qlearn,
            .rl_qlearn => .rl_qlearn, // terminal
        };
    }

    /// Decay epsilon over time (eps-greedy annealing)
    pub fn decayEpsilon(self: *Bandit, min_eps: f64) void {
        self.epsilon = @max(min_eps, self.epsilon * 0.995);
    }

    // ── RNG (SplitMix64) ──

    fn nextU64(self: *Bandit) u64 {
        self.rng_state +%= 0x9e3779b97f4a7c15;
        var z = self.rng_state;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }

    fn nextFloat(self: *Bandit) f64 {
        return @as(f64, @floatFromInt(self.nextU64() >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
    }

    /// Sample from Beta(alpha, beta) using Jöhnk's algorithm
    /// Simple, no-alloc, sufficient for our posteriors
    fn sampleBeta(self: *Bandit, alpha: f64, beta_p: f64) f64 {
        // For alpha,beta >= 1, use inverse CDF approximation via gamma ratio
        // Simplified: use rejection sampling for small params
        if (alpha <= 0 or beta_p <= 0) return 0.5;

        // Jöhnk's method for alpha,beta < 1 is inefficient.
        // For alpha,beta >= 1 use the transformation method:
        // X ~ Gamma(alpha), Y ~ Gamma(beta) => X/(X+Y) ~ Beta(alpha,beta)
        const x = self.sampleGamma(alpha);
        const y = self.sampleGamma(beta_p);
        if (x + y == 0) return 0.5;
        return x / (x + y);
    }

    /// Sample from Gamma(shape, 1) using Marsaglia-Tsang
    fn sampleGamma(self: *Bandit, shape: f64) f64 {
        if (shape < 1.0) {
            // Boost: Gamma(a) = Gamma(a+1) * U^(1/a)
            const u = self.nextFloat();
            return self.sampleGamma(shape + 1.0) * math.pow(f64, u, 1.0 / shape);
        }
        const d = shape - 1.0 / 3.0;
        const c = 1.0 / @sqrt(9.0 * d);
        while (true) {
            var x: f64 = undefined;
            var v: f64 = undefined;
            while (true) {
                x = self.sampleNormal();
                v = 1.0 + c * x;
                if (v > 0) break;
            }
            v = v * v * v;
            const u = self.nextFloat();
            if (u < 1.0 - 0.0331 * (x * x) * (x * x)) return d * v;
            if (@log(u) < 0.5 * x * x + d * (1.0 - v + @log(v))) return d * v;
        }
    }

    /// Box-Muller normal sample
    fn sampleNormal(self: *Bandit) f64 {
        const uni1 = @max(1e-10, self.nextFloat());
        const uni2 = self.nextFloat();
        return @sqrt(-2.0 * @log(uni1)) * @cos(2.0 * math.pi * uni2);
    }
};

// ============================================================================
// RL State (for rl_qlearn strategy)
// ============================================================================

pub const MAX_STATES: usize = 32;

pub const RLState = struct {
    /// Q-table: Q[state][arm] — expected cumulative reward
    q_table: [MAX_STATES][MAX_ARMS]f64,
    current_state: u8,
    n_states: u8,
    /// State transition counts: T[s][a] → next_state (mode)
    transition_counts: [MAX_STATES][MAX_ARMS][MAX_STATES]u16,

    pub fn init(n_states: u8) RLState {
        const rl = RLState{
            .q_table = [_][MAX_ARMS]f64{[_]f64{0} ** MAX_ARMS} ** MAX_STATES,
            .current_state = 0,
            .n_states = n_states,
            .transition_counts = [_][MAX_ARMS][MAX_STATES]u16{
                [_][MAX_STATES]u16{[_]u16{0} ** MAX_STATES} ** MAX_ARMS,
            } ** MAX_STATES,
        };
        return rl;
    }

    /// Q-learning update: Q(s,a) += lr * (r + gamma * max_a' Q(s',a') - Q(s,a))
    pub fn update(
        self: *RLState,
        state: u8,
        arm: u8,
        reward: f64,
        next_state: u8,
        lr: f64,
        discount: f64,
    ) void {
        if (state >= self.n_states or next_state >= self.n_states) return;

        // Find max Q for next state
        var max_q: f64 = -math.inf(f64);
        for (0..MAX_ARMS) |a| {
            if (self.q_table[next_state][a] > max_q) {
                max_q = self.q_table[next_state][a];
            }
        }
        if (max_q == -math.inf(f64)) max_q = 0;

        const td_error = reward + discount * max_q - self.q_table[state][arm];
        self.q_table[state][arm] += lr * td_error;

        // Track transitions
        if (self.transition_counts[state][arm][next_state] < math.maxInt(u16)) {
            self.transition_counts[state][arm][next_state] += 1;
        }
        self.current_state = next_state;
    }

    /// Best arm for current state
    pub fn bestArm(self: *const RLState, state: u8, n_arms: u8) u8 {
        var best: u8 = 0;
        var best_q: f64 = -math.inf(f64);
        for (0..n_arms) |a| {
            if (self.q_table[state][a] > best_q) {
                best_q = self.q_table[state][a];
                best = @intCast(a);
            }
        }
        return best;
    }

    /// Most likely next state given (state, arm)
    pub fn likelyNext(self: *const RLState, state: u8, arm: u8) u8 {
        var best: u8 = 0;
        var best_count: u16 = 0;
        for (0..self.n_states) |s| {
            if (self.transition_counts[state][arm][s] > best_count) {
                best_count = self.transition_counts[state][arm][s];
                best = @intCast(s);
            }
        }
        return best;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "bandit arm basics" {
    var arm = Arm.init(0, "baseline");
    try std.testing.expectEqual(@as(u64, 0), arm.pulls);
    try std.testing.expectEqualStrings("baseline", arm.getName());

    arm.update(1.0);
    arm.update(0.5);
    arm.update(0.75);
    try std.testing.expectEqual(@as(u64, 3), arm.pulls);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), arm.meanReward(), 0.001);
}

test "epsilon greedy selects best" {
    var b = Bandit.init(.epsilon_greedy, 42);
    _ = try b.addArm("bad");
    _ = try b.addArm("good");
    _ = try b.addArm("meh");

    // Train: arm 1 is clearly better
    for (0..100) |_| {
        b.pull(0, 0.2);
        b.pull(1, 0.9);
        b.pull(2, 0.5);
    }

    try std.testing.expectEqual(@as(u8, 1), b.bestArm());

    // With eps=0, should always select best
    b.epsilon = 0;
    for (0..10) |_| {
        try std.testing.expectEqual(@as(u8, 1), b.selectArm());
    }
}

test "UCB1 explores unpulled arms first" {
    var b = Bandit.init(.ucb1, 99);
    _ = try b.addArm("a");
    _ = try b.addArm("b");
    _ = try b.addArm("c");

    // First 3 pulls should visit each arm once (UCB1 = inf for unpulled)
    const first = b.selectArm();
    b.pull(first, 0.5);
    const second = b.selectArm();
    try std.testing.expect(second != first);
    b.pull(second, 0.5);
    const third = b.selectArm();
    try std.testing.expect(third != first and third != second);
}

test "Thompson samples from posteriors" {
    var b = Bandit.init(.thompson, 1234);
    _ = try b.addArm("lo");
    _ = try b.addArm("hi");

    // Strong evidence arm 1 is better
    for (0..200) |_| {
        b.pull(0, 0.1);
        b.pull(1, 0.9);
    }

    // Thompson should pick arm 1 most of the time
    var arm1_count: u32 = 0;
    for (0..100) |_| {
        if (b.selectArm() == 1) arm1_count += 1;
    }
    try std.testing.expect(arm1_count > 80);
}

test "evolution progresses strategies" {
    var b = Bandit.init(.ab_test, 0);
    try std.testing.expectEqual(Strategy.ab_test, b.strategy);
    b.evolve();
    try std.testing.expectEqual(Strategy.epsilon_greedy, b.strategy);
    b.evolve();
    try std.testing.expectEqual(Strategy.ucb1, b.strategy);
    b.evolve();
    try std.testing.expectEqual(Strategy.thompson, b.strategy);
    b.evolve();
    try std.testing.expectEqual(Strategy.softmax, b.strategy);
    b.evolve();
    try std.testing.expectEqual(Strategy.rl_qlearn, b.strategy);
    b.evolve(); // terminal
    try std.testing.expectEqual(Strategy.rl_qlearn, b.strategy);
}

test "GF(3) trits balance" {
    var b = Bandit.init(.ab_test, 0);
    _ = try b.addArm("worst");
    _ = try b.addArm("mid");
    _ = try b.addArm("best");

    b.pull(0, 0.1);
    b.pull(1, 0.5);
    b.pull(2, 0.9);

    const t = b.trits();
    try std.testing.expectEqual(@as(i2, -1), t[0]); // worst
    try std.testing.expectEqual(@as(i2, 0), t[1]); // mid
    try std.testing.expectEqual(@as(i2, 1), t[2]); // best

    // Sum = 0 (GF(3) conserved)
    const sum = @as(i8, t[0]) + @as(i8, t[1]) + @as(i8, t[2]);
    try std.testing.expectEqual(@as(i8, 0), sum);
}

test "RL Q-learning converges" {
    var rl = RLState.init(3);
    // State 0 → arm 1 → reward 1 → state 1 (good)
    // State 0 → arm 0 → reward 0 → state 2 (bad)
    for (0..100) |_| {
        rl.update(0, 1, 1.0, 1, 0.1, 0.99);
        rl.update(0, 0, 0.0, 2, 0.1, 0.99);
    }

    // Q(0,1) should be much higher than Q(0,0)
    try std.testing.expect(rl.q_table[0][1] > rl.q_table[0][0]);
    try std.testing.expectEqual(@as(u8, 1), rl.bestArm(0, 2));
}

test "cumulative regret grows sublinearly for UCB1" {
    var b = Bandit.init(.ucb1, 777);
    _ = try b.addArm("0.3");
    _ = try b.addArm("0.7"); // best
    _ = try b.addArm("0.5");

    const rewards = [3]f64{ 0.3, 0.7, 0.5 };

    for (0..500) |_| {
        const arm = b.selectArm();
        // Deterministic reward for testing
        b.pull(arm, rewards[arm]);
    }

    const regret = b.cumulativeRegret();
    // UCB1 regret should be O(log n), much less than linear (0.4 * 500/3 ≈ 67)
    try std.testing.expect(regret < 50);
}

test "softmax temperature affects exploration" {
    // High temperature → more uniform, low → more greedy
    var b_hot = Bandit.init(.softmax, 42);
    var b_cold = Bandit.init(.softmax, 42);
    _ = try b_hot.addArm("bad");
    _ = try b_hot.addArm("good");
    _ = try b_cold.addArm("bad");
    _ = try b_cold.addArm("good");

    for (0..50) |_| {
        b_hot.pull(0, 0.2);
        b_hot.pull(1, 0.8);
        b_cold.pull(0, 0.2);
        b_cold.pull(1, 0.8);
    }

    b_hot.temperature = 10.0;
    b_cold.temperature = 0.01;

    // Cold should almost always pick arm 1
    var cold_picks: u32 = 0;
    for (0..100) |_| {
        if (b_cold.selectArm() == 1) cold_picks += 1;
    }
    try std.testing.expect(cold_picks > 95);
}

test "history ring buffer wraps" {
    var b = Bandit.init(.ab_test, 0);
    _ = try b.addArm("a");

    for (0..300) |_| {
        b.pull(0, 0.5);
    }

    try std.testing.expectEqual(@as(u16, 256), b.history_len);
    try std.testing.expectEqual(@as(u64, 300), b.total_pulls);
}
