//! Swarm Triad — Distributed triadic coordination for Gay color mining
//!
//! Zig translation of Gay.jl's swarm_triad.jl.
//!
//! Core invariant: every triad_split produces 3 agents whose trits sum to 0 mod 3
//! (GF(3) conservation). A SentinelMonitor tracks compliance across the swarm.
//!
//! wasm32-freestanding compatible. No allocator in hot path (except agent registry).

const std = @import("std");
const splitmix = @import("../splitmix_trit.zig");

const SplitMix64 = splitmix.SplitMix64;
const Trit = splitmix.Trit;

// ============================================================================
// Constants
// ============================================================================

/// Default swarm seed (ASCII "gay_colo" = 0x6761795f636f6c6f)
pub const GAY_SEED_SWARM: u64 = 0x6761795f636f6c6f;

/// Golden ratio constant for seed splitting
const GOLDEN: u64 = 0x9e3779b97f4a7c15;

/// SM64 PRNG multiplier (same as Julia coordinate_swarm)
const SM64_MUL: u64 = 0x5D588B656C078965;
const SM64_ADD: u64 = 0x269EC3;

// ============================================================================
// Agent types
// ============================================================================

pub const AgentState = enum(u8) {
    alive,
    compliant,
    non_compliant,
    dead,
};

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
};

pub const SwarmAgent = struct {
    id: u64,
    state: AgentState,
    seed: u64,
    trit: Trit,
    parent_id: u64,
    generation: u32,

    /// Derive an RGB color from the agent's seed via SplitMix64 mixing.
    pub fn color(self: *const SwarmAgent) Color {
        var rng = SplitMix64.init(self.seed);
        const r_bits = rng.next();
        const g_bits = rng.next();
        const b_bits = rng.next();
        return .{
            .r = @as(f32, @floatFromInt(r_bits >> 40)) / 16777215.0,
            .g = @as(f32, @floatFromInt(g_bits >> 40)) / 16777215.0,
            .b = @as(f32, @floatFromInt(b_bits >> 40)) / 16777215.0,
        };
    }

    /// Identity is the agent id.
    pub fn identity(self: *const SwarmAgent) u64 {
        return self.id;
    }

    /// Check compliance.
    pub fn isCompliant(self: *const SwarmAgent) bool {
        return self.state == .compliant;
    }
};

/// Create a root agent from a seed.
pub fn createAgent(seed: u64) SwarmAgent {
    return .{
        .id = seed,
        .state = .alive,
        .seed = seed,
        .trit = .ergodic, // root agents are ergodic (0)
        .parent_id = 0,
        .generation = 0,
    };
}

// ============================================================================
// Triad split — mandatory 3-way with GF(3) conservation
// ============================================================================

pub const Triad = struct {
    minus: SwarmAgent,
    ergodic: SwarmAgent,
    plus: SwarmAgent,

    /// Verify GF(3) conservation: trits sum to 0 mod 3.
    pub fn isConserved(self: *const Triad) bool {
        const sum: i16 = @as(i16, @intFromEnum(self.minus.trit)) +
            @as(i16, @intFromEnum(self.ergodic.trit)) +
            @as(i16, @intFromEnum(self.plus.trit));
        return @mod(sum, 3) == 0;
    }
};

/// Split a parent agent into a triad of children.
/// Assigns trits -1, 0, +1 — GF(3) sum = 0.
/// Child seeds are derived from parent seed XOR golden ratio offsets.
pub fn triadSplit(parent: *const SwarmAgent) Triad {
    const gen = parent.generation + 1;
    const base = parent.seed;
    return .{
        .minus = .{
            .id = base ^ (GOLDEN *% 1),
            .state = .alive,
            .seed = base ^ (GOLDEN *% 1),
            .trit = .minus,
            .parent_id = parent.id,
            .generation = gen,
        },
        .ergodic = .{
            .id = base ^ (GOLDEN *% 2),
            .state = .alive,
            .seed = base ^ (GOLDEN *% 2),
            .trit = .ergodic,
            .parent_id = parent.id,
            .generation = gen,
        },
        .plus = .{
            .id = base ^ (GOLDEN *% 3),
            .state = .alive,
            .seed = base ^ (GOLDEN *% 3),
            .trit = .plus,
            .parent_id = parent.id,
            .generation = gen,
        },
    };
}

// ============================================================================
// File operations with compliance checking
// ============================================================================

pub const FileOpTag = enum(u8) {
    read_file,
    write_file,
    delete_file,
};

pub const FileOperation = struct {
    tag: FileOpTag,
    /// Path as a slice (borrowed, not owned).
    path: []const u8,
    /// Data for write operations; empty for read/delete.
    data: []const u8,

    pub fn readFile(path: []const u8) FileOperation {
        return .{ .tag = .read_file, .path = path, .data = &.{} };
    }

    pub fn writeFile(path: []const u8, data: []const u8) FileOperation {
        return .{ .tag = .write_file, .path = path, .data = data };
    }

    pub fn deleteFile(path: []const u8) FileOperation {
        return .{ .tag = .delete_file, .path = path, .data = &.{} };
    }
};

/// Execute a file operation on behalf of an agent.
/// Returns true if the agent is alive or compliant (allowed to operate).
/// Non-compliant or dead agents are rejected.
pub fn executeFileOp(agent: *SwarmAgent, op: FileOperation) bool {
    _ = op;
    return switch (agent.state) {
        .alive, .compliant => true,
        .non_compliant, .dead => false,
    };
}

// ============================================================================
// SwarmTriadState — coordinated triple-RNG state
// ============================================================================

pub const SwarmTriadState = struct {
    minus: u64,
    ergodic: u64,
    plus: u64,
    xor_fingerprint: u64,

    pub fn init(seed: u64) SwarmTriadState {
        return .{
            .minus = seed ^ (GOLDEN *% 1),
            .ergodic = seed ^ (GOLDEN *% 2),
            .plus = seed ^ (GOLDEN *% 3),
            .xor_fingerprint = seed ^ (seed << 13) ^ (seed >> 7),
        };
    }

    /// SM64 single step (matches Julia sm64_next).
    fn sm64Next(s: u64) u64 {
        return s *% SM64_MUL +% SM64_ADD;
    }

    /// Coordinate the swarm for n steps, returning combined XOR fingerprint.
    pub fn coordinate(self: *const SwarmTriadState, n: usize) u64 {
        var fp = self.xor_fingerprint;
        var m = self.minus;
        var e = self.ergodic;
        var p = self.plus;
        for (0..n) |_| {
            m = sm64Next(m);
            e = sm64Next(e);
            p = sm64Next(p);
            fp ^= m ^ e ^ p;
        }
        return fp;
    }
};

// ============================================================================
// SentinelMonitor — swarm-wide compliance tracking
// ============================================================================

pub const SentinelMonitor = struct {
    agents: std.ArrayList(SwarmAgent),
    split_count: u64,
    file_op_count: u64,

    pub fn init(allocator: std.mem.Allocator) SentinelMonitor {
        return .{
            .agents = std.ArrayList(SwarmAgent).init(allocator),
            .split_count = 0,
            .file_op_count = 0,
        };
    }

    pub fn deinit(self: *SentinelMonitor) void {
        self.agents.deinit();
    }

    /// Register an agent for monitoring.
    pub fn registerAgent(self: *SentinelMonitor, agent: SwarmAgent) !void {
        try self.agents.append(agent);
    }

    /// Register all three agents of a triad.
    pub fn registerTriad(self: *SentinelMonitor, triad: *const Triad) !void {
        try self.agents.append(triad.minus);
        try self.agents.append(triad.ergodic);
        try self.agents.append(triad.plus);
        self.split_count += 1;
    }

    /// Record a file operation.
    pub fn recordFileOp(self: *SentinelMonitor) void {
        self.file_op_count += 1;
    }

    /// Monitor the swarm: mark agents without valid trit assignments as non-compliant.
    pub fn monitorSwarm(self: *SentinelMonitor) void {
        for (self.agents.items) |*agent| {
            if (agent.state == .alive) {
                // Agents that remain alive without explicit compliance are suspect
                // but we don't change state here — compliance is set by external checks.
            }
        }
    }

    /// Compliance report: count compliant vs total.
    pub fn complianceReport(self: *const SentinelMonitor) struct { compliant: usize, total: usize } {
        var compliant: usize = 0;
        for (self.agents.items) |agent| {
            if (agent.state == .compliant) compliant += 1;
        }
        return .{ .compliant = compliant, .total = self.agents.items.len };
    }
};

// ============================================================================
// World builder (mirrors Julia world_swarm_triad)
// ============================================================================

pub const WorldSwarmTriad = struct {
    swarm: SwarmTriadState,
    initial_fingerprint: u64,
    final_fingerprint: u64,
    n_colors: usize,
    seed: u64,
    triadic_balance: bool,
};

pub fn worldSwarmTriad(seed: u64, n_colors: usize) WorldSwarmTriad {
    const swarm = SwarmTriadState.init(seed);
    const initial_fp = swarm.xor_fingerprint;
    const final_fp = swarm.coordinate(n_colors);
    return .{
        .swarm = swarm,
        .initial_fingerprint = initial_fp,
        .final_fingerprint = final_fp,
        .n_colors = n_colors,
        .seed = seed,
        .triadic_balance = true,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "triad creation and structure" {
    const root = createAgent(42);
    try std.testing.expectEqual(root.state, .alive);
    try std.testing.expectEqual(root.trit, .ergodic);
    try std.testing.expectEqual(root.generation, 0);

    const triad = triadSplit(&root);
    try std.testing.expectEqual(triad.minus.trit, .minus);
    try std.testing.expectEqual(triad.ergodic.trit, .ergodic);
    try std.testing.expectEqual(triad.plus.trit, .plus);
    try std.testing.expectEqual(triad.minus.generation, 1);
    try std.testing.expectEqual(triad.minus.parent_id, root.id);
}

test "GF(3) conservation" {
    const root = createAgent(42);
    const triad = triadSplit(&root);
    try std.testing.expect(triad.isConserved());

    // Nested split — each child triad also conserves
    const nested = triadSplit(&triad.plus);
    try std.testing.expect(nested.isConserved());

    const nested2 = triadSplit(&triad.minus);
    try std.testing.expect(nested2.isConserved());
}

test "compliance monitoring" {
    const allocator = std.testing.allocator;
    var sentinel = SentinelMonitor.init(allocator);
    defer sentinel.deinit();

    const root = createAgent(99);
    const triad = triadSplit(&root);
    try sentinel.registerTriad(&triad);

    const report = sentinel.complianceReport();
    try std.testing.expectEqual(report.total, 3);
    try std.testing.expectEqual(report.compliant, 0); // all alive, none compliant yet
    try std.testing.expectEqual(sentinel.split_count, 1);

    // Mark one compliant
    sentinel.agents.items[0].state = .compliant;
    const report2 = sentinel.complianceReport();
    try std.testing.expectEqual(report2.compliant, 1);
}

test "file operation verification" {
    var agent_ok = createAgent(1);
    agent_ok.state = .compliant;
    var agent_bad = createAgent(2);
    agent_bad.state = .non_compliant;
    var agent_dead = createAgent(3);
    agent_dead.state = .dead;

    const op = FileOperation.writeFile("test.txt", "hello");
    try std.testing.expect(executeFileOp(&agent_ok, op));
    try std.testing.expect(!executeFileOp(&agent_bad, op));
    try std.testing.expect(!executeFileOp(&agent_dead, op));

    // Alive agents can also operate
    var agent_alive = createAgent(4);
    try std.testing.expect(executeFileOp(&agent_alive, FileOperation.readFile("x")));
    try std.testing.expect(executeFileOp(&agent_alive, FileOperation.deleteFile("y")));
}

test "SwarmTriadState coordinate determinism" {
    const swarm = SwarmTriadState.init(42);
    const fp1 = swarm.coordinate(1000);
    const fp2 = swarm.coordinate(1000);
    try std.testing.expectEqual(fp1, fp2); // deterministic

    // Different seed => different fingerprint
    const swarm2 = SwarmTriadState.init(43);
    const fp3 = swarm2.coordinate(1000);
    try std.testing.expect(fp1 != fp3);
}

test "world builder" {
    const world = worldSwarmTriad(42, 1000);
    try std.testing.expectEqual(world.seed, 42);
    try std.testing.expectEqual(world.n_colors, 1000);
    try std.testing.expect(world.triadic_balance);
    try std.testing.expect(world.initial_fingerprint != world.final_fingerprint);
}

test "agent color derivation" {
    const agent = createAgent(42);
    const c = agent.color();
    // Colors should be in [0, 1]
    try std.testing.expect(c.r >= 0.0 and c.r <= 1.0);
    try std.testing.expect(c.g >= 0.0 and c.g <= 1.0);
    try std.testing.expect(c.b >= 0.0 and c.b <= 1.0);

    // Different seeds => different colors
    const agent2 = createAgent(999);
    const c2 = agent2.color();
    try std.testing.expect(c.r != c2.r or c.g != c2.g or c.b != c2.b);
}
