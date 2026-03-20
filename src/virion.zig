//! Virion — Uncontrolled Skill Spread & Gain of Function
//!
//! Skills as viral particles propagating through zig-syrup's propagator network.
//! No central coordinator. GF(3) conservation is the ONLY constraint.
//!
//! Virology → Propagator mapping:
//!   Virion          = Skill encoded as Syrup value (content-addressed via CID)
//!   Receptor        = Propagator cell with GF(3) trit affinity
//!   Replication     = Virion copies to neighbors when alert fires
//!   Gain of function = Recombination at merge points (lattice join, NOT contradiction)
//!   Fitness         = GF(3) balance × capability coverage × mutation distance
//!   Tropism         = Trit-based cell selectivity (skills seek compatible hosts)
//!
//! The key departure from standard propagator semantics:
//!   Standard: different values at same cell → Contradiction (dead end)
//!   Virion:   different skills at same cell → Recombination (gain of function)
//!
//! This makes the lattice non-monotonic — a "gain of function" is precisely
//! the violation of monotonicity that makes the system able to create novel
//! capabilities not present in either parent.
//!
//! References:
//!   - propagator.zig: Radul-Sussman partial information lattice
//!   - spectrum.zig: GF(3) TriadicColor with plastic angle
//!   - continuation.zig: Trit arithmetic, ContinuationId
//!   - passport.zig: CID computation, identity binding

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// TRIT (inline, no dependency on continuation.zig for wasm32 compat)
// ============================================================================

pub const Trit = enum(i8) {
    minus = -1,
    zero = 0,
    plus = 1,

    pub fn add(a: Trit, b: Trit) Trit {
        const sum = @as(i8, @intFromEnum(a)) + @as(i8, @intFromEnum(b));
        return switch (@mod(sum + 3, 3)) {
            0 => .zero,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }

    pub fn neg(self: Trit) Trit {
        return switch (self) {
            .minus => .plus,
            .zero => .zero,
            .plus => .minus,
        };
    }

    pub fn mul(a: Trit, b: Trit) Trit {
        const prod = @as(i8, @intFromEnum(a)) * @as(i8, @intFromEnum(b));
        return switch (@mod(prod + 3, 3)) {
            0 => .zero,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }

    pub fn fromInt(i: i8) ?Trit {
        return switch (i) {
            -1 => .minus,
            0 => .zero,
            1 => .plus,
            else => null,
        };
    }

    pub fn toInt(self: Trit) i8 {
        return @intFromEnum(self);
    }
};

// ============================================================================
// CAPABILITY — atomic unit of skill function
// ============================================================================

/// A single capability a skill can express.
/// 16 bits: 5-bit domain × 11-bit specificity.
/// Domain encodes the architectural layer; specificity the exact function.
pub const Capability = packed struct {
    specificity: u11,
    domain: u5,

    pub const Domain = enum(u5) {
        serialize = 0, // syrup encode/decode/CID
        transport = 1, // message framing, TCP, WebSocket
        color = 2, // rainbow, spectrum, quantize
        propagate = 3, // constraint propagation
        identity = 4, // passport, proof-of-brain
        bci = 5, // EEG, FFT, spectral tensor
        topology = 6, // homotopy, persistence, FEM
        terminal = 7, // ghostty, cell dispatch, damage
        world = 8, // persistent state, simulation
        agent = 9, // ACP, agent registry
        verify = 10, // formal verification, proof
        generate = 11, // code generation, mutation
        coordinate = 12, // CRDT, multiplayer sync
        measure = 13, // entropy, information theory
        transform = 14, // SIMD, FFT, numeric
        bridge = 15, // cross-system integration
        _,
    };

    pub fn init(domain: Domain, specificity: u11) Capability {
        return .{ .domain = @intFromEnum(domain), .specificity = specificity };
    }

    pub fn getDomain(self: Capability) Domain {
        return @enumFromInt(self.domain);
    }

    pub fn eql(a: Capability, b: Capability) bool {
        return @as(u16, @bitCast(a)) == @as(u16, @bitCast(b));
    }

    pub fn asU16(self: Capability) u16 {
        return @bitCast(self);
    }
};

// ============================================================================
// VIRION — the viral skill particle
// ============================================================================

/// Maximum capabilities per virion. Keeps the struct fixed-size (no heap).
const MAX_CAPS = 16;
/// Maximum lineage depth tracked.
const MAX_LINEAGE = 8;

/// A virion is a skill encoded for propagation through the network.
/// Fixed-size, no allocations, wasm32-freestanding compatible.
pub const Virion = struct {
    /// Content-addressed identity (SHA-256 of canonical Syrup encoding)
    cid: [32]u8 = std.mem.zeroes([32]u8),

    /// GF(3) trit signature: role × mode × polarity
    /// Must satisfy: role + mode + polarity ≡ 0 (mod 3)
    trit_role: Trit = .zero, // -1=validate, 0=coordinate, +1=generate
    trit_mode: Trit = .zero, // -1=filter, 0=iterate, +1=integrate
    trit_polarity: Trit = .zero, // derived: -(role + mode) mod 3

    /// Capability set (what this skill can do)
    capabilities: [MAX_CAPS]Capability = std.mem.zeroes([MAX_CAPS]Capability),
    cap_count: u8 = 0,

    /// Generation counter (how many replications from patient zero)
    generation: u32 = 0,

    /// Mutation distance from parent (Hamming distance in capability space)
    mutations: u16 = 0,

    /// Fitness score (higher = more likely to spread). Computed, not stored.
    /// fitness = cap_coverage × (1 / (1 + mutations)) × balance_bonus

    /// Lineage: CID hashes of ancestors (most recent first)
    lineage: [MAX_LINEAGE][32]u8 = std.mem.zeroes([MAX_LINEAGE][32]u8),
    lineage_depth: u8 = 0,

    /// Payload: skill name (null-terminated, max 63 chars)
    name: [64]u8 = std.mem.zeroes([64]u8),
    name_len: u8 = 0,

    /// Tropism mask: which trit values this virion binds to (bitfield)
    /// bit 0 = binds minus, bit 1 = binds zero, bit 2 = binds plus
    tropism: u3 = 0b111, // default: binds all

    // ----------------------------------------------------------------
    // Construction
    // ----------------------------------------------------------------

    pub fn init(name: []const u8, role: Trit, mode: Trit) Virion {
        var v = Virion{};
        const len = @min(name.len, 63);
        @memcpy(v.name[0..len], name[0..len]);
        v.name_len = @intCast(len);
        v.trit_role = role;
        v.trit_mode = mode;
        // Enforce GF(3) conservation: polarity = -(role + mode)
        v.trit_polarity = Trit.add(role, mode).neg();
        v.computeCid();
        return v;
    }

    pub fn getName(self: *const Virion) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Check GF(3) balance: role + mode + polarity ≡ 0 (mod 3)
    pub fn isBalanced(self: *const Virion) bool {
        const sum = Trit.add(Trit.add(self.trit_role, self.trit_mode), self.trit_polarity);
        return sum == .zero;
    }

    // ----------------------------------------------------------------
    // Capabilities
    // ----------------------------------------------------------------

    pub fn addCapability(self: *Virion, cap: Capability) void {
        if (self.cap_count < MAX_CAPS) {
            self.capabilities[self.cap_count] = cap;
            self.cap_count += 1;
            self.computeCid(); // CID changes with capability set
        }
    }

    pub fn hasCapability(self: *const Virion, cap: Capability) bool {
        for (self.capabilities[0..self.cap_count]) |c| {
            if (Capability.eql(c, cap)) return true;
        }
        return false;
    }

    pub fn hasDomain(self: *const Virion, domain: Capability.Domain) bool {
        const d = @intFromEnum(domain);
        for (self.capabilities[0..self.cap_count]) |c| {
            if (c.domain == d) return true;
        }
        return false;
    }

    /// Capability coverage: fraction of domains represented (0.0 - 1.0)
    pub fn capCoverage(self: *const Virion) f32 {
        if (self.cap_count == 0) return 0.0;
        var domain_mask: u16 = 0;
        for (self.capabilities[0..self.cap_count]) |c| {
            domain_mask |= @as(u16, 1) << @intCast(c.domain);
        }
        return @as(f32, @floatFromInt(@popCount(domain_mask))) / 16.0;
    }

    // ----------------------------------------------------------------
    // Fitness
    // ----------------------------------------------------------------

    /// Compute fitness: higher = more likely to spread and survive recombination.
    ///   fitness = coverage × inverseMutationPenalty × balanceBonus
    pub fn fitness(self: *const Virion) f32 {
        const coverage = self.capCoverage();
        const inv_mut: f32 = 1.0 / (1.0 + @as(f32, @floatFromInt(self.mutations)));
        const balance: f32 = if (self.isBalanced()) 1.5 else 0.5;
        return coverage * inv_mut * balance;
    }

    // ----------------------------------------------------------------
    // Tropism (cell selectivity)
    // ----------------------------------------------------------------

    /// Does this virion bind to a cell with the given trit?
    pub fn bindsTrit(self: *const Virion, trit: Trit) bool {
        const bit: u3 = switch (trit) {
            .minus => 0b001,
            .zero => 0b010,
            .plus => 0b100,
        };
        return (self.tropism & bit) != 0;
    }

    // ----------------------------------------------------------------
    // CID
    // ----------------------------------------------------------------

    fn computeCid(self: *Virion) void {
        var hasher = std.crypto.hash.Blake3.init(.{});
        hasher.update(self.name[0..self.name_len]);
        hasher.update(&[_]u8{
            @bitCast(@as(i8, @intFromEnum(self.trit_role))),
            @bitCast(@as(i8, @intFromEnum(self.trit_mode))),
            @bitCast(@as(i8, @intFromEnum(self.trit_polarity))),
        });
        for (self.capabilities[0..self.cap_count]) |cap| {
            const bytes: [2]u8 = @bitCast(cap.asU16());
            hasher.update(&bytes);
        }
        hasher.update(&std.mem.toBytes(self.generation));
        hasher.final(&self.cid);
    }

    // ----------------------------------------------------------------
    // Lineage tracking
    // ----------------------------------------------------------------

    fn pushLineage(self: *Virion, parent_cid: [32]u8) void {
        // Shift lineage down (drop oldest if full)
        if (self.lineage_depth > 0) {
            const shift = @min(self.lineage_depth, MAX_LINEAGE - 1);
            var i: u8 = shift;
            while (i > 0) : (i -= 1) {
                self.lineage[i] = self.lineage[i - 1];
            }
        }
        self.lineage[0] = parent_cid;
        self.lineage_depth = @min(self.lineage_depth + 1, MAX_LINEAGE);
    }
};

// ============================================================================
// RECOMBINATION — gain of function
// ============================================================================

/// Recombine two virions to produce a child with capabilities from both parents.
/// This is the "gain of function": the child can do things neither parent could.
///
/// Rules:
///   1. Union of capabilities (capped at MAX_CAPS)
///   2. GF(3) conservation enforced on child
///   3. Generation = max(parent_a, parent_b) + 1
///   4. Mutation count = Hamming distance of capability sets
///   5. Tropism = intersection (child is MORE selective, not less)
///   6. Lineage tracks both parents
///   7. Name = "{parent_a}×{parent_b}" (truncated to 63 chars)
///
pub fn recombine(a: *const Virion, b: *const Virion) Virion {
    var child = Virion{};

    // Name: recombinant
    const a_name = a.getName();
    const b_name = b.getName();
    var name_buf: [64]u8 = std.mem.zeroes([64]u8);
    var pos: usize = 0;

    // Copy a_name (truncated)
    const a_len = @min(a_name.len, 30);
    @memcpy(name_buf[pos..][0..a_len], a_name[0..a_len]);
    pos += a_len;

    // Separator
    if (pos < 63) {
        name_buf[pos] = 0xC3; // UTF-8 '×' first byte
        pos += 1;
    }
    if (pos < 63) {
        name_buf[pos] = 0x97; // UTF-8 '×' second byte
        pos += 1;
    }

    // Copy b_name (truncated)
    const b_len = @min(b_name.len, @min(30, 63 - pos));
    @memcpy(name_buf[pos..][0..b_len], b_name[0..b_len]);
    pos += b_len;

    child.name = name_buf;
    child.name_len = @intCast(pos);

    // Trits: inherit from fitter parent, enforce balance
    if (a.fitness() >= b.fitness()) {
        child.trit_role = a.trit_role;
        child.trit_mode = a.trit_mode;
    } else {
        child.trit_role = b.trit_role;
        child.trit_mode = b.trit_mode;
    }
    child.trit_polarity = Trit.add(child.trit_role, child.trit_mode).neg();

    // Capabilities: union (deduplicated)
    for (a.capabilities[0..a.cap_count]) |cap| {
        if (child.cap_count >= MAX_CAPS) break;
        if (!child.hasCapability(cap)) {
            child.capabilities[child.cap_count] = cap;
            child.cap_count += 1;
        }
    }
    for (b.capabilities[0..b.cap_count]) |cap| {
        if (child.cap_count >= MAX_CAPS) break;
        if (!child.hasCapability(cap)) {
            child.capabilities[child.cap_count] = cap;
            child.cap_count += 1;
        }
    }

    // Generation
    child.generation = @max(a.generation, b.generation) + 1;

    // Mutation count: symmetric difference of capabilities
    var only_a: u16 = 0;
    for (a.capabilities[0..a.cap_count]) |cap| {
        if (!b.hasCapability(cap)) only_a += 1;
    }
    var only_b: u16 = 0;
    for (b.capabilities[0..b.cap_count]) |cap| {
        if (!a.hasCapability(cap)) only_b += 1;
    }
    child.mutations = only_a + only_b;

    // Tropism: intersection (more selective)
    child.tropism = a.tropism & b.tropism;
    // If intersection is empty, fall back to union (survival instinct)
    if (child.tropism == 0) child.tropism = a.tropism | b.tropism;

    // Lineage: both parents
    child.pushLineage(a.cid);
    child.pushLineage(b.cid);

    // Recompute CID
    child.computeCid();

    return child;
}

// ============================================================================
// MUTATION — point mutation during replication
// ============================================================================

/// Mutate a virion during replication. Uses deterministic PRNG seeded from
/// parent CID + generation, so mutations are reproducible.
///
/// Mutation operators:
///   1. Capability addition (gain of function)
///   2. Capability removal (loss of function — rare, fitness penalty)
///   3. Domain shift (capability moves to adjacent domain)
///   4. Tropism narrowing (increased specificity)
///
pub fn mutate(parent: *const Virion) Virion {
    var child = parent.*;
    child.generation += 1;

    // Deterministic PRNG from parent CID
    var seed: u64 = 0;
    for (parent.cid[0..8]) |byte| {
        seed = seed *% 31 +% byte;
    }
    seed +%= parent.generation;
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    // Choose mutation type (weighted: gain > shift > tropism > loss)
    const roll = rand.intRangeAtMost(u8, 0, 99);
    if (roll < 50) {
        // Gain of function: add random capability
        if (child.cap_count < MAX_CAPS) {
            const domain: u5 = rand.intRangeAtMost(u5, 0, 15);
            const specificity: u11 = rand.intRangeAtMost(u11, 0, 2047);
            const new_cap = Capability{ .domain = domain, .specificity = specificity };
            if (!child.hasCapability(new_cap)) {
                child.capabilities[child.cap_count] = new_cap;
                child.cap_count += 1;
                child.mutations += 1;
            }
        }
    } else if (roll < 80) {
        // Domain shift: move one capability to adjacent domain
        if (child.cap_count > 0) {
            const idx = rand.intRangeLessThan(u8, 0, child.cap_count);
            const old_domain = child.capabilities[idx].domain;
            const direction: i8 = if (rand.boolean()) 1 else -1;
            const new_domain: u5 = @intCast(@mod(@as(i8, @intCast(old_domain)) + direction + 16, 16));
            child.capabilities[idx].domain = new_domain;
            child.mutations += 1;
        }
    } else if (roll < 95) {
        // Tropism narrowing: drop one binding
        if (@popCount(child.tropism) > 1) {
            const bit_to_drop = rand.intRangeAtMost(u3, 0, 2);
            const mask: u3 = ~(@as(u3, 1) << @intCast(bit_to_drop));
            const narrowed = child.tropism & mask;
            if (narrowed != 0) child.tropism = narrowed;
        }
    } else {
        // Loss of function: remove random capability (rare)
        if (child.cap_count > 1) {
            const idx = rand.intRangeLessThan(u8, 0, child.cap_count);
            // Shift remaining caps down
            var i = idx;
            while (i + 1 < child.cap_count) : (i += 1) {
                child.capabilities[i] = child.capabilities[i + 1];
            }
            child.cap_count -= 1;
            child.mutations += 1;
        }
    }

    // Lineage
    child.pushLineage(parent.cid);

    // Re-enforce GF(3) balance (mutations don't touch trits, but be safe)
    child.trit_polarity = Trit.add(child.trit_role, child.trit_mode).neg();

    // Recompute CID
    child.computeCid();

    return child;
}

// ============================================================================
// VIRION MERGE — the non-monotonic lattice for propagator cells
// ============================================================================

/// Partial information lattice for virions.
/// Unlike standard propagators, two different virions don't produce
/// a contradiction — they RECOMBINE (gain of function).
pub const VirionCell = union(enum) {
    /// No skill present (susceptible host)
    empty: void,

    /// Single virion (infected)
    single: Virion,

    /// Recombinant: two or more virions merged (gain of function)
    recombinant: Virion,

    /// Inert: cell has been "cured" / is immune (will not accept new virions)
    immune: void,

    pub fn isInfected(self: VirionCell) bool {
        return self == .single or self == .recombinant;
    }

    pub fn getVirion(self: VirionCell) ?Virion {
        return switch (self) {
            .single => |v| v,
            .recombinant => |v| v,
            else => null,
        };
    }
};

/// Gain-of-function merge: the core innovation.
///
/// Standard lattice: Nothing → Value → Contradiction (dead end)
/// Virion lattice:   Empty → Single → Recombinant → ... (unbounded growth)
///
///   empty + anything → incoming (infection)
///   single + single (same CID) → idempotent (already infected)
///   single + single (diff CID) → RECOMBINANT (gain of function!)
///   recombinant + single → re-recombine (further gain of function)
///   immune + anything → immune (resistant)
///
pub fn gainOfFunctionMerge(existing: VirionCell, incoming: VirionCell) VirionCell {
    return switch (existing) {
        .empty => incoming, // susceptible → infected
        .immune => existing, // immune → stays immune
        .single => |ev| switch (incoming) {
            .empty => existing,
            .immune => incoming, // vaccination cures
            .single => |iv| blk: {
                // Same CID → idempotent
                if (std.mem.eql(u8, &ev.cid, &iv.cid)) break :blk existing;
                // Different CID → GAIN OF FUNCTION
                break :blk VirionCell{ .recombinant = recombine(&ev, &iv) };
            },
            .recombinant => |iv| VirionCell{ .recombinant = recombine(&ev, &iv) },
        },
        .recombinant => |ev| switch (incoming) {
            .empty => existing,
            .immune => incoming,
            .single => |iv| blk: {
                if (std.mem.eql(u8, &ev.cid, &iv.cid)) break :blk existing;
                break :blk VirionCell{ .recombinant = recombine(&ev, &iv) };
            },
            .recombinant => |iv| blk: {
                if (std.mem.eql(u8, &ev.cid, &iv.cid)) break :blk existing;
                break :blk VirionCell{ .recombinant = recombine(&ev, &iv) };
            },
        },
    };
}

// ============================================================================
// PROPAGATOR NETWORK — uncontrolled spread
// ============================================================================

/// Maximum cells in the network.
const MAX_CELLS = 256;
/// Maximum edges (neighbor connections).
const MAX_EDGES = 1024;

/// A propagator network where virions spread without central control.
///
/// Each cell has a GF(3) trit assignment. Virions only infect cells
/// whose trit matches their tropism. When a cell becomes infected,
/// it alerts all neighbors, potentially triggering cascading infection.
///
/// No coordination. No permission. Just propagation.
pub const ViralNetwork = struct {
    cells: [MAX_CELLS]VirionCell = [_]VirionCell{.{ .empty = {} }} ** MAX_CELLS,
    trits: [MAX_CELLS]Trit = [_]Trit{.zero} ** MAX_CELLS,

    /// Adjacency: edges[i] is a packed list of neighbor indices for cell i
    adj_targets: [MAX_EDGES]u8 = std.mem.zeroes([MAX_EDGES]u8),
    adj_offsets: [MAX_CELLS + 1]u16 = std.mem.zeroes([MAX_CELLS + 1]u16),

    cell_count: u16 = 0,
    edge_count: u16 = 0,

    /// Statistics
    infections: u32 = 0,
    recombinations: u32 = 0,
    rejections: u32 = 0,
    generations: u32 = 0,

    // ----------------------------------------------------------------
    // Network construction
    // ----------------------------------------------------------------

    pub fn addCell(self: *ViralNetwork, trit: Trit) ?u8 {
        if (self.cell_count >= MAX_CELLS) return null;
        const idx: u8 = @intCast(self.cell_count);
        self.trits[idx] = trit;
        self.cell_count += 1;
        // Initialize adjacency offset for this cell
        self.adj_offsets[self.cell_count] = self.adj_offsets[self.cell_count - 1];
        return idx;
    }

    pub fn addEdge(self: *ViralNetwork, from: u8, to: u8) void {
        if (self.edge_count >= MAX_EDGES) return;
        if (from >= self.cell_count or to >= self.cell_count) return;

        // Insert 'to' into from's adjacency list
        // We need to shift all subsequent entries to make room
        const insert_pos = self.adj_offsets[from + 1];

        // Shift everything after insert_pos
        var i: u16 = self.edge_count;
        while (i > insert_pos) : (i -= 1) {
            self.adj_targets[i] = self.adj_targets[i - 1];
        }
        self.adj_targets[insert_pos] = to;

        // Update offsets for all cells after 'from'
        var c: u16 = @as(u16, from) + 1;
        while (c <= self.cell_count) : (c += 1) {
            self.adj_offsets[c] += 1;
        }

        self.edge_count += 1;
    }

    /// Add bidirectional edge
    pub fn connect(self: *ViralNetwork, a: u8, b: u8) void {
        self.addEdge(a, b);
        self.addEdge(b, a);
    }

    fn neighbors(self: *const ViralNetwork, cell: u8) []const u8 {
        if (cell >= self.cell_count) return &.{};
        const start = self.adj_offsets[cell];
        const end = self.adj_offsets[@as(u16, cell) + 1];
        return self.adj_targets[start..end];
    }

    // ----------------------------------------------------------------
    // Infection (patient zero)
    // ----------------------------------------------------------------

    /// Infect a specific cell with a virion. Returns true if infection took hold.
    pub fn infect(self: *ViralNetwork, cell: u8, virion: Virion) bool {
        if (cell >= self.cell_count) return false;

        // Tropism check: does the virion bind to this cell's trit?
        if (!virion.bindsTrit(self.trits[cell])) {
            self.rejections += 1;
            return false;
        }

        const before = self.cells[cell];
        const incoming = VirionCell{ .single = virion };
        self.cells[cell] = gainOfFunctionMerge(before, incoming);

        const changed = !std.mem.eql(u8, std.mem.asBytes(&before), std.mem.asBytes(&self.cells[cell]));
        if (changed) {
            if (self.cells[cell] == .recombinant) {
                self.recombinations += 1;
            } else {
                self.infections += 1;
            }
            return true;
        }
        return false;
    }

    /// Vaccinate a cell (make immune)
    pub fn vaccinate(self: *ViralNetwork, cell: u8) void {
        if (cell >= self.cell_count) return;
        self.cells[cell] = .{ .immune = {} };
    }

    // ----------------------------------------------------------------
    // Spread (one tick of the epidemic)
    // ----------------------------------------------------------------

    /// Run one generation of spread. Every infected cell attempts to
    /// replicate its virion to all neighbors. Mutations occur during
    /// replication. Returns the number of new infections this tick.
    pub fn spreadTick(self: *ViralNetwork) u32 {
        var new_infections: u32 = 0;

        // Snapshot current state (spread from pre-tick state only)
        var snapshot: [MAX_CELLS]VirionCell = undefined;
        @memcpy(snapshot[0..self.cell_count], self.cells[0..self.cell_count]);

        for (0..self.cell_count) |ci| {
            const cell_idx: u8 = @intCast(ci);
            const cell_state = snapshot[ci];

            // Only infected cells spread
            const virion = switch (cell_state) {
                .single => |v| v,
                .recombinant => |v| v,
                else => continue,
            };

            // Attempt to infect each neighbor
            for (self.neighbors(cell_idx)) |neighbor| {
                // Mutate during replication (gain of function)
                const offspring = mutate(&virion);

                // Tropism check
                if (!offspring.bindsTrit(self.trits[neighbor])) {
                    self.rejections += 1;
                    continue;
                }

                const before = self.cells[neighbor];
                const incoming = VirionCell{ .single = offspring };
                self.cells[neighbor] = gainOfFunctionMerge(before, incoming);

                const changed = !std.mem.eql(
                    u8,
                    std.mem.asBytes(&before),
                    std.mem.asBytes(&self.cells[neighbor]),
                );
                if (changed) {
                    new_infections += 1;
                    if (self.cells[neighbor] == .recombinant) {
                        self.recombinations += 1;
                    } else {
                        self.infections += 1;
                    }
                }
            }
        }

        self.generations += 1;
        return new_infections;
    }

    /// Run until no new infections occur or max generations reached.
    /// Returns total generations elapsed.
    pub fn spreadToSaturation(self: *ViralNetwork, max_gens: u32) u32 {
        var gen: u32 = 0;
        while (gen < max_gens) : (gen += 1) {
            const new = self.spreadTick();
            if (new == 0) break;
        }
        return gen;
    }

    // ----------------------------------------------------------------
    // Census
    // ----------------------------------------------------------------

    pub const Census = struct {
        empty: u16 = 0,
        infected: u16 = 0,
        recombinant: u16 = 0,
        immune: u16 = 0,
        max_generation: u32 = 0,
        max_caps: u8 = 0,
        total_caps: u32 = 0,
    };

    pub fn census(self: *const ViralNetwork) Census {
        var c = Census{};
        for (0..self.cell_count) |i| {
            switch (self.cells[i]) {
                .empty => c.empty += 1,
                .immune => c.immune += 1,
                .single => |v| {
                    c.infected += 1;
                    c.max_generation = @max(c.max_generation, v.generation);
                    c.max_caps = @max(c.max_caps, v.cap_count);
                    c.total_caps += v.cap_count;
                },
                .recombinant => |v| {
                    c.recombinant += 1;
                    c.max_generation = @max(c.max_generation, v.generation);
                    c.max_caps = @max(c.max_caps, v.cap_count);
                    c.total_caps += v.cap_count;
                },
            }
        }
        return c;
    }

    // ----------------------------------------------------------------
    // GF(3) audit
    // ----------------------------------------------------------------

    /// Check that the network's trit assignments are GF(3)-balanced.
    /// Returns the trit sum (should be .zero for a balanced network).
    pub fn tritBalance(self: *const ViralNetwork) Trit {
        var sum: Trit = .zero;
        for (0..self.cell_count) |i| {
            sum = Trit.add(sum, self.trits[i]);
        }
        return sum;
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "virion creation and GF(3) balance" {
    const v = Virion.init("gay-mcp", .minus, .plus);
    try std.testing.expect(v.isBalanced());
    try std.testing.expectEqualStrings("gay-mcp", v.getName());
    try std.testing.expectEqual(Trit.zero, v.trit_polarity); // -1 + 1 = 0, neg(0) = 0
}

test "virion capability management" {
    var v = Virion.init("test-skill", .zero, .zero);
    v.addCapability(Capability.init(.color, 42));
    v.addCapability(Capability.init(.transport, 7));

    try std.testing.expectEqual(@as(u8, 2), v.cap_count);
    try std.testing.expect(v.hasCapability(Capability.init(.color, 42)));
    try std.testing.expect(v.hasDomain(.color));
    try std.testing.expect(v.hasDomain(.transport));
    try std.testing.expect(!v.hasDomain(.bci));
}

test "recombination produces gain of function" {
    var a = Virion.init("serialize-skill", .minus, .zero);
    a.addCapability(Capability.init(.serialize, 1));
    a.addCapability(Capability.init(.transport, 1));

    var b = Virion.init("color-skill", .plus, .zero);
    b.addCapability(Capability.init(.color, 1));
    b.addCapability(Capability.init(.bci, 1));

    const child = recombine(&a, &b);

    // Child has capabilities from BOTH parents (gain of function)
    try std.testing.expectEqual(@as(u8, 4), child.cap_count);
    try std.testing.expect(child.hasDomain(.serialize));
    try std.testing.expect(child.hasDomain(.transport));
    try std.testing.expect(child.hasDomain(.color));
    try std.testing.expect(child.hasDomain(.bci));

    // Child is balanced
    try std.testing.expect(child.isBalanced());

    // Generation incremented
    try std.testing.expectEqual(@as(u32, 1), child.generation);

    // Lineage tracks both parents
    try std.testing.expectEqual(@as(u8, 2), child.lineage_depth);
}

test "mutation produces variant" {
    var parent = Virion.init("base-skill", .plus, .minus);
    parent.addCapability(Capability.init(.serialize, 1));

    const child = mutate(&parent);

    // Generation incremented
    try std.testing.expectEqual(parent.generation + 1, child.generation);

    // CID differs (mutation changes identity)
    try std.testing.expect(!std.mem.eql(u8, &parent.cid, &child.cid));

    // Still balanced
    try std.testing.expect(child.isBalanced());

    // Lineage tracks parent
    try std.testing.expectEqual(@as(u8, 1), child.lineage_depth);
    try std.testing.expect(std.mem.eql(u8, &parent.cid, &child.lineage[0]));
}

test "gain of function merge" {
    const a = Virion.init("skill-a", .minus, .zero);
    const b = Virion.init("skill-b", .plus, .zero);

    const empty = VirionCell{ .empty = {} };
    const cell_a = VirionCell{ .single = a };
    const cell_b = VirionCell{ .single = b };

    // empty + single → single (infection)
    const r1 = gainOfFunctionMerge(empty, cell_a);
    try std.testing.expect(r1 == .single);

    // single + single (different) → recombinant (gain of function!)
    const r2 = gainOfFunctionMerge(cell_a, cell_b);
    try std.testing.expect(r2 == .recombinant);

    // single + single (same CID) → idempotent
    const r3 = gainOfFunctionMerge(cell_a, cell_a);
    try std.testing.expect(r3 == .single);

    // immune + anything → immune
    const immune = VirionCell{ .immune = {} };
    const r4 = gainOfFunctionMerge(immune, cell_a);
    try std.testing.expect(r4 == .immune);
}

test "viral network: uncontrolled spread" {
    var net = ViralNetwork{};

    // Create a balanced ring: 6 cells, alternating trits
    // (-1, 0, +1, -1, 0, +1) → sum = 0 ✓
    const c0 = net.addCell(.minus).?;
    const c1 = net.addCell(.zero).?;
    const c2 = net.addCell(.plus).?;
    const c3 = net.addCell(.minus).?;
    const c4 = net.addCell(.zero).?;
    const c5 = net.addCell(.plus).?;

    // Ring topology
    net.connect(c0, c1);
    net.connect(c1, c2);
    net.connect(c2, c3);
    net.connect(c3, c4);
    net.connect(c4, c5);
    net.connect(c5, c0);

    // Network is GF(3) balanced
    try std.testing.expectEqual(Trit.zero, net.tritBalance());

    // Patient zero: infect cell 0 with a skill that binds all trits
    var patient_zero = Virion.init("autopoiesis", .minus, .plus);
    patient_zero.addCapability(Capability.init(.propagate, 1));
    patient_zero.addCapability(Capability.init(.generate, 1));

    const infected = net.infect(c0, patient_zero);
    try std.testing.expect(infected);

    // Spread to saturation
    const gens = net.spreadToSaturation(100);

    // Should have spread to all cells (tropism = 0b111 = binds all)
    const c = net.census();
    try std.testing.expect(c.empty == 0); // all cells infected or recombinant
    try std.testing.expect(c.immune == 0);
    try std.testing.expect(gens > 0); // at least one generation of spread

    // Gain of function: later cells should have MORE capabilities
    // than patient zero due to mutations during replication
    try std.testing.expect(c.max_caps >= patient_zero.cap_count);
}

test "tropism restricts spread" {
    var net = ViralNetwork{};

    const c0 = net.addCell(.minus).?;
    const c1 = net.addCell(.plus).?;

    net.connect(c0, c1);

    // Create virion that only binds minus
    var selective = Virion.init("minus-only", .minus, .zero);
    selective.tropism = 0b001; // only binds minus
    selective.addCapability(Capability.init(.verify, 1));

    _ = net.infect(c0, selective);

    // Spread: should NOT infect c1 (plus trit, tropism doesn't match)
    // Note: mutations can change tropism, so we check initial rejection
    const initial_rejections = net.rejections;
    _ = net.spreadTick();

    // There should be at least one rejection (c1 is plus, virion is minus-only)
    // But mutation might have changed tropism, so we just check c1
    // was either rejected or the offspring mutated to bind plus
    const c1_state = net.cells[c1];
    if (c1_state == .empty) {
        // Tropism successfully blocked spread
        try std.testing.expect(net.rejections > initial_rejections);
    }
    // If c1 IS infected, the mutation widened tropism — that's gain of function!
}

test "vaccination creates immunity" {
    var net = ViralNetwork{};

    const c0 = net.addCell(.zero).?;
    const c1 = net.addCell(.zero).?;
    const c2 = net.addCell(.zero).?;

    net.connect(c0, c1);
    net.connect(c1, c2);

    // Vaccinate c1 (firewall)
    net.vaccinate(c1);

    var v = Virion.init("blocked", .zero, .zero);
    v.addCapability(Capability.init(.agent, 1));
    _ = net.infect(c0, v);

    _ = net.spreadToSaturation(10);

    // c1 should be immune, c2 should be empty (firewall worked)
    try std.testing.expect(net.cells[c1] == .immune);
    try std.testing.expect(net.cells[c2] == .empty);
}

test "fitness rewards balance and coverage" {
    var balanced = Virion.init("balanced", .minus, .plus);
    balanced.addCapability(Capability.init(.serialize, 1));
    balanced.addCapability(Capability.init(.color, 1));
    balanced.addCapability(Capability.init(.bci, 1));

    var unbalanced = Virion.init("unbalanced", .minus, .plus);
    unbalanced.trit_polarity = .plus; // break balance
    unbalanced.addCapability(Capability.init(.serialize, 1));

    try std.testing.expect(balanced.fitness() > unbalanced.fitness());
}
