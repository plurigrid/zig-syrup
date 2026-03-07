//! World Bandit Example
//!
//! Demonstrates the progression:
//!   A/B (static) → Epsilon-Greedy → UCB1 → Thompson → Softmax → Q-Learning
//!
//! Three world variants compete as bandit arms.
//! GF(3) trits track best/worst/middle in real time.

const std = @import("std");
const worlds = @import("worlds");

const Bandit = worlds.Bandit;
const Strategy = worlds.BanditStrategy;

fn tritChar(t: i2) u8 {
    return switch (t) {
        1 => '+',
        -1 => '-',
        0 => '~',
        else => '?',
    };
}

pub fn main() !void {
    const print = std.debug.print;

    print("\n", .{});
    print("  ╔═══════════════════════════════════════════════╗\n", .{});
    print("  ║  world-bandit: A/B → Bandit → Thompson → RL  ║\n", .{});
    print("  ╚═══════════════════════════════════════════════╝\n\n", .{});

    // True reward probabilities (unknown to the bandit)
    const true_rewards = [3]f64{ 0.3, 0.7, 0.5 };
    const arm_names = [3][]const u8{ "a://baseline", "b://variant", "c://zero-g" };

    // Phase through each strategy
    const strategies = [_]Strategy{
        .ab_test,
        .epsilon_greedy,
        .ucb1,
        .thompson,
        .softmax,
        .rl_qlearn,
    };

    for (strategies) |strat| {
        print("  ── {s} ──\n", .{strat.label()});

        var b = Bandit.init(strat, 42);
        for (arm_names) |name| _ = try b.addArm(name);

        // RL state for Q-learning
        var rl = worlds.RLState.init(3);
        var current_state: u8 = 0;

        const rounds: u32 = 200;
        for (0..rounds) |_| {
            const arm = if (strat == .rl_qlearn)
                rl.bestArm(current_state, b.n_arms)
            else
                b.selectArm();

            // Deterministic-ish reward with small noise
            const noise = @as(f64, @floatFromInt(b.total_pulls % 7)) / 20.0 - 0.15;
            const reward = @min(1.0, @max(0.0, true_rewards[arm] + noise));

            b.pull(arm, reward);

            if (strat == .rl_qlearn) {
                const next = if (reward > 0.5) @as(u8, 1) else @as(u8, 2);
                rl.update(current_state, arm, reward, next, b.lr, b.discount);
                current_state = next;
            }

            if (strat == .epsilon_greedy) b.decayEpsilon(0.01);
        }

        // Results
        const t = b.trits();
        for (0..b.n_arms) |i| {
            const arm = &b.arms[i];
            print("    [{c}] {s:<16} pulls={d:<5} mean={d:.3}\n", .{
                tritChar(t[i]),
                arm.getName(),
                arm.pulls,
                arm.meanReward(),
            });
        }

        const regret = b.cumulativeRegret();
        print("    regret={d:.1}  best={s}\n\n", .{
            regret,
            b.arms[b.bestArm()].getName(),
        });
    }

    // Evolution demo: single bandit evolves through all strategies
    print("  ── Evolution (auto-promote) ──\n", .{});
    var evo = Bandit.init(.ab_test, 1337);
    for (arm_names) |name| _ = try evo.addArm(name);

    for (0..6) |phase| {
        print("    phase {d}: {s}", .{ phase, evo.strategy.label() });

        for (0..50) |_| {
            const arm = evo.selectArm();
            const noise = @as(f64, @floatFromInt(evo.total_pulls % 11)) / 30.0 - 0.15;
            const reward = @min(1.0, @max(0.0, true_rewards[arm] + noise));
            evo.pull(arm, reward);
        }

        print(" → best={s} regret={d:.1}\n", .{
            evo.arms[evo.bestArm()].getName(),
            evo.cumulativeRegret(),
        });
        evo.evolve();
    }

    print("\n  done. ({d} total pulls across all phases)\n\n", .{evo.total_pulls});
}
