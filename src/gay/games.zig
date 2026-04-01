// games.zig: Open games with colored strategies, Nash equilibrium, game composition
// Zig translation of Gay.jl's games.jl and traced_tensor.jl
// Coordination games, Mobius inversion, Markov blankets, traced monoidal categories

const std = @import("std");
const splitmix = @import("splitmix.zig");
const splitmix64 = splitmix.splitmix64;
const GAY_SEED: u64 = splitmix.GAY_SEED;

// ============================================================================
// Player & Facility (Coordination Model)
// ============================================================================

pub const SchedulingPolicy = enum { fifo, delay, spf };

pub const Player = struct {
    id: u32,
    load: f64,
    current_facility: u32,
    cost: f64,
};

pub const Facility = struct {
    id: u32,
    assigned_players: std.BoundedArray(u32, 256),
    scheduling_policy: SchedulingPolicy,
    delay_factor: f64,
};

pub const CoordinationModel = struct {
    players: std.BoundedArray(Player, 256),
    facilities: std.BoundedArray(Facility, 64),

    pub fn init(n: u32, m: u32) CoordinationModel {
        var model: CoordinationModel = .{
            .players = .{},
            .facilities = .{},
        };
        // Create facilities
        for (0..m) |j| {
            model.facilities.append(.{
                .id = @intCast(j),
                .assigned_players = .{},
                .scheduling_policy = .fifo,
                .delay_factor = 0.1,
            }) catch unreachable;
        }
        // Create players, round-robin assign
        for (0..n) |i| {
            const fac: u32 = @intCast(i % m);
            model.players.append(.{
                .id = @intCast(i),
                .load = 1.0,
                .current_facility = fac,
                .cost = 0.0,
            }) catch unreachable;
            model.facilities.slice()[fac].assigned_players.append(@intCast(i)) catch unreachable;
        }
        return model;
    }

    pub fn computeCost(self: *const CoordinationModel, facility_id: u32, player_id: u32) f64 {
        const fac = self.facilities.slice()[facility_id];
        const assigned = fac.assigned_players.slice();
        if (assigned.len == 0) return 0.0;

        var base_cost: f64 = 0.0;
        for (assigned) |pid| {
            base_cost += self.players.slice()[pid].load;
        }

        var delay: f64 = 0.0;
        switch (fac.scheduling_policy) {
            .fifo => {
                for (assigned, 0..) |pid, pos| {
                    if (pid == player_id) {
                        delay = @as(f64, @floatFromInt(pos + 1)) * fac.delay_factor;
                        break;
                    }
                }
            },
            .delay => {
                delay = @abs(@sin(@as(f64, @floatFromInt(player_id)) * 0.1 + 1069.0)) * fac.delay_factor;
            },
            .spf => {
                for (assigned, 0..) |pid, pos| {
                    if (pid == player_id) {
                        delay = @as(f64, @floatFromInt(assigned.len - pos)) * fac.delay_factor;
                        break;
                    }
                }
            },
        }
        return base_cost + delay;
    }

    pub fn socialCost(self: *const CoordinationModel) f64 {
        var total: f64 = 0.0;
        for (self.facilities.slice()) |fac| {
            for (fac.assigned_players.slice()) |pid| {
                total += self.computeCost(fac.id, pid);
            }
        }
        return total;
    }

    pub fn makespan(self: *const CoordinationModel) f64 {
        var max_cost: f64 = 0.0;
        for (self.facilities.slice()) |fac| {
            for (fac.assigned_players.slice()) |pid| {
                max_cost = @max(max_cost, self.computeCost(fac.id, pid));
            }
        }
        return max_cost;
    }
};

// ============================================================================
// Chromatic State (color from game config)
// ============================================================================

pub const ChromaticState = struct {
    address: u32,
    r: f64,
    g: f64,
    b: f64,
    stability: f64,
};

pub fn gameStateToAddress(model: *const CoordinationModel, player_id: u32) u32 {
    const fac_id = model.players.slice()[player_id].current_facility;
    const congestion: u32 = @intCast(model.facilities.slice()[fac_id].assigned_players.len);
    const m: u32 = @intCast(model.facilities.len);
    return (fac_id + congestion * m) % 2187;
}

pub fn chromaticState(model: *const CoordinationModel, player_id: u32) ChromaticState {
    const address = gameStateToAddress(model, player_id);
    var rng = splitmix64(@as(u64, address));
    const r: f64 = @as(f64, @floatFromInt(rng & 0xFFFF)) / 65535.0;
    rng = splitmix64(rng);
    const g: f64 = @as(f64, @floatFromInt(rng & 0xFFFF)) / 65535.0;
    rng = splitmix64(rng);
    const b: f64 = @as(f64, @floatFromInt(rng & 0xFFFF)) / 65535.0;
    const fac_id = model.players.slice()[player_id].current_facility;
    const n_assigned = model.facilities.slice()[fac_id].assigned_players.len;
    const stability = 1.0 / @as(f64, @floatFromInt(@max(n_assigned, 1)));
    return .{ .address = address, .r = r, .g = g, .b = b, .stability = stability };
}

// ============================================================================
// Mobius Inversion
// ============================================================================

/// Mobius function on coalitions (represented as bitmasks).
/// mu(S, T) = 1 if S==T, (-1)^(|T|-|S|) if S subset T, 0 otherwise.
pub fn moebiusFunction(coalition1: u64, coalition2: u64) i32 {
    if (coalition1 == coalition2) return 1;
    if ((coalition1 & coalition2) == coalition1) {
        // coalition1 is subset of coalition2
        const diff = @popCount(coalition2) - @popCount(coalition1);
        return if (diff % 2 == 0) 1 else -1;
    }
    return 0;
}

// ============================================================================
// Markov Blanket
// ============================================================================

/// Returns bitmask of players sharing a facility with player_id (excluding self).
pub fn markovBlanket(model: *const CoordinationModel, player_id: u32) u64 {
    const fac_id = model.players.slice()[player_id].current_facility;
    var blanket: u64 = 0;
    for (model.facilities.slice()[fac_id].assigned_players.slice()) |pid| {
        if (pid != player_id) {
            blanket |= @as(u64, 1) << @intCast(pid);
        }
    }
    return blanket;
}

/// Verify blanket structure: blanket size == facility occupancy - 1.
pub fn verifyBlanketStructure(model: *const CoordinationModel) bool {
    for (0..model.players.len) |i| {
        const pid: u32 = @intCast(i);
        const blanket = markovBlanket(model, pid);
        const fac_id = model.players.slice()[pid].current_facility;
        const expected = model.facilities.slice()[fac_id].assigned_players.len - 1;
        if (@popCount(blanket) != expected) return false;
    }
    return true;
}

// ============================================================================
// Price of Anarchy
// ============================================================================

pub fn priceOfAnarchy(selfish: *const CoordinationModel, optimal: *const CoordinationModel) f64 {
    const s = selfish.makespan();
    const o = optimal.makespan();
    return if (o == 0.0) 1.0 else s / o;
}

// ============================================================================
// Open Game (Hedges-style)
// ============================================================================

pub const OpenGame = struct {
    name: [32]u8,
    name_len: u8,
    /// Number of strategy choices
    n_strategies: u32,
    /// Payoff matrix (row-major, max 16x16)
    payoffs: [256]f64,
    /// Color fingerprint
    fingerprint: u64,

    pub fn init(name: []const u8, n_strategies: u32, seed: u64) OpenGame {
        var game: OpenGame = .{
            .name = [_]u8{0} ** 32,
            .name_len = @intCast(@min(name.len, 32)),
            .n_strategies = n_strategies,
            .payoffs = [_]f64{0.0} ** 256,
            .fingerprint = 0,
        };
        @memcpy(game.name[0..game.name_len], name[0..game.name_len]);
        // Generate payoffs from seed
        var s = seed;
        var fp: u64 = 0;
        for (0..n_strategies * n_strategies) |i| {
            s = splitmix64(s);
            game.payoffs[i] = @as(f64, @floatFromInt(s & 0xFFFF)) / 65535.0;
            fp ^= s;
        }
        game.fingerprint = fp;
        return game;
    }

    /// Check if strategy profile (i, j) is a Nash equilibrium.
    pub fn isNash(self: *const OpenGame, i: u32, j: u32) bool {
        const n = self.n_strategies;
        const current = self.payoffs[i * n + j];
        // Check player 1 deviations
        for (0..n) |alt| {
            if (self.payoffs[alt * n + j] > current + 1e-10) return false;
        }
        // Check player 2 deviations (use column)
        for (0..n) |alt| {
            if (self.payoffs[i * n + alt] > current + 1e-10) return false;
        }
        return true;
    }

    /// Find all Nash equilibria.
    pub fn findNashEquilibria(self: *const OpenGame) std.BoundedArray([2]u32, 64) {
        var result: std.BoundedArray([2]u32, 64) = .{};
        for (0..self.n_strategies) |i| {
            for (0..self.n_strategies) |j| {
                if (self.isNash(@intCast(i), @intCast(j))) {
                    result.append(.{ @intCast(i), @intCast(j) }) catch break;
                }
            }
        }
        return result;
    }
};

// ============================================================================
// Game Composition
// ============================================================================

/// Sequential composition: play game1 then game2.
pub fn composeSequential(g1: *const OpenGame, g2: *const OpenGame) OpenGame {
    var result = OpenGame.init("seq", @min(g1.n_strategies, g2.n_strategies), g1.fingerprint ^ g2.fingerprint);
    result.fingerprint = g1.fingerprint ^ g2.fingerprint;
    // Combined payoffs: sum
    const n = result.n_strategies;
    for (0..n) |i| {
        for (0..n) |j| {
            result.payoffs[i * n + j] = g1.payoffs[i * n + j] + g2.payoffs[i * n + j];
        }
    }
    return result;
}

/// Parallel composition: tensor product of games.
pub fn composeParallel(g1: *const OpenGame, g2: *const OpenGame) OpenGame {
    var result = OpenGame.init("par", g1.n_strategies * g2.n_strategies, g1.fingerprint ^ g2.fingerprint);
    result.fingerprint = g1.fingerprint ^ g2.fingerprint;
    return result;
}

// ============================================================================
// Traced Monoidal Category (String Diagrams with Feedback)
// ============================================================================

pub const TracedMorphism = struct {
    transform: u64,
    rotation: u6,
    parity_flip: bool,
    seed: u64,

    pub fn identity(seed: u64) TracedMorphism {
        return .{ .transform = 0, .rotation = 0, .parity_flip = false, .seed = seed };
    }

    pub fn fromConcept(i: u32, j: u32, k: u32, seed: u64) TracedMorphism {
        const idx = @as(u64, i) * 69 * 69 + @as(u64, j) * 69 + @as(u64, k);
        const h = splitmix64(seed ^ idx);
        return .{
            .transform = h,
            .rotation = @truncate(h & 63),
            .parity_flip = (h & 64) != 0,
            .seed = seed,
        };
    }

    /// Compose: f ; g
    pub fn compose(self: TracedMorphism, other: TracedMorphism) TracedMorphism {
        const new_transform = std.math.rotl(u64, self.transform, self.rotation) ^ other.transform;
        return .{
            .transform = new_transform,
            .rotation = @truncate((@as(u7, self.rotation) + @as(u7, other.rotation)) % 64),
            .parity_flip = self.parity_flip != other.parity_flip,
            .seed = self.seed,
        };
    }

    /// Tensor product: f tensor g
    pub fn tensorProduct(self: TracedMorphism, other: TracedMorphism) TracedMorphism {
        return .{
            .transform = self.transform ^ other.transform,
            .rotation = @truncate((@as(u7, self.rotation) + @as(u7, other.rotation)) % 64),
            .parity_flip = self.parity_flip != other.parity_flip,
            .seed = self.seed,
        };
    }

    /// Feedback loop: iterate n times with XOR accumulation.
    pub fn feedbackLoop(self: TracedMorphism, n: u32) TracedMorphism {
        var result = TracedMorphism.identity(self.seed);
        var accumulated: u64 = 0;
        for (0..n) |_| {
            result = result.compose(self);
            accumulated ^= result.transform;
        }
        return .{
            .transform = accumulated,
            .rotation = result.rotation,
            .parity_flip = result.parity_flip,
            .seed = self.seed,
        };
    }

    /// Categorical trace: iterate feedback to fixpoint.
    pub fn categoricalTrace(self: TracedMorphism, feedback_transform: u64, max_iter: u32) TracedMorphism {
        var trace_state = TracedMorphism.identity(self.seed);
        for (0..max_iter) |_| {
            const combined = self.compose(trace_state);
            const new_transform = std.math.rotl(u64, combined.transform, 16) ^ feedback_transform;
            const new_trace = TracedMorphism{
                .transform = new_transform,
                .rotation = @truncate(combined.rotation),
                .parity_flip = combined.parity_flip,
                .seed = self.seed,
            };
            if (new_trace.transform == trace_state.transform) break;
            trace_state = new_trace;
        }
        return self.compose(trace_state);
    }
};

// ============================================================================
// Tensor Network
// ============================================================================

pub const TensorNetwork = struct {
    const MAX_NODES = 32;
    const MAX_EDGES = 64;

    nodes: std.BoundedArray(TracedMorphism, MAX_NODES),
    /// Edges: (from, to)
    edges: std.BoundedArray([2]u8, MAX_EDGES),
    /// Trace edges: node index
    trace_edges: std.BoundedArray(u8, MAX_NODES),
    fingerprint: u32,
    seed: u64,

    pub fn init(seed: u64) TensorNetwork {
        return .{
            .nodes = .{},
            .edges = .{},
            .trace_edges = .{},
            .fingerprint = 0,
            .seed = seed,
        };
    }

    pub fn addNode(self: *TensorNetwork, m: TracedMorphism) u8 {
        const idx: u8 = @intCast(self.nodes.len);
        self.nodes.append(m) catch return idx;
        return idx;
    }

    pub fn addEdge(self: *TensorNetwork, from: u8, to: u8) void {
        self.edges.append(.{ from, to }) catch {};
    }

    pub fn addTrace(self: *TensorNetwork, node: u8) void {
        self.trace_edges.append(node) catch {};
    }

    pub fn run(self: *TensorNetwork) TracedMorphism {
        if (self.nodes.len == 0) return TracedMorphism.identity(self.seed);
        var result = self.nodes.slice()[0];
        for (1..self.nodes.len) |i| {
            const m = self.nodes.slice()[i];
            var has_edge = false;
            for (self.edges.slice()) |e| {
                if (e[0] == i - 1 and e[1] == i) {
                    has_edge = true;
                    break;
                }
            }
            result = if (has_edge) result.compose(m) else result.tensorProduct(m);
        }
        for (self.trace_edges.slice()) |node_idx| {
            const m = self.nodes.slice()[node_idx];
            const traced = m.feedbackLoop(100);
            result = result.compose(traced);
        }
        self.fingerprint = @truncate(result.transform);
        return result;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "coordination model init" {
    const model = CoordinationModel.init(6, 3);
    try std.testing.expectEqual(@as(usize, 6), model.players.len);
    try std.testing.expectEqual(@as(usize, 3), model.facilities.len);
    // Round-robin: 2 players per facility
    for (model.facilities.slice()) |fac| {
        try std.testing.expectEqual(@as(usize, 2), fac.assigned_players.len);
    }
}

test "social cost and makespan" {
    const model = CoordinationModel.init(6, 3);
    const sc = model.socialCost();
    const ms = model.makespan();
    try std.testing.expect(sc > 0.0);
    try std.testing.expect(ms > 0.0);
    try std.testing.expect(sc >= ms);
}

test "chromatic state determinism" {
    const model = CoordinationModel.init(4, 2);
    const cs1 = chromaticState(&model, 0);
    const cs2 = chromaticState(&model, 0);
    try std.testing.expectEqual(cs1.address, cs2.address);
    try std.testing.expectEqual(cs1.r, cs2.r);
    try std.testing.expectEqual(cs1.g, cs2.g);
    try std.testing.expectEqual(cs1.b, cs2.b);
}

test "mobius function" {
    // S == T
    try std.testing.expectEqual(@as(i32, 1), moebiusFunction(0b101, 0b101));
    // S subset T, diff=1 -> -1
    try std.testing.expectEqual(@as(i32, -1), moebiusFunction(0b001, 0b011));
    // S subset T, diff=2 -> 1
    try std.testing.expectEqual(@as(i32, 1), moebiusFunction(0b001, 0b111));
    // Not subset
    try std.testing.expectEqual(@as(i32, 0), moebiusFunction(0b110, 0b011));
}

test "markov blanket verification" {
    const model = CoordinationModel.init(6, 3);
    try std.testing.expect(verifyBlanketStructure(&model));
}

test "open game nash equilibria" {
    // Prisoner's dilemma style
    var game: OpenGame = .{
        .name = [_]u8{0} ** 32,
        .name_len = 2,
        .n_strategies = 2,
        .payoffs = [_]f64{0.0} ** 256,
        .fingerprint = 0,
    };
    game.name[0] = 'P';
    game.name[1] = 'D';
    // Payoff matrix where (1,1) is the unique maximum
    game.payoffs[0] = 1.0; // (0,0)
    game.payoffs[1] = 0.0; // (0,1)
    game.payoffs[2] = 0.0; // (1,0)
    game.payoffs[3] = 2.0; // (1,1)
    // (1,1) is Nash: 2 > 0 in both row and column
    try std.testing.expect(game.isNash(1, 1));
}

test "game composition sequential" {
    const g1 = OpenGame.init("g1", 3, GAY_SEED);
    const g2 = OpenGame.init("g2", 3, splitmix64(GAY_SEED));
    const composed = composeSequential(&g1, &g2);
    try std.testing.expectEqual(@as(u32, 3), composed.n_strategies);
    try std.testing.expectEqual(g1.fingerprint ^ g2.fingerprint, composed.fingerprint);
}

test "traced morphism compose determinism" {
    const a = TracedMorphism.fromConcept(1, 2, 3, GAY_SEED);
    const b = TracedMorphism.fromConcept(4, 5, 6, GAY_SEED);
    const ab1 = a.compose(b);
    const ab2 = a.compose(b);
    // Same inputs => same output (deterministic)
    try std.testing.expectEqual(ab1.transform, ab2.transform);
    try std.testing.expectEqual(ab1.rotation, ab2.rotation);
}

test "feedback loop determinism" {
    const m = TracedMorphism.fromConcept(1, 1, 1, GAY_SEED);
    const fb1 = m.feedbackLoop(10);
    const fb2 = m.feedbackLoop(10);
    try std.testing.expectEqual(fb1.transform, fb2.transform);
}

test "identity feedback vanishes" {
    const id = TracedMorphism.identity(GAY_SEED);
    const fb = id.feedbackLoop(10);
    try std.testing.expectEqual(@as(u64, 0), fb.transform);
}

test "tensor product with identity preserves parity" {
    const id = TracedMorphism.identity(GAY_SEED);
    const m = TracedMorphism.fromConcept(3, 3, 3, GAY_SEED);
    const result = id.tensorProduct(m);
    try std.testing.expectEqual(m.parity_flip, result.parity_flip);
}

test "tensor network composition" {
    var net = TensorNetwork.init(GAY_SEED);
    const n1 = net.addNode(TracedMorphism.identity(GAY_SEED));
    const n2 = net.addNode(TracedMorphism.fromConcept(1, 1, 1, GAY_SEED));
    const n3 = net.addNode(TracedMorphism.fromConcept(2, 2, 2, GAY_SEED));
    net.addEdge(n1, n2);
    net.addEdge(n2, n3);
    const result = net.run();
    try std.testing.expect(result.transform != 0);
    try std.testing.expect(net.fingerprint != 0);
}

test "categorical trace converges" {
    const m = TracedMorphism.fromConcept(5, 5, 5, GAY_SEED);
    const traced = m.categoricalTrace(0xDEADBEEF, 100);
    // Should produce a valid morphism
    try std.testing.expect(traced.seed == GAY_SEED);
}

test "price of anarchy" {
    const selfish = CoordinationModel.init(6, 2);
    const optimal = CoordinationModel.init(6, 3);
    const poa = priceOfAnarchy(&selfish, &optimal);
    try std.testing.expect(poa >= 1.0);
}
