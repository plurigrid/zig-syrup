//! PufferLib FFI Bridge
//!
//! Zero-copy C ABI for PufferLib's vectorized environment interface.
//! Each env instance = (Bandit + AGM BeliefSet + RL state).
//!
//! PufferLib pattern:
//!   Python allocates observations/actions/rewards/terminals as numpy arrays.
//!   C code receives pointers and writes directly. Zero copies.
//!
//! Memory layout (per agent, 128 bytes observation):
//!   [0..15]    bandit arm means (16 × u8, scaled 0-255)
//!   [16..31]   bandit arm pulls (16 × u8, log-scaled)
//!   [32..33]   strategy (u8), best_arm (u8)
//!   [34..35]   cumulative_regret (u16, scaled)
//!   [36..39]   GF(3) trits packed (16 × 2-bit)
//!   [40..103]  AGM belief entrenchments (64 × u8)
//!   [104..111] AGM sphere sizes (8 × u8)
//!   [112]      AGM n_beliefs
//!   [113]      AGM gf3_trit
//!   [114..115] AGM generation (u16)
//!   [116..127] reserved / padding
//!
//! Action space: Discrete(16) = select bandit arm
//! Reward: f32 = stochastic reward from true arm distribution

const std = @import("std");
const bandit = @import("bandit.zig");
const agm = @import("agm.zig");

const Bandit = bandit.Bandit;
const BeliefSet = agm.BeliefSet;

pub const OBS_SIZE: usize = 128;
pub const MAX_ENVS: usize = 8192;

/// PufferLib Log struct (C-compatible)
pub const Log = extern struct {
    episode_return: f32,
    episode_length: f32,
    score: f32,
};

/// Single environment instance (opaque to Python — accessed only via pointers)
pub const Env = struct {
    // PufferLib shared memory pointers (set by Python/Cython)
    observations: [*]u8,
    actions: [*]i32,
    rewards: [*]f32,
    terminals: [*]u8,
    log: Log,

    // Internal state (Zig-managed)
    bandit_state: Bandit,
    belief_state: BeliefSet,
    rl_state: bandit.RLState,

    // Environment config
    n_arms: u8,
    max_steps: u32,
    current_step: u32,
    episode: u32,

    // True reward distributions (hidden from agent)
    true_probs: [bandit.MAX_ARMS]f32,
};

/// Initialize a single environment
export fn c_init(env: *Env, n_arms: u8, seed: u64) void {
    env.bandit_state = Bandit.init(.epsilon_greedy, seed);
    env.belief_state = BeliefSet.init();
    env.rl_state = bandit.RLState.init(4); // 4 epistemic states
    env.n_arms = n_arms;
    env.max_steps = 200;
    env.current_step = 0;
    env.episode = 0;
    env.log = .{ .episode_return = 0, .episode_length = 0, .score = 0 };

    // Add arms
    const arm_names = [_][]const u8{
        "arm0", "arm1", "arm2", "arm3",
        "arm4", "arm5", "arm6", "arm7",
        "arm8", "arm9", "armA", "armB",
        "armC", "armD", "armE", "armF",
    };
    for (0..@min(n_arms, bandit.MAX_ARMS)) |i| {
        _ = env.bandit_state.addArm(arm_names[i]) catch {};
    }

    // Default true reward probabilities (can be overridden)
    for (0..bandit.MAX_ARMS) |i| {
        env.true_probs[i] = 0.1 + @as(f32, @floatFromInt(i % n_arms)) * 0.8 / @as(f32, @floatFromInt(@max(1, n_arms - 1)));
    }

    // Initialize AGM spheres
    env.belief_state.addSphere();
    env.belief_state.addSphere();
    env.belief_state.addSphere();
}

/// Reset environment (called at episode start)
export fn c_reset(env: *Env) void {
    // Log episode stats before reset
    if (env.current_step > 0) {
        env.log.episode_return = @floatCast(env.bandit_state.arms[env.bandit_state.bestArm()].meanReward());
        env.log.episode_length = @floatCast(@as(f64, @floatFromInt(env.current_step)));
        env.log.score = @floatCast(1.0 - env.bandit_state.cumulativeRegret() /
            @as(f64, @floatFromInt(@max(1, env.current_step))));
    }

    // Reset bandit (keep learned values — transfer learning across episodes)
    // Only reset step counter
    env.current_step = 0;
    env.episode += 1;
    env.terminals[0] = 0;

    // Strategy evolution: every N episodes, promote
    if (env.episode > 0 and env.episode % 50 == 0) {
        env.bandit_state.evolve();
    }

    // Write initial observation
    writeObs(env);
}

/// Step environment (called every tick)
export fn c_step(env: *Env) void {
    // Read action from shared buffer
    const action: u8 = @intCast(@min(env.actions[0], @as(i32, env.n_arms) - 1));

    // Generate stochastic reward from true distribution
    const true_p = env.true_probs[action];
    const noise = @as(f32, @floatFromInt(env.bandit_state.total_pulls % 17)) / 50.0 - 0.16;
    const reward = @min(1.0, @max(0.0, true_p + noise));

    // Update bandit
    env.bandit_state.pull(action, @floatCast(reward));

    // AGM belief revision based on observation
    const prop: u64 = @as(u64, action) << 32 | env.current_step;
    const ent: u8 = @intFromFloat(@min(255.0, reward * 255.0));

    if (reward > 0.7) {
        // Strong positive evidence → expand belief (arm is good)
        env.belief_state.expand(prop, ent);
    } else if (reward < 0.3) {
        // Strong negative evidence → contract (arm is bad)
        _ = env.belief_state.contract(prop);
    } else {
        // Ambiguous → revise (update without strong commitment)
        env.belief_state.revise(prop, ent);
    }

    // RL state transition
    const state = @as(u8, @intCast(@min(3, action / @max(1, env.n_arms / 4))));
    const next_state = if (reward > 0.5) @as(u8, 0) else @as(u8, @intCast(@min(3, state + 1)));
    env.rl_state.update(state, action, @floatCast(reward), next_state, 0.1, 0.99);

    // Epsilon decay
    if (env.bandit_state.strategy == .epsilon_greedy) {
        env.bandit_state.decayEpsilon(0.01);
    }

    // Write outputs
    env.rewards[0] = reward;
    env.current_step += 1;
    env.terminals[0] = if (env.current_step >= env.max_steps) 1 else 0;

    // Write observation
    writeObs(env);
}

/// Pack observation into shared buffer
fn writeObs(env: *Env) void {
    const obs = env.observations[0..OBS_SIZE];
    @memset(obs, 0);

    // [0..15] arm means (scaled to 0-255)
    for (0..env.bandit_state.n_arms) |i| {
        obs[i] = @intFromFloat(@min(255.0, env.bandit_state.arms[i].meanReward() * 255.0));
    }

    // [16..31] arm pulls (log-scaled)
    for (0..env.bandit_state.n_arms) |i| {
        const pulls_f = @as(f64, @floatFromInt(env.bandit_state.arms[i].pulls));
        obs[16 + i] = @intFromFloat(@min(255.0, @log(pulls_f + 1.0) * 30.0));
    }

    // [32] strategy
    obs[32] = @intFromEnum(env.bandit_state.strategy);
    // [33] best arm
    obs[33] = env.bandit_state.bestArm();
    // [34..35] cumulative regret (u16, scaled)
    const regret = @min(65535.0, env.bandit_state.cumulativeRegret() * 100.0);
    const regret_u16: u16 = @intFromFloat(regret);
    obs[34] = @truncate(regret_u16);
    obs[35] = @truncate(regret_u16 >> 8);

    // [36..39] GF(3) trits packed (16 × 2-bit in 4 bytes)
    const trits = env.bandit_state.trits();
    for (0..4) |byte_idx| {
        var byte_val: u8 = 0;
        for (0..4) |bit_idx| {
            const arm_idx = byte_idx * 4 + bit_idx;
            const trit_val: u8 = switch (trits[arm_idx]) {
                1 => 0b01,
                -1 => 0b10,
                0 => 0b00,
                else => 0b11,
            };
            byte_val |= trit_val << @intCast(bit_idx * 2);
        }
        obs[36 + byte_idx] = byte_val;
    }

    // [40..103] AGM belief entrenchments
    _ = env.belief_state.packObs(obs[40..112]);

    // [112] AGM n_beliefs
    obs[112] = env.belief_state.n_beliefs;
    // [113] AGM gf3 trit
    obs[113] = @bitCast(@as(i8, @intCast(@as(i32, env.belief_state.gf3Trit()))));
    // [114..115] AGM generation
    obs[114] = @truncate(env.belief_state.generation);
    obs[115] = @truncate(env.belief_state.generation >> 8);
}

/// Vectorized init — allocate N environments
/// Returns opaque pointer (Python passes back to vec_step/vec_reset/vec_close)
export fn vec_init(
    observations: [*]u8,
    actions: [*]i32,
    rewards: [*]f32,
    terminals: [*]u8,
    num_envs: i32,
    n_arms: i32,
    seed: u64,
) ?[*]Env {
    // Allocate environment array (using C malloc for Python compatibility)
    const n: usize = @intCast(num_envs);
    const raw = std.c.malloc(n * @sizeOf(Env)) orelse return null;
    const envs: [*]Env = @ptrCast(@alignCast(raw));

    for (0..n) |i| {
        envs[i].observations = observations + i * OBS_SIZE;
        envs[i].actions = actions + i;
        envs[i].rewards = rewards + i;
        envs[i].terminals = terminals + i;
        c_init(&envs[i], @intCast(n_arms), seed +% i);
    }

    return envs;
}

/// Vectorized reset
export fn vec_reset(envs: [*]Env, num_envs: i32) void {
    for (0..@as(usize, @intCast(num_envs))) |i| {
        c_reset(&envs[i]);
    }
}

/// Vectorized step
export fn vec_step(envs: [*]Env, num_envs: i32) void {
    for (0..@as(usize, @intCast(num_envs))) |i| {
        c_step(&envs[i]);
    }
}

/// Vectorized close
export fn vec_close(envs: [*]Env, num_envs: i32) void {
    _ = num_envs;
    std.c.free(@ptrCast(envs));
}

/// Get episode statistics for logging
export fn vec_log(envs: [*]Env, env_idx: i32, out_return: *f32, out_length: *f32, out_score: *f32) void {
    const e = &envs[@intCast(env_idx)];
    out_return.* = e.log.episode_return;
    out_length.* = e.log.episode_length;
    out_score.* = e.log.score;
}

/// Set true reward probability for an arm (for curriculum learning)
export fn set_true_prob(envs: [*]Env, env_idx: i32, arm: i32, prob: f32) void {
    envs[@intCast(env_idx)].true_probs[@intCast(arm)] = prob;
}

/// Force strategy evolution
export fn evolve_strategy(envs: [*]Env, env_idx: i32) void {
    envs[@intCast(env_idx)].bandit_state.evolve();
}

/// Get GF(3) balance status
export fn get_gf3_balanced(envs: [*]Env, env_idx: i32) u8 {
    return if (envs[@intCast(env_idx)].belief_state.isBalanced()) 1 else 0;
}

// ============================================================================
// Tests
// ============================================================================

test "env init and reset" {
    var obs: [OBS_SIZE]u8 = undefined;
    var actions = [_]i32{0};
    var rewards = [_]f32{0};
    var terminals = [_]u8{0};

    var env = Env{
        .observations = &obs,
        .actions = &actions,
        .rewards = &rewards,
        .terminals = &terminals,
        .log = .{ .episode_return = 0, .episode_length = 0, .score = 0 },
        .bandit_state = undefined,
        .belief_state = undefined,
        .rl_state = undefined,
        .n_arms = 0,
        .max_steps = 0,
        .current_step = 0,
        .episode = 0,
        .true_probs = undefined,
    };

    c_init(&env, 4, 42);
    try std.testing.expectEqual(@as(u8, 4), env.n_arms);
    try std.testing.expectEqual(@as(u8, 4), env.bandit_state.n_arms);

    c_reset(&env);
    try std.testing.expectEqual(@as(u32, 0), env.current_step);

    // Observation should be populated
    try std.testing.expectEqual(@as(u8, 0), obs[0]); // arm 0 mean = 0 before any pulls
}

test "env step produces reward" {
    var obs: [OBS_SIZE]u8 = undefined;
    var actions = [_]i32{1}; // select arm 1
    var rewards = [_]f32{0};
    var terminals = [_]u8{0};

    var env = Env{
        .observations = &obs,
        .actions = &actions,
        .rewards = &rewards,
        .terminals = &terminals,
        .log = .{ .episode_return = 0, .episode_length = 0, .score = 0 },
        .bandit_state = undefined,
        .belief_state = undefined,
        .rl_state = undefined,
        .n_arms = 0,
        .max_steps = 0,
        .current_step = 0,
        .episode = 0,
        .true_probs = undefined,
    };

    c_init(&env, 3, 42);
    c_reset(&env);
    c_step(&env);

    try std.testing.expect(rewards[0] >= 0 and rewards[0] <= 1.0);
    try std.testing.expectEqual(@as(u32, 1), env.current_step);
    try std.testing.expectEqual(@as(u8, 0), terminals[0]); // not done yet
}

test "episode terminates at max_steps" {
    var obs: [OBS_SIZE]u8 = undefined;
    var actions = [_]i32{0};
    var rewards = [_]f32{0};
    var terminals = [_]u8{0};

    var env = Env{
        .observations = &obs,
        .actions = &actions,
        .rewards = &rewards,
        .terminals = &terminals,
        .log = .{ .episode_return = 0, .episode_length = 0, .score = 0 },
        .bandit_state = undefined,
        .belief_state = undefined,
        .rl_state = undefined,
        .n_arms = 0,
        .max_steps = 0,
        .current_step = 0,
        .episode = 0,
        .true_probs = undefined,
    };

    c_init(&env, 3, 42);
    env.max_steps = 10;
    c_reset(&env);

    for (0..10) |_| c_step(&env);

    try std.testing.expectEqual(@as(u8, 1), terminals[0]);
}

test "AGM beliefs update during steps" {
    var obs: [OBS_SIZE]u8 = undefined;
    var actions = [_]i32{2};
    var rewards = [_]f32{0};
    var terminals = [_]u8{0};

    var env = Env{
        .observations = &obs,
        .actions = &actions,
        .rewards = &rewards,
        .terminals = &terminals,
        .log = .{ .episode_return = 0, .episode_length = 0, .score = 0 },
        .bandit_state = undefined,
        .belief_state = undefined,
        .rl_state = undefined,
        .n_arms = 0,
        .max_steps = 0,
        .current_step = 0,
        .episode = 0,
        .true_probs = undefined,
    };

    c_init(&env, 4, 42);
    c_reset(&env);

    // Run several steps
    for (0..20) |_| c_step(&env);

    // AGM should have recorded beliefs
    try std.testing.expect(env.belief_state.generation > 0);
    try std.testing.expect(env.belief_state.history_len > 0);
}
