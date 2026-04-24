//! SDF Chapter 7: Propagator Networks
//! Implements bidirectional constraint propagation for BCI neurofeedback.
//!
//! Enriched with partial information lattice (Nothing < Value < Contradiction)
//! per Radul & Sussman "The Art of the Propagator".

const std = @import("std");
pub const poly = @import("poly.zig");

// =============================================================================
// Partial Information Lattice
// =============================================================================

/// Three-valued lattice: Nothing < Value(T) < Contradiction
pub fn CellValue(comptime T: type) type {
    return union(enum) {
        nothing: void,
        value: T,
        contradiction: struct { a: T, b: T },

        const Self = @This();

        pub fn isNothing(self: Self) bool {
            return self == .nothing;
        }

        pub fn hasValue(self: Self) ?T {
            return switch (self) {
                .value => |v| v,
                else => null,
            };
        }

        pub fn isContradiction(self: Self) bool {
            return self == .contradiction;
        }
    };
}

/// Merge function signature: combines two CellValues according to lattice rules.
pub fn MergeFn(comptime T: type) type {
    return *const fn (CellValue(T), CellValue(T)) CellValue(T);
}

/// Default merge: overwrite semantics (backward compatible with original behavior).
/// Incoming value always wins over existing, nothing is identity.
pub fn defaultMerge(comptime T: type) MergeFn(T) {
    return struct {
        fn merge(existing: CellValue(T), incoming: CellValue(T)) CellValue(T) {
            return switch (incoming) {
                .nothing => existing,
                .value => incoming,
                .contradiction => incoming,
            };
        }
    }.merge;
}

/// Lattice merge: monotonic partial information (SDF semantics).
/// Nothing < Value < Contradiction. Same values are idempotent,
/// different values produce a contradiction.
pub fn latticeMerge(comptime T: type) MergeFn(T) {
    return struct {
        fn merge(existing: CellValue(T), incoming: CellValue(T)) CellValue(T) {
            return switch (existing) {
                .nothing => incoming,
                .contradiction => existing, // Contradiction absorbs everything
                .value => |a| switch (incoming) {
                    .nothing => existing,
                    .value => |b| if (std.meta.eql(a, b))
                        existing
                    else
                        CellValue(T){ .contradiction = .{ .a = a, .b = b } },
                    .contradiction => incoming,
                },
            };
        }
    }.merge;
}

// =============================================================================
// Cell: holds partial information, alerts neighbors on change
// =============================================================================

pub fn Cell(comptime T: type, comptime merge_fn: MergeFn(T)) type {
    return struct {
        const Self = @This();

        name: []const u8,
        content: CellValue(T) = .{ .nothing = {} },
        neighbors: std.ArrayListUnmanaged(*Propagator(T, merge_fn)),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, name: []const u8) Self {
            return Self{
                .name = name,
                .allocator = allocator,
                .neighbors = std.ArrayListUnmanaged(*Propagator(T, merge_fn)).empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.neighbors.deinit(self.allocator);
        }

        pub fn add_neighbor(self: *Self, propagator: *Propagator(T, merge_fn)) anyerror!void {
            try self.neighbors.append(self.allocator, propagator);
        }

        pub fn set_content(self: *Self, value: T) anyerror!void {
            const incoming = CellValue(T){ .value = value };
            const merged = merge_fn(self.content, incoming);

            // Alert neighbors if state changed
            if (!std.meta.eql(self.content, merged)) {
                self.content = merged;
                try self.alert_neighbors();
            }
        }

        /// Set content directly from a CellValue (for advanced usage)
        pub fn set_cell_value(self: *Self, cv: CellValue(T)) anyerror!void {
            const merged = merge_fn(self.content, cv);
            if (!std.meta.eql(self.content, merged)) {
                self.content = merged;
                try self.alert_neighbors();
            }
        }

        /// Returns the value if present, null if nothing or contradiction.
        pub fn get_content(self: *const Self) ?T {
            return self.content.hasValue();
        }

        /// Returns the full CellValue (nothing/value/contradiction).
        pub fn get_cell_value(self: *const Self) CellValue(T) {
            return self.content;
        }

        /// Coalgebra readout: the cell as a q-position in `CellValue(T)`.
        /// Same data as `get_cell_value`, named for the positions/directions split.
        pub fn readout(self: *const Self) CellValue(T) {
            return self.content;
        }

        /// Coalgebra direction: read, write value, or force contradiction.
        pub const Direction = union(enum) {
            read: void,
            write: T,
            contradict: struct { a: T, b: T },
        };

        /// Apply a direction to the cell (merging via `merge_fn`) and return
        /// the resulting position. `.read` is the identity direction.
        pub fn inject(self: *Self, direction: Direction) anyerror!CellValue(T) {
            switch (direction) {
                .read => {},
                .write => |v| try self.set_content(v),
                .contradict => |pair| try self.set_cell_value(.{ .contradiction = pair }),
            }
            return self.content;
        }

        fn alert_neighbors(self: *Self) anyerror!void {
            for (self.neighbors.items) |prop| {
                try prop.alert();
            }
        }
    };
}

/// Backward-compatible alias: Cell with overwrite semantics.
pub fn SimpleCell(comptime T: type) type {
    return Cell(T, defaultMerge(T));
}

// =============================================================================
// Propagator: computes output from inputs via function
// =============================================================================

pub fn Propagator(comptime T: type, comptime merge_fn: MergeFn(T)) type {
    return struct {
        const Self = @This();

        inputs: []const *Cell(T, merge_fn),
        outputs: []const *Cell(T, merge_fn),
        function: *const fn ([]const ?T) ?T,

        pub fn alert(self: *Self) anyerror!void {
            var args = std.ArrayListUnmanaged(?T).empty;
            const alloc = self.inputs[0].allocator;
            defer args.deinit(alloc);

            for (self.inputs) |cell| {
                try args.append(alloc, cell.get_content());
            }

            if (self.function(args.items)) |result| {
                for (self.outputs) |out_cell| {
                    try out_cell.set_content(result);
                }
            }
        }
    };
}

/// Backward-compatible alias: Propagator with overwrite semantics.
pub fn SimplePropagator(comptime T: type) type {
    return Propagator(T, defaultMerge(T));
}

// =============================================================================
// Counit ε: Nashator Equilibrium → Propagator Cell
// =============================================================================
// Closes the ∇ ⊣ δ adjunction:
//   η : Id → δ∘∇  (propagator proposes → Nashator evaluates fitness)
//   ε : ∇∘δ → Id  (Nashator survivors → re-embedded as cell content)
//
// Polymathic = ∇ (continuous gradient across domains)
// Sakana    = δ (discrete evolutionary selection)
// This counit embeds selected equilibria back into the propagator lattice.

/// An equilibrium selected by Nashator (δ operator output).
pub const NashEquilibrium = struct {
    /// Player/domain index → strategy value (NaN = eliminated)
    strategies: []const f32,
    /// Fitness score from game-theoretic evaluation (higher = survived selection)
    fitness: f32,
    /// GF(3) trit balance of the equilibrium (-1, 0, +1)
    trit_balance: i8,
};

/// Counit ε: embed a Nashator equilibrium into propagator cells.
/// Each surviving strategy becomes committed partial information.
/// Eliminated strategies (NaN) are skipped (remain as Nothing in the lattice).
/// Returns the number of cells successfully updated.
pub fn embed_equilibrium(
    comptime merge_fn: MergeFn(f32),
    cells: []const *Cell(f32, merge_fn),
    eq: NashEquilibrium,
) anyerror!usize {
    const n = @min(cells.len, eq.strategies.len);
    var embedded: usize = 0;
    for (0..n) |i| {
        const s = eq.strategies[i];
        if (std.math.isNan(s)) continue; // eliminated by δ — leave as Nothing
        try cells[i].set_content(s);
        embedded += 1;
    }
    return embedded;
}

/// Unit η: extract propagator cell contents as a strategy vector for Nashator.
/// Nothing cells become NaN (signal to δ: "needs evaluation").
/// Contradiction cells become -∞ (signal to δ: "infeasible, prune").
pub fn extract_strategies(
    comptime merge_fn: MergeFn(f32),
    cells: []const *Cell(f32, merge_fn),
    out: []f32,
) usize {
    const n = @min(cells.len, out.len);
    for (0..n) |i| {
        const cv = cells[i].get_cell_value();
        out[i] = switch (cv) {
            .nothing => std.math.nan(f32),
            .value => |v| v,
            .contradiction => -std.math.inf(f32),
        };
    }
    return n;
}

// =============================================================================
// Polynomial Functor Lift Φ_{p,q}
// =============================================================================
//
// Minimal bridge from polynomial shapes (positions + direction fibers) to
// propagator coalgebras. Given cell lattice states, we pick a q-position per
// carrier element and accumulate q-direction demand; the GF(3) residual tracks
// the shape delta between p and q.

pub const PolynomialShape = struct {
    /// Human-readable label (for logs/debugging only).
    name: []const u8,
    /// Number of positions in the polynomial functor.
    position_count: usize,
    /// Arity table: direction count for each position.
    direction_count_per_position: []const usize,

    pub fn isValid(self: PolynomialShape) bool {
        return self.position_count > 0 and
            self.direction_count_per_position.len == self.position_count;
    }

    pub fn totalDirections(self: PolynomialShape) usize {
        var total: usize = 0;
        for (self.direction_count_per_position) |n| total += n;
        return total;
    }

    pub fn directionsAt(self: PolynomialShape, position: usize) usize {
        return self.direction_count_per_position[position];
    }

    /// Borrow this shape as a `poly.Poly` view (same arity data, no copy).
    pub fn toPoly(self: PolynomialShape) poly.Poly {
        return .{ .name = self.name, .arities = self.direction_count_per_position };
    }
};

pub const PhiWitness = struct {
    /// Carrier size |X| from the propagator side.
    carrier_size: usize,
    /// Sum of direction arities across p-positions.
    p_total_directions: usize,
    /// Sum of selected q-direction arities after lifting.
    q_total_directions: usize,
    /// Signed delta q_total - p_total.
    direction_delta: i64,
    /// GF(3)-balanced residual in {-1,0,+1}.
    gf3_residual: i8,
    /// Number of Nothing lattice points seen in the carrier.
    nothing_count: usize,
    /// Number of Contradiction lattice points seen in the carrier.
    contradiction_count: usize,

    /// Surprisal-satisficing update between two Φ witnesses (prior → posterior).
    /// Returns the GF(3)-balanced trit of the posterior's direction_delta minus
    /// the prior's, saturating via `balancedTrit`. This is the algorithmically-
    /// realizable KL-derived update: a full posterior is discarded in favor of
    /// a three-valued residual that the propagator can absorb in parallel with
    /// acting on its next prediction.
    pub fn klTritUpdate(prior: PhiWitness, posterior: PhiWitness) PhiError!i8 {
        const update, const overflow = @subWithOverflow(
            posterior.direction_delta,
            prior.direction_delta,
        );
        if (overflow != 0) return error.ArithmeticOverflow;
        return balancedTrit(update);
    }

    /// Runtime invariant check used by tests and callers who want a quick
    /// sanity gate before consuming the witness downstream.
    pub fn isConsistent(self: PhiWitness) bool {
        if (self.gf3_residual < -1 or self.gf3_residual > 1) return false;
        if (balancedTrit(self.direction_delta) != self.gf3_residual) return false;
        if (self.nothing_count > self.carrier_size) return false;
        return self.contradiction_count <= (self.carrier_size - self.nothing_count);
    }
};

pub const PhiError = error{
    InvalidPolynomialShape,
    BufferTooSmall,
    ArithmeticOverflow,
};

fn hashValueToPosition(comptime T: type, value: T, position_count: usize) usize {
    var hasher = std.hash.Wyhash.init(0x69);
    hasher.update(std.mem.asBytes(&value));
    const bucket = hasher.final() % @as(u64, @intCast(position_count));
    return @intCast(bucket);
}

fn balancedTrit(delta: i64) i8 {
    const r = @mod(delta, 3);
    return switch (r) {
        0 => 0,
        1 => 1,
        2 => -1,
        else => unreachable,
    };
}

fn checkedAddUsize(a: usize, b: usize) PhiError!usize {
    const sum, const overflow = @addWithOverflow(a, b);
    if (overflow != 0) return error.ArithmeticOverflow;
    return sum;
}

fn totalDirectionsChecked(p: PolynomialShape) PhiError!usize {
    var total: usize = 0;
    for (p.direction_count_per_position) |n| {
        total = try checkedAddUsize(total, n);
    }
    return total;
}

fn toI64Exact(v: usize) PhiError!i64 {
    if (@bitSizeOf(usize) > @bitSizeOf(i64)) {
        const max_i64_as_usize: usize = @intCast(std.math.maxInt(i64));
        if (v > max_i64_as_usize) return error.ArithmeticOverflow;
    }
    return @intCast(v);
}

/// Φ_{p,q}: map propagator carrier cells into q-positions and measure the
/// resulting q-direction load against p. The caller provides out_positions as
/// scratch space; each entry is populated with the selected q-position index.
///
/// Mapping policy:
/// - Nothing        -> q position 0
/// - Contradiction  -> q last position
/// - Value(v)       -> stable hash bucket in q positions
pub fn phi_p_q(
    comptime T: type,
    comptime merge_fn: MergeFn(T),
    p: PolynomialShape,
    q: PolynomialShape,
    cells: []const *Cell(T, merge_fn),
    out_positions: []usize,
) PhiError!PhiWitness {
    if (!p.isValid() or !q.isValid()) return error.InvalidPolynomialShape;
    if (out_positions.len < cells.len) return error.BufferTooSmall;

    var q_total_directions: usize = 0;
    var nothing_count: usize = 0;
    var contradiction_count: usize = 0;

    for (cells, 0..) |cell, idx| {
        const pos: usize = switch (cell.get_cell_value()) {
            .nothing => blk: {
                nothing_count += 1;
                break :blk 0;
            },
            .contradiction => blk: {
                contradiction_count += 1;
                break :blk q.position_count - 1;
            },
            .value => |v| hashValueToPosition(T, v, q.position_count),
        };

        out_positions[idx] = pos;
        q_total_directions = try checkedAddUsize(q_total_directions, q.directionsAt(pos));
    }

    const p_total_directions = try totalDirectionsChecked(p);
    const direction_delta: i64 = try toI64Exact(q_total_directions) -
        try toI64Exact(p_total_directions);

    return PhiWitness{
        .carrier_size = cells.len,
        .p_total_directions = p_total_directions,
        .q_total_directions = q_total_directions,
        .direction_delta = direction_delta,
        .gf3_residual = balancedTrit(direction_delta),
        .nothing_count = nothing_count,
        .contradiction_count = contradiction_count,
    };
}

// =============================================================================
// Poly Module Action API (triangleleft + representable y)
// =============================================================================
//
// Thin explicit API for:
// - p triangleleft q : polynomial module action witness over coalgebras
// - y_i              : representable monomial at position i in p

pub const ModuleActionError = PhiError || error{
    InvalidRepresentablePosition,
};

/// Representable monomial y_i with a single fiber arity y^{A_i}.
pub const RepresentableY = struct {
    position: usize,
    arity: [1]usize,

    pub fn asPolynomial(self: *const RepresentableY) PolynomialShape {
        return .{
            .name = "y",
            .position_count = 1,
            .direction_count_per_position = self.arity[0..],
        };
    }
};

/// Build representable y_i from base polynomial p at position i.
pub fn representable_y(p: PolynomialShape, position: usize) ModuleActionError!RepresentableY {
    if (!p.isValid()) return error.InvalidPolynomialShape;
    if (position >= p.position_count) return error.InvalidRepresentablePosition;
    return .{
        .position = position,
        .arity = .{p.directionsAt(position)},
    };
}

pub const ModuleActionWitness = struct {
    phi: PhiWitness,
    representable_position: ?usize,
    representable_directions: ?usize,

    pub fn isBalanced(self: ModuleActionWitness) bool {
        return self.phi.gf3_residual == 0;
    }
};

/// Explicit p triangleleft q witness over a propagator carrier.
pub fn triangleleft(
    comptime T: type,
    comptime merge_fn: MergeFn(T),
    p: PolynomialShape,
    q: PolynomialShape,
    cells: []const *Cell(T, merge_fn),
    out_positions: []usize,
) ModuleActionError!ModuleActionWitness {
    const phi = try phi_p_q(T, merge_fn, p, q, cells, out_positions);
    return .{
        .phi = phi,
        .representable_position = null,
        .representable_directions = null,
    };
}

/// Specialized witness for y_i triangleleft q.
pub fn triangleleft_representable_y(
    comptime T: type,
    comptime merge_fn: MergeFn(T),
    rep: RepresentableY,
    q: PolynomialShape,
    cells: []const *Cell(T, merge_fn),
    out_positions: []usize,
) ModuleActionError!ModuleActionWitness {
    const y_poly = rep.asPolynomial();
    const phi = try phi_p_q(T, merge_fn, y_poly, q, cells, out_positions);
    return .{
        .phi = phi,
        .representable_position = rep.position,
        .representable_directions = rep.arity[0],
    };
}

// =============================================================================
// BCI Logic as Propagator Function
// =============================================================================

pub fn neurofeedback_gate(args: []const ?f32) ?f32 {
    const focus = args[0] orelse return null;
    const relax = args[1] orelse return null;
    const threshold = args[2] orelse return null;
    const social = if (args.len > 3) (args[3] orelse 0.0) else 0.0;

    // Social trit modulates threshold (positive social interaction lowers barrier to flow)
    // Ternary tower: social modulation = T2 = 1/9, relaxation gate = T1 = 1/3
    const T1: f32 = 1.0 / 3.0;
    const T2: f32 = 1.0 / 9.0;
    const effective_threshold = threshold - (social * T2);

    if (focus > effective_threshold and relax < T1) {
        return 1.0; // Trigger Action
    } else {
        return 0.0; // No Action
    }
}

// =============================================================================
// Substrate Witness Gate
// =============================================================================

/// Computational substrate identifier.
pub const Substrate = enum {
    tree_walk, // nanoclj sequential eval (fuel-bounded, no TCO)
    bytecode_vm, // nanoclj register VM (22-opcode, linear dispatch)
    inet, // nanoclj interaction net (GF(3) trit-balanced, optimal sharing)
    lokke_guile, // Lokke/Guile Scheme (proper tail calls, GMP, CPS)
};

/// Result of a four-substrate witness comparison.
/// Maps to the CellValue lattice: agreement → Value, disagreement → Contradiction.
pub const SubstrateWitness = struct {
    tree_walk_answer: bool,
    inet_answer: bool,
    lokke_answer: bool,
    both_halted: bool,
    inet_trit_balanced: bool,

    pub fn agrees(self: SubstrateWitness) bool {
        return self.tree_walk_answer == self.inet_answer and
            self.tree_walk_answer == self.lokke_answer;
    }

    /// Sequential substrates (tree-walk + lokke) agree but inet diverges.
    pub fn sequentialAgree(self: SubstrateWitness) bool {
        return self.tree_walk_answer == self.lokke_answer;
    }

    /// Count how many substrates say true.
    pub fn trueCount(self: SubstrateWitness) u8 {
        var n: u8 = 0;
        if (self.tree_walk_answer) n += 1;
        if (self.inet_answer) n += 1;
        if (self.lokke_answer) n += 1;
        return n;
    }
};

/// Witness gate: args[0] = tree-walk result (1.0=true, 0.0=false),
/// args[1] = inet result, args[2] = trit sum from EEG epoch.
/// Returns the trit sum if substrates agree, null (forcing contradiction
/// via lattice merge on the output cell) if they disagree.
pub fn witness_gate(args: []const ?f32) ?f32 {
    const tw = args[0] orelse return null;
    const inet = args[1] orelse return null;
    const trit_sum = args[2] orelse return null;

    const tw_bool = tw > 0.5;
    const inet_bool = inet > 0.5;

    if (tw_bool == inet_bool) {
        return trit_sum;
    } else {
        return null; // Substrates disagree — propagator produces nothing
    }
}

/// Classifier ill-posedness: same EEG channel, two classification methods,
/// different trit assignments. This is orthogonal to Church-Turing divergence.
/// range-based: trit = if (max-min > threshold) 1 else 0
/// stddev-based: trit = if (stddev > threshold) 1 else 0
/// On boundary channels (e.g. Ch7 at ~33k range, ~17k stddev, threshold 50k/5k),
/// these methods disagree.
pub const ClassifierWitness = struct {
    channel: u8,
    range_trit: i2, // -1, 0, +1 via range method
    stddev_trit: i2, // -1, 0, +1 via stddev method

    pub fn agrees(self: ClassifierWitness) bool {
        return self.range_trit == self.stddev_trit;
    }
};

/// Classifier gate: args[0] = range-based trit, args[1] = stddev-based trit.
/// Returns the trit if both methods agree, null on classifier divergence.
pub fn classifier_gate(args: []const ?f32) ?f32 {
    const range_trit = args[0] orelse return null;
    const std_trit = args[1] orelse return null;

    if (range_trit == std_trit) {
        return range_trit;
    } else {
        return null; // Classifier substrate divergence
    }
}

/// Epochal time witness: encodes Hickey/Fogus model where identity is a
/// succession of immutable values, and the transition function f(old)->new
/// is itself substrate-dependent. Each epoch is a value; the identity is
/// the recording session; perception is the substrate's readback.
pub const EpochalWitness = struct {
    epoch: u32,
    glimpse_start: u64, // ticks at epoch start (564,480 per sample @ 250Hz)
    trit_sum: i8, // sum of per-channel trits for this epoch
    substrate: SubstrateWitness, // four-substrate comparison
    classifier: ?ClassifierWitness, // null if classifiers agree

    /// The epoch is well-posed if all substrates and classifiers agree.
    pub fn isWellPosed(self: EpochalWitness) bool {
        if (!self.substrate.agrees()) return false;
        if (self.classifier) |c| return c.agrees();
        return true;
    }

    /// Count the number of distinct ill-posedness sources.
    pub fn illPosedCount(self: EpochalWitness) u8 {
        var n: u8 = 0;
        if (!self.substrate.agrees()) n += 1; // Church-Turing divergence
        if (self.classifier) |c| {
            if (!c.agrees()) n += 1; // Classifier divergence
        }
        return n;
    }
};

/// Epochal gate: args[0] = epoch trit sum, args[1] = substrate agreement (1/0),
/// args[2] = classifier agreement (1/0). Returns trit sum only if both agree.
pub fn epochal_gate(args: []const ?f32) ?f32 {
    const trit_sum = args[0] orelse return null;
    const substrate_ok = args[1] orelse return null;
    const classifier_ok = args[2] orelse return null;

    if (substrate_ok > 0.5 and classifier_ok > 0.5) {
        return trit_sum;
    }
    return null; // ill-posed epoch: at least one divergence source
}

// =============================================================================
// Spatial Propagator Functions
// =============================================================================

/// Adjacency gate: propagates focus influence between adjacent nodes.
/// args[0] = self focus, args[1..] = neighbor focuses.
/// Returns blended focus (80% self + 20% neighbor average).
pub fn adjacency_gate(args: []const ?f32) ?f32 {
    const self_focus = args[0] orelse return null;
    var neighbor_sum: f32 = 0;
    var neighbor_count: u32 = 0;
    for (args[1..]) |arg| {
        if (arg) |v| {
            neighbor_sum += v;
            neighbor_count += 1;
        }
    }
    if (neighbor_count == 0) return self_focus;
    const neighbor_avg = neighbor_sum / @as(f32, @floatFromInt(neighbor_count));
    // Ternary tower: self = 1 - T1 = 2/3, neighbor = T1 = 1/3
    const T1: f32 = 1.0 / 3.0;
    return self_focus * (1.0 - T1) + neighbor_avg * T1;
}

/// Focus propagator: maps focus level (0..1) to brightness multiplier.
/// Focused = 1.0, unfocused = 2/3. Ternary tower: base = 2/3, range = 1/3.
pub fn focus_brightness(args: []const ?f32) ?f32 {
    const focus_level = args[0] orelse return null;
    const T1: f32 = 1.0 / 3.0;
    return (2.0 * T1) + focus_level * T1;
}

// =============================================================================
// Tests
// =============================================================================

test "CellValue nothing" {
    const cv = CellValue(f32){ .nothing = {} };
    try std.testing.expect(cv.isNothing());
    try std.testing.expect(cv.hasValue() == null);
    try std.testing.expect(!cv.isContradiction());
}

test "PolynomialShape validates arity table" {
    const ok = PolynomialShape{
        .name = "q",
        .position_count = 3,
        .direction_count_per_position = &[_]usize{ 1, 2, 3 },
    };
    try std.testing.expect(ok.isValid());
    try std.testing.expectEqual(@as(usize, 6), ok.totalDirections());

    const bad = PolynomialShape{
        .name = "bad",
        .position_count = 2,
        .direction_count_per_position = &[_]usize{1},
    };
    try std.testing.expect(!bad.isValid());
}

test "phi_p_q maps lattice states and computes GF(3) residual" {
    const allocator = std.testing.allocator;
    const FCell = Cell(f32, latticeMerge(f32));

    var c0 = FCell.init(allocator, "c0");
    defer c0.deinit();
    var c1 = FCell.init(allocator, "c1");
    defer c1.deinit();
    var c2 = FCell.init(allocator, "c2");
    defer c2.deinit();

    try c1.set_content(0.75);
    try c2.set_cell_value(.{ .contradiction = .{ .a = 1.0, .b = 2.0 } });

    const p = PolynomialShape{
        .name = "p",
        .position_count = 2,
        .direction_count_per_position = &[_]usize{ 2, 1 },
    };
    const q = PolynomialShape{
        .name = "q",
        .position_count = 3,
        .direction_count_per_position = &[_]usize{ 1, 2, 3 },
    };

    const cells = [_]*FCell{ &c0, &c1, &c2 };
    var lifted_positions: [3]usize = undefined;
    const witness = try phi_p_q(
        f32,
        latticeMerge(f32),
        p,
        q,
        &cells,
        &lifted_positions,
    );

    try std.testing.expectEqual(@as(usize, 3), witness.carrier_size);
    try std.testing.expectEqual(@as(usize, 1), witness.nothing_count);
    try std.testing.expectEqual(@as(usize, 1), witness.contradiction_count);
    try std.testing.expectEqual(@as(usize, 0), lifted_positions[0]); // nothing -> first q-position
    try std.testing.expectEqual(@as(usize, 2), lifted_positions[2]); // contradiction -> last q-position
    try std.testing.expect(witness.gf3_residual >= -1 and witness.gf3_residual <= 1);
    try std.testing.expect(witness.isConsistent());
}

test "PhiWitness consistency check rejects malformed witnesses" {
    const good = PhiWitness{
        .carrier_size = 3,
        .p_total_directions = 5,
        .q_total_directions = 8,
        .direction_delta = 3,
        .gf3_residual = 0,
        .nothing_count = 1,
        .contradiction_count = 1,
    };
    try std.testing.expect(good.isConsistent());

    var bad_residual = good;
    bad_residual.gf3_residual = 1;
    try std.testing.expect(!bad_residual.isConsistent());

    var bad_counts = good;
    bad_counts.nothing_count = 2;
    bad_counts.contradiction_count = 2;
    try std.testing.expect(!bad_counts.isConsistent());
}

test "phi_p_q requires enough output storage" {
    const allocator = std.testing.allocator;
    const FCell = Cell(f32, defaultMerge(f32));
    var c = FCell.init(allocator, "single");
    defer c.deinit();
    try c.set_content(1.0);

    const p = PolynomialShape{
        .name = "p",
        .position_count = 1,
        .direction_count_per_position = &[_]usize{1},
    };
    const q = PolynomialShape{
        .name = "q",
        .position_count = 1,
        .direction_count_per_position = &[_]usize{1},
    };

    const cells = [_]*FCell{&c};
    var too_small: [0]usize = .{};

    try std.testing.expectError(
        error.BufferTooSmall,
        phi_p_q(
            f32,
            defaultMerge(f32),
            p,
            q,
            &cells,
            &too_small,
        ),
    );
}

test "representable_y validates index and builds y-monomial" {
    const p = PolynomialShape{
        .name = "p",
        .position_count = 3,
        .direction_count_per_position = &[_]usize{ 4, 2, 1 },
    };

    const rep = try representable_y(p, 1);
    try std.testing.expectEqual(@as(usize, 1), rep.position);
    try std.testing.expectEqual(@as(usize, 2), rep.arity[0]);

    const y_poly = rep.asPolynomial();
    try std.testing.expect(y_poly.isValid());
    try std.testing.expectEqual(@as(usize, 1), y_poly.position_count);
    try std.testing.expectEqual(@as(usize, 2), y_poly.totalDirections());

    try std.testing.expectError(error.InvalidRepresentablePosition, representable_y(p, 3));
}

test "triangleleft wraps phi_p_q witness" {
    const allocator = std.testing.allocator;
    const FCell = Cell(f32, latticeMerge(f32));

    var c0 = FCell.init(allocator, "c0");
    defer c0.deinit();
    var c1 = FCell.init(allocator, "c1");
    defer c1.deinit();
    try c1.set_content(0.2);

    const p = PolynomialShape{
        .name = "p",
        .position_count = 2,
        .direction_count_per_position = &[_]usize{ 2, 1 },
    };
    const q = PolynomialShape{
        .name = "q",
        .position_count = 2,
        .direction_count_per_position = &[_]usize{ 1, 3 },
    };

    const cells = [_]*FCell{ &c0, &c1 };
    var direct_positions: [2]usize = undefined;
    var action_positions: [2]usize = undefined;

    const direct = try phi_p_q(f32, latticeMerge(f32), p, q, &cells, &direct_positions);
    const action = try triangleleft(f32, latticeMerge(f32), p, q, &cells, &action_positions);

    try std.testing.expectEqual(direct, action.phi);
    try std.testing.expectEqual(direct_positions, action_positions);
    try std.testing.expectEqual(@as(?usize, null), action.representable_position);
    try std.testing.expectEqual(@as(?usize, null), action.representable_directions);
}

test "triangleleft_representable_y uses selected p-fiber arity" {
    const allocator = std.testing.allocator;
    const FCell = Cell(f32, latticeMerge(f32));

    var c0 = FCell.init(allocator, "c0");
    defer c0.deinit();
    var c1 = FCell.init(allocator, "c1");
    defer c1.deinit();
    try c0.set_content(0.9);

    const p = PolynomialShape{
        .name = "p",
        .position_count = 2,
        .direction_count_per_position = &[_]usize{ 5, 1 },
    };
    const rep = try representable_y(p, 0);

    const q = PolynomialShape{
        .name = "q",
        .position_count = 3,
        .direction_count_per_position = &[_]usize{ 1, 2, 3 },
    };

    const cells = [_]*FCell{ &c0, &c1 };
    var positions: [2]usize = undefined;
    const action = try triangleleft_representable_y(
        f32,
        latticeMerge(f32),
        rep,
        q,
        &cells,
        &positions,
    );

    try std.testing.expectEqual(@as(?usize, 0), action.representable_position);
    try std.testing.expectEqual(@as(?usize, 5), action.representable_directions);
    try std.testing.expectEqual(@as(usize, 5), action.phi.p_total_directions);
    try std.testing.expectEqual(@as(usize, 2), action.phi.carrier_size);
}

test "phi_p_q detects overflow in p total direction count" {
    const allocator = std.testing.allocator;
    const FCell = Cell(f32, defaultMerge(f32));

    const p = PolynomialShape{
        .name = "p_overflow",
        .position_count = 2,
        .direction_count_per_position = &[_]usize{ std.math.maxInt(usize), 1 },
    };
    const q = PolynomialShape{
        .name = "q",
        .position_count = 1,
        .direction_count_per_position = &[_]usize{1},
    };

    const cells = [_]*FCell{};
    var positions: [0]usize = .{};
    _ = allocator; // keep allocator referenced for symmetry with other tests

    try std.testing.expectError(
        error.ArithmeticOverflow,
        phi_p_q(
            f32,
            defaultMerge(f32),
            p,
            q,
            &cells,
            &positions,
        ),
    );
}

test "phi_p_q detects overflow in q direction accumulation" {
    const allocator = std.testing.allocator;
    const FCell = Cell(f32, defaultMerge(f32));

    var c0 = FCell.init(allocator, "c0");
    defer c0.deinit();
    var c1 = FCell.init(allocator, "c1");
    defer c1.deinit();

    const p = PolynomialShape{
        .name = "p",
        .position_count = 1,
        .direction_count_per_position = &[_]usize{0},
    };
    const q = PolynomialShape{
        .name = "q_overflow",
        .position_count = 1,
        .direction_count_per_position = &[_]usize{std.math.maxInt(usize)},
    };

    const cells = [_]*FCell{ &c0, &c1 }; // both Nothing => map to q position 0
    var positions: [2]usize = undefined;

    try std.testing.expectError(
        error.ArithmeticOverflow,
        phi_p_q(
            f32,
            defaultMerge(f32),
            p,
            q,
            &cells,
            &positions,
        ),
    );
}

test "phi_p_q detects overflow converting direction counts to i64" {
    if (@bitSizeOf(usize) <= @bitSizeOf(i64)) return;

    const allocator = std.testing.allocator;
    const FCell = Cell(f32, defaultMerge(f32));

    var c0 = FCell.init(allocator, "c0");
    defer c0.deinit();

    const huge: usize = @as(usize, @intCast(std.math.maxInt(i64))) + 1;

    const p = PolynomialShape{
        .name = "p",
        .position_count = 1,
        .direction_count_per_position = &[_]usize{0},
    };
    const q = PolynomialShape{
        .name = "q_i64_overflow",
        .position_count = 1,
        .direction_count_per_position = &[_]usize{huge},
    };

    const cells = [_]*FCell{&c0}; // maps to q position 0 => q_total_directions = huge
    var positions: [1]usize = undefined;

    try std.testing.expectError(
        error.ArithmeticOverflow,
        phi_p_q(
            f32,
            defaultMerge(f32),
            p,
            q,
            &cells,
            &positions,
        ),
    );
}

test "CellValue value" {
    const cv = CellValue(f32){ .value = 42.0 };
    try std.testing.expect(!cv.isNothing());
    try std.testing.expectEqual(@as(?f32, 42.0), cv.hasValue());
    try std.testing.expect(!cv.isContradiction());
}

test "CellValue contradiction" {
    const cv = CellValue(f32){ .contradiction = .{ .a = 1.0, .b = 2.0 } };
    try std.testing.expect(!cv.isNothing());
    try std.testing.expect(cv.hasValue() == null);
    try std.testing.expect(cv.isContradiction());
}

test "defaultMerge overwrite semantics" {
    const merge = defaultMerge(f32);
    const nothing = CellValue(f32){ .nothing = {} };
    const val1 = CellValue(f32){ .value = 1.0 };
    const val2 = CellValue(f32){ .value = 2.0 };

    // nothing + value = value
    try std.testing.expectEqual(val1, merge(nothing, val1));
    // value + nothing = original value
    try std.testing.expectEqual(val1, merge(val1, nothing));
    // value + different value = incoming wins
    try std.testing.expectEqual(val2, merge(val1, val2));
}

test "latticeMerge monotonic" {
    const merge = latticeMerge(f32);
    const nothing = CellValue(f32){ .nothing = {} };
    const val1 = CellValue(f32){ .value = 1.0 };
    const val2 = CellValue(f32){ .value = 2.0 };

    // nothing + value = value
    try std.testing.expectEqual(val1, merge(nothing, val1));
    // value + nothing = original value
    try std.testing.expectEqual(val1, merge(val1, nothing));
    // value + same value = idempotent
    try std.testing.expectEqual(val1, merge(val1, val1));
    // value + different value = contradiction
    const result = merge(val1, val2);
    try std.testing.expect(result.isContradiction());
}

test "latticeMerge contradiction absorbs" {
    const merge = latticeMerge(f32);
    const contradiction = CellValue(f32){ .contradiction = .{ .a = 1.0, .b = 2.0 } };
    const val3 = CellValue(f32){ .value = 3.0 };
    const nothing = CellValue(f32){ .nothing = {} };

    // contradiction + anything = contradiction
    try std.testing.expect(merge(contradiction, val3).isContradiction());
    try std.testing.expect(merge(contradiction, nothing).isContradiction());
    // anything + contradiction = contradiction
    try std.testing.expect(merge(val3, contradiction).isContradiction());
    try std.testing.expect(merge(nothing, contradiction).isContradiction());
}

test "SimpleCell backward compat" {
    const allocator = std.testing.allocator;
    var cell = SimpleCell(f32).init(allocator, "test");
    defer cell.deinit();

    try std.testing.expect(cell.get_content() == null);
    try cell.set_content(42.0);
    try std.testing.expectEqual(@as(?f32, 42.0), cell.get_content());
    // Overwrite
    try cell.set_content(99.0);
    try std.testing.expectEqual(@as(?f32, 99.0), cell.get_content());
}

test "lattice Cell detects contradiction" {
    const allocator = std.testing.allocator;
    const LCell = Cell(f32, latticeMerge(f32));
    var cell = LCell.init(allocator, "lattice_test");
    defer cell.deinit();

    try cell.set_content(1.0);
    try std.testing.expectEqual(@as(?f32, 1.0), cell.get_content());

    // Setting same value is fine
    try cell.set_content(1.0);
    try std.testing.expectEqual(@as(?f32, 1.0), cell.get_content());

    // Setting different value creates contradiction
    try cell.set_content(2.0);
    try std.testing.expect(cell.get_cell_value().isContradiction());
    try std.testing.expect(cell.get_content() == null); // contradiction returns null
}

test "neurofeedback_gate still works" {
    // Focused with low relaxation above threshold -> trigger
    const result1 = neurofeedback_gate(&.{ 0.8, 0.1, 0.5 });
    try std.testing.expectEqual(@as(?f32, 1.0), result1);

    // Below threshold -> no trigger
    const result2 = neurofeedback_gate(&.{ 0.3, 0.1, 0.5 });
    try std.testing.expectEqual(@as(?f32, 0.0), result2);

    // Null input -> null output
    const result3 = neurofeedback_gate(&.{ null, 0.1, 0.5 });
    try std.testing.expect(result3 == null);
}

test "adjacency_gate blending" {
    // Self focus 1.0, two neighbors at 0.0 -> 2/3 * 1.0 + 1/3 * 0.0 = 2/3
    const result = adjacency_gate(&.{ 1.0, 0.0, 0.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), result.?, 0.001);

    // Self focus 0.0, two neighbors at 1.0 -> 2/3 * 0.0 + 1/3 * 1.0 = 1/3
    const result2 = adjacency_gate(&.{ 0.0, 1.0, 1.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), result2.?, 0.001);

    // No neighbors
    const result3 = adjacency_gate(&.{0.5});
    try std.testing.expectEqual(@as(?f32, 0.5), result3);
}

test "focus_brightness mapping" {
    // focus=1.0 -> 2/3 + 1/3 = 1.0
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), focus_brightness(&.{1.0}).?, 0.001);
    // focus=0.0 -> 2/3 + 0 = 2/3
    try std.testing.expectApproxEqAbs(@as(f32, 2.0 / 3.0), focus_brightness(&.{0.0}).?, 0.001);
    // focus=0.5 -> 2/3 + 1/6 = 5/6
    try std.testing.expectApproxEqAbs(@as(f32, 5.0 / 6.0), focus_brightness(&.{0.5}).?, 0.001);
}

test "witness_gate substrates agree" {
    // Both say true (1.0), trit sum = 5.0 → passes through
    const result = witness_gate(&.{ 1.0, 1.0, 5.0 });
    try std.testing.expectEqual(@as(?f32, 5.0), result);
}

test "witness_gate substrates disagree" {
    // tree-walk=true, inet=false → null (Church-Turing divergence)
    const result = witness_gate(&.{ 1.0, 0.0, 5.0 });
    try std.testing.expect(result == null);
}

test "witness_gate with lattice cell contradiction" {
    const allocator = std.testing.allocator;
    const LCell = Cell(f32, latticeMerge(f32));

    // Simulate: tree-walk says trit_sum=5, inet says trit_sum=3
    var tw_cell = LCell.init(allocator, "tree_walk");
    defer tw_cell.deinit();
    var inet_cell = LCell.init(allocator, "inet");
    defer inet_cell.deinit();

    try tw_cell.set_content(5.0);
    try inet_cell.set_content(5.0);

    // Same value: no contradiction
    try std.testing.expect(!tw_cell.get_cell_value().isContradiction());

    // Different substrate answers merge to contradiction
    var merged_cell = LCell.init(allocator, "merged");
    defer merged_cell.deinit();
    try merged_cell.set_content(5.0); // tree-walk says 5
    try merged_cell.set_content(3.0); // inet says 3
    try std.testing.expect(merged_cell.get_cell_value().isContradiction());
}

test "SubstrateWitness all agree" {
    const w = SubstrateWitness{
        .tree_walk_answer = true,
        .inet_answer = true,
        .lokke_answer = true,
        .both_halted = true,
        .inet_trit_balanced = true,
    };
    try std.testing.expect(w.agrees());
    try std.testing.expect(w.sequentialAgree());
    try std.testing.expectEqual(@as(u8, 3), w.trueCount());
}

test "SubstrateWitness inet diverges" {
    const w = SubstrateWitness{
        .tree_walk_answer = true,
        .inet_answer = false,
        .lokke_answer = true,
        .both_halted = true,
        .inet_trit_balanced = true,
    };
    try std.testing.expect(!w.agrees());
    try std.testing.expect(w.sequentialAgree());
    try std.testing.expectEqual(@as(u8, 2), w.trueCount());
}

test "Substrate enum" {
    try std.testing.expect(@intFromEnum(Substrate.tree_walk) != @intFromEnum(Substrate.lokke_guile));
}

test "ClassifierWitness agrees" {
    const cw = ClassifierWitness{
        .channel = 3,
        .range_trit = 1,
        .stddev_trit = 1,
    };
    try std.testing.expect(cw.agrees());
}

test "ClassifierWitness diverges on Ch7" {
    // Real case: Ch7 E15, range=32601 -> trit=0, stddev=17077 -> trit=1
    const cw = ClassifierWitness{
        .channel = 7,
        .range_trit = 0,
        .stddev_trit = 1,
    };
    try std.testing.expect(!cw.agrees());
}

test "classifier_gate agrees" {
    const args = [_]?f32{ 1.0, 1.0 };
    const result = classifier_gate(&args);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(f32, 1.0), result.?);
}

test "classifier_gate diverges" {
    const args = [_]?f32{ 0.0, 1.0 };
    const result = classifier_gate(&args);
    try std.testing.expect(result == null);
}

test "EpochalWitness well-posed" {
    const ew = EpochalWitness{
        .epoch = 5,
        .glimpse_start = 5 * 250 * 564_480,
        .trit_sum = 5,
        .substrate = .{
            .tree_walk_answer = true,
            .inet_answer = true,
            .lokke_answer = true,
            .both_halted = true,
            .inet_trit_balanced = true,
        },
        .classifier = null, // classifiers agree (no divergence)
    };
    try std.testing.expect(ew.isWellPosed());
    try std.testing.expectEqual(@as(u8, 0), ew.illPosedCount());
}

test "EpochalWitness double ill-posed (E15)" {
    // Epoch 15: Church-Turing divergence + classifier divergence
    const ew = EpochalWitness{
        .epoch = 15,
        .glimpse_start = 15 * 250 * 564_480,
        .trit_sum = 4,
        .substrate = .{
            .tree_walk_answer = true,
            .inet_answer = false, // inet diverges
            .lokke_answer = true,
            .both_halted = true,
            .inet_trit_balanced = true,
        },
        .classifier = .{
            .channel = 7,
            .range_trit = 0, // range says clean
            .stddev_trit = 1, // stddev says flicker
        },
    };
    try std.testing.expect(!ew.isWellPosed());
    try std.testing.expectEqual(@as(u8, 2), ew.illPosedCount());
}

test "epochal_gate well-posed passes" {
    const args = [_]?f32{ 5.0, 1.0, 1.0 };
    const result = epochal_gate(&args);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(f32, 5.0), result.?);
}

test "epochal_gate ill-posed blocks" {
    // substrate disagrees
    const args1 = [_]?f32{ 5.0, 0.0, 1.0 };
    try std.testing.expect(epochal_gate(&args1) == null);
    // classifier disagrees
    const args2 = [_]?f32{ 4.0, 1.0, 0.0 };
    try std.testing.expect(epochal_gate(&args2) == null);
    // both disagree
    const args3 = [_]?f32{ 4.0, 0.0, 0.0 };
    try std.testing.expect(epochal_gate(&args3) == null);
}

// =============================================================================
// ∇ ⊣ δ Adjunction Tests (Embryogenesis: Polymathic ∇ / Sakana δ)
// =============================================================================

test "counit ε: embed equilibrium into lattice cells" {
    const allocator = std.testing.allocator;
    const LCell = Cell(f32, latticeMerge(f32));

    var c0 = LCell.init(allocator, "domain_0");
    defer c0.deinit();
    var c1 = LCell.init(allocator, "domain_1");
    defer c1.deinit();
    var c2 = LCell.init(allocator, "domain_2");
    defer c2.deinit();

    const cells = [_]*LCell{ &c0, &c1, &c2 };
    const eq = NashEquilibrium{
        .strategies = &[_]f32{ 0.7, std.math.nan(f32), 0.3 },
        .fitness = 0.95,
        .trit_balance = 0,
    };

    const embedded = try embed_equilibrium(latticeMerge(f32), &cells, eq);
    try std.testing.expectEqual(@as(usize, 2), embedded); // NaN skipped
    try std.testing.expectEqual(@as(?f32, 0.7), c0.get_content());
    try std.testing.expect(c1.get_content() == null); // was NaN → stays Nothing
    try std.testing.expectEqual(@as(?f32, 0.3), c2.get_content());
}

test "unit η: extract strategies from cells" {
    const allocator = std.testing.allocator;
    const LCell = Cell(f32, latticeMerge(f32));

    var c0 = LCell.init(allocator, "strat_0");
    defer c0.deinit();
    var c1 = LCell.init(allocator, "strat_1");
    defer c1.deinit();
    var c2 = LCell.init(allocator, "strat_2");
    defer c2.deinit();

    try c0.set_content(0.5);
    // c1 left as Nothing
    try c2.set_content(1.0);
    try c2.set_content(2.0); // contradiction

    const cells = [_]*LCell{ &c0, &c1, &c2 };
    var out: [3]f32 = undefined;
    _ = extract_strategies(latticeMerge(f32), &cells, &out);

    try std.testing.expectEqual(@as(f32, 0.5), out[0]); // value
    try std.testing.expect(std.math.isNan(out[1])); // nothing → NaN
    try std.testing.expect(std.math.isNegativeInf(out[2])); // contradiction → -∞
}

test "η then ε roundtrip preserves committed values" {
    const allocator = std.testing.allocator;
    const LCell = Cell(f32, latticeMerge(f32));

    // Phase 1: propagator proposes (∇)
    var c0 = LCell.init(allocator, "p0");
    defer c0.deinit();
    var c1 = LCell.init(allocator, "p1");
    defer c1.deinit();
    try c0.set_content(0.8);
    // c1 uncommitted

    // Phase 2: extract for Nashator (η)
    const cells = [_]*LCell{ &c0, &c1 };
    var strats: [2]f32 = undefined;
    _ = extract_strategies(latticeMerge(f32), &cells, &strats);

    // Phase 3: Nashator selects (δ) — keeps c0, commits c1 to 0.6
    strats[1] = 0.6;
    const eq = NashEquilibrium{
        .strategies = &strats,
        .fitness = 1.0,
        .trit_balance = 0,
    };

    // Phase 4: embed back (ε)
    const embedded = try embed_equilibrium(latticeMerge(f32), &cells, eq);
    try std.testing.expectEqual(@as(usize, 2), embedded);
    try std.testing.expectEqual(@as(?f32, 0.8), c0.get_content()); // unchanged (lattice merge: same value)
    try std.testing.expectEqual(@as(?f32, 0.6), c1.get_content()); // now committed
}

test "Φ witness is invariant under η;ε roundtrip on committed cells" {
    const allocator = std.testing.allocator;
    const LCell = Cell(f32, latticeMerge(f32));

    var c0 = LCell.init(allocator, "p0"); defer c0.deinit();
    var c1 = LCell.init(allocator, "p1"); defer c1.deinit();
    try c0.set_content(0.3);
    try c1.set_content(0.7);
    const cells = [_]*LCell{ &c0, &c1 };

    const p = PolynomialShape{
        .name = "p",
        .position_count = 2,
        .direction_count_per_position = &[_]usize{ 2, 1 },
    };
    const q = PolynomialShape{
        .name = "q",
        .position_count = 3,
        .direction_count_per_position = &[_]usize{ 1, 2, 3 },
    };

    var before_positions: [2]usize = undefined;
    const before = try phi_p_q(f32, latticeMerge(f32), p, q, &cells, &before_positions);

    // η extract → ε embed with identical values preserves carrier state.
    var strats: [2]f32 = undefined;
    _ = extract_strategies(latticeMerge(f32), &cells, &strats);
    const eq = NashEquilibrium{
        .strategies = &strats,
        .fitness = 0.0,
        .trit_balance = 0,
    };
    _ = try embed_equilibrium(latticeMerge(f32), &cells, eq);

    var after_positions: [2]usize = undefined;
    const after = try phi_p_q(f32, latticeMerge(f32), p, q, &cells, &after_positions);

    // Φ depends only on the lattice position of each cell, which is preserved
    // byte-for-byte by the η;ε roundtrip — so the full witness matches.
    try std.testing.expectEqual(before, after);
    try std.testing.expectEqualSlices(usize, &before_positions, &after_positions);
}

test "PhiWitness.klTritUpdate: surprisal-satisficing trit between prior and posterior" {
    // Active-inference interpretation: rather than carry a full posterior, the
    // propagator observes a GF(3)-balanced trit of the direction_delta change
    // (prior → posterior) in parallel with acting on its next prediction.
    const allocator = std.testing.allocator;
    const LCell = Cell(f32, latticeMerge(f32));

    var c0 = LCell.init(allocator, "p0"); defer c0.deinit();
    var c1 = LCell.init(allocator, "p1"); defer c1.deinit();
    try c0.set_content(0.25);
    try c1.set_content(0.75);
    const cells = [_]*LCell{ &c0, &c1 };

    const p = PolynomialShape{
        .name = "p",
        .position_count = 2,
        .direction_count_per_position = &[_]usize{ 2, 2 },
    };
    // Asymmetric q: contradiction lands at position_count-1 with arity 5, so
    // any inject that moves a cell into Contradiction shifts direction_delta.
    const q = PolynomialShape{
        .name = "q",
        .position_count = 4,
        .direction_count_per_position = &[_]usize{ 1, 1, 1, 5 },
    };

    var prior_positions: [2]usize = undefined;
    const prior = try phi_p_q(f32, latticeMerge(f32), p, q, &cells, &prior_positions);

    // Identity update: .read does not perturb the carrier, so posterior ≡ prior.
    _ = try c0.inject(.{ .read = {} });
    var same_positions: [2]usize = undefined;
    const same = try phi_p_q(f32, latticeMerge(f32), p, q, &cells, &same_positions);
    try std.testing.expectEqual(@as(i8, 0), try PhiWitness.klTritUpdate(prior, same));

    // Move c1 to a contradiction. phi_p_q routes Contradiction to q-position
    // q.position_count-1 (arity 5), strictly ≥ any Value bucket (arity 1), so
    // direction_delta must strictly increase.
    _ = try c1.inject(.{ .contradict = .{ .a = 0.75, .b = 0.5 } });
    var post_positions: [2]usize = undefined;
    const posterior = try phi_p_q(f32, latticeMerge(f32), p, q, &cells, &post_positions);

    const update = try PhiWitness.klTritUpdate(prior, posterior);
    try std.testing.expect(update >= -1 and update <= 1);
    try std.testing.expect(posterior.direction_delta > prior.direction_delta);
    try std.testing.expectEqual(
        balancedTrit(posterior.direction_delta - prior.direction_delta),
        update,
    );

    // Anti-symmetry under GF(3): reverse update negates the trit (mod 3).
    const reverse = try PhiWitness.klTritUpdate(posterior, prior);
    try std.testing.expectEqual(balancedTrit(-@as(i64, update)), reverse);
}

test "open-games: prisoner's dilemma Nash embeds via ε and Φ witnesses the fiber" {
    // Skill use: `open-games` (ERGODIC 0). Prisoner's Dilemma from the skill card —
    //   prisonersDilemma.play () = (Defect, Defect)
    // — instantiated on the propagator carrier. ε embeds the Nash strategy vector,
    // Φ_{p,q} reports the GF(3)-balanced fiber residual, η extracts it back.
    const allocator = std.testing.allocator;
    const LCell = Cell(f32, latticeMerge(f32));

    var p1 = LCell.init(allocator, "player1_strategy");
    defer p1.deinit();
    var p2 = LCell.init(allocator, "player2_strategy");
    defer p2.deinit();

    // Strategy encoding: 1.0 = Defect, 0.0 = Cooperate. Nash = (D, D).
    const nash = NashEquilibrium{
        .strategies = &[_]f32{ 1.0, 1.0 },
        .fitness = -2.0, // standard PD payoff for mutual defect
        .trit_balance = 0,
    };

    const cells = [_]*LCell{ &p1, &p2 };
    const embedded = try embed_equilibrium(latticeMerge(f32), &cells, nash);
    try std.testing.expectEqual(@as(usize, 2), embedded);

    // p = strategies polynomial: 2 players × 2 choices each.
    const p = PolynomialShape{
        .name = "pd_players",
        .position_count = 2,
        .direction_count_per_position = &[_]usize{ 2, 2 },
    };
    // q = payoff-outcome polynomial: CC, CD, DC, DD, each a single readout.
    const q = PolynomialShape{
        .name = "pd_payoffs",
        .position_count = 4,
        .direction_count_per_position = &[_]usize{ 1, 1, 1, 1 },
    };

    var out_positions: [2]usize = undefined;
    const witness = try phi_p_q(f32, latticeMerge(f32), p, q, &cells, &out_positions);

    try std.testing.expectEqual(@as(usize, 2), witness.carrier_size);
    try std.testing.expectEqual(@as(usize, 0), witness.nothing_count);
    try std.testing.expectEqual(@as(usize, 0), witness.contradiction_count);
    try std.testing.expectEqual(@as(usize, 4), witness.p_total_directions);
    // Both cells carry 1.0, so they hash to the same q-position; all q-positions
    // have arity 1 here, so q_total = 2 regardless of which bucket.
    try std.testing.expectEqual(@as(usize, 2), witness.q_total_directions);
    try std.testing.expectEqual(@as(i64, -2), witness.direction_delta);
    // balancedTrit(-2): @mod(-2,3) = 1 → +1. Residual captures "q fiber underweight vs p choice."
    try std.testing.expectEqual(@as(i8, 1), witness.gf3_residual);
    try std.testing.expectEqual(out_positions[0], out_positions[1]); // identical strategies → same fiber

    // η roundtrip: Nash strategies survive the trip through the carrier.
    var strats: [2]f32 = undefined;
    _ = extract_strategies(latticeMerge(f32), &cells, &strats);
    try std.testing.expectEqual(@as(f32, 1.0), strats[0]);
    try std.testing.expectEqual(@as(f32, 1.0), strats[1]);

    // Witness integrity gate.
    try std.testing.expect(witness.isConsistent());
}

test "open-games: Φ fiber assignment is deterministic per strategy profile" {
    // Follow-up to PD-Nash test. Invariant: same strategy value → same q-bucket under
    // phi_p_q's Wyhash mapping, so the fiber class of a profile is well-defined.
    // Profiles with different values MAY also land in different fibers (separating
    // non-Nash from Nash), but that depends on Wyhash's bucket distribution and is
    // not asserted here; only the deterministic same-value-same-fiber invariant is.
    const allocator = std.testing.allocator;
    const LCell = Cell(f32, latticeMerge(f32));

    const p = PolynomialShape{
        .name = "pd_players",
        .position_count = 2,
        .direction_count_per_position = &[_]usize{ 2, 2 },
    };
    const q = PolynomialShape{
        .name = "pd_payoffs_weighted",
        .position_count = 4,
        .direction_count_per_position = &[_]usize{ 1, 2, 3, 4 },
    };

    // (D, D) — Nash.
    var d1 = LCell.init(allocator, "dd_p1");
    defer d1.deinit();
    var d2 = LCell.init(allocator, "dd_p2");
    defer d2.deinit();
    try d1.set_content(1.0);
    try d2.set_content(1.0);
    const dd_cells = [_]*LCell{ &d1, &d2 };
    var dd_pos: [2]usize = undefined;
    const dd = try phi_p_q(f32, latticeMerge(f32), p, q, &dd_cells, &dd_pos);

    // (C, C) — dominated profile.
    var c1 = LCell.init(allocator, "cc_p1");
    defer c1.deinit();
    var c2 = LCell.init(allocator, "cc_p2");
    defer c2.deinit();
    try c1.set_content(0.0);
    try c2.set_content(0.0);
    const cc_cells = [_]*LCell{ &c1, &c2 };
    var cc_pos: [2]usize = undefined;
    const cc = try phi_p_q(f32, latticeMerge(f32), p, q, &cc_cells, &cc_pos);

    // Well-defined fibers: identical values land in identical buckets.
    try std.testing.expectEqual(dd_pos[0], dd_pos[1]);
    try std.testing.expectEqual(cc_pos[0], cc_pos[1]);
    // q_total is determined entirely by the chosen fiber's arity.
    try std.testing.expectEqual(@as(usize, 2) * q.directionsAt(dd_pos[0]), dd.q_total_directions);
    try std.testing.expectEqual(@as(usize, 2) * q.directionsAt(cc_pos[0]), cc.q_total_directions);
    // Both witnesses pass the integrity gate.
    try std.testing.expect(dd.isConsistent());
    try std.testing.expect(cc.isConsistent());
}

test "Cell inject(.contradict) propagates contradiction through network" {
    const allocator = std.testing.allocator;
    const LCell = Cell(f32, latticeMerge(f32));

    var a = LCell.init(allocator, "a"); defer a.deinit();
    var b = LCell.init(allocator, "b"); defer b.deinit();
    var c = LCell.init(allocator, "c"); defer c.deinit();

    try a.set_content(1.0);
    try b.set_content(2.0);

    const inputs = [_]*LCell{ &a, &b };
    const outputs = [_]*LCell{&c};
    var prop = Propagator(f32, latticeMerge(f32)){
        .inputs = &inputs,
        .outputs = &outputs,
        .function = adderFn,
    };
    try a.add_neighbor(&prop);
    try b.add_neighbor(&prop);

    try prop.alert();
    try std.testing.expectEqual(@as(?f32, 3.0), c.readout().hasValue());

    // Injecting a contradiction on a lattice cell absorbs to Contradiction
    // (top of the lattice). adderFn sees `null` for a.get_content() and the
    // output stays at its previously-latched value — but a itself is now top.
    _ = try a.inject(.{ .contradict = .{ .a = 1.0, .b = 9.0 } });
    try std.testing.expect(a.readout().isContradiction());
    // c retains its last good sum; latticeMerge does not forget.
    try std.testing.expectEqual(@as(?f32, 3.0), c.readout().hasValue());

    // Φ witness over the network reports the contradiction:
    // - a → q last position (contradiction bucket)
    // - b, c → hashed value buckets
    const p = PolynomialShape{
        .name = "network",
        .position_count = 3,
        .direction_count_per_position = &[_]usize{ 1, 1, 1 },
    };
    const q = PolynomialShape{
        .name = "lattice_state",
        .position_count = 3,
        .direction_count_per_position = &[_]usize{ 0, 1, 2 },
    };
    const cells = [_]*LCell{ &a, &b, &c };
    var positions: [3]usize = undefined;
    const w = try phi_p_q(f32, latticeMerge(f32), p, q, &cells, &positions);
    try std.testing.expectEqual(@as(usize, 1), w.contradiction_count);
    try std.testing.expect(w.isConsistent());
}

test "Cell inject drives propagator network via neighbor alert" {
    const allocator = std.testing.allocator;
    const LCell = Cell(f32, latticeMerge(f32));

    var a = LCell.init(allocator, "a"); defer a.deinit();
    var b = LCell.init(allocator, "b"); defer b.deinit();
    var c = LCell.init(allocator, "c"); defer c.deinit();

    const inputs = [_]*LCell{ &a, &b };
    const outputs = [_]*LCell{&c};
    var prop = Propagator(f32, latticeMerge(f32)){
        .inputs = &inputs,
        .outputs = &outputs,
        .function = adderFn,
    };

    try a.add_neighbor(&prop);
    try b.add_neighbor(&prop);

    // inject(.write) on an input fires alert_neighbors → propagator recomputes.
    // First write alone leaves c at Nothing (b still nothing, sum undefined).
    _ = try a.inject(.{ .write = 4.0 });
    try std.testing.expect(c.readout().isNothing());

    // Second write completes the inputs; propagator produces the sum.
    _ = try b.inject(.{ .write = 6.0 });
    try std.testing.expectEqual(@as(?f32, 10.0), c.readout().hasValue());
}

fn adderFn(args: []const ?f32) ?f32 {
    if (args.len < 2) return null;
    const a = args[0] orelse return null;
    const b = args[1] orelse return null;
    return a + b;
}

test "adder propagator as p_a (x) p_b (x) p_c: shape total = product of component totals" {
    const allocator = std.testing.allocator;
    const LCell = Cell(f32, latticeMerge(f32));

    // Component shapes: each input/output cell has one position with one direction
    // (read-once per cycle). Trivially, p_total = 1 for each component.
    const p_a = PolynomialShape{ .name = "a", .position_count = 1, .direction_count_per_position = &[_]usize{1} };
    const p_b = PolynomialShape{ .name = "b", .position_count = 1, .direction_count_per_position = &[_]usize{1} };
    const p_c = PolynomialShape{ .name = "c", .position_count = 1, .direction_count_per_position = &[_]usize{1} };

    // Composite via Dirichlet tensor: p_a (x) p_b (x) p_c.
    var ab = try poly.tensor(allocator, p_a.toPoly(), p_b.toPoly());
    defer ab.deinit();
    var abc = try poly.tensor(allocator, ab.asPoly(), p_c.toPoly());
    defer abc.deinit();

    // Distribution law for Dirichlet: total_dir(p (x) q) = total_dir(p) * total_dir(q).
    var abc_total: usize = 0;
    for (abc.arities) |a| abc_total += a;
    try std.testing.expectEqual(
        p_a.totalDirections() * p_b.totalDirections() * p_c.totalDirections(),
        abc_total,
    );
    try std.testing.expectEqual(
        p_a.position_count * p_b.position_count * p_c.position_count,
        abc.arities.len,
    );

    // Build the adder propagator and fire it.
    var a_cell = LCell.init(allocator, "a"); defer a_cell.deinit();
    var b_cell = LCell.init(allocator, "b"); defer b_cell.deinit();
    var c_cell = LCell.init(allocator, "c"); defer c_cell.deinit();

    try a_cell.set_content(2.0);
    try b_cell.set_content(3.0);

    const inputs = [_]*LCell{ &a_cell, &b_cell };
    const outputs = [_]*LCell{&c_cell};
    var prop = Propagator(f32, latticeMerge(f32)){
        .inputs = &inputs,
        .outputs = &outputs,
        .function = adderFn,
    };
    try prop.alert();
    try std.testing.expectEqual(@as(?f32, 5.0), c_cell.readout().hasValue());

    // Shape-level Φ witness: map all three cells through phi into a q-shape.
    // q is a single-position, single-direction target — the "sum fiber". Every
    // carrier lands in q-position 0 with arity 1, so q_total = 3.
    const q = PolynomialShape{
        .name = "sum_fiber",
        .position_count = 1,
        .direction_count_per_position = &[_]usize{1},
    };
    const cells = [_]*LCell{ &a_cell, &b_cell, &c_cell };

    // Witness over the composite: p_total = total_directions(p_a (x) p_b (x) p_c) = 1.
    const p_composite = PolynomialShape{
        .name = "abc",
        .position_count = abc.arities.len,
        .direction_count_per_position = abc.arities,
    };
    var composite_positions: [3]usize = undefined;
    const composite_witness = try phi_p_q(
        f32,
        latticeMerge(f32),
        p_composite,
        q,
        &cells,
        &composite_positions,
    );
    try std.testing.expectEqual(@as(usize, 1), composite_witness.p_total_directions);
    try std.testing.expectEqual(@as(usize, 3), composite_witness.q_total_directions);
    try std.testing.expectEqual(@as(i64, 2), composite_witness.direction_delta);
    // balancedTrit(2) = -1 (since 2 mod 3 = 2 -> -1).
    try std.testing.expectEqual(@as(i8, -1), composite_witness.gf3_residual);
    try std.testing.expect(composite_witness.isConsistent());

    // Witness over a single component (a alone vs the sum fiber) for comparison.
    const a_only = [_]*LCell{&a_cell};
    var a_pos: [1]usize = undefined;
    const a_witness = try phi_p_q(f32, latticeMerge(f32), p_a, q, &a_only, &a_pos);
    try std.testing.expectEqual(@as(usize, 1), a_witness.p_total_directions);
    try std.testing.expectEqual(@as(usize, 1), a_witness.q_total_directions);
    try std.testing.expectEqual(@as(i8, 0), a_witness.gf3_residual);
    try std.testing.expect(a_witness.isConsistent());
}

test "Cell coalgebra: readout + inject name positions/directions" {
    const allocator = std.testing.allocator;
    const LCell = Cell(f32, latticeMerge(f32));

    var cell = LCell.init(allocator, "coalg_demo");
    defer cell.deinit();

    // position starts at Nothing.
    try std.testing.expect(cell.readout().isNothing());

    // .read is the identity direction.
    const after_read = try cell.inject(.{ .read = {} });
    try std.testing.expect(after_read.isNothing());

    // .write advances to Value.
    const after_write = try cell.inject(.{ .write = 3.5 });
    try std.testing.expectEqual(@as(?f32, 3.5), after_write.hasValue());
    try std.testing.expectEqual(@as(?f32, 3.5), cell.readout().hasValue());

    // .contradict advances to Contradiction (lattice top).
    const after_contra = try cell.inject(.{ .contradict = .{ .a = 3.5, .b = 7.0 } });
    try std.testing.expect(after_contra.isContradiction());
}

test "PolynomialShape.toPoly bridges shape-level compose and tensor" {
    const allocator = std.testing.allocator;

    const p = PolynomialShape{
        .name = "p",
        .position_count = 1,
        .direction_count_per_position = &[_]usize{2},
    };
    const q = PolynomialShape{
        .name = "q",
        .position_count = 2,
        .direction_count_per_position = &[_]usize{ 1, 3 },
    };

    const p_poly = p.toPoly();
    const q_poly = q.toPoly();
    try std.testing.expectEqualSlices(usize, p.direction_count_per_position, p_poly.arities);
    try std.testing.expectEqualSlices(usize, q.direction_count_per_position, q_poly.arities);

    // p ◁ q: single p-position of arity 2 over |q|=2 → 4 composed positions.
    var composed = try poly.compose(allocator, p_poly, q_poly);
    defer composed.deinit();
    try std.testing.expectEqualSlices(usize, &[_]usize{ 2, 4, 4, 6 }, composed.arities);

    // p ⊗ q: 1×2 positions, arities p_a × q_a.
    var tensored = try poly.tensor(allocator, p_poly, q_poly);
    defer tensored.deinit();
    try std.testing.expectEqualSlices(usize, &[_]usize{ 2, 6 }, tensored.arities);

    // p ⊗ y ≅ p at the shape level.
    var p_tensor_y = try poly.tensor(allocator, p_poly, poly.y);
    defer p_tensor_y.deinit();
    try std.testing.expect(poly.Poly.eql(p_tensor_y.asPoly(), p_poly));
}
