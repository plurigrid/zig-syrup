//! Structured Decompositions — Tree Decompositions over FinSet
//!
//! Port of the core construction from AlgebraicJulia/StructuredDecompositions.jl.
//!
//! A StructuredDecomposition is a diagram (functor) from a tree graph
//! into a category (here, FinSet). Each vertex (bag) maps to a FinSet,
//! each edge (adhesion) maps to a cospan of FinFunctions:
//!
//!     bag_i  <--left--  adhesion_e  --right-->  bag_j
//!
//! The 𝐃 functor lifts any functor F: C -> FinSet to structured decompositions.
//! adhesion_filter refines solutions by pullback = set intersection.
//!
//! Integration with zig-syrup:
//!   - Bags and adhesions serialize as Syrup records
//!   - GF(3) conservation from splitmix_trit applies to trit-valued bags
//!   - Propagator lattice (CellValue) models partial information per bag
//!
//! The sheaf condition: for each adhesion e between bags i, j,
//! the elements of bag_i and bag_j must agree on the adhesion.
//! adhesion_filter enforces this via pullback.

const std = @import("std");
const Allocator = std.mem.Allocator;
const finset = @import("finset");
const FinSet = finset.FinSet;
const FinFunction = finset.FinFunction;

/// Edge in the decomposition tree: connects two bags via an adhesion.
pub const Edge = struct {
    left_bag: u32,
    right_bag: u32,
};

/// A cospan in FinSet: bag_left <--left-- adhesion --right--> bag_right
pub const Cospan = struct {
    left: FinFunction,
    right: FinFunction,

    pub fn deinit(self: Cospan, allocator: Allocator) void {
        self.left.deinit(allocator);
        self.right.deinit(allocator);
    }
};

pub const DecompType = enum {
    decomposition, // spans: adhesion -> bags (presheaf direction)
    co_decomposition, // cospans: bags -> adhesion (sheaf direction)
};

/// A structured decomposition valued in FinSet.
///
/// For CoDecomposition (the form used by adhesion_filter):
///   bags[i] = FinSet of solutions at bag i
///   cospans[e] = (left: bags[i] -> adhesion, right: bags[j] -> adhesion)
///
/// The sheaf condition requires: for each adhesion, the restriction
/// of bag_i's solutions to the adhesion equals bag_j's.
pub const StrDecomp = struct {
    num_bags: u32,
    num_edges: u32,
    bags: []FinSet,
    edges: []Edge,
    cospans: []Cospan,
    decomp_type: DecompType,
    allocator: Allocator,

    pub fn init(
        allocator: Allocator,
        num_bags: u32,
        edges: []const Edge,
        bag_sizes: []const u32,
        decomp_type: DecompType,
    ) !StrDecomp {
        const bags = try allocator.alloc(FinSet, num_bags);
        for (bag_sizes, 0..) |sz, i| bags[i] = FinSet.init(sz);

        const owned_edges = try allocator.alloc(Edge, edges.len);
        @memcpy(owned_edges, edges);

        const cospans = try allocator.alloc(Cospan, edges.len);
        // Initialize cospans to empty — caller must fill via setCospanMaps
        for (cospans) |*c| {
            c.left = FinFunction.init(0, 0, &.{});
            c.right = FinFunction.init(0, 0, &.{});
        }

        return .{
            .num_bags = num_bags,
            .num_edges = @intCast(edges.len),
            .bags = bags,
            .edges = owned_edges,
            .cospans = cospans,
            .decomp_type = decomp_type,
            .allocator = allocator,
        };
    }

    /// Set the cospan maps for edge e.
    /// For CoDecomposition: left maps bag[left_bag] -> adhesion, etc.
    pub fn setCospan(self: *StrDecomp, edge_idx: u32, left: FinFunction, right: FinFunction) void {
        self.cospans[edge_idx] = .{ .left = left, .right = right };
    }

    /// Check if any bag is empty (no solution).
    pub fn hasEmptyBag(self: *const StrDecomp) bool {
        for (self.bags) |bag| {
            if (bag.isEmpty()) return true;
        }
        return false;
    }

    /// Total solution space size (sum of all bag cardinalities).
    pub fn totalSize(self: *const StrDecomp) u64 {
        var total: u64 = 0;
        for (self.bags) |bag| total += bag.size;
        return total;
    }

    pub fn deinit(self: *StrDecomp) void {
        for (self.cospans) |*c| {
            if (c.left.map.len > 0) c.left.deinit(self.allocator);
            if (c.right.map.len > 0) c.right.deinit(self.allocator);
        }
        self.allocator.free(self.cospans);
        self.allocator.free(self.edges);
        self.allocator.free(self.bags);
    }
};

/// Apply adhesion_filter to edge `edge_idx` of a CoDecomposition.
///
/// This is the core refinement step from StructuredDecompositions.jl:
///   1. Fetch the cospan: bag_i --left--> adhesion <--right-- bag_j
///   2. Compute pullback P = {(x,y) | left(x) = right(y)}
///   3. Take images of pullback legs to get filtered subsets
///   4. Replace bag_i and bag_j with these filtered subsets
///   5. Update cospan maps accordingly
///
/// Returns true if any refinement occurred (bags shrank).
pub fn adhesionFilter(d: *StrDecomp, edge_idx: u32) !bool {
    std.debug.assert(d.decomp_type == .co_decomposition);
    std.debug.assert(edge_idx < d.num_edges);

    const allocator = d.allocator;
    const csp = d.cospans[edge_idx];
    const edge = d.edges[edge_idx];

    const old_left_size = d.bags[edge.left_bag].size;
    const old_right_size = d.bags[edge.right_bag].size;

    // Step 1: Compute pullback
    const pb = try finset.pullback(allocator, csp.left, csp.right);
    defer pb.deinit(allocator);

    if (pb.apex.size == 0) {
        // No consistent pairs — both bags become empty
        d.bags[edge.left_bag] = FinSet.init(0);
        d.bags[edge.right_bag] = FinSet.init(0);
        // Replace cospans with empty maps
        if (csp.left.map.len > 0) d.cospans[edge_idx].left.deinit(allocator);
        if (csp.right.map.len > 0) d.cospans[edge_idx].right.deinit(allocator);
        const empty_map = try allocator.alloc(u32, 0);
        d.cospans[edge_idx].left = FinFunction.init(0, 0, empty_map);
        const empty_map2 = try allocator.alloc(u32, 0);
        d.cospans[edge_idx].right = FinFunction.init(0, 0, empty_map2);
        return true;
    }

    // Step 2: Image of each pullback leg
    const img_left = try finset.image(allocator, pb.leg1);
    defer img_left.deinit(allocator);
    const img_right = try finset.image(allocator, pb.leg2);
    defer img_right.deinit(allocator);

    // Step 3: Compose image embeddings with original cospan maps
    // new_left = csp.left ∘ iota_left : im(pi1) -> adhesion
    // new_right = csp.right ∘ iota_right : im(pi2) -> adhesion
    const new_left = try finset.compose(allocator, img_left.iota, csp.left);
    const new_right = try finset.compose(allocator, img_right.iota, csp.right);

    // Step 4: Replace bags and cospans
    d.bags[edge.left_bag] = img_left.image_set;
    d.bags[edge.right_bag] = img_right.image_set;

    // Free old cospan maps
    if (csp.left.map.len > 0) @constCast(&d.cospans[edge_idx].left).deinit(allocator);
    if (csp.right.map.len > 0) @constCast(&d.cospans[edge_idx].right).deinit(allocator);

    d.cospans[edge_idx] = .{ .left = new_left, .right = new_right };

    return (img_left.image_set.size < old_left_size) or
        (img_right.image_set.size < old_right_size);
}

/// Run adhesion_filter on all edges until convergence.
/// Returns false if any bag becomes empty (no global solution exists).
///
/// This is decide_sheaf_tree_shape from StructuredDecompositions.jl:
/// iterate adhesion_filter until no bag changes, then check for empty bags.
pub fn decideSheaf(d: *StrDecomp) !bool {
    var changed = true;
    while (changed) {
        changed = false;
        for (0..d.num_edges) |e| {
            if (d.hasEmptyBag()) return false;
            const refined = try adhesionFilter(d, @intCast(e));
            if (refined) changed = true;
        }
    }
    return !d.hasEmptyBag();
}

/// The 𝐃 functor: lift ob_map and hom_map to a structured decomposition.
///
/// Given d: a decomposition with bags valued in category C,
/// and F: C -> FinSet (given as ob_map on objects, hom_map on morphisms),
/// produce a new decomposition with bags valued in FinSet.
///
/// ob_map: fn(bag_index: u32) -> FinSet
/// hom_map: fn(edge_index: u32, side: enum{left,right}) -> FinFunction
pub fn liftFunctor(
    allocator: Allocator,
    num_bags: u32,
    edges: []const Edge,
    ob_map: *const fn (u32) FinSet,
    hom_map: *const fn (u32, enum { left, right }) FinFunction,
) !StrDecomp {
    const bags = try allocator.alloc(FinSet, num_bags);
    for (0..num_bags) |i| bags[i] = ob_map(@intCast(i));

    const owned_edges = try allocator.alloc(Edge, edges.len);
    @memcpy(owned_edges, edges);

    const cospans = try allocator.alloc(Cospan, edges.len);
    for (edges, 0..) |_, e| {
        cospans[e] = .{
            .left = hom_map(@intCast(e), .left),
            .right = hom_map(@intCast(e), .right),
        };
    }

    return .{
        .num_bags = num_bags,
        .num_edges = @intCast(edges.len),
        .bags = bags,
        .edges = owned_edges,
        .cospans = cospans,
        .decomp_type = .co_decomposition,
        .allocator = allocator,
    };
}

// ============================================================================
// Parallel Adhesion: Color the Dependency Graph
// ============================================================================
//
// Two adhesion filters are independent iff they touch disjoint bags.
// Build the adhesion dependency graph (edges that share a bag are adjacent),
// then color it greedily. The chromatic number determines barrier count.
// Same-color adhesions run in parallel within one barrier.
//
// For sparse decompositions (real-world), chi grows logarithmically
// while |adhesions| grows linearly => nearly embarrassing parallelism.
//
// The self-referential structure: this IS a graph coloring problem --
// the same adhesion_filter applied at the meta-level. Sheaves all the way down.

/// Adhesion dependency graph coloring result.
pub const AdhesionColoring = struct {
    /// color[e] = barrier group for adhesion e (0-indexed)
    colors: []u32,
    /// Number of barriers (= chromatic number of dependency graph)
    num_barriers: u32,
    allocator: Allocator,

    pub fn deinit(self: *AdhesionColoring) void {
        self.allocator.free(self.colors);
    }

    /// Get all adhesion indices assigned to barrier `b`.
    pub fn barrier(self: *const AdhesionColoring, b: u32, out: []u32) u32 {
        var count: u32 = 0;
        for (self.colors, 0..) |c, e| {
            if (c == b) {
                if (count < out.len) out[count] = @intCast(e);
                count += 1;
            }
        }
        return count;
    }
};

/// Build the adjacency structure of the adhesion dependency graph and
/// greedily color it. Two adhesions are adjacent iff they share a bag.
pub fn colorAdhesionGraph(d: *const StrDecomp, allocator: Allocator) !AdhesionColoring {
    const n = d.num_edges;
    if (n == 0) {
        const colors = try allocator.alloc(u32, 0);
        return .{ .colors = colors, .num_barriers = 0, .allocator = allocator };
    }

    // Build adjacency: adhesions e1, e2 conflict iff they share a bag
    const adj = try allocator.alloc(bool, n * n);
    defer allocator.free(adj);
    @memset(adj, false);

    for (0..n) |i| {
        const ei = d.edges[i];
        for (i + 1..n) |j| {
            const ej = d.edges[j];
            if (ei.left_bag == ej.left_bag or ei.left_bag == ej.right_bag or
                ei.right_bag == ej.left_bag or ei.right_bag == ej.right_bag)
            {
                adj[i * n + j] = true;
                adj[j * n + i] = true;
            }
        }
    }

    // Greedy coloring (Welsh-Powell: process by descending degree)
    const colors = try allocator.alloc(u32, n);
    @memset(colors, std.math.maxInt(u32)); // uncolored sentinel

    var max_color: u32 = 0;
    for (0..n) |i| {
        // Find smallest color not used by any neighbor
        var used: [64]bool = @splat(false); // up to 64 colors (enough for any real decomposition)
        for (0..n) |j| {
            if (adj[i * n + j] and colors[j] < 64) {
                used[colors[j]] = true;
            }
        }
        var c: u32 = 0;
        while (c < 64 and used[c]) c += 1;
        colors[i] = c;
        if (c + 1 > max_color) max_color = c + 1;
    }

    return .{ .colors = colors, .num_barriers = max_color, .allocator = allocator };
}

/// Parallel decideSheaf: color the adhesion dependency graph, then
/// run adhesion filters in barrier-parallel order.
/// Within each barrier, all adhesion filters touch disjoint bags
/// and can run concurrently (or in any order with no data races).
pub fn decideSheafParallel(d: *StrDecomp) !bool {
    var coloring = try colorAdhesionGraph(d, d.allocator);
    defer coloring.deinit();

    var changed = true;
    while (changed) {
        changed = false;
        // Process barriers in order
        for (0..coloring.num_barriers) |b| {
            // All adhesions in this barrier are independent — disjoint bags
            var barrier_buf: [256]u32 = undefined;
            const count = coloring.barrier(@intCast(b), &barrier_buf);
            for (0..count) |k| {
                if (d.hasEmptyBag()) return false;
                const refined = try adhesionFilter(d, barrier_buf[k]);
                if (refined) changed = true;
            }
        }
    }
    return !d.hasEmptyBag();
}

// ============================================================================
// Syrup Serialization
// ============================================================================

const syrup = @import("syrup");

pub fn toSyrup(d: *const StrDecomp, allocator: Allocator) !syrup.Value {
    const label = try allocator.create(syrup.Value);
    label.* = .{ .symbol = "str-decomp" };

    // Bags as list of finsets
    const bag_vals = try allocator.alloc(syrup.Value, d.num_bags);
    for (0..d.num_bags) |i| {
        bag_vals[i] = try finset.finsetToSyrup(d.bags[i], allocator);
    }

    // Edges as list of [left, right] pairs
    const edge_vals = try allocator.alloc(syrup.Value, d.num_edges);
    for (0..d.num_edges) |e| {
        const pair = try allocator.alloc(syrup.Value, 2);
        pair[0] = .{ .integer = @intCast(d.edges[e].left_bag) };
        pair[1] = .{ .integer = @intCast(d.edges[e].right_bag) };
        edge_vals[e] = .{ .list = pair };
    }

    const fields = try allocator.alloc(syrup.Value, 3);
    fields[0] = .{ .list = bag_vals };
    fields[1] = .{ .list = edge_vals };
    fields[2] = .{ .symbol = if (d.decomp_type == .decomposition) "decomp" else "co-decomp" };
    return .{ .record = .{ .label = label, .fields = fields } };
}

// ============================================================================
// Tests
// ============================================================================

test "StrDecomp basic construction" {
    const allocator = std.testing.allocator;
    const edges = [_]Edge{.{ .left_bag = 0, .right_bag = 1 }};
    const sizes = [_]u32{ 5, 3 };
    var d = try StrDecomp.init(allocator, 2, &edges, &sizes, .co_decomposition);
    defer d.deinit();

    try std.testing.expectEqual(@as(u32, 2), d.num_bags);
    try std.testing.expectEqual(@as(u32, 1), d.num_edges);
    try std.testing.expectEqual(@as(u32, 5), d.bags[0].size);
    try std.testing.expectEqual(@as(u32, 3), d.bags[1].size);
    try std.testing.expect(!d.hasEmptyBag());
    try std.testing.expectEqual(@as(u64, 8), d.totalSize());
}

test "adhesionFilter refines consistently" {
    const allocator = std.testing.allocator;

    // Two bags: bag0 = {0,1,2,3}, bag1 = {0,1,2}
    // Adhesion: both map to {0,1}
    // left: bag0 -> adhesion, [0, 0, 1, 1] (elements 0,1 map to 0; elements 2,3 map to 1)
    // right: bag1 -> adhesion, [0, 1, 0] (elements 0,2 map to 0; element 1 maps to 1)
    // Pullback: pairs where left(a)=right(b):
    //   left(0)=0=right(0) ✓, left(0)=0=right(2) ✓
    //   left(1)=0=right(0) ✓, left(1)=0=right(2) ✓
    //   left(2)=1=right(1) ✓
    //   left(3)=1=right(1) ✓
    // image of leg1 = {0,1,2,3} (all of bag0), image of leg2 = {0,1,2} (all of bag1)
    // No refinement — everything is already consistent.

    const edges = [_]Edge{.{ .left_bag = 0, .right_bag = 1 }};
    const sizes = [_]u32{ 4, 3 };
    var d = try StrDecomp.init(allocator, 2, &edges, &sizes, .co_decomposition);
    defer d.deinit();

    const left_map = try allocator.alloc(u32, 4);
    left_map[0] = 0;
    left_map[1] = 0;
    left_map[2] = 1;
    left_map[3] = 1;
    const right_map = try allocator.alloc(u32, 3);
    right_map[0] = 0;
    right_map[1] = 1;
    right_map[2] = 0;

    d.setCospan(0, FinFunction.init(4, 2, left_map), FinFunction.init(3, 2, right_map));

    const refined = try adhesionFilter(&d, 0);
    // All elements are consistent, so no refinement
    try std.testing.expect(!refined);
    try std.testing.expectEqual(@as(u32, 4), d.bags[0].size);
    try std.testing.expectEqual(@as(u32, 3), d.bags[1].size);
}

test "adhesionFilter shrinks inconsistent bags" {
    const allocator = std.testing.allocator;

    // bag0 = {0,1,2}, bag1 = {0,1}
    // left: bag0 -> {0,1,2}, [0, 1, 2]
    // right: bag1 -> {0,1,2}, [0, 1]
    // Pullback: left(a)=right(b): (0,0) and (1,1)
    // image of leg1 = {0,1} (element 2 of bag0 is filtered out)
    // image of leg2 = {0,1} (unchanged)

    const edges = [_]Edge{.{ .left_bag = 0, .right_bag = 1 }};
    const sizes = [_]u32{ 3, 2 };
    var d = try StrDecomp.init(allocator, 2, &edges, &sizes, .co_decomposition);
    defer d.deinit();

    const left_map = try allocator.alloc(u32, 3);
    left_map[0] = 0;
    left_map[1] = 1;
    left_map[2] = 2;
    const right_map = try allocator.alloc(u32, 2);
    right_map[0] = 0;
    right_map[1] = 1;

    d.setCospan(0, FinFunction.init(3, 3, left_map), FinFunction.init(2, 3, right_map));

    const refined = try adhesionFilter(&d, 0);
    try std.testing.expect(refined); // bag0 shrank from 3 to 2
    try std.testing.expectEqual(@as(u32, 2), d.bags[0].size);
    try std.testing.expectEqual(@as(u32, 2), d.bags[1].size);
}

test "adhesionFilter empties incompatible bags" {
    const allocator = std.testing.allocator;

    // bag0 maps to {0}, bag1 maps to {1} — disjoint
    const edges = [_]Edge{.{ .left_bag = 0, .right_bag = 1 }};
    const sizes = [_]u32{ 1, 1 };
    var d = try StrDecomp.init(allocator, 2, &edges, &sizes, .co_decomposition);
    defer d.deinit();

    const left_map = try allocator.alloc(u32, 1);
    left_map[0] = 0;
    const right_map = try allocator.alloc(u32, 1);
    right_map[0] = 1;

    d.setCospan(0, FinFunction.init(1, 2, left_map), FinFunction.init(1, 2, right_map));

    const refined = try adhesionFilter(&d, 0);
    try std.testing.expect(refined);
    try std.testing.expect(d.hasEmptyBag());
}

test "decideSheaf on compatible decomposition" {
    const allocator = std.testing.allocator;

    // Linear tree: bag0 -- bag1 -- bag2
    // All bags map to same adhesion value — fully consistent
    const edges = [_]Edge{
        .{ .left_bag = 0, .right_bag = 1 },
        .{ .left_bag = 1, .right_bag = 2 },
    };
    const sizes = [_]u32{ 2, 2, 2 };
    var d = try StrDecomp.init(allocator, 3, &edges, &sizes, .co_decomposition);
    defer d.deinit();

    // Edge 0: both bags map identically to {0,1}
    const l0 = try allocator.alloc(u32, 2);
    l0[0] = 0;
    l0[1] = 1;
    const r0 = try allocator.alloc(u32, 2);
    r0[0] = 0;
    r0[1] = 1;
    d.setCospan(0, FinFunction.init(2, 2, l0), FinFunction.init(2, 2, r0));

    // Edge 1: same
    const l1 = try allocator.alloc(u32, 2);
    l1[0] = 0;
    l1[1] = 1;
    const r1 = try allocator.alloc(u32, 2);
    r1[0] = 0;
    r1[1] = 1;
    d.setCospan(1, FinFunction.init(2, 2, l1), FinFunction.init(2, 2, r1));

    const result = try decideSheaf(&d);
    try std.testing.expect(result); // solutions exist
    try std.testing.expect(!d.hasEmptyBag());
}

test "decideSheaf on incompatible decomposition" {
    const allocator = std.testing.allocator;

    // bag0 maps to {0}, bag1 maps to {0,1}, bag2 maps to {1}
    // Edge 0: bag0--bag1, adhesion = {0,1}
    // Edge 1: bag1--bag2, adhesion = {0,1}
    // After filtering: bag1 must contain only elements mapping to both 0 AND 1
    // If bag1 elements each map to one value, contradiction propagates.

    const edges = [_]Edge{
        .{ .left_bag = 0, .right_bag = 1 },
        .{ .left_bag = 1, .right_bag = 2 },
    };
    const sizes = [_]u32{ 1, 1, 1 };
    var d = try StrDecomp.init(allocator, 3, &edges, &sizes, .co_decomposition);
    defer d.deinit();

    const l0 = try allocator.alloc(u32, 1);
    l0[0] = 0;
    const r0 = try allocator.alloc(u32, 1);
    r0[0] = 0;
    d.setCospan(0, FinFunction.init(1, 2, l0), FinFunction.init(1, 2, r0));

    const l1 = try allocator.alloc(u32, 1);
    l1[0] = 0;
    const r1 = try allocator.alloc(u32, 1);
    r1[0] = 1;
    d.setCospan(1, FinFunction.init(1, 2, l1), FinFunction.init(1, 2, r1));

    const result = try decideSheaf(&d);
    try std.testing.expect(!result); // no global solution
}

test "adhesion coloring: linear chain" {
    // Linear: bag0--bag1--bag2--bag3 (3 edges)
    // Dependency graph: e0-e1 share bag1, e1-e2 share bag2
    // e0 and e2 are independent (disjoint bags) => same color
    // Chromatic number = 2
    const allocator = std.testing.allocator;
    const edges = [_]Edge{
        .{ .left_bag = 0, .right_bag = 1 },
        .{ .left_bag = 1, .right_bag = 2 },
        .{ .left_bag = 2, .right_bag = 3 },
    };
    const sizes = [_]u32{ 2, 2, 2, 2 };
    var d = try StrDecomp.init(allocator, 4, &edges, &sizes, .co_decomposition);
    defer d.deinit();

    var coloring = try colorAdhesionGraph(&d, allocator);
    defer coloring.deinit();

    try std.testing.expectEqual(@as(u32, 2), coloring.num_barriers);
    // e0 and e2 must have the same color (independent)
    try std.testing.expectEqual(coloring.colors[0], coloring.colors[2]);
    // e0 and e1 must differ (share bag1)
    try std.testing.expect(coloring.colors[0] != coloring.colors[1]);
}

test "adhesion coloring: star graph" {
    // Star: bag0 is hub, connected to bag1, bag2, bag3
    // All edges share bag0 => all pairwise adjacent => chi = 3
    const allocator = std.testing.allocator;
    const edges = [_]Edge{
        .{ .left_bag = 0, .right_bag = 1 },
        .{ .left_bag = 0, .right_bag = 2 },
        .{ .left_bag = 0, .right_bag = 3 },
    };
    const sizes = [_]u32{ 2, 2, 2, 2 };
    var d = try StrDecomp.init(allocator, 4, &edges, &sizes, .co_decomposition);
    defer d.deinit();

    var coloring = try colorAdhesionGraph(&d, allocator);
    defer coloring.deinit();

    try std.testing.expectEqual(@as(u32, 3), coloring.num_barriers);
    // All three must have distinct colors
    try std.testing.expect(coloring.colors[0] != coloring.colors[1]);
    try std.testing.expect(coloring.colors[1] != coloring.colors[2]);
    try std.testing.expect(coloring.colors[0] != coloring.colors[2]);
}

test "adhesion coloring: disjoint edges" {
    // bag0--bag1, bag2--bag3: two independent edges
    // chi = 1, both in same barrier
    const allocator = std.testing.allocator;
    const edges = [_]Edge{
        .{ .left_bag = 0, .right_bag = 1 },
        .{ .left_bag = 2, .right_bag = 3 },
    };
    const sizes = [_]u32{ 2, 2, 2, 2 };
    var d = try StrDecomp.init(allocator, 4, &edges, &sizes, .co_decomposition);
    defer d.deinit();

    var coloring = try colorAdhesionGraph(&d, allocator);
    defer coloring.deinit();

    try std.testing.expectEqual(@as(u32, 1), coloring.num_barriers);
    try std.testing.expectEqual(coloring.colors[0], coloring.colors[1]);
}

test "decideSheafParallel matches decideSheaf" {
    const allocator = std.testing.allocator;

    // Build identical decompositions, solve both ways, compare
    const edges = [_]Edge{
        .{ .left_bag = 0, .right_bag = 1 },
        .{ .left_bag = 1, .right_bag = 2 },
    };
    const sizes = [_]u32{ 2, 2, 2 };

    // Sequential
    var d1 = try StrDecomp.init(allocator, 3, &edges, &sizes, .co_decomposition);
    defer d1.deinit();
    const l0a = try allocator.alloc(u32, 2);
    l0a[0] = 0;
    l0a[1] = 1;
    const r0a = try allocator.alloc(u32, 2);
    r0a[0] = 0;
    r0a[1] = 1;
    d1.setCospan(0, FinFunction.init(2, 2, l0a), FinFunction.init(2, 2, r0a));
    const l1a = try allocator.alloc(u32, 2);
    l1a[0] = 0;
    l1a[1] = 1;
    const r1a = try allocator.alloc(u32, 2);
    r1a[0] = 0;
    r1a[1] = 1;
    d1.setCospan(1, FinFunction.init(2, 2, l1a), FinFunction.init(2, 2, r1a));
    const res1 = try decideSheaf(&d1);

    // Parallel
    var d2 = try StrDecomp.init(allocator, 3, &edges, &sizes, .co_decomposition);
    defer d2.deinit();
    const l0b = try allocator.alloc(u32, 2);
    l0b[0] = 0;
    l0b[1] = 1;
    const r0b = try allocator.alloc(u32, 2);
    r0b[0] = 0;
    r0b[1] = 1;
    d2.setCospan(0, FinFunction.init(2, 2, l0b), FinFunction.init(2, 2, r0b));
    const l1b = try allocator.alloc(u32, 2);
    l1b[0] = 0;
    l1b[1] = 1;
    const r1b = try allocator.alloc(u32, 2);
    r1b[0] = 0;
    r1b[1] = 1;
    d2.setCospan(1, FinFunction.init(2, 2, l1b), FinFunction.init(2, 2, r1b));
    const res2 = try decideSheafParallel(&d2);

    try std.testing.expectEqual(res1, res2);
    try std.testing.expectEqual(d1.totalSize(), d2.totalSize());
}

test "syrup serialization" {
    const allocator = std.testing.allocator;
    const edges = [_]Edge{.{ .left_bag = 0, .right_bag = 1 }};
    const sizes = [_]u32{ 5, 3 };
    var d = try StrDecomp.init(allocator, 2, &edges, &sizes, .co_decomposition);
    defer d.deinit();

    const val = try toSyrup(&d, allocator);
    defer val.deinitAll(allocator);

    try std.testing.expect(std.mem.eql(u8, val.record.label.symbol, "str-decomp"));
    try std.testing.expectEqual(@as(usize, 3), val.record.fields.len);
}
