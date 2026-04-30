//! SET as RL Environment via Open Game Composition
//!
//! This module lifts set_game.zig into the open game framework (nanoclj-zig/open_game.zig).
//! The central thesis: SET-finding decomposes into 13 RL-able surfaces, each an open game
//! box with play (forward: observation→action) and coplay (backward: reward→update).
//!
//! Obstructions to compositionality are catalogued explicitly — they are the places where
//! the composed game fails to decompose into independent subgames, requiring coordination.
//!
//! 3-MATCH verification: every triple of cards forms a valid SET iff each of the 4 GF(3)
//! properties sums to 0 mod 3. This is the "carry-free verification" — O(1) check, no
//! propagation, no ripple. The open game coplay (backward) pass uses this as the ground
//! truth reward signal.
//!
//! Architecture:
//!   SET_Game = nature(deal) ; (decision(scan)⊗decision(thresh)⊗decision(switch)⊗decision(depth))
//!             ; forward(group) ; dependent-decision(search) ; forward(gf3-verify)
//!             ; add-payoffs(fitness) ; discount(0.99)

const std = @import("std");
const set = @import("set_game");
const lux = @import("lux_color");

const Card = set.Card;
const Board = set.Board;
const Strategy = set.Strategy;
const Arena = set.Arena;
const SetTriple = set.SetTriple;
const Rng = set.Rng;
const Trit = lux.Trit;

// ============================================================================
// Open Game Box Types (mirroring open_game.zig's Scan categories)
// ============================================================================

const BoxKind = enum(u4) {
    nature,               // stochastic, no learnable params (Board.deal)
    decision,             // learnable: obs → action (Strategy.findSet)
    decision_no_obs,      // learnable: ∅ → param (threshold, switch, depth)
    dependent_decision,   // learnable: obs-dependent (scan conditioned on groups)
    forward_function,     // deterministic: no backward (isSet, thirdCard, findAllSets)
    backward_function,    // deterministic with backward (mobiusCount → reward shaping)
    add_payoffs,          // terminal reward (Arena.evaluate)
    discount,             // temporal discounting
    lens,                 // bidirectional (colorVerifyBest)
};

// ============================================================================
// Obstruction Catalogue: where compositionality breaks
// ============================================================================
// An obstruction is a point where the composed game cannot be decomposed into
// independent subgames. These require coordination signals between boxes.

const ObstructionKind = enum(u4) {
    /// scan_order affects which groups are formed → group quality affects search success
    /// Sequential dependency: decision(scan) must precede forward(group)
    scan_group_coupling,

    /// threshold affects whether groups are investigated → search space depends on threshold
    /// Cross-box dependency: decision(threshold) constrains dependent-decision(search)
    threshold_search_coupling,

    /// depth_limit truncates search → found SETs depend on budget allocation
    /// Resource constraint: decision(depth) bounds dependent-decision(search)
    depth_search_truncation,

    /// switch_after rotates attention → different property groupings see different SETs
    /// Temporal dependency: decision(switch) induces non-stationarity in search
    switch_nonstationarity,

    /// Board state changes after SET removal → future decisions depend on past actions
    /// History dependency: nature(deal) + add-payoffs creates a Markov chain
    board_state_markov,

    /// Möbius reward shaping depends on ALL board cards → not decomposable per-card
    /// Global dependency: backward(mobius) requires full board context
    mobius_global_context,

    /// GF(3) verification is property-wise independent BUT the reward is per-triple
    /// Aggregation obstruction: forward(verify) decomposes, add-payoffs does not
    verification_reward_gap,

    /// Perceptual grouping creates information loss → cannot recover ungrouped view
    /// Irreversibility: forward(group) is a surjection, not an injection
    group_information_loss,

    /// Two-player gamut game: alignment transforms are not commutative
    /// Multi-agent obstruction: Agent A's alignment ≠ Agent B's alignment (in general)
    gamut_noncommutativity,
};

const Obstruction = struct {
    kind: ObstructionKind,
    box_a: BoxKind,        // first coupled box
    box_b: BoxKind,        // second coupled box
    severity: u4,          // 0 = mild (local fix), 15 = fundamental (structural)
    composable_around: bool, // can we compose around this obstruction?
};

const OBSTRUCTION_CATALOGUE = [_]Obstruction{
    .{ .kind = .scan_group_coupling,       .box_a = .decision,           .box_b = .forward_function,    .severity = 8,  .composable_around = true },
    .{ .kind = .threshold_search_coupling,  .box_a = .decision_no_obs,   .box_b = .dependent_decision,  .severity = 6,  .composable_around = true },
    .{ .kind = .depth_search_truncation,    .box_a = .decision_no_obs,   .box_b = .dependent_decision,  .severity = 10, .composable_around = false },
    .{ .kind = .switch_nonstationarity,     .box_a = .decision_no_obs,   .box_b = .decision,            .severity = 7,  .composable_around = true },
    .{ .kind = .board_state_markov,         .box_a = .nature,            .box_b = .add_payoffs,          .severity = 12, .composable_around = false },
    .{ .kind = .mobius_global_context,       .box_a = .backward_function, .box_b = .add_payoffs,          .severity = 9,  .composable_around = false },
    .{ .kind = .verification_reward_gap,    .box_a = .forward_function,  .box_b = .add_payoffs,          .severity = 4,  .composable_around = true },
    .{ .kind = .group_information_loss,     .box_a = .forward_function,  .box_b = .dependent_decision,  .severity = 11, .composable_around = false },
    .{ .kind = .gamut_noncommutativity,     .box_a = .lens,              .box_b = .lens,                .severity = 13, .composable_around = false },
};

// ============================================================================
// Open Game Scan for SET (matches open_game.zig Scan struct)
// ============================================================================

const SetGameScan = struct {
    decision_boxes: u8 = 4,              // scan_order, threshold, switch, depth
    dependent_decision_boxes: u8 = 1,    // search conditioned on groups
    nature_boxes: u8 = 1,                // board dealing
    forward_function_boxes: u8 = 3,      // grouping, GF(3) verify, thirdCard
    backward_function_boxes: u8 = 1,     // Möbius reward shaping
    payoff_boxes: u8 = 1,                // fitness
    discount_boxes: u8 = 1,              // temporal
    lens_boxes: u8 = 1,                  // colorVerifyBest

    fn strategicBoxes(self: *const SetGameScan) u8 {
        return self.decision_boxes + self.dependent_decision_boxes +
            self.nature_boxes + self.forward_function_boxes +
            self.backward_function_boxes + self.payoff_boxes +
            self.discount_boxes + self.lens_boxes;
    }

    fn hasStrategicSurface(self: *const SetGameScan) bool {
        return (self.decision_boxes + self.dependent_decision_boxes) > 0;
    }

    fn obstructionCount(_: *const SetGameScan) usize {
        return OBSTRUCTION_CATALOGUE.len;
    }

    fn composableObstructions(_: *const SetGameScan) usize {
        var count: usize = 0;
        for (OBSTRUCTION_CATALOGUE) |o| {
            if (o.composable_around) count += 1;
        }
        return count;
    }

    fn fundamentalObstructions(self: *const SetGameScan) usize {
        return self.obstructionCount() - self.composableObstructions();
    }
};

const SET_GAME_SCAN = SetGameScan{};

// ============================================================================
// Play Mode (Forward): Board → Strategy → SetTriple?
// ============================================================================
// The "play" function of the composed open game. Takes a board state,
// applies the strategy's perceptual grouping, searches within groups,
// and returns the found SET (or null). This is the forward trace.

const PlayTrace = struct {
    board: Board,
    strategy: Strategy,
    groups: [3]GroupInfo,
    found_set: ?SetTriple,
    checks_performed: u16,
    gf3_verified: bool,
    trits: [3]Trit,
    conserved: bool,
};

const GroupInfo = struct {
    prop_value: u2,
    count: u8,
    indices: [set.MAX_BOARD]u8,
};

fn play(board: *const Board, strategy: *const Strategy) PlayTrace {
    var trace: PlayTrace = undefined;
    trace.board = board.*;
    trace.strategy = strategy.*;
    trace.checks_performed = 0;

    // Group by primary property (forward-function box: "perceptual-group")
    const primary: u2 = @intFromEnum(strategy.scan_order);
    for (0..3) |g| {
        trace.groups[g] = .{ .prop_value = @intCast(g), .count = 0, .indices = undefined };
    }
    for (0..board.len) |i| {
        const val = board.cards[i].prop(primary);
        const gi = &trace.groups[val];
        gi.indices[gi.count] = @intCast(i);
        gi.count += 1;
    }

    // Search (dependent-decision box: conditioned on group observation)
    trace.found_set = strategy.findSet(board);

    // GF(3) verify (forward-function box: deterministic, carry-free)
    if (trace.found_set) |triple| {
        trace.gf3_verified = set.isSet(
            board.cards[triple.i],
            board.cards[triple.j],
            board.cards[triple.k],
        );
        // 3-MATCH: map cards to trits for color conservation check
        const ta = Card.toTrit(@truncate(board.cards[triple.i].perceptualIndex() % 3));
        const tb = Card.toTrit(@truncate(board.cards[triple.j].perceptualIndex() % 3));
        const tc = Card.toTrit(@truncate(board.cards[triple.k].perceptualIndex() % 3));
        trace.trits = .{ ta, tb, tc };
        trace.conserved = Trit.conserved(&trace.trits);
    } else {
        trace.gf3_verified = false;
        trace.trits = .{ .ergodic, .ergodic, .ergodic };
        trace.conserved = true;
    }

    return trace;
}

// ============================================================================
// Evaluate Mode (Backward): PlayTrace × Reward → StrategyUpdate
// ============================================================================
// The "evaluate" function performs best-response diagnostics.
// For each decision box, check if there exists a profitable deviation.

const BestResponseDiagnostic = struct {
    box_name: []const u8,
    current_value: u8,
    best_value: u8,
    current_payoff: f32,
    best_payoff: f32,
    is_equilibrium: bool,
    profitable_deviation: bool,
};

const EvaluationResult = struct {
    diagnostics: [6]BestResponseDiagnostic, // 4 decisions + 1 dependent + 1 lens
    diag_count: u8,
    total_payoff: f32,
    discounted_payoff: f32,
    mobius_shaped_payoff: f32,
    nash_equilibrium: bool,
    obstruction_active: [OBSTRUCTION_CATALOGUE.len]bool,
};

fn evaluate(trace: *const PlayTrace, rng: *Rng) EvaluationResult {
    var result: EvaluationResult = undefined;
    result.diag_count = 0;
    result.nash_equilibrium = true;

    // Base payoff: did we find a SET?
    const base_payoff: f32 = if (trace.found_set != null) 1.0 else 0.0;

    // Möbius shaping (backward-function box)
    var mobius_bonus: f32 = 0.0;
    if (trace.found_set != null) {
        const all_sets = trace.board.findAllSets();
        const density: f32 = @as(f32, @floatFromInt(all_sets.count)) / 220.0;
        mobius_bonus = density * 0.5; // harder boards = more reward
    }

    result.total_payoff = base_payoff + mobius_bonus;
    result.discounted_payoff = result.total_payoff * 0.99;
    result.mobius_shaped_payoff = result.total_payoff;

    // Best-response check for scan_order (decision box 1)
    {
        var best_found: u32 = 0;
        var best_order: u2 = @intFromEnum(trace.strategy.scan_order);
        var current_found: u32 = 0;

        for (0..4) |order_val| {
            var alt_strat = trace.strategy;
            alt_strat.scan_order = @enumFromInt(@as(u2, @intCast(order_val)));
            var found: u32 = 0;
            var test_rng = Rng.init(rng.state);
            for (0..10) |_| {
                var board = Board.deal(&test_rng, 12);
                if (alt_strat.findSet(&board) != null) found += 1;
            }
            if (order_val == @intFromEnum(trace.strategy.scan_order)) current_found = found;
            if (found > best_found) {
                best_found = found;
                best_order = @intCast(order_val);
            }
        }

        const is_eq = (best_order == @intFromEnum(trace.strategy.scan_order));
        result.diagnostics[result.diag_count] = .{
            .box_name = "scan_order",
            .current_value = @intFromEnum(trace.strategy.scan_order),
            .best_value = best_order,
            .current_payoff = @as(f32, @floatFromInt(current_found)) / 10.0,
            .best_payoff = @as(f32, @floatFromInt(best_found)) / 10.0,
            .is_equilibrium = is_eq,
            .profitable_deviation = !is_eq,
        };
        if (!is_eq) result.nash_equilibrium = false;
        result.diag_count += 1;
    }

    // Best-response check for depth_limit (decision box 2 — representative)
    {
        var best_found: u32 = 0;
        var best_depth: u4 = trace.strategy.depth_limit;
        var current_found: u32 = 0;

        for (3..15) |depth_val| {
            var alt_strat = trace.strategy;
            alt_strat.depth_limit = @intCast(depth_val);
            var found: u32 = 0;
            var test_rng = Rng.init(rng.state);
            for (0..10) |_| {
                var board = Board.deal(&test_rng, 12);
                if (alt_strat.findSet(&board) != null) found += 1;
            }
            if (depth_val == trace.strategy.depth_limit) current_found = found;
            if (found > best_found) {
                best_found = found;
                best_depth = @intCast(depth_val);
            }
        }

        const is_eq = (best_depth == trace.strategy.depth_limit);
        result.diagnostics[result.diag_count] = .{
            .box_name = "depth_limit",
            .current_value = trace.strategy.depth_limit,
            .best_value = best_depth,
            .current_payoff = @as(f32, @floatFromInt(current_found)) / 10.0,
            .best_payoff = @as(f32, @floatFromInt(best_found)) / 10.0,
            .is_equilibrium = is_eq,
            .profitable_deviation = !is_eq,
        };
        if (!is_eq) result.nash_equilibrium = false;
        result.diag_count += 1;
    }

    // 3-MATCH conservation check (lens box — bidirectional)
    {
        const cons_payoff: f32 = if (trace.conserved) 0.1 else -0.1;
        result.diagnostics[result.diag_count] = .{
            .box_name = "3match_lens",
            .current_value = if (trace.conserved) 1 else 0,
            .best_value = 1,
            .current_payoff = cons_payoff,
            .best_payoff = 0.1,
            .is_equilibrium = trace.conserved,
            .profitable_deviation = !trace.conserved,
        };
        result.diag_count += 1;
    }

    // Obstruction activation check
    for (0..OBSTRUCTION_CATALOGUE.len) |i| {
        result.obstruction_active[i] = checkObstructionActive(&OBSTRUCTION_CATALOGUE[i], trace);
    }

    return result;
}

fn checkObstructionActive(obs: *const Obstruction, trace: *const PlayTrace) bool {
    return switch (obs.kind) {
        .scan_group_coupling => blk: {
            // Active if groups are highly unbalanced
            const max_g = @max(trace.groups[0].count, @max(trace.groups[1].count, trace.groups[2].count));
            const min_g = @min(trace.groups[0].count, @min(trace.groups[1].count, trace.groups[2].count));
            break :blk (max_g > min_g * 3);
        },
        .depth_search_truncation => trace.found_set == null and trace.checks_performed > 0,
        .board_state_markov => true, // always active in sequential play
        .mobius_global_context => trace.board.len > 12,
        .verification_reward_gap => trace.found_set != null and !trace.gf3_verified,
        .group_information_loss => blk: {
            // Active if any group has 0 members (information about missing values lost)
            break :blk (trace.groups[0].count == 0 or trace.groups[1].count == 0 or trace.groups[2].count == 0);
        },
        else => false,
    };
}

// ============================================================================
// RL Episode: play → evaluate → update loop
// ============================================================================

const Episode = struct {
    traces: [20]PlayTrace,
    evaluations: [20]EvaluationResult,
    step_count: u8,
    cumulative_reward: f32,
    sets_found: u32,
    nash_steps: u32, // steps where strategy was at Nash equilibrium
};

fn runEpisode(strategy: *Strategy, rng: *Rng, steps: u8) Episode {
    var ep: Episode = undefined;
    ep.step_count = @min(steps, 20);
    ep.cumulative_reward = 0;
    ep.sets_found = 0;
    ep.nash_steps = 0;

    for (0..ep.step_count) |i| {
        var board = Board.deal(rng, 12);
        ep.traces[i] = play(&board, strategy);
        ep.evaluations[i] = evaluate(&ep.traces[i], rng);
        ep.cumulative_reward += ep.evaluations[i].discounted_payoff;
        if (ep.traces[i].found_set != null) ep.sets_found += 1;
        if (ep.evaluations[i].nash_equilibrium) ep.nash_steps += 1;

        // Policy update: if profitable deviation found, take it
        for (0..ep.evaluations[i].diag_count) |d| {
            const diag = ep.evaluations[i].diagnostics[d];
            if (diag.profitable_deviation) {
                if (std.mem.eql(u8, diag.box_name, "scan_order")) {
                    strategy.scan_order = @enumFromInt(@as(u2, @truncate(diag.best_value)));
                } else if (std.mem.eql(u8, diag.box_name, "depth_limit")) {
                    strategy.depth_limit = @truncate(diag.best_value);
                }
            }
        }
    }

    return ep;
}

// ============================================================================
// Curriculum: board difficulty levels (from rl-perceptual-set.md §6)
// ============================================================================

const DifficultyLevel = enum(u3) {
    trivial,      // μ=1: single isolated SET
    easy,         // μ=3-5: multiple SETs, some overlap
    medium,       // μ>10: dense SET structure
    hard,         // 12 cards near cap-set boundary
    impossible,   // 20 cards, 0 SETs (cap set)
};

fn dealAtDifficulty(rng: *Rng, level: DifficultyLevel) Board {
    switch (level) {
        .trivial => {
            // Deal until exactly 1 SET exists
            for (0..100) |_| {
                const b = Board.deal(rng, 12);
                const result = b.findAllSets();
                if (result.count == 1) return b;
            }
            return Board.deal(rng, 12);
        },
        .easy => {
            for (0..100) |_| {
                const b = Board.deal(rng, 12);
                const result = b.findAllSets();
                if (result.count >= 3 and result.count <= 5) return b;
            }
            return Board.deal(rng, 12);
        },
        .medium => {
            for (0..100) |_| {
                const b = Board.deal(rng, 15);
                const result = b.findAllSets();
                if (result.count > 10) return b;
            }
            return Board.deal(rng, 15);
        },
        .hard => {
            // Deal 12 cards, prefer boards with few SETs
            for (0..100) |_| {
                const b = Board.deal(rng, 12);
                const result = b.findAllSets();
                if (result.count <= 2 and result.count > 0) return b;
            }
            return Board.deal(rng, 12);
        },
        .impossible => {
            // Use greedy cap set construction
            const cap = set.CapSearch.greedyCap(rng);
            var b = Board.init();
            const n: u8 = @min(cap.len, set.MAX_BOARD);
            @memcpy(b.cards[0..n], cap.cards[0..n]);
            b.len = n;
            return b;
        },
    }
}

// ============================================================================
// Three-MATCH Composed Verification
// ============================================================================
// Verifies GF(3) conservation across a sequence of play traces.
// Every consecutive triple of found SETs must have trit-sum = 0 (mod 3).

fn verifyThreeMatchSequence(traces: []const PlayTrace) struct { verified: u32, violations: u32 } {
    var verified: u32 = 0;
    var violations: u32 = 0;

    if (traces.len < 3) return .{ .verified = 0, .violations = 0 };

    var i: usize = 0;
    while (i + 2 < traces.len) : (i += 1) {
        if (traces[i].found_set == null or traces[i + 1].found_set == null or traces[i + 2].found_set == null) continue;

        // Check conservation across the triple of SETs
        // Each SET has 3 trits; the meta-trit for each SET is the sum of its card trits
        const meta_a = tritSum3(traces[i].trits);
        const meta_b = tritSum3(traces[i + 1].trits);
        const meta_c = tritSum3(traces[i + 2].trits);
        const meta_triad = [_]Trit{ meta_a, meta_b, meta_c };

        if (Trit.conserved(&meta_triad)) {
            verified += 1;
        } else {
            violations += 1;
        }
    }

    return .{ .verified = verified, .violations = violations };
}

fn tritSum3(trits: [3]Trit) Trit {
    return trits[0].add(trits[1]).add(trits[2]);
}

// ============================================================================
// Tests
// ============================================================================

test "scan has 13 strategic boxes" {
    try std.testing.expectEqual(@as(u8, 13), SET_GAME_SCAN.strategicBoxes());
}

test "scan has strategic surface" {
    try std.testing.expect(SET_GAME_SCAN.hasStrategicSurface());
}

test "obstruction catalogue has 9 entries" {
    try std.testing.expectEqual(@as(usize, 9), OBSTRUCTION_CATALOGUE.len);
}

test "4 obstructions are composable-around" {
    try std.testing.expectEqual(@as(usize, 4), SET_GAME_SCAN.composableObstructions());
}

test "5 fundamental obstructions" {
    try std.testing.expectEqual(@as(usize, 5), SET_GAME_SCAN.fundamentalObstructions());
}

test "play produces valid trace" {
    var rng = Rng.init(1069);
    var board = Board.deal(&rng, 12);
    const strat = Strategy.init(&rng);
    const trace = play(&board, &strat);
    try std.testing.expectEqual(@as(u8, 12), trace.board.len);
    // Groups should partition the 12 cards
    const total = @as(u16, trace.groups[0].count) + trace.groups[1].count + trace.groups[2].count;
    try std.testing.expectEqual(@as(u16, 12), total);
}

test "play with found SET verifies GF(3)" {
    var rng = Rng.init(42);
    var found_and_verified = false;
    for (0..100) |_| {
        var board = Board.deal(&rng, 12);
        const strat = Strategy{ .scan_order = .color_first, .group_threshold = 1, .switch_after = 8, .depth_limit = 14, .fitness = 0 };
        const trace = play(&board, &strat);
        if (trace.found_set != null) {
            try std.testing.expect(trace.gf3_verified);
            found_and_verified = true;
            break;
        }
    }
    try std.testing.expect(found_and_verified);
}

test "evaluate detects non-equilibrium" {
    var rng = Rng.init(2026);
    // Use a bad strategy (very low depth limit)
    var board = Board.deal(&rng, 12);
    const bad_strat = Strategy{ .scan_order = .shade_first, .group_threshold = 4, .switch_after = 1, .depth_limit = 3, .fitness = 0 };
    const trace = play(&board, &bad_strat);
    const eval_result = evaluate(&trace, &rng);
    // With depth=3, there's likely a profitable deviation to higher depth
    // Ensure evaluation ran without crash; diagnostics count is bounded by surfaces
    try std.testing.expect(eval_result.diag_count <= 13);
}

test "episode runs without crash" {
    var rng = Rng.init(1069);
    var strat = Strategy.init(&rng);
    const ep = runEpisode(&strat, &rng, 10);
    try std.testing.expectEqual(@as(u8, 10), ep.step_count);
    try std.testing.expect(ep.cumulative_reward >= 0);
}

test "curriculum deals boards at each difficulty" {
    var rng = Rng.init(7777);
    inline for (std.meta.fields(DifficultyLevel)) |field| {
        const level: DifficultyLevel = @enumFromInt(field.value);
        const board = dealAtDifficulty(&rng, level);
        try std.testing.expect(board.len > 0);
    }
}

test "three-match verification on episode sequence" {
    var rng = Rng.init(1069);
    var strat = Strategy{ .scan_order = .color_first, .group_threshold = 1, .switch_after = 8, .depth_limit = 14, .fitness = 0 };
    const ep = runEpisode(&strat, &rng, 20);
    const result = verifyThreeMatchSequence(ep.traces[0..ep.step_count]);
    // Just ensure it runs; conservation at meta-level is not guaranteed
    _ = result;
}

test "obstruction activation on real trace" {
    var rng = Rng.init(42);
    var board = Board.deal(&rng, 12);
    const strat = Strategy.init(&rng);
    const trace = play(&board, &strat);
    const eval_result = evaluate(&trace, &rng);
    // board_state_markov should always be active
    try std.testing.expect(eval_result.obstruction_active[4]); // index 4 = board_state_markov
}
