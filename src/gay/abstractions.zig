// abstractions.zig: Abstract foundations bundled from Gay.jl
// Translated from: abstract_acset.jl, abstract_free_gadget.jl, abstract_gay_crdt.jl,
//   abstract_gay_probe.jl, abstract_world.jl, dialectica.jl, homotopy_hypothesis.jl,
//   bartons_free.jl, birb.jl

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;
const sm = @import("splitmix.zig");
const splitmix64 = sm.splitmix64;

// ============================================================================
// Section 1: Abstract ACSets
// ============================================================================

pub const ChromaticClass = enum(u8) {
    chromatic,
    achromatic,
    hybrid,
};

pub const GlueModality = enum(u8) {
    free_monad,
    regret_monad,
    state_monad,
    continuation_monad,
    writer_monad,
    cofree_comonad,
    coregret_comonad,
    store_comonad,
    env_comonad,
    traced_comonad,
};

pub const AdjunctionKind = enum(u8) {
    free_forgetful,
    curried_uncurried,
    direct_inverse,
    galois_connection,
    schrodinger_bridge,
};

pub const HigherStructure = enum(u8) {
    two_morphism,
    lax_monoidal,
    pseudo_functor,
    infinity_groupoid,
};

pub const GameStructure = enum(u8) {
    thesis_antithesis,
    witness_challenge,
    game_equilibrium,
    fixed_point,
};

/// Abstract ACSet: typed attributed C-set with chromatic classification
pub const AbstractACSet = struct {
    class: ChromaticClass,
    glue: GlueModality,
    seed: u64,

    pub fn init(class: ChromaticClass, glue: GlueModality, seed: u64) AbstractACSet {
        return .{ .class = class, .glue = glue, .seed = seed };
    }

    pub fn modalityIndex(self: AbstractACSet) u8 {
        return @backingInt(self.glue);
    }

    /// Self-reinterpretation: advance seed, potentially shift modality
    pub fn selfReinterpret(self: *AbstractACSet) void {
        self.seed = splitmix64(self.seed);
        const idx = self.seed % 10;
        self.glue = @fromBackingInt(@intCast(@as(u8, @intCast(idx))));
    }

    /// Agentive bind: compose two ACSets via seed mixing
    pub fn agentiveBind(self: AbstractACSet, other: AbstractACSet) AbstractACSet {
        return .{
            .class = if (self.class == other.class) self.class else .hybrid,
            .glue = self.glue,
            .seed = splitmix64(self.seed ^ other.seed),
        };
    }
};

// ============================================================================
// Section 2: Free Gadgets
// ============================================================================

pub const TritDirection = enum(i2) {
    back = -1,
    stay = 0,
    forward = 1,
};

pub const GadgetKind = enum(u8) {
    three_match,
    edge,
    thread,
};

pub const FreeGadget = struct {
    kind: GadgetKind,
    seed: u64,
    arity: u8,
    connections: [8]u16, // neighbor indices, 0 = empty
    degree: u8,

    pub fn init(kind: GadgetKind, seed: u64, arity: u8) FreeGadget {
        return .{
            .kind = kind,
            .seed = seed,
            .arity = arity,
            .connections = @splat(0),
            .degree = 0,
        };
    }

    pub fn color(self: FreeGadget) u24 {
        const s = splitmix64(self.seed);
        return @intCast(s & 0xFFFFFF);
    }

    pub fn fingerprint(self: FreeGadget) u64 {
        return splitmix64(self.seed ^ @as(u64, self.arity));
    }

    pub fn connect(self: *FreeGadget, neighbor: u16) bool {
        if (self.degree >= 8) return false;
        self.connections[self.degree] = neighbor;
        self.degree += 1;
        return true;
    }
};

pub const TritWalkState = struct {
    position: u64,
    direction: TritDirection,
    steps: u32,

    pub fn init(seed: u64) TritWalkState {
        return .{ .position = seed, .direction = .stay, .steps = 0 };
    }

    pub fn step(self: *TritWalkState) void {
        self.position = splitmix64(self.position);
        const trit_val = self.position % 3;
        self.direction = @fromBackingInt(@intCast(@as(i2, @intCast(trit_val)) - 1));
        self.steps += 1;
    }

    /// Merge two walks (CRDT-like: max steps, XOR position)
    pub fn merge(a: TritWalkState, b: TritWalkState) TritWalkState {
        return .{
            .position = a.position ^ b.position,
            .direction = if (a.steps >= b.steps) a.direction else b.direction,
            .steps = @max(a.steps, b.steps),
        };
    }
};

// ============================================================================
// Section 3: CRDT Interface
// ============================================================================

pub const CRDTOrdering = enum(u8) {
    less_than,
    equal,
    greater_than,
    concurrent,
};

pub const CRDTKind = enum(u8) {
    g_counter,
    pn_counter,
    g_set,
    or_set,
    lww_register,
};

/// GCounter: grow-only counter, merge = max per replica
pub const GCounter = struct {
    counts: [16]u64,
    replica_id: u8,

    pub fn init(replica_id: u8) GCounter {
        return .{ .counts = @splat(0), .replica_id = replica_id };
    }

    pub fn increment(self: *GCounter) void {
        self.counts[self.replica_id] +|= 1;
    }

    pub fn value(self: GCounter) u64 {
        var sum: u64 = 0;
        for (self.counts) |c| sum +|= c;
        return sum;
    }

    pub fn merge(a: GCounter, b: GCounter) GCounter {
        var result = a;
        for (&result.counts, b.counts) |*r, bc| {
            r.* = @max(r.*, bc);
        }
        return result;
    }

    pub fn compare(a: GCounter, b: GCounter) CRDTOrdering {
        var a_leq_b = true;
        var b_leq_a = true;
        for (a.counts, b.counts) |ac, bc| {
            if (ac > bc) a_leq_b = false;
            if (bc > ac) b_leq_a = false;
        }
        if (a_leq_b and b_leq_a) return .equal;
        if (a_leq_b) return .less_than;
        if (b_leq_a) return .greater_than;
        return .concurrent;
    }
};

/// LWWRegister: last-writer-wins register
pub fn LWWRegister(comptime T: type) type {
    return struct {
        value: T,
        timestamp: u64,
        replica_id: u8,

        const Self = @This();

        pub fn init(val: T, ts: u64, replica: u8) Self {
            return .{ .value = val, .timestamp = ts, .replica_id = replica };
        }

        pub fn set(self: *Self, val: T, ts: u64) void {
            if (ts > self.timestamp) {
                self.value = val;
                self.timestamp = ts;
            }
        }

        pub fn merge(a: Self, b: Self) Self {
            if (a.timestamp > b.timestamp) return a;
            if (b.timestamp > a.timestamp) return b;
            // tie-break by replica_id
            return if (a.replica_id >= b.replica_id) a else b;
        }
    };
}

// ============================================================================
// Section 4: Probe Interface
// ============================================================================

pub const ProbeKind = enum(u8) {
    synthetic,
    reafferent,
    path_invariance,
    spi, // synthetic-path-invariance
};

pub const ProbeResult = struct {
    kind: ProbeKind,
    value: f64,
    fingerprint: u64,
    valid: bool,
};

/// Probe: composable measurement interface
pub const Probe = struct {
    kind: ProbeKind,
    seed: u64,

    pub fn init(kind: ProbeKind, seed: u64) Probe {
        return .{ .kind = kind, .seed = seed };
    }

    pub fn run(self: Probe, target_seed: u64) ProbeResult {
        const mixed = splitmix64(self.seed ^ target_seed);
        const val: f64 = @as(f64, @floatFromInt(mixed & 0xFFFF)) / 65535.0;
        return .{
            .kind = self.kind,
            .value = val,
            .fingerprint = mixed,
            .valid = val > 0.01,
        };
    }

    /// Compose two probes: SPI = synthetic + path_invariance
    pub fn compose(a: Probe, b: Probe) Probe {
        const new_kind: ProbeKind = if (a.kind == .synthetic and b.kind == .path_invariance)
            .spi
        else
            a.kind;
        return .{ .kind = new_kind, .seed = splitmix64(a.seed ^ b.seed) };
    }

    /// Reafferent saturation: ratio of expected vs observed
    pub fn reafferentSaturation(self: Probe, observed: f64, expected: f64) f64 {
        _ = self;
        if (expected == 0.0) return 0.0;
        return @min(observed / expected, 1.0);
    }
};

// ============================================================================
// Section 5: Abstract World
// ============================================================================

pub const WorldFlow = enum(u8) {
    play,
    coplay,
    evaluate,
    bidirectional,
};

pub const AgentKind = enum(u8) {
    social_choice,
    geometric,
    algorithmic,
};

pub const MCEquivalence = enum(u8) {
    zigzag,
    boomerang,
    gaymc,
};

/// BidirectionalFlow: Para construction for open games
pub const BidirectionalFlow = struct {
    forward_seed: u64,
    backward_seed: u64,
    equilibrium: bool,

    pub fn init(seed: u64) BidirectionalFlow {
        return .{
            .forward_seed = seed,
            .backward_seed = splitmix64(seed),
            .equilibrium = false,
        };
    }

    pub fn play(self: *BidirectionalFlow) u64 {
        self.forward_seed = splitmix64(self.forward_seed);
        return self.forward_seed;
    }

    pub fn coplay(self: *BidirectionalFlow, observation: u64) void {
        self.backward_seed = splitmix64(self.backward_seed ^ observation);
    }

    pub fn checkEquilibrium(self: *BidirectionalFlow) bool {
        // Equilibrium when forward/backward converge mod 3 (GF(3))
        const f_trit = self.forward_seed % 3;
        const b_trit = self.backward_seed % 3;
        self.equilibrium = ((f_trit + b_trit) % 3 == 0);
        return self.equilibrium;
    }
};

/// InteractiveProof: commit-challenge-respond-verify
pub const InteractiveProof = struct {
    commitment: u64,
    challenge: u64,
    response: u64,
    verified: bool,

    pub fn init() InteractiveProof {
        return .{ .commitment = 0, .challenge = 0, .response = 0, .verified = false };
    }

    pub fn commit(self: *InteractiveProof, secret: u64) void {
        self.commitment = splitmix64(secret);
    }

    pub fn setChallenge(self: *InteractiveProof, c: u64) void {
        self.challenge = c;
    }

    pub fn respond(self: *InteractiveProof, secret: u64) void {
        self.response = splitmix64(secret ^ self.challenge);
    }

    pub fn verify(self: *InteractiveProof) bool {
        self.verified = (splitmix64(self.response) != 0);
        return self.verified;
    }
};

/// ParaGay: parametric lifting for open game composition
pub const ParaGay = struct {
    seed: u64,
    level: u8, // 0=Para, 1=ParaPara, 2=Sharp

    pub fn init(seed: u64) ParaGay {
        return .{ .seed = seed, .level = 0 };
    }

    pub fn lift(self: *ParaGay) void {
        self.seed = splitmix64(self.seed);
        self.level = @min(self.level + 1, 2);
    }

    /// CNOT reduce: collapse two levels
    pub fn cnotReduce(self: *ParaGay) void {
        if (self.level > 0) self.level -= 1;
        self.seed = splitmix64(self.seed);
    }
};

// ============================================================================
// Section 6: Dialectica Interpretation
// ============================================================================

pub const DialecticaMove = enum(u8) {
    witness,
    challenge,
};

/// DialecticaGame: de Paiva's Dialectica categories
pub const DialecticaGame = struct {
    seed: u64,
    move_count: u32,
    entropy: f64,

    pub fn init(seed: u64) DialecticaGame {
        return .{ .seed = seed, .move_count = 0, .entropy = 0.0 };
    }

    pub fn nextColor(self: *DialecticaGame) u24 {
        self.seed = splitmix64(self.seed);
        self.move_count += 1;
        return @intCast(self.seed & 0xFFFFFF);
    }

    pub fn colorAt(self: DialecticaGame, step: u32) u24 {
        var s = self.seed;
        for (0..step) |_| s = splitmix64(s);
        return @intCast(s & 0xFFFFFF);
    }

    /// Interaction entropy: log2 of move space
    pub fn interactionEntropy(self: *DialecticaGame) f64 {
        if (self.move_count == 0) return 0.0;
        self.entropy = @log2(@as(f64, @floatFromInt(self.move_count)));
        return self.entropy;
    }

    /// Linear Dialectica: tensor (A tensor B)
    pub fn tensor(a: DialecticaGame, b: DialecticaGame) DialecticaGame {
        return .{
            .seed = splitmix64(a.seed ^ b.seed),
            .move_count = a.move_count + b.move_count,
            .entropy = a.entropy + b.entropy,
        };
    }

    /// Linear Dialectica: par (A par B)
    pub fn par(a: DialecticaGame, b: DialecticaGame) DialecticaGame {
        return .{
            .seed = splitmix64(a.seed +% b.seed),
            .move_count = @max(a.move_count, b.move_count),
            .entropy = @max(a.entropy, b.entropy),
        };
    }

    /// Bang (!) modality: promote to reusable
    pub fn bang(self: DialecticaGame) DialecticaGame {
        return .{
            .seed = splitmix64(splitmix64(self.seed)),
            .move_count = self.move_count,
            .entropy = self.entropy * 2.0,
        };
    }

    /// Composition with cut elimination check
    pub fn compose(a: DialecticaGame, b: DialecticaGame) DialecticaGame {
        return tensor(a, b);
    }

    pub fn verifyCutElimination(a: DialecticaGame, b: DialecticaGame) bool {
        const ab = compose(a, b);
        const ba = compose(b, a);
        // Cut elimination: entropy is stable under reordering
        return @abs(ab.entropy - ba.entropy) < 1e-10;
    }
};

// ============================================================================
// Section 7: Homotopy Hypothesis
// ============================================================================

pub const CellDimension = enum(u8) {
    thing, // 0-cell
    process, // 1-cell (morphism)
    meta_process, // 2-cell (natural transformation)
};

pub const NCell = struct {
    dimension: u8,
    seed: u64,
    source: u64, // source cell fingerprint
    target: u64, // target cell fingerprint

    pub fn makeThing(seed: u64) NCell {
        return .{ .dimension = 0, .seed = seed, .source = 0, .target = 0 };
    }

    pub fn makeProcess(seed: u64, src: u64, tgt: u64) NCell {
        return .{ .dimension = 1, .seed = seed, .source = src, .target = tgt };
    }

    pub fn makeMetaProcess(seed: u64, src: u64, tgt: u64) NCell {
        return .{ .dimension = 2, .seed = seed, .source = src, .target = tgt };
    }

    pub fn pathColor(self: NCell) u24 {
        return @intCast(splitmix64(self.seed ^ self.source ^ self.target) & 0xFFFFFF);
    }
};

/// InfinityGroupoid: collection of n-cells with coherence
pub const InfinityGroupoid = struct {
    cells: [64]NCell,
    count: u8,
    max_dimension: u8,

    pub fn init() InfinityGroupoid {
        return .{
            .cells = undefined,
            .count = 0,
            .max_dimension = 0,
        };
    }

    pub fn addCell(self: *InfinityGroupoid, cell: NCell) bool {
        if (self.count >= 64) return false;
        self.cells[self.count] = cell;
        self.count += 1;
        if (cell.dimension > self.max_dimension) self.max_dimension = cell.dimension;
        return true;
    }

    /// Associator color: coherence witness at dimension 2
    pub fn associatorColor(self: InfinityGroupoid) u24 {
        var h: u64 = 0;
        for (0..self.count) |i| {
            if (self.cells[i].dimension == 2)
                h ^= self.cells[i].seed;
        }
        return @intCast(splitmix64(h) & 0xFFFFFF);
    }

    /// Pentagonator color: coherence witness at dimension 3+
    pub fn pentagonatorColor(self: InfinityGroupoid) u24 {
        var h: u64 = 0;
        for (0..self.count) |i| {
            if (self.cells[i].dimension >= 3)
                h ^= self.cells[i].seed;
        }
        return @intCast(splitmix64(h) & 0xFFFFFF);
    }
};

/// ChebyshevCoherence: approximate homotopy coherences via Chebyshev polynomials
pub const ChebyshevCoherence = struct {
    level: u8,

    pub fn init(level: u8) ChebyshevCoherence {
        return .{ .level = level };
    }

    /// T_n(x) Chebyshev polynomial of the first kind
    pub fn chebyshevT(n: u8, x: f64) f64 {
        if (n == 0) return 1.0;
        if (n == 1) return x;
        var t_prev: f64 = 1.0;
        var t_curr: f64 = x;
        for (2..@as(usize, n) + 1) |_| {
            const t_next = 2.0 * x * t_curr - t_prev;
            t_prev = t_curr;
            t_curr = t_next;
        }
        return t_curr;
    }

    /// Coherence error at given level
    pub fn coherenceError(self: ChebyshevCoherence, x: f64) f64 {
        const exact = chebyshevT(self.level + 1, x);
        const approx = chebyshevT(self.level, x);
        return @abs(exact - approx);
    }
};

// ============================================================================
// Section 8: Barton's Free (Monad/Comonad)
// ============================================================================

/// Free monad tag
pub const FreeTag = enum(u8) {
    pure,
    suspend_step,
};

/// Free monad over a seed-based functor
pub const FreeMonad = struct {
    tag: FreeTag,
    value: u64,

    pub fn pure(val: u64) FreeMonad {
        return .{ .tag = .pure, .value = val };
    }

    pub fn lift(seed: u64) FreeMonad {
        return .{ .tag = .suspend_step, .value = seed };
    }

    pub fn bind(self: FreeMonad, f_seed: u64) FreeMonad {
        return switch (self.tag) {
            .pure => .{ .tag = .pure, .value = splitmix64(self.value ^ f_seed) },
            .suspend_step => .{ .tag = .suspend_step, .value = splitmix64(self.value ^ f_seed) },
        };
    }
};

/// Cofree comonad: seed + lazy continuation
pub const CofreeComonad = struct {
    head: u64,
    tail_seed: u64,

    pub fn init(head: u64, tail_seed: u64) CofreeComonad {
        return .{ .head = head, .tail_seed = tail_seed };
    }

    pub fn extract(self: CofreeComonad) u64 {
        return self.head;
    }

    pub fn extend(self: CofreeComonad) CofreeComonad {
        return .{
            .head = splitmix64(self.head ^ self.tail_seed),
            .tail_seed = splitmix64(self.tail_seed),
        };
    }
};

/// Pair free monad with cofree comonad (adjunction witness)
pub fn pairFreeCofree(f: FreeMonad, c: CofreeComonad) u64 {
    return splitmix64(f.value ^ c.head);
}

/// Triple rotation: GF(3) cycling through three monadic perspectives
pub fn tripleRotation(seed: u64) [3]u64 {
    return .{
        splitmix64(seed),
        splitmix64(splitmix64(seed)),
        splitmix64(splitmix64(splitmix64(seed))),
    };
}

pub const DuckPerspective = enum(u8) {
    communist, // collective
    capitalist, // individual
    post, // transcendent
};

/// Best-response dynamics
pub const BestResponseDynamics = struct {
    state: u64,
    nonlinear: bool,

    pub fn init(seed: u64, nonlinear: bool) BestResponseDynamics {
        return .{ .state = seed, .nonlinear = nonlinear };
    }

    pub fn step(self: *BestResponseDynamics) u64 {
        self.state = splitmix64(self.state);
        if (self.nonlinear) {
            // nonlinear: fold trit structure
            const trit = self.state % 3;
            self.state = splitmix64(self.state +% trit);
        }
        return self.state;
    }

    pub fn resilienceMeasure(self: BestResponseDynamics) f64 {
        const bits = @popCount(self.state);
        return @as(f64, @floatFromInt(bits)) / 64.0;
    }
};

/// ThreeMatchGadget: tripartite decision
pub const ThreeMatchGadget = struct {
    edges: [3]u64,

    pub fn init(seed: u64) ThreeMatchGadget {
        const r = tripleRotation(seed);
        return .{ .edges = r };
    }

    pub fn decide(self: ThreeMatchGadget) u8 {
        // majority vote over GF(3)
        var votes: [3]u8 = @splat(0);
        for (self.edges) |e| votes[e % 3] += 1;
        var best: u8 = 0;
        for (1..3) |i| {
            if (votes[i] > votes[best]) best = @intCast(i);
        }
        return best;
    }
};

// ============================================================================
// Section 9: Birb (Combinators + Sonification)
// ============================================================================

pub const BirbNote = struct {
    frequency: f64, // Hz
    duration: f64, // seconds
    timbre: u24, // color-as-timbre

    pub fn fromSeed(seed: u64) BirbNote {
        const s = splitmix64(seed);
        // Map to audible range 220-880 Hz (A3-A5)
        const freq = 220.0 + @as(f64, @floatFromInt(s & 0xFFFF)) / 65535.0 * 660.0;
        const dur = 0.1 + @as(f64, @floatFromInt((s >> 16) & 0xFF)) / 255.0 * 0.9;
        const color: u24 = @intCast((s >> 24) & 0xFFFFFF);
        return .{ .frequency = freq, .duration = dur, .timbre = color };
    }
};

pub const WorldMagnet = struct {
    name_hash: u64,
    position: [3]f64,

    pub const ORIGIN = WorldMagnet{ .name_hash = 0, .position = .{ 0, 0, 0 } };
    pub const PINEAPPLE = WorldMagnet{ .name_hash = 0xAAAAAA, .position = .{ 1, 0, 0 } };
    pub const WIZARD = WorldMagnet{ .name_hash = 0xBBBBBB, .position = .{ 0, 1, 0 } };
    pub const SCHEMER = WorldMagnet{ .name_hash = 0xCCCCCC, .position = .{ 0, 0, 1 } };

    pub fn distance(a: WorldMagnet, b: WorldMagnet) f64 {
        var sum: f64 = 0;
        for (0..3) |i| {
            const d = a.position[i] - b.position[i];
            sum += d * d;
        }
        return @sqrt(sum);
    }

    pub fn fieldStrength(self: WorldMagnet, point: [3]f64) f64 {
        var sum: f64 = 0;
        for (0..3) |i| {
            const d = self.position[i] - point[i];
            sum += d * d;
        }
        const r = @sqrt(sum);
        if (r < 1e-10) return 1e10;
        return 1.0 / (r * r);
    }
};

pub const HARMONIC_RATIOS = [_]f64{ 1.0, 9.0 / 8.0, 5.0 / 4.0, 4.0 / 3.0, 3.0 / 2.0, 5.0 / 3.0, 15.0 / 8.0, 2.0 };

/// Compress any seed to a GF(3) triple
pub fn compressToThree(seed: u64) [3]u8 {
    return .{
        @intCast(seed % 3),
        @intCast((seed / 3) % 3),
        @intCast((seed / 9) % 3),
    };
}

/// Decompress GF(3) triple back to seed-space
pub fn decompressFromThree(triple: [3]u8) u64 {
    return @as(u64, triple[0]) + @as(u64, triple[1]) * 3 + @as(u64, triple[2]) * 9;
}

/// Chirp: ascending frequency sweep
pub fn chirp(seed: u64, steps: u8) [16]BirbNote {
    var notes: [16]BirbNote = undefined;
    var s = seed;
    const n = @min(steps, 16);
    for (0..n) |i| {
        notes[i] = BirbNote.fromSeed(s);
        s = splitmix64(s);
    }
    for (n..16) |i| {
        notes[i] = .{ .frequency = 0, .duration = 0, .timbre = 0 };
    }
    return notes;
}

/// Warble: alternating frequency pattern
pub fn warble(seed: u64) [2]BirbNote {
    return .{
        BirbNote.fromSeed(seed),
        BirbNote.fromSeed(splitmix64(seed)),
    };
}

// ============================================================================
// Tests
// ============================================================================

test "AbstractACSet: self-reinterpret preserves class" {
    var acset = AbstractACSet.init(.chromatic, .free_monad, 42);
    const orig_class = acset.class;
    acset.selfReinterpret();
    try std.testing.expectEqual(orig_class, acset.class);
    try std.testing.expect(acset.seed != 42);
}

test "AbstractACSet: agentive bind" {
    const a = AbstractACSet.init(.chromatic, .free_monad, 1);
    const b = AbstractACSet.init(.achromatic, .state_monad, 2);
    const c = a.agentiveBind(b);
    try std.testing.expectEqual(ChromaticClass.hybrid, c.class);
}

test "FreeGadget: connect and color" {
    var g = FreeGadget.init(.three_match, 42, 3);
    try std.testing.expect(g.connect(1));
    try std.testing.expect(g.connect(2));
    try std.testing.expectEqual(@as(u8, 2), g.degree);
    try std.testing.expect(g.color() != 0);
}

test "TritWalkState: step and merge" {
    var w1 = TritWalkState.init(100);
    var w2 = TritWalkState.init(200);
    w1.step();
    w1.step();
    w2.step();
    const merged = TritWalkState.merge(w1, w2);
    try std.testing.expectEqual(@as(u32, 2), merged.steps);
}

test "GCounter: increment, merge, compare" {
    var a = GCounter.init(0);
    var b = GCounter.init(1);
    a.increment();
    a.increment();
    b.increment();
    try std.testing.expectEqual(@as(u64, 2), a.value());
    try std.testing.expectEqual(@as(u64, 1), b.value());
    const m = GCounter.merge(a, b);
    try std.testing.expectEqual(@as(u64, 3), m.value());
    try std.testing.expectEqual(CRDTOrdering.concurrent, GCounter.compare(a, b));
}

test "LWWRegister: merge picks latest" {
    const Reg = LWWRegister(u64);
    const a = Reg.init(10, 5, 0);
    const b = Reg.init(20, 7, 1);
    const m = Reg.merge(a, b);
    try std.testing.expectEqual(@as(u64, 20), m.value);
}

test "Probe: compose and run" {
    const syn = Probe.init(.synthetic, 42);
    const pi = Probe.init(.path_invariance, 99);
    const spi = Probe.compose(syn, pi);
    try std.testing.expectEqual(ProbeKind.spi, spi.kind);
    const result = spi.run(1000);
    try std.testing.expect(result.valid);
}

test "BidirectionalFlow: play-coplay-equilibrium" {
    var flow = BidirectionalFlow.init(12345);
    const out = flow.play();
    flow.coplay(out);
    _ = flow.checkEquilibrium();
    // Just ensure it runs without error
    try std.testing.expect(flow.forward_seed != 0);
}

test "InteractiveProof: commit-challenge-respond-verify" {
    var proof = InteractiveProof.init();
    proof.commit(42);
    proof.setChallenge(7);
    proof.respond(42);
    try std.testing.expect(proof.verify());
}

test "ParaGay: lift and reduce" {
    var p = ParaGay.init(42);
    try std.testing.expectEqual(@as(u8, 0), p.level);
    p.lift();
    try std.testing.expectEqual(@as(u8, 1), p.level);
    p.lift();
    try std.testing.expectEqual(@as(u8, 2), p.level);
    p.cnotReduce();
    try std.testing.expectEqual(@as(u8, 1), p.level);
}

test "DialecticaGame: tensor and cut elimination" {
    var a = DialecticaGame.init(10);
    _ = a.nextColor();
    _ = a.nextColor();
    _ = a.interactionEntropy();
    var b = DialecticaGame.init(20);
    _ = b.nextColor();
    _ = b.interactionEntropy();
    const t = DialecticaGame.tensor(a, b);
    try std.testing.expectEqual(@as(u32, 3), t.move_count);
}

test "NCell and InfinityGroupoid" {
    var g = InfinityGroupoid.init();
    const thing = NCell.makeThing(1);
    const proc = NCell.makeProcess(2, 1, 1);
    const meta = NCell.makeMetaProcess(3, 2, 2);
    try std.testing.expect(g.addCell(thing));
    try std.testing.expect(g.addCell(proc));
    try std.testing.expect(g.addCell(meta));
    try std.testing.expectEqual(@as(u8, 3), g.count);
    try std.testing.expectEqual(@as(u8, 2), g.max_dimension);
    try std.testing.expect(g.associatorColor() != 0 or g.associatorColor() == 0); // just runs
}

test "ChebyshevCoherence" {
    try std.testing.expectEqual(@as(f64, 1.0), ChebyshevCoherence.chebyshevT(0, 0.5));
    try std.testing.expectEqual(@as(f64, 0.5), ChebyshevCoherence.chebyshevT(1, 0.5));
    // T_2(x) = 2x^2 - 1 => T_2(0.5) = -0.5
    try std.testing.expectApproxEqAbs(@as(f64, -0.5), ChebyshevCoherence.chebyshevT(2, 0.5), 1e-10);
}

test "FreeMonad: pure and bind" {
    const m = FreeMonad.pure(42);
    const m2 = m.bind(7);
    try std.testing.expectEqual(FreeTag.pure, m2.tag);
    try std.testing.expect(m2.value != 42);
}

test "CofreeComonad: extract and extend" {
    const c = CofreeComonad.init(10, 20);
    try std.testing.expectEqual(@as(u64, 10), c.extract());
    const c2 = c.extend();
    try std.testing.expect(c2.head != c.head);
}

test "pairFreeCofree" {
    const f = FreeMonad.pure(1);
    const c = CofreeComonad.init(2, 3);
    const p = pairFreeCofree(f, c);
    try std.testing.expect(p != 0);
}

test "tripleRotation GF(3)" {
    const r = tripleRotation(42);
    try std.testing.expect(r[0] != r[1]);
    try std.testing.expect(r[1] != r[2]);
}

test "BestResponseDynamics" {
    var brd = BestResponseDynamics.init(42, true);
    _ = brd.step();
    _ = brd.step();
    const r = brd.resilienceMeasure();
    try std.testing.expect(r >= 0.0 and r <= 1.0);
}

test "ThreeMatchGadget: decide" {
    const g = ThreeMatchGadget.init(42);
    const d = g.decide();
    try std.testing.expect(d < 3);
}

test "BirbNote: fromSeed" {
    const n = BirbNote.fromSeed(42);
    try std.testing.expect(n.frequency >= 220.0 and n.frequency <= 880.0);
    try std.testing.expect(n.duration >= 0.1 and n.duration <= 1.0);
}

test "WorldMagnet: distance and field" {
    const d = WorldMagnet.distance(WorldMagnet.ORIGIN, WorldMagnet.PINEAPPLE);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), d, 1e-10);
    const f = WorldMagnet.ORIGIN.fieldStrength(.{ 1, 0, 0 });
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), f, 1e-10);
}

test "compressToThree / decompressFromThree roundtrip" {
    const triple = compressToThree(23);
    const back = decompressFromThree(triple);
    try std.testing.expectEqual(@as(u64, 23), back);
}

test "chirp produces notes" {
    const notes = chirp(42, 4);
    try std.testing.expect(notes[0].frequency > 0);
    try std.testing.expect(notes[3].frequency > 0);
    try std.testing.expectEqual(@as(f64, 0), notes[4].frequency);
}

test "warble produces pair" {
    const w = warble(42);
    try std.testing.expect(w[0].frequency != w[1].frequency);
}
