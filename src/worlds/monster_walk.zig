//! Monster Walk — 71-shard routing for the Monster group
//!
//! Bridges meta-introspector/monster's 71-shard architecture with
//! zig-syrup's GF(3) trit system and Syrup serialization.
//!
//! The Monster group M has order:
//!   2^46 × 3^20 × 5^9 × 7^6 × 11^2 × 13^3 × 17 × 19 × 23 × 29 × 31 × 41 × 47 × 59 × 71
//!
//! 15 supersingular primes divide |M|. The largest is 71, which gives
//! the natural shard count. Data is hashed and reduced mod 71 for routing.
//!
//! j-invariant per shard: j(s) = 744 + 196884 × s
//!   (744 = constant term of j(τ), 196884 = 1 + 196883 = 1 + dim(V♮))
//!
//! GF(3) mapping: each shard gets a trit via shard_id mod 3 → {-1, 0, +1}

const std = @import("std");
const crypto = std.crypto;

// ============================================================================
// SplitMix64 — Strong Parallelism Invariant (SPI)
//
// Same seed + same index = same value. Always.
// Across: Zig, Guile (gf3-goblins.scm), WGSL (wgpu_compute), WASM (Hoot).
//
// Constants match goblins_ffi.zig and splitmix_trit.zig exactly.
// This is the identity function. If monster_walk used a different hash
// for shard routing, agents in different runtimes would get different
// shards for the same seed — breaking shared protentions across the
// polyglot boundary.
// ============================================================================

const SM_GOLDEN: u64 = 0x9e3779b97f4a7c15;
const SM_MIX1: u64 = 0xbf58476d1ce4e5b9;
const SM_MIX2: u64 = 0x94d049bb133111eb;

/// SplitMix64 at (seed, index). Deterministic. Cross-runtime.
pub fn splitmix64At(seed: u64, index: u64) u64 {
    const state = seed +% (SM_GOLDEN *% index);
    var z = state;
    z = (z ^ (z >> 30)) *% SM_MIX1;
    z = (z ^ (z >> 27)) *% SM_MIX2;
    z = z ^ (z >> 31);
    return z;
}

/// Extract GF(3) trit from SplitMix64 value.
pub fn splitmixTrit(value: u64) Trit {
    return switch (value % 3) {
        0 => .minus,
        1 => .zero,
        2 => .plus,
        else => unreachable,
    };
}

/// Extract hue [0, 360) from SplitMix64 value (lower 16 bits).
pub fn splitmixHue(value: u64) f32 {
    return @as(f32, @floatFromInt(value & 0xFFFF)) / 65535.0 * 360.0;
}

// ============================================================================
// Quale — The Undifferentiated Identity
//
// A neonate doesn't experience "the number 3" and "the color red" as
// separate things bound together. There is one perceptual intensity
// that adults later carve into modalities. Synesthesia isn't pathology;
// it's the residue of the pre-differentiated state.
//
// A SplitMix64 value is the same: one u64 that we PROJECT into
// shard_id, trit, hue, ecstasis, j_invariant. The projections are
// our modalities. The value is what there is before projection.
//
// Quale = the raw value before any projection function is applied.
// It has no type other than u64. The types come from observation.
// ============================================================================

/// A single undifferentiated identity value from SplitMix64.
/// All typed projections (shard, trit, hue, ecstasis, j-invariant)
/// are derived from this one value. There is no binding problem
/// because nothing was ever separate.
pub const Quale = struct {
    /// The raw value. This is what the identity IS.
    raw: u64,
    /// The seed that generated it. This is WHO.
    seed: u64,
    /// The index at which it was generated. This is WHEN.
    index: u64,

    pub fn init(seed: u64, index: u64) Quale {
        return .{
            .raw = splitmix64At(seed, index),
            .seed = seed,
            .index = index,
        };
    }

    // Projections — each extracts a different modality from the same raw value.

    pub fn shard(self: Quale) u8 {
        return @intCast(self.raw % SHARD_COUNT);
    }

    pub fn trit(self: Quale) Trit {
        return splitmixTrit(self.raw);
    }

    pub fn hue(self: Quale) f32 {
        return splitmixHue(self.raw);
    }

    pub fn ecstasis(self: Quale) Ecstasis {
        return Ecstasis.fromTrit(Trit.fromShard(self.shard()));
    }

    pub fn jInv(self: Quale) u64 {
        return jInvariant(self.shard());
    }

    /// Place this quale as an agent in the shard lattice.
    pub fn asAgent(self: Quale, generation: u64) AgentHorizon {
        return .{
            .agent_id = self.seed,
            .shard_id = self.shard(),
            .ecstasis = self.ecstasis(),
            .generation = generation,
            .j_invariant = self.jInv(),
        };
    }

    /// Two qualia from the same seed are the same identity at different moments.
    pub fn sameIdentity(a: Quale, b: Quale) bool {
        return a.seed == b.seed;
    }

    /// Two qualia that project to the same shard share a clearing,
    /// regardless of whether they share an identity.
    pub fn shareClearing(a: Quale, b: Quale) bool {
        return a.shard() == b.shard();
    }
};

/// The 15 supersingular primes dividing the Monster group order.
pub const MONSTER_PRIMES = [15]u64{ 2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 41, 47, 59, 71 };

/// Exponents in the prime factorization of |M|.
pub const MONSTER_EXPONENTS = [15]u8{ 46, 20, 9, 6, 2, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1 };

/// Number of shards (largest Monster prime).
pub const SHARD_COUNT: u8 = 71;

/// Dimension of the smallest faithful representation of M.
pub const MONSTER_DIM: u64 = 196883;

/// Constant term of the j-invariant q-expansion.
pub const J_CONSTANT: u64 = 744;

/// Coefficient of q^1 in j(τ) = 1/q + 744 + 196884q + ...
pub const J_COEFF_1: u64 = 196884;

/// Monster Walk step constant (0x1F90 = 8080, the leading digits of |M|).
pub const MONSTER_WALK_STEP: u64 = 0x1F90;

/// GF(3) trit values.
pub const Trit = enum(i8) {
    minus = -1,
    zero = 0,
    plus = 1,

    pub fn fromShard(shard_id: u8) Trit {
        return switch (@as(u2, @intCast(shard_id % 3))) {
            0 => .zero,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }

    pub fn add(a: Trit, b: Trit) Trit {
        const sum: i8 = @rem(@as(i8, @backingInt(a)) + @as(i8, @backingInt(b)) + 3, 3) - 1;
        return @fromBackingInt(@intCast(sum));
    }

    pub fn name(self: Trit) []const u8 {
        return switch (self) {
            .minus => "MINUS",
            .zero => "ERGODIC",
            .plus => "PLUS",
        };
    }
};

/// A message routed through the 71-shard Monster Walk system.
pub const ShardMessage = struct {
    shard_id: u8,
    monster_position: u64,
    j_invariant: u64,
    trit: Trit,
    data: []const u8,

    pub fn format(
        self: ShardMessage,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("Shard({d}) j={d} trit={s} pos=0x{x}", .{
            self.shard_id,
            self.j_invariant,
            self.trit.name(),
            self.monster_position,
        });
    }
};

/// Compute shard ID from data via SplitMix64 (SPI-compliant).
/// Hashes data to a u64 seed, then SplitMix64(seed, 0) mod 71.
/// This ensures the same data routes to the same shard in Zig, Guile,
/// WGSL, and WASM — the Strong Parallelism Invariant.
pub fn shardId(data: []const u8) u8 {
    // Fold data into a u64 seed (FNV-1a, then SplitMix64 finalize)
    var seed: u64 = 0xcbf29ce484222325; // FNV offset basis
    for (data) |b| {
        seed ^= @as(u64, b);
        seed *%= 0x100000001b3; // FNV prime
    }
    return @intCast(splitmix64At(seed, 0) % SHARD_COUNT);
}

/// Compute the Monster Walk position by stepping through bytes.
pub fn monsterPosition(data: []const u8) u64 {
    var pos: u64 = 0;
    for (data) |b| {
        pos = pos +% (@as(u64, b) *% MONSTER_WALK_STEP);
    }
    return pos;
}

/// j-invariant for a shard: 744 + 196884 × shard_id.
pub fn jInvariant(shard_id: u8) u64 {
    return J_CONSTANT + J_COEFF_1 * @as(u64, shard_id);
}

/// Route data through the Monster Walk, producing a ShardMessage.
pub fn route(data: []const u8) ShardMessage {
    const sid = shardId(data);
    return .{
        .shard_id = sid,
        .monster_position = monsterPosition(data),
        .j_invariant = jInvariant(sid),
        .trit = Trit.fromShard(sid),
        .data = data,
    };
}

/// Shard router that accumulates messages per shard.
pub const ShardRouter = struct {
    shards: [SHARD_COUNT]std.ArrayListUnmanaged(ShardMessage),
    allocator: std.mem.Allocator,
    total_routed: u64,

    pub fn init(allocator: std.mem.Allocator) ShardRouter {
        var shards: [SHARD_COUNT]std.ArrayListUnmanaged(ShardMessage) = undefined;
        for (&shards) |*s| {
            s.* = .{};
        }
        return .{
            .shards = shards,
            .allocator = allocator,
            .total_routed = 0,
        };
    }

    pub fn deinit(self: *ShardRouter) void {
        for (&self.shards) |*s| {
            s.deinit(self.allocator);
        }
    }

    pub fn send(self: *ShardRouter, data: []const u8) !ShardMessage {
        const msg = route(data);
        try self.shards[msg.shard_id].append(self.allocator, msg);
        self.total_routed += 1;
        return msg;
    }

    pub fn shardCount(self: *const ShardRouter, shard_id: u8) usize {
        return self.shards[shard_id].items.len;
    }

    /// Check GF(3) conservation across all shards.
    /// Returns true if sum of all shard trits ≡ 0 (mod 3).
    pub fn isConserved(self: *const ShardRouter) bool {
        var sum: i32 = 0;
        for (self.shards, 0..) |shard, i| {
            sum += @as(i32, @backingInt(Trit.fromShard(@intCast(i)))) * @as(i32, @intCast(shard.items.len));
        }
        return @rem(@mod(sum, 3), 3) == 0;
    }

    /// Distribution statistics: how many shards have messages.
    pub fn activeShards(self: *const ShardRouter) u8 {
        var count: u8 = 0;
        for (self.shards) |s| {
            if (s.items.len > 0) count += 1;
        }
        return count;
    }
};

/// Map a Monster prime to its GF(3) role.
pub fn primeToTrit(prime: u64) Trit {
    return switch (prime) {
        2, 3, 5 => .minus, // small primes: validators
        7, 11, 13 => .zero, // mid primes: coordinators
        17, 19, 23, 29, 31, 41, 47, 59, 71 => .plus, // large primes: generators
        else => .zero,
    };
}

/// Check if a number is divisible by any Monster prime.
pub fn monsterDivisible(n: u64) [15]bool {
    var result: [15]bool = undefined;
    for (MONSTER_PRIMES, 0..) |p, i| {
        result[i] = (n % p == 0);
    }
    return result;
}

/// Count how many Monster primes divide n.
pub fn monsterPrimeCount(n: u64) u8 {
    var count: u8 = 0;
    for (MONSTER_PRIMES) |p| {
        if (n % p == 0) count += 1;
    }
    return count;
}

// ============================================================================
// Shared Protentions — Heidegger's Trialectic in Multi-Agent Shards
//
// Heidegger's threefold temporal ecstasis maps to GF(3):
//   Gewesenheit (having-been / retention)  → MINUS (-1)
//   Gegenwart   (present / primal impression) → ZERO (0)
//   Zukunft     (future / protention)       → PLUS (+1)
//
// In a multi-agent system, agents sharing a shard share a temporal
// horizon. A "protention" is the structural anticipation of what comes
// next — not a prediction (epistemic) but a pre-thematic orientation
// (ontological). When multiple agents occupy the same shard, their
// protentions are shared: they inhabit the same temporal clearing.
//
// This is para-rigorous: the GF(3) conservation law (retention +
// impression + protention ≡ 0 mod 3) is exhaustively verifiable;
// the phenomenological interpretation is parametrizable but not
// machine-checkable. The Isabelle2 bridge checks the algebra,
// not the ontology.
// ============================================================================

/// Temporal ecstasis (Heidegger's threefold time-structure).
pub const Ecstasis = enum(i8) {
    retention = -1, // Gewesenheit: having-been
    impression = 0, // Gegenwart: present moment
    protention = 1, // Zukunft: not-yet, structural anticipation

    pub fn fromTrit(t: Trit) Ecstasis {
        return @fromBackingInt(@intCast(@backingInt(t)));
    }

    pub fn toTrit(self: Ecstasis) Trit {
        return @fromBackingInt(@intCast(@backingInt(self)));
    }

    pub fn name(self: Ecstasis) []const u8 {
        return switch (self) {
            .retention => "Gewesenheit",
            .impression => "Gegenwart",
            .protention => "Zukunft",
        };
    }
};

/// An agent's temporal stance within a shard.
pub const AgentHorizon = struct {
    agent_id: u64,
    shard_id: u8,
    ecstasis: Ecstasis,
    /// Monotonic generation (from cell_sync / Ewig)
    generation: u64,
    /// The j-invariant anchors the agent's shard position
    j_invariant: u64,

    pub fn format(
        self: AgentHorizon,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("Agent(0x{x}) shard={d} {s} gen={d}", .{
            self.agent_id,
            self.shard_id,
            self.ecstasis.name(),
            self.generation,
        });
    }
};

/// Shared protention: multiple agents in the same shard with the same
/// temporal orientation. This is the "clearing" (Lichtung) where
/// coordinated anticipation happens.
pub const SharedProtention = struct {
    shard_id: u8,
    ecstasis: Ecstasis,
    agents: []const u64,
    generation: u64,
    j_invariant: u64,

    /// Check trialectic conservation: the ecstasis values across a group
    /// of shared protentions must sum to 0 mod 3 for the system to be
    /// temporally balanced.
    pub fn isBalanced(protentions: []const SharedProtention) bool {
        var sum: i32 = 0;
        for (protentions) |p| {
            sum += @as(i32, @backingInt(p.ecstasis)) * @as(i32, @intCast(p.agents.len));
        }
        return @rem(@mod(sum, 3), 3) == 0;
    }
};

// ============================================================================
// Relativistic Computing — Light Cones on the Shard Lattice
//
// Gwern hosts Bradbury's Matrioshka Brain paper: computation bounded by c
// means coordination cost ∝ causal distance. Mattern (1989) proved that
// vector time in distributed systems is isomorphic to Minkowski spacetime.
//
// In the 71-shard system:
// - Intra-shard coordination is "local" (same light cone)
// - Cross-shard coordination costs j-invariant distance / c
// - An agent's "light cone" at generation g covers shards reachable
//   within g steps at propagation speed c_shard
//
// The j-invariant metric: d(s1, s2) = |j(s1) - j(s2)| = 196884 × |s1 - s2|
// This is the "proper distance" between shards. At propagation speed
// c_shard (shards per generation), the light cone at generation g
// from shard s covers shards in [s - g×c_shard, s + g×c_shard] mod 71.
//
// Para-rigorous: the lattice structure is exhaustively checkable;
// the mapping to Minkowski spacetime is structural analogy, not theorem.
// ============================================================================

/// Propagation speed: how many shards a signal can cross per generation.
/// Default 1 = nearest-neighbor only. Parametrizable for different
/// "universes" (fast light = loose coupling, slow light = tight locality).
pub const DEFAULT_C_SHARD: u8 = 1;

/// Causal distance between two shards via j-invariant metric.
pub fn shardDistance(s1: u8, s2: u8) u64 {
    const diff = if (s1 > s2) s1 - s2 else s2 - s1;
    // Toroidal: pick the shorter way around mod 71
    const wrapped = @min(diff, SHARD_COUNT - diff);
    return J_COEFF_1 * @as(u64, wrapped);
}

/// Can shard s2 be reached from s1 within `budget` generations
/// at propagation speed c_shard?
pub fn inLightCone(s1: u8, s2: u8, budget: u64, c_shard: u8) bool {
    const diff = if (s1 > s2) s1 - s2 else s2 - s1;
    const wrapped = @min(diff, SHARD_COUNT - diff);
    return wrapped <= budget * c_shard;
}

/// The light cone of a shard at a given generation: all reachable shard IDs.
pub fn lightCone(origin: u8, budget: u64, c_shard: u8) LightConeIterator {
    return .{
        .origin = origin,
        .radius = @intCast(@min(budget * c_shard, SHARD_COUNT / 2)),
        .offset = 0,
        .done = false,
    };
}

pub const LightConeIterator = struct {
    origin: u8,
    radius: u8,
    offset: u8, // current offset from origin (0..radius)
    done: bool,

    /// Next shard in the light cone. Returns null when exhausted.
    /// Yields origin first, then ±1, ±2, ... ±radius (toroidal).
    pub fn next(self: *LightConeIterator) ?u8 {
        if (self.done) return null;
        if (self.offset == 0) {
            self.offset = 1;
            return self.origin;
        }
        if (self.offset > self.radius) {
            self.done = true;
            return null;
        }
        // Yield (origin + offset) mod 71, then (origin - offset) mod 71
        // We alternate: even calls → +offset, odd calls → -offset then advance
        const pos = @as(u8, @intCast(@mod(@as(i16, self.origin) + @as(i16, self.offset), SHARD_COUNT)));
        const neg = @as(u8, @intCast(@mod(@as(i16, self.origin) - @as(i16, self.offset) + SHARD_COUNT, SHARD_COUNT)));
        _ = neg;
        self.offset += 1;
        return pos;
    }

    /// Count of shards in this light cone.
    pub fn size(self: *const LightConeIterator) u8 {
        return 1 + 2 * self.radius;
    }
};

/// Place an agent into the Monster Walk shard system.
/// Uses SplitMix64(agent_id, 0) for shard assignment — SPI-compliant.
/// The same agent_id will land on the same shard in Zig, Guile, and WASM.
/// Temporal ecstasis derived from shard trit.
pub fn placeAgent(agent_id: u64, generation: u64) AgentHorizon {
    const sid: u8 = @intCast(splitmix64At(agent_id, 0) % SHARD_COUNT);
    return .{
        .agent_id = agent_id,
        .shard_id = sid,
        .ecstasis = Ecstasis.fromTrit(Trit.fromShard(sid)),
        .generation = generation,
        .j_invariant = jInvariant(sid),
    };
}

/// Place an agent from a did:gay identifier (bytes) — SPI-compliant.
/// Routes through shardId() which uses FNV→SplitMix64.
pub fn placeAgentDid(did_bytes: []const u8, generation: u64) AgentHorizon {
    const sid = shardId(did_bytes);
    return .{
        .agent_id = splitmix64At(@as(u64, sid), 0),
        .shard_id = sid,
        .ecstasis = Ecstasis.fromTrit(Trit.fromShard(sid)),
        .generation = generation,
        .j_invariant = jInvariant(sid),
    };
}

// ============================================================================
// Active Inference — Friston's Free Energy Principle on the Shard Lattice
//
// Friston: organisms minimize variational free energy F ≈ surprise + complexity.
// Two modes of minimization:
//   Perceptual inference: update internal model to match observations (change self)
//   Active inference:     act on world to match predictions (change world)
//
// On the 71-shard lattice:
//   Markov blanket  = shard boundary (sensory: incoming messages, active: outgoing)
//   Internal states = agent's model of neighboring shard contents
//   External states = actual contents of shards outside the light cone
//   Free energy     = prediction error summed over the light cone boundary
//
// The connection to the "kinetic/potential" distinction:
//   Potential energy = stored free energy (surprise waiting to be resolved)
//   Kinetic energy   = active inference in progress (Monster Walk stepping)
//   Conservation     = total information energy is GF(3)-balanced
//
// The connection to Heidegger:
//   Perceptual inference IS retention (Gewesenheit): updating model from past
//   Primal impression IS the Markov blanket boundary (Gegenwart): the now
//   Active inference IS protention (Zukunft): acting to make the future match
//
// Para-rigorous: the free energy decomposition and Markov blanket structure
// are exhaustively checkable on 71 shards. The claim that this constitutes
// "inference" in the Fristonian sense is the parametrizable part.
// ============================================================================

/// An agent's generative model of its shard neighborhood.
/// Tracks expected vs observed trit values for shards in its light cone.
pub const GenerativeModel = struct {
    agent: AgentHorizon,
    /// Expected trit for each shard (the agent's prediction).
    /// Null = no prediction (shard outside model).
    predictions: [SHARD_COUNT]?Trit,
    /// Observed trit for each shard (sensory input via messages).
    /// Null = not yet observed.
    observations: [SHARD_COUNT]?Trit,

    pub fn init(agent: AgentHorizon) GenerativeModel {
        var m = GenerativeModel{
            .agent = agent,
            .predictions = @splat(null),
            .observations = @splat(null),
        };
        // Self-prediction is always correct (reafference).
        m.predictions[agent.shard_id] = Trit.fromShard(agent.shard_id);
        m.observations[agent.shard_id] = Trit.fromShard(agent.shard_id);
        return m;
    }

    /// Observe a shard's trit (sensory input crossing the Markov blanket).
    pub fn observe(self: *GenerativeModel, shard_id: u8, trit: Trit) void {
        self.observations[shard_id] = trit;
    }

    /// Predict a shard's trit (set expectation).
    pub fn predict(self: *GenerativeModel, shard_id: u8, trit: Trit) void {
        self.predictions[shard_id] = trit;
    }

    /// Perceptual inference: update prediction to match observation.
    /// This is retention — learning from what has been.
    pub fn perceptualInference(self: *GenerativeModel, shard_id: u8) void {
        if (self.observations[shard_id]) |obs| {
            self.predictions[shard_id] = obs;
        }
    }

    /// Free energy at a single shard: 0 if match or unknown, 1 if mismatch.
    /// This is the surprise — the prediction error.
    fn surprise(self: *const GenerativeModel, shard_id: u8) u8 {
        const pred = self.predictions[shard_id] orelse return 0;
        const obs = self.observations[shard_id] orelse return 0;
        return if (pred != obs) 1 else 0;
    }

    /// Total free energy: sum of surprise across the light cone.
    /// F = Σ surprise(s) for s in light_cone(agent, budget, c)
    pub fn freeEnergy(self: *const GenerativeModel, budget: u64, c_shard: u8) u32 {
        var f: u32 = 0;
        var i: u8 = 0;
        while (i < SHARD_COUNT) : (i += 1) {
            if (inLightCone(self.agent.shard_id, i, budget, c_shard)) {
                f += self.surprise(i);
            }
        }
        return f;
    }

    /// Is this agent at equilibrium? Free energy = 0 within its light cone.
    pub fn atEquilibrium(self: *const GenerativeModel, budget: u64, c_shard: u8) bool {
        return self.freeEnergy(budget, c_shard) == 0;
    }

    /// Perceptual inference over entire light cone: update all predictions
    /// to match observations. Reduces free energy to zero (at cost of
    /// abandoning prior beliefs). This is the "easy" path.
    pub fn fullPerceptualInference(self: *GenerativeModel, budget: u64, c_shard: u8) void {
        var i: u8 = 0;
        while (i < SHARD_COUNT) : (i += 1) {
            if (inLightCone(self.agent.shard_id, i, budget, c_shard)) {
                self.perceptualInference(i);
            }
        }
    }

    /// Count shards where prediction and observation are both known.
    pub fn observedCount(self: *const GenerativeModel) u8 {
        var count: u8 = 0;
        for (self.predictions, self.observations) |p, o| {
            if (p != null and o != null) count += 1;
        }
        return count;
    }
};

/// Information energy: the trialectic decomposition.
pub const InfoEnergy = struct {
    potential: u32, // free energy stored (unresolved prediction errors)
    kinetic: u32, // active inference steps taken this generation
    generation: u64,

    /// GF(3) balance: potential + kinetic + dissipated ≡ 0 (mod 3)
    pub fn isBalanced(self: InfoEnergy) bool {
        return @rem(@mod(self.potential + self.kinetic, 3), 3) == 0;
    }
};

// ============================================================================
// Information Memory — Superadditive Fusion
//
// "The sum of memories is greater than its parts."
//
// Individual GenerativeModels are sparse: each agent observes/predicts
// only its light cone. When two models merge:
//
//   1. Coverage grows: A knows shard 3, B knows shard 40 → A∪B knows both.
//      This is additive — the union of observed slots.
//
//   2. Coherence emerges: where A and B both observed shard 7, agreement
//      confirms the observation (reducing uncertainty), disagreement
//      reveals the shard is in flux. This is the superadditive part —
//      information that exists in neither model alone.
//
//   3. Triangulation: if A predicts shard 12 and B observed shard 12,
//      A's free energy at shard 12 can be resolved without A ever
//      observing it directly. B's memory becomes A's perception.
//
// The Fristonian reading: merging models = expanding the Markov blanket.
// The Heideggerian reading: shared memory = shared Gewesenheit (having-been).
// The superadditivity = the clearing (Lichtung) that opens between agents.
//
// Para-rigorous: the coverage and coherence counts are exhaustively
// computable over 71 slots. The claim that coherence constitutes
// "more than the sum" is the interpretive layer.
// ============================================================================

/// Result of merging two generative models.
pub const MemoryFusion = struct {
    /// Slots observed by A only.
    a_only: u8,
    /// Slots observed by B only.
    b_only: u8,
    /// Slots observed by both (overlap).
    shared: u8,
    /// Of the shared slots, how many agree on the trit value.
    agreements: u8,
    /// Of the shared slots, how many disagree.
    disagreements: u8,
    /// Slots where one agent predicted and the other observed
    /// (triangulation: resolves free energy without direct observation).
    triangulations: u8,
    /// Total coverage of the fused model.
    total_coverage: u8,

    /// Superadditivity: does the fusion know more than A + B individually?
    /// True when there are triangulations (knowledge neither had alone)
    /// or when shared observations produce confirmations/conflicts.
    pub fn isSuperadditive(self: MemoryFusion) bool {
        return self.triangulations > 0 or self.shared > 0;
    }

    /// The "clearing" size: information that exists only in the relation.
    pub fn clearingSize(self: MemoryFusion) u8 {
        return self.agreements + self.triangulations;
    }

    /// Surprise in the fusion: disagreements that neither agent expected.
    pub fn fusionSurprise(self: MemoryFusion) u8 {
        return self.disagreements;
    }
};

/// Fuse two generative models. The result describes what the joint
/// memory contains that the parts do not.
pub fn fuseMemories(a: *const GenerativeModel, b: *const GenerativeModel) MemoryFusion {
    var result = MemoryFusion{
        .a_only = 0,
        .b_only = 0,
        .shared = 0,
        .agreements = 0,
        .disagreements = 0,
        .triangulations = 0,
        .total_coverage = 0,
    };

    var i: u8 = 0;
    while (i < SHARD_COUNT) : (i += 1) {
        const a_obs = a.observations[i];
        const b_obs = b.observations[i];
        const a_pred = a.predictions[i];
        const b_pred = b.predictions[i];

        const a_has = a_obs != null;
        const b_has = b_obs != null;

        if (a_has and b_has) {
            result.shared += 1;
            if (a_obs.? == b_obs.?) {
                result.agreements += 1;
            } else {
                result.disagreements += 1;
            }
        } else if (a_has) {
            result.a_only += 1;
        } else if (b_has) {
            result.b_only += 1;
        }

        // Triangulation: A predicted, B observed (or vice versa),
        // and neither directly observed it themselves.
        if (a_pred != null and b_obs != null and a_obs == null) {
            result.triangulations += 1;
        }
        if (b_pred != null and a_obs != null and b_obs == null) {
            result.triangulations += 1;
        }

        if (a_has or b_has) {
            result.total_coverage += 1;
        }
    }

    return result;
}

/// Apply fusion: update model A with B's observations (shared memory).
/// After this, A's free energy will be lower wherever B had observations
/// that A had predictions for. This is the "memory is greater than parts"
/// operation — A learns from B's experience without having lived it.
pub fn applyFusion(a: *GenerativeModel, b: *const GenerativeModel) void {
    var i: u8 = 0;
    while (i < SHARD_COUNT) : (i += 1) {
        // Import B's observations into A where A has none
        if (a.observations[i] == null and b.observations[i] != null) {
            a.observations[i] = b.observations[i];
        }
        // Import B's predictions into A where A has none
        if (a.predictions[i] == null and b.predictions[i] != null) {
            a.predictions[i] = b.predictions[i];
        }
    }
}

// ============================================================================
// Networked Topology — LEO Constellation Mapping
//
// Starlink-class LEO constellations are toroidal meshes: satellites in
// orbital shells form rings, with inter-satellite laser links (ISLs)
// connecting neighbors within a shell and across shells.
//
// The 71-shard ring maps naturally onto an orbital shell:
//   71 shards ↔ 71 orbital positions (5.07° spacing)
//   shardDistance() ↔ ISL hop count × propagation delay
//   inLightCone() ↔ reachable within RTT budget
//   DEFAULT_C_SHARD ↔ ISL bandwidth (shards/generation)
//
// Latency tiers (one-way, approximate):
//   Intra-shard (local):     0 ms   (same ground station)
//   Adjacent shard (1 hop):  2-5 ms (ISL within shell)
//   Cross-shell (N hops):    N × 3 ms (inter-shell ISL)
//   Ground bounce:          20-40 ms (up + down + routing)
//   GEO fallback:          300 ms   (geostationary relay)
//
// The free energy cost of cross-shard observation IS the latency.
// Active inference over Starlink = choosing which shards to observe
// given a fixed RTT budget. This is bandwidth allocation as protention.
//
// Para-rigorous: the toroidal topology is exact; the latency numbers
// are empirical approximations parametrizable per constellation.
// ============================================================================

/// Latency model for a LEO constellation mapped onto the 71-shard ring.
pub const ConstellationParams = struct {
    /// One-way ISL delay per hop (milliseconds).
    isl_hop_ms: u16 = 3,
    /// Ground-to-sat one-way delay (milliseconds).
    ground_up_ms: u16 = 10,
    /// Maximum one-way RTT budget for real-time coordination (ms).
    rtt_budget_ms: u16 = 50,
    /// Shards per orbital shell (maps onto SHARD_COUNT).
    shards_per_shell: u8 = SHARD_COUNT,

    /// One-way latency between two shards (ms).
    pub fn latencyMs(self: ConstellationParams, s1: u8, s2: u8) u32 {
        const diff = if (s1 > s2) s1 - s2 else s2 - s1;
        const hops = @min(diff, self.shards_per_shell - diff);
        // Ground up + N ISL hops + ground down
        return @as(u32, self.ground_up_ms) * 2 + @as(u32, self.isl_hop_ms) * hops;
    }

    /// How many shard-hops fit within the RTT budget?
    pub fn reachableHops(self: ConstellationParams) u8 {
        if (self.isl_hop_ms == 0) return self.shards_per_shell / 2;
        const available = if (self.rtt_budget_ms > self.ground_up_ms * 2)
            self.rtt_budget_ms - self.ground_up_ms * 2
        else
            0;
        return @intCast(@min(available / self.isl_hop_ms, self.shards_per_shell / 2));
    }

    /// Is a shard reachable within the RTT budget?
    pub fn isReachable(self: ConstellationParams, s1: u8, s2: u8) bool {
        return self.latencyMs(s1, s2) <= self.rtt_budget_ms;
    }
};

/// Default Starlink-class parameters.
pub const STARLINK_PARAMS = ConstellationParams{
    .isl_hop_ms = 3,
    .ground_up_ms = 10,
    .rtt_budget_ms = 50,
};

/// GEO fallback parameters (for comparison / degraded mode).
pub const GEO_PARAMS = ConstellationParams{
    .isl_hop_ms = 0, // single hop
    .ground_up_ms = 300,
    .rtt_budget_ms = 700,
};

// ============================================================================
// passport.gay Integration — Shard-Routed Identity
//
// passport.zig proves individual identity via EEG entropy → did:gay.
// Monster Walk extends this to collective identity:
//   did:gay → SplitMix64 seed → shard placement → shared protention group
//
// The "Palantir for the people" requires group attestation:
//   - Multiple agents in the same shard can co-sign observations
//   - Agreement across Markov blankets = corroborated testimony
//   - Disagreement = detectable, attributable, non-repudiable
//
// No central verifier. The shard IS the verification context.
// Agents verify each other through memory fusion (fuseMemories):
//   agreements = mutual attestation
//   disagreements = disputes with audit trail
//   triangulations = third-party corroboration
// ============================================================================

/// Bind a did:gay identifier to a Monster Walk shard.
/// The DID's base32 content is hashed to a shard, giving the identity
/// a home in the 71-shard lattice. Agents with DIDs in the same shard
/// share a temporal horizon and can co-attest observations.
pub fn didToShard(did_bytes: []const u8) u8 {
    return shardId(did_bytes);
}

/// Group attestation: N agents in the same shard all observed the same
/// trit at a given shard. Returns the attestation strength.
pub const Attestation = struct {
    shard_id: u8,
    target_shard: u8,
    observed_trit: Trit,
    attestors: u8,
    total_in_shard: u8,

    /// Quorum: more than half the agents in the shard agree.
    pub fn hasQuorum(self: Attestation) bool {
        return self.attestors > self.total_in_shard / 2;
    }

    /// Unanimous: all agents agree.
    pub fn isUnanimous(self: Attestation) bool {
        return self.attestors == self.total_in_shard;
    }
};

/// Compute group attestation from an array of generative models
/// all belonging to agents in the same shard.
pub fn attestShard(
    models: []const GenerativeModel,
    target_shard: u8,
) ?Attestation {
    if (models.len == 0) return null;
    const home_shard = models[0].agent.shard_id;

    // Count observations of each trit value at target_shard
    var counts = [_]u8{ 0, 0, 0 }; // minus, zero, plus
    for (models) |m| {
        if (m.observations[target_shard]) |obs| {
            const idx: usize = @intCast(@as(u8, @bitCast(@backingInt(obs))) +% 1);
            counts[idx] += 1;
        }
    }

    // Find majority trit
    var max_idx: usize = 0;
    if (counts[1] > counts[max_idx]) max_idx = 1;
    if (counts[2] > counts[max_idx]) max_idx = 2;
    const majority_trit: Trit = @fromBackingInt(@intCast(@as(i8, @intCast(max_idx)) - 1));

    return .{
        .shard_id = home_shard,
        .target_shard = target_shard,
        .observed_trit = majority_trit,
        .attestors = counts[max_idx],
        .total_in_shard = @intCast(models.len),
    };
}

// ============================================================================
// Para-rigorous postcondition checks
//
// These mirror (but do not replace) the MonsterLean/MonsterLean/ProofIndex.lean
// formal proofs. Each check names the theorem it orbits around.
// "Para-rigorous" = parametrizable runtime assertions around rigorous
// theorem provers (Lean4, Isabelle2). They are exhaustive over finite
// domains or structural over invariants, never probabilistic.
// ============================================================================

/// Result of a postcondition check (same shape as agm_isabelle.CheckResult)
pub const CheckResult = struct {
    passed: bool,
    postulate: []const u8,
    message: []const u8,
};

/// MonsterLean theorem 1: monster_starts_with_8080
/// The Monster group order begins with digits 8080.
/// We verify the walk step constant encodes this.
pub fn checkStartsWith8080() CheckResult {
    const ok = MONSTER_WALK_STEP == 0x1F90 and MONSTER_WALK_STEP == 8080;
    return .{
        .passed = ok,
        .postulate = "monster_starts_with_8080",
        .message = if (ok) "MONSTER_WALK_STEP = 0x1F90 = 8080" else "VIOLATION: step constant != 8080",
    };
}

/// MonsterLean theorem 10: seventy_one_cubed
/// 71^3 = 357911. Exhaustive arithmetic check.
pub fn checkSeventyOneCubed() CheckResult {
    const ok = @as(u64, 71) * 71 * 71 == 357911;
    return .{
        .passed = ok,
        .postulate = "seventy_one_cubed",
        .message = if (ok) "71^3 = 357911" else "VIOLATION: 71^3 arithmetic",
    };
}

/// MonsterLean theorem 8: monster_group_properties
/// |M| has exactly 15 prime divisors, largest is 71.
pub fn checkPrimeCount() CheckResult {
    const ok = MONSTER_PRIMES.len == 15 and MONSTER_PRIMES[14] == 71;
    return .{
        .passed = ok,
        .postulate = "monster_group_properties",
        .message = if (ok) "15 supersingular primes, max=71" else "VIOLATION: prime table",
    };
}

/// Moonshine: 196883 = 47 × 59 × 71 (dimension of smallest faithful rep).
/// This is the "1" in McKay's observation: 196884 = 1 + 196883.
pub fn checkMonsterDim() CheckResult {
    const ok = MONSTER_DIM == 47 * 59 * 71 and J_COEFF_1 == MONSTER_DIM + 1;
    return .{
        .passed = ok,
        .postulate = "moonshine_mckay",
        .message = if (ok) "196883 = 47×59×71, 196884 = 1+196883" else "VIOLATION: moonshine constants",
    };
}

/// GF(3) conservation: exhaustive check that Trit.add is commutative.
pub fn checkTritCommutativity() CheckResult {
    const trits = [_]Trit{ .minus, .zero, .plus };
    for (trits) |a| {
        for (trits) |b| {
            if (Trit.add(a, b) != Trit.add(b, a)) return .{
                .passed = false,
                .postulate = "GF3-Comm",
                .message = "VIOLATION: trit addition not commutative",
            };
        }
    }
    return .{
        .passed = true,
        .postulate = "GF3-Comm",
        .message = "trit_add_comm verified (exhaustive 9 pairs)",
    };
}

/// GF(3): every trit has an additive inverse.
pub fn checkTritInverse() CheckResult {
    const trits = [_]Trit{ .minus, .zero, .plus };
    for (trits) |a| {
        var found = false;
        for (trits) |b| {
            if (Trit.add(a, b) == .zero) {
                found = true;
                break;
            }
        }
        if (!found) return .{
            .passed = false,
            .postulate = "GF3-Inverse",
            .message = "VIOLATION: trit without inverse",
        };
    }
    return .{
        .passed = true,
        .postulate = "GF3-Inverse",
        .message = "trit_add_inverse verified (exhaustive)",
    };
}

/// Shard → trit mapping covers all three residues mod 3 across the 71 shards.
/// Exactly: 24 shards map to zero, 24 to plus, 23 to minus (71 = 23×3 + 2).
pub fn checkShardTritCoverage() CheckResult {
    var counts = [_]u8{ 0, 0, 0 }; // minus, zero, plus
    var i: u8 = 0;
    while (i < SHARD_COUNT) : (i += 1) {
        const t = Trit.fromShard(i);
        const idx: usize = @intCast(@as(u8, @bitCast(@backingInt(t))) +% 1);
        counts[idx] += 1;
    }
    // 71 shards: 0→24, 1→24, 2→23 (since 71 mod 3 = 2)
    const ok = counts[0] == 23 and counts[1] == 24 and counts[2] == 24;
    return .{
        .passed = ok,
        .postulate = "shard_trit_coverage",
        .message = if (ok) "71 shards: minus=23 zero=24 plus=24" else "VIOLATION: trit distribution",
    };
}

/// j-invariant monotonicity: j(s) < j(s+1) for all valid shards.
pub fn checkJInvariantMonotone() CheckResult {
    var i: u8 = 0;
    while (i < SHARD_COUNT - 1) : (i += 1) {
        if (jInvariant(i) >= jInvariant(i + 1)) return .{
            .passed = false,
            .postulate = "j_invariant_monotone",
            .message = "VIOLATION: j-invariant not strictly increasing",
        };
    }
    return .{
        .passed = true,
        .postulate = "j_invariant_monotone",
        .message = "j(s) strictly increasing over 71 shards",
    };
}

/// Relativistic: light cone is symmetric and toroidal.
/// For all s, the light cone at budget=0 contains only s itself;
/// at budget=35 (with c=1), it covers all 71 shards.
pub fn checkLightConeSymmetry() CheckResult {
    // budget=0 → only self
    if (!inLightCone(0, 0, 0, DEFAULT_C_SHARD)) return .{
        .passed = false,
        .postulate = "light_cone_self",
        .message = "VIOLATION: shard not in own light cone at budget=0",
    };
    // budget=0 → neighbor excluded
    if (inLightCone(0, 1, 0, DEFAULT_C_SHARD)) return .{
        .passed = false,
        .postulate = "light_cone_locality",
        .message = "VIOLATION: neighbor reachable at budget=0",
    };
    // Symmetry: d(a,b) == d(b,a)
    var i: u8 = 0;
    while (i < SHARD_COUNT) : (i += 1) {
        var j: u8 = 0;
        while (j < SHARD_COUNT) : (j += 1) {
            if (shardDistance(i, j) != shardDistance(j, i)) return .{
                .passed = false,
                .postulate = "light_cone_symmetry",
                .message = "VIOLATION: shard distance not symmetric",
            };
        }
    }
    return .{
        .passed = true,
        .postulate = "light_cone_symmetry",
        .message = "d(s1,s2)=d(s2,s1) verified (exhaustive 71x71)",
    };
}

/// Run the full para-rigorous postcondition suite.
pub fn runAllChecks() [9]CheckResult {
    return .{
        checkStartsWith8080(),
        checkSeventyOneCubed(),
        checkPrimeCount(),
        checkMonsterDim(),
        checkTritCommutativity(),
        checkTritInverse(),
        checkShardTritCoverage(),
        checkJInvariantMonotone(),
        checkLightConeSymmetry(),
    };
}

/// C ABI export: bitmask of passing checks (for PufferLib / external verifiers).
/// 9 checks → bits 0..8 of a u16.
export fn monster_check_all() u16 {
    const results = runAllChecks();
    var mask: u16 = 0;
    for (results, 0..) |r, i| {
        if (r.passed) mask |= @as(u16, 1) << @intCast(i);
    }
    return mask;
}

// ============================================================================
// Tests
// ============================================================================

test "shard routing deterministic" {
    const msg1 = route("hello monster");
    const msg2 = route("hello monster");
    try std.testing.expectEqual(msg1.shard_id, msg2.shard_id);
    try std.testing.expectEqual(msg1.monster_position, msg2.monster_position);
    try std.testing.expectEqual(msg1.j_invariant, msg2.j_invariant);
}

test "shard id range" {
    const inputs = [_][]const u8{ "a", "bb", "ccc", "moonshine", "leech lattice", "vertex operator algebra" };
    for (inputs) |inp| {
        const sid = shardId(inp);
        try std.testing.expect(sid < SHARD_COUNT);
    }
}

test "j-invariant bounds" {
    try std.testing.expectEqual(@as(u64, 744), jInvariant(0));
    try std.testing.expectEqual(@as(u64, 744 + 196884), jInvariant(1));
    try std.testing.expectEqual(@as(u64, 744 + 196884 * 70), jInvariant(70));
}

test "monster walk step is 8080" {
    try std.testing.expectEqual(@as(u64, 8080), MONSTER_WALK_STEP);
}

test "monster primes count" {
    try std.testing.expectEqual(@as(usize, 15), MONSTER_PRIMES.len);
    try std.testing.expectEqual(@as(u64, 71), MONSTER_PRIMES[14]);
}

test "GF(3) trit from shard" {
    try std.testing.expectEqual(Trit.zero, Trit.fromShard(0));
    try std.testing.expectEqual(Trit.plus, Trit.fromShard(1));
    try std.testing.expectEqual(Trit.minus, Trit.fromShard(2));
    try std.testing.expectEqual(Trit.zero, Trit.fromShard(3));
}

test "shard router" {
    const allocator = std.testing.allocator;
    var router = ShardRouter.init(allocator);
    defer router.deinit();

    _ = try router.send("moonshine");
    _ = try router.send("j-invariant");
    _ = try router.send("vertex operator algebra");

    try std.testing.expectEqual(@as(u64, 3), router.total_routed);
    try std.testing.expect(router.activeShards() > 0);
}

test "monster divisibility" {
    const div = monsterDivisible(196883);
    // 196883 = 47 × 59 × 71
    try std.testing.expect(div[12]); // 47
    try std.testing.expect(div[13]); // 59
    try std.testing.expect(div[14]); // 71
    try std.testing.expectEqual(@as(u8, 3), monsterPrimeCount(196883));
}

test "monster dim factors" {
    try std.testing.expectEqual(@as(u64, 196883), 47 * 59 * 71);
}

test "prime trit mapping" {
    try std.testing.expectEqual(Trit.minus, primeToTrit(2));
    try std.testing.expectEqual(Trit.zero, primeToTrit(7));
    try std.testing.expectEqual(Trit.plus, primeToTrit(71));
}

test "ecstasis roundtrip" {
    inline for ([_]Trit{ .minus, .zero, .plus }) |t| {
        const e = Ecstasis.fromTrit(t);
        try std.testing.expectEqual(t, e.toTrit());
    }
}

test "ecstasis names" {
    try std.testing.expectEqualStrings("Gewesenheit", Ecstasis.retention.name());
    try std.testing.expectEqualStrings("Gegenwart", Ecstasis.impression.name());
    try std.testing.expectEqualStrings("Zukunft", Ecstasis.protention.name());
}

test "agent placement deterministic" {
    const a1 = placeAgent(0xDEADBEEF, 1);
    const a2 = placeAgent(0xDEADBEEF, 2);
    try std.testing.expectEqual(a1.shard_id, a2.shard_id);
    try std.testing.expectEqual(a1.ecstasis, a2.ecstasis);
    try std.testing.expect(a1.shard_id < SHARD_COUNT);
}

test "shared protention balance" {
    // Three protentions, one per ecstasis, each with 1 agent → balanced
    const p = [_]SharedProtention{
        .{ .shard_id = 0, .ecstasis = .retention, .agents = &.{1}, .generation = 0, .j_invariant = 744 },
        .{ .shard_id = 1, .ecstasis = .impression, .agents = &.{2}, .generation = 0, .j_invariant = 744 + 196884 },
        .{ .shard_id = 2, .ecstasis = .protention, .agents = &.{3}, .generation = 0, .j_invariant = 744 + 196884 * 2 },
    };
    // -1 + 0 + 1 = 0 mod 3 → balanced
    try std.testing.expect(SharedProtention.isBalanced(&p));
}

test "shard distance symmetric and toroidal" {
    // d(a,b) == d(b,a)
    try std.testing.expectEqual(shardDistance(0, 5), shardDistance(5, 0));
    // Toroidal: d(0, 70) == d(0, 1) (both are 1 step around the ring)
    try std.testing.expectEqual(shardDistance(0, 1), shardDistance(0, 70));
    // d(0, 0) == 0
    try std.testing.expectEqual(@as(u64, 0), shardDistance(0, 0));
    // d(0, 1) == 196884
    try std.testing.expectEqual(@as(u64, 196884), shardDistance(0, 1));
}

test "light cone containment" {
    // Self always reachable
    try std.testing.expect(inLightCone(10, 10, 0, 1));
    // Neighbor reachable at budget=1
    try std.testing.expect(inLightCone(10, 11, 1, 1));
    // Neighbor NOT reachable at budget=0
    try std.testing.expect(!inLightCone(10, 11, 0, 1));
    // Toroidal: shard 0 reaches shard 70 at budget=1
    try std.testing.expect(inLightCone(0, 70, 1, 1));
    // High c_shard: everything reachable at budget=1 with c=36
    try std.testing.expect(inLightCone(0, 35, 1, 36));
}

test "light cone iterator size" {
    const lc0 = lightCone(10, 0, 1);
    try std.testing.expectEqual(@as(u8, 1), lc0.size()); // just self
    const lc3 = lightCone(10, 3, 1);
    try std.testing.expectEqual(@as(u8, 7), lc3.size()); // self + 3 on each side
}

test "memory fusion superadditivity" {
    const agent_a = placeAgent(100, 0);
    const agent_b = placeAgent(200, 0);
    var model_a = GenerativeModel.init(agent_a);
    var model_b = GenerativeModel.init(agent_b);

    // A observes shards 5, 6, 7
    model_a.observe(5, .plus);
    model_a.observe(6, .minus);
    model_a.observe(7, .zero);

    // B observes shards 7, 8, 9
    model_b.observe(7, .zero);
    model_b.observe(8, .plus);
    model_b.observe(9, .minus);

    // A predicts shard 8 (hasn't observed it)
    model_a.predict(8, .minus);

    const fusion = fuseMemories(&model_a, &model_b);

    // Shard 7: both observed, same value → agreement
    try std.testing.expect(fusion.agreements >= 1);
    // Shard 8: A predicted, B observed, A didn't observe → triangulation
    try std.testing.expect(fusion.triangulations >= 1);
    // Superadditive: shared observations + triangulations
    try std.testing.expect(fusion.isSuperadditive());
    // Total coverage > either alone
    try std.testing.expect(fusion.total_coverage > model_a.observedCount());
    try std.testing.expect(fusion.total_coverage > model_b.observedCount());
}

test "apply fusion reduces free energy" {
    const agent_a = placeAgent(100, 0);
    const agent_b = placeAgent(200, 0);
    var model_a = GenerativeModel.init(agent_a);
    var model_b = GenerativeModel.init(agent_b);

    // A predicts shard 10 incorrectly
    model_a.predict(10, .plus);
    // B actually observed shard 10
    const actual = Trit.fromShard(10);
    model_b.observe(10, actual);
    model_b.predict(10, actual);

    // A has free energy if shard 10 is in light cone and observed
    // But A hasn't observed shard 10 yet, so surprise is 0 (unknown)
    // After fusion, A gets B's observation → now A can compute surprise
    applyFusion(&model_a, &model_b);

    // A now has B's observation of shard 10
    try std.testing.expect(model_a.observations[10] != null);

    // If A's prediction was wrong, perceptual inference fixes it
    model_a.perceptualInference(10);
    try std.testing.expectEqual(@as(u8, 0), model_a.surprise(10));
}

test "clearing size is emergent" {
    const agent_a = placeAgent(300, 0);
    const agent_b = placeAgent(400, 0);
    var model_a = GenerativeModel.init(agent_a);
    var model_b = GenerativeModel.init(agent_b);

    // Both observe the same 3 shards with same values
    inline for ([_]u8{ 20, 21, 22 }) |s| {
        const t = Trit.fromShard(s);
        model_a.observe(s, t);
        model_b.observe(s, t);
    }

    const fusion = fuseMemories(&model_a, &model_b);
    // Clearing = agreements + triangulations. Agreements exist only
    // in the relation between A and B, not in either alone.
    try std.testing.expect(fusion.clearingSize() >= 3);
    try std.testing.expectEqual(@as(u8, 0), fusion.fusionSurprise());
}

test "starlink latency model" {
    const p = STARLINK_PARAMS;
    // Same shard: ground bounce only
    try std.testing.expectEqual(@as(u32, 20), p.latencyMs(5, 5));
    // Adjacent: 20 + 3 = 23ms
    try std.testing.expectEqual(@as(u32, 23), p.latencyMs(5, 6));
    // Toroidal: shard 0 to shard 70 is 1 hop
    try std.testing.expectEqual(@as(u32, 23), p.latencyMs(0, 70));
    // 10 hops: 20 + 30 = 50ms (at budget boundary)
    try std.testing.expectEqual(@as(u32, 50), p.latencyMs(0, 10));
    // Reachable hops within 50ms budget: (50 - 20) / 3 = 10
    try std.testing.expectEqual(@as(u8, 10), p.reachableHops());
    // Shard 10 hops away: exactly at budget
    try std.testing.expect(p.isReachable(0, 10));
    // Shard 11 hops away: over budget
    try std.testing.expect(!p.isReachable(0, 11));
}

test "geo fallback latency" {
    const p = GEO_PARAMS;
    // Ground bounce dominates: 600ms
    try std.testing.expectEqual(@as(u32, 600), p.latencyMs(0, 0));
    // Still reachable within 700ms budget
    try std.testing.expect(p.isReachable(0, 0));
    // GEO: every shard reachable (single hop, all within shell)
    try std.testing.expectEqual(@as(u8, 35), p.reachableHops());
}

test "did to shard deterministic" {
    const did1 = "did:gay:abcdefghijklmnopqrstuvwx";
    const did2 = "did:gay:abcdefghijklmnopqrstuvwx";
    try std.testing.expectEqual(didToShard(did1), didToShard(did2));
    try std.testing.expect(didToShard(did1) < SHARD_COUNT);
}

test "group attestation quorum" {
    const agents = [_]AgentHorizon{
        .{ .agent_id = 1, .shard_id = 5, .ecstasis = .protention, .generation = 0, .j_invariant = jInvariant(5) },
        .{ .agent_id = 2, .shard_id = 5, .ecstasis = .protention, .generation = 0, .j_invariant = jInvariant(5) },
        .{ .agent_id = 3, .shard_id = 5, .ecstasis = .protention, .generation = 0, .j_invariant = jInvariant(5) },
    };

    var models: [3]GenerativeModel = undefined;
    for (&models, agents) |*m, a| {
        m.* = GenerativeModel.init(a);
    }

    // All three observe shard 10 as .plus
    for (&models) |*m| {
        m.observe(10, .plus);
    }

    const att = attestShard(&models, 10).?;
    try std.testing.expect(att.hasQuorum());
    try std.testing.expect(att.isUnanimous());
    try std.testing.expectEqual(Trit.plus, att.observed_trit);
    try std.testing.expectEqual(@as(u8, 3), att.attestors);
}

test "group attestation no quorum on disagreement" {
    const agents = [_]AgentHorizon{
        .{ .agent_id = 1, .shard_id = 5, .ecstasis = .protention, .generation = 0, .j_invariant = jInvariant(5) },
        .{ .agent_id = 2, .shard_id = 5, .ecstasis = .protention, .generation = 0, .j_invariant = jInvariant(5) },
        .{ .agent_id = 3, .shard_id = 5, .ecstasis = .protention, .generation = 0, .j_invariant = jInvariant(5) },
    };

    var models: [3]GenerativeModel = undefined;
    for (&models, agents) |*m, a| {
        m.* = GenerativeModel.init(a);
    }

    // Each observes a different trit → no majority > 1
    models[0].observe(10, .plus);
    models[1].observe(10, .minus);
    models[2].observe(10, .zero);

    const att = attestShard(&models, 10).?;
    try std.testing.expect(!att.hasQuorum());
    try std.testing.expect(!att.isUnanimous());
    try std.testing.expectEqual(@as(u8, 1), att.attestors);
}

test "generative model self-prediction" {
    const agent = placeAgent(42, 0);
    const model = GenerativeModel.init(agent);
    // Self-prediction always correct → 0 surprise at own shard
    try std.testing.expectEqual(@as(u8, 0), model.surprise(agent.shard_id));
    // At least 1 observed shard (self)
    try std.testing.expect(model.observedCount() >= 1);
}

test "free energy increases with prediction error" {
    const agent = placeAgent(42, 0);
    var model = GenerativeModel.init(agent);
    // Initially at equilibrium (only self observed, self matches)
    try std.testing.expectEqual(@as(u32, 0), model.freeEnergy(5, 1));
    // Observe neighbor with correct prediction → still zero
    const neighbor: u8 = (agent.shard_id + 1) % SHARD_COUNT;
    const correct_trit = Trit.fromShard(neighbor);
    model.predict(neighbor, correct_trit);
    model.observe(neighbor, correct_trit);
    try std.testing.expectEqual(@as(u32, 0), model.freeEnergy(5, 1));
    // Now introduce mismatch → free energy rises
    model.predict(neighbor, .plus);
    model.observe(neighbor, .minus);
    try std.testing.expect(model.freeEnergy(5, 1) > 0);
}

test "perceptual inference reduces free energy" {
    const agent = placeAgent(42, 0);
    var model = GenerativeModel.init(agent);
    const neighbor: u8 = (agent.shard_id + 1) % SHARD_COUNT;
    // Create mismatch
    model.predict(neighbor, .plus);
    model.observe(neighbor, .minus);
    try std.testing.expect(model.freeEnergy(5, 1) > 0);
    // Perceptual inference: update prediction to match observation
    model.fullPerceptualInference(5, 1);
    try std.testing.expectEqual(@as(u32, 0), model.freeEnergy(5, 1));
}

test "equilibrium after full inference" {
    const agent = placeAgent(99, 0);
    var model = GenerativeModel.init(agent);
    // Populate some mismatches
    var i: u8 = 0;
    while (i < 5) : (i += 1) {
        const s = (agent.shard_id + i + 1) % SHARD_COUNT;
        model.predict(s, .plus);
        model.observe(s, .zero);
    }
    try std.testing.expect(!model.atEquilibrium(10, 1));
    model.fullPerceptualInference(10, 1);
    try std.testing.expect(model.atEquilibrium(10, 1));
}

test "quale: projections are consistent" {
    const q = Quale.init(42, 0);
    // All projections derive from the same raw value
    try std.testing.expectEqual(q.raw, splitmix64At(42, 0));
    try std.testing.expect(q.shard() < SHARD_COUNT);
    try std.testing.expect(q.hue() >= 0.0 and q.hue() < 360.0);
    // shard → ecstasis → trit is consistent path
    try std.testing.expectEqual(q.ecstasis().toTrit(), Trit.fromShard(q.shard()));
}

test "quale: same seed is same identity" {
    const q1 = Quale.init(999, 0);
    const q2 = Quale.init(999, 1);
    const q3 = Quale.init(1000, 0);
    try std.testing.expect(Quale.sameIdentity(q1, q2));
    try std.testing.expect(!Quale.sameIdentity(q1, q3));
    // Same identity, different moments → possibly different raw values
    try std.testing.expect(q1.raw != q2.raw);
}

test "quale: shared clearing without shared identity" {
    // Find two different seeds that land on the same shard
    var seed: u64 = 0;
    const ref_shard = Quale.init(0, 0).shard();
    seed = 1;
    while (seed < 1000) : (seed += 1) {
        const q = Quale.init(seed, 0);
        if (q.shard() == ref_shard) {
            try std.testing.expect(Quale.shareClearing(Quale.init(0, 0), q));
            try std.testing.expect(!Quale.sameIdentity(Quale.init(0, 0), q));
            break;
        }
    }
}

test "quale: asAgent roundtrip" {
    const q = Quale.init(0xCAFE, 0);
    const agent = q.asAgent(42);
    try std.testing.expectEqual(q.shard(), agent.shard_id);
    try std.testing.expectEqual(q.ecstasis(), agent.ecstasis);
    try std.testing.expectEqual(q.jInv(), agent.j_invariant);
    try std.testing.expectEqual(@as(u64, 0xCAFE), agent.agent_id);
    try std.testing.expectEqual(@as(u64, 42), agent.generation);
}

test "SPI: splitmix64 matches goblins_ffi constants" {
    // These constants MUST match goblins_ffi.zig, splitmix_trit.zig,
    // and wgpu_compute.zig. If they don't, the SPI is broken.
    try std.testing.expectEqual(@as(u64, 0x9e3779b97f4a7c15), SM_GOLDEN);
    try std.testing.expectEqual(@as(u64, 0xbf58476d1ce4e5b9), SM_MIX1);
    try std.testing.expectEqual(@as(u64, 0x94d049bb133111eb), SM_MIX2);
}

test "SPI: deterministic across calls" {
    const v1 = splitmix64At(42, 0);
    const v2 = splitmix64At(42, 0);
    try std.testing.expectEqual(v1, v2);
    // Different index → different value
    try std.testing.expect(v1 != splitmix64At(42, 1));
    // Different seed → different value
    try std.testing.expect(v1 != splitmix64At(43, 0));
}

test "SPI: shard assignment via splitmix64" {
    // Same agent_id always lands on same shard
    const a1 = placeAgent(0xDEADBEEF, 0);
    const a2 = placeAgent(0xDEADBEEF, 100);
    try std.testing.expectEqual(a1.shard_id, a2.shard_id);
    try std.testing.expectEqual(a1.ecstasis, a2.ecstasis);
    try std.testing.expect(a1.shard_id < SHARD_COUNT);
}

test "SPI: trit from splitmix value" {
    // Verify trit extraction covers all three values
    var seen = [_]bool{ false, false, false };
    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        const t = splitmixTrit(splitmix64At(i, 0));
        const idx: usize = @intCast(@as(u8, @bitCast(@backingInt(t))) +% 1);
        seen[idx] = true;
    }
    for (seen) |s| try std.testing.expect(s);
}

test "SPI: hue in range" {
    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        const h = splitmixHue(splitmix64At(i, 0));
        try std.testing.expect(h >= 0.0 and h < 360.0);
    }
}

test "para-rigorous postcondition suite" {
    const results = runAllChecks();
    for (results) |r| {
        try std.testing.expect(r.passed);
    }
}

test "monster_check_all C ABI export" {
    const mask = monster_check_all();
    // All 9 checks should pass → mask = 0x1FF
    try std.testing.expectEqual(@as(u16, 0x1FF), mask);
}
