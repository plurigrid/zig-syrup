//! Ripser: Persistent Homology via Implicit Simplex Representation
//!
//! A pure Zig port of Ripser's "simple branch" algorithm for computing
//! Vietoris-Rips persistent homology. Uses the combinatorial number system
//! to implicitly represent simplices, avoiding storage of full simplex data.
//!
//! Key algorithmic ideas (Bauer 2021):
//! - Combinatorial number system for compact simplex indexing
//! - Coboundary enumeration for matrix column construction
//! - Apparent pairs shortcut (most pairs detected without reduction)
//! - Clearing optimization (skip columns in image of boundary)
//!
//! Reference: Ulrich Bauer, "Ripser: efficient computation of Vietoris-Rips
//! persistence barcodes", J. Appl. Comput. Topol. 5 (2021), 391-423.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// BINOMIAL COEFFICIENT TABLE (comptime)
// ============================================================================

/// Maximum vertices supported
const MAX_N = 128;
/// Maximum simplex dimension + 2 (k values 0..MAX_K-1)
const MAX_K = 8;

/// Comptime-initialized binomial coefficient table.
/// C(n,k) is looked up in O(1) via `binomial_table[n][k]`.
fn computeBinomialTable() [MAX_N][MAX_K]usize {
    @setEvalBranchQuota(100_000);
    var t: [MAX_N][MAX_K]usize = undefined;
    for (0..MAX_N) |n| {
        t[n][0] = 1;
        for (1..MAX_K) |k| {
            if (k > n) {
                t[n][k] = 0;
            } else {
                t[n][k] = t[n - 1][k - 1] + t[n - 1][k];
            }
        }
    }
    return t;
}

/// Global comptime binomial table
const binomial_table: [MAX_N][MAX_K]usize = computeBinomialTable();

/// Look up C(n,k) from the precomputed table; returns 0 for out-of-range.
fn binomial(n: usize, k: usize) usize {
    if (n >= MAX_N or k >= MAX_K) return 0;
    return binomial_table[n][k];
}

// ============================================================================
// DISTANCE MATRIX
// ============================================================================

/// Compressed lower-triangular distance matrix (symmetric, zero diagonal).
/// Stores n*(n-1)/2 entries in row-major lower-triangular order.
pub const DistanceMatrix = struct {
    distances: []f64,
    n: usize,

    pub fn init(n: usize, allocator: Allocator) !DistanceMatrix {
        const size = if (n >= 2) n * (n - 1) / 2 else 0;
        const distances = try allocator.alloc(f64, size);
        @memset(distances, 0);
        return .{ .distances = distances, .n = n };
    }

    pub fn deinit(self: *DistanceMatrix, allocator: Allocator) void {
        allocator.free(self.distances);
    }

    /// Get distance between points i and j (symmetric; diagonal = 0).
    pub fn get(self: DistanceMatrix, i: usize, j: usize) f64 {
        if (i == j) return 0;
        const row = @max(i, j);
        const col = @min(i, j);
        return self.distances[row * (row - 1) / 2 + col];
    }

    /// Set distance between points i and j.
    pub fn set(self: *DistanceMatrix, i: usize, j: usize, val: f64) void {
        if (i == j) return;
        const row = @max(i, j);
        const col = @min(i, j);
        self.distances[row * (row - 1) / 2 + col] = val;
    }

    /// Compute from point cloud using Euclidean distances.
    pub fn fromPointCloud(points: []const []const f64, allocator: Allocator) !DistanceMatrix {
        const n = points.len;
        var dm = try DistanceMatrix.init(n, allocator);
        for (0..n) |i| {
            for (0..i) |j| {
                var sum: f64 = 0;
                for (0..points[i].len) |d| {
                    const diff = points[i][d] - points[j][d];
                    sum += diff * diff;
                }
                dm.set(i, j, @sqrt(sum));
            }
        }
        return dm;
    }
};

// ============================================================================
// SIMPLEX TYPES
// ============================================================================

/// A simplex entry: combinatorial index + filtration diameter + coefficient.
pub const SimplexEntry = struct {
    index: usize,
    coefficient: i8,
    diameter: f64,

    pub fn init_(index: usize, diameter: f64, coefficient: i8) SimplexEntry {
        return .{ .index = index, .coefficient = coefficient, .diameter = diameter };
    }
};

/// Recover the vertices of a simplex from its combinatorial index.
///
/// In the combinatorial number system, a k-simplex on vertices
/// v_0 > v_1 > ... > v_k has index = sum_{i=0}^{k} C(v_i, k+1-i).
///
/// `dim` is the simplex dimension (number of vertices = dim+1).
/// `n` is the number of points in the complex.
/// `vertices` must have length >= dim+1; filled in decreasing order.
pub fn getSimplexVertices(index: usize, dim: usize, n: usize, vertices: []usize) void {
    var idx = index;
    var v: usize = n - 1;
    for (0..dim + 1) |i| {
        const k = dim + 1 - i; // from dim+1 down to 1
        while (binomial(v, k) > idx) {
            if (v == 0) break;
            v -= 1;
        }
        vertices[i] = v;
        idx -= binomial(v, k);
        if (v > 0) v -= 1;
    }
}

/// Compute the combinatorial index of a simplex from its vertices.
/// Vertices must be in strictly decreasing order.
pub fn getSimplexIndex(vertices: []const usize, dim: usize) usize {
    var idx: usize = 0;
    for (0..dim + 1) |i| {
        idx += binomial(vertices[i], dim + 1 - i);
    }
    return idx;
}

/// Compute the diameter (max pairwise distance) of a simplex.
pub fn getSimplexDiameter(index: usize, dim: usize, n: usize, dist: DistanceMatrix) f64 {
    var vertices: [MAX_K]usize = undefined;
    getSimplexVertices(index, dim, n, vertices[0 .. dim + 1]);
    var max_dist: f64 = 0;
    for (0..dim + 1) |i| {
        for (0..i) |j| {
            max_dist = @max(max_dist, dist.get(vertices[i], vertices[j]));
        }
    }
    return max_dist;
}

// ============================================================================
// COBOUNDARY ENUMERATOR
// ============================================================================

/// Enumerates the cofacets (coboundary simplices) of a given k-simplex.
///
/// Given a k-simplex sigma, iterates over all (k+1)-simplices tau that contain
/// sigma as a face. Each cofacet is obtained by inserting one new vertex v
/// into the vertex set of sigma. The iteration proceeds from the highest
/// possible vertex downward, tracking how the combinatorial index changes.
pub const CoboundaryEnumerator = struct {
    simplex_index: usize,
    dim: usize,
    n: usize,
    dist: *const DistanceMatrix,
    vertices: [MAX_K]usize,
    /// Current candidate vertex to insert (decreasing from n-1)
    position: usize,
    /// Index contribution from vertices above the insertion point
    idx_above: usize,
    /// Index contribution from vertices below the insertion point
    idx_below: usize,
    /// Which vertex slot we are between (0 = above all, dim+1 = below all)
    vertex_slot: usize,
    done: bool,

    pub fn create(simplex_index: usize, dim: usize, n: usize, dist: *const DistanceMatrix) CoboundaryEnumerator {
        var self: CoboundaryEnumerator = .{
            .simplex_index = simplex_index,
            .dim = dim,
            .n = n,
            .dist = dist,
            .vertices = undefined,
            .position = if (n > 0) n - 1 else 0,
            .idx_above = 0,
            .idx_below = simplex_index,
            .vertex_slot = 0,
            .done = n == 0,
        };
        getSimplexVertices(simplex_index, dim, n, self.vertices[0 .. dim + 1]);
        return self;
    }

    /// Return the next cofacet, or null if enumeration is complete.
    pub fn next(self: *CoboundaryEnumerator) ?SimplexEntry {
        while (!self.done) {
            if (self.vertex_slot > self.dim + 1) {
                self.done = true;
                return null;
            }

            // Upper bound for vertex to insert at this slot
            const upper: usize = if (self.vertex_slot == 0)
                self.n
            else
                self.vertices[self.vertex_slot - 1];

            // Lower bound (exclusive): vertex at current slot, or 0 if past all vertices
            const lower: usize = if (self.vertex_slot <= self.dim)
                self.vertices[self.vertex_slot] + 1
            else
                0;

            if (self.position >= upper) {
                if (upper == 0) {
                    self.done = true;
                    return null;
                }
                self.position = upper - 1;
            }

            if (self.position >= lower) {
                const v = self.position;
                const k_coeff = self.dim + 2 - self.vertex_slot;
                const cofacet_index = self.idx_above + binomial(v, k_coeff) + self.idx_below;

                // Cofacet diameter: max of sigma's diameter and distances from v to sigma vertices
                var diam: f64 = getSimplexDiameter(self.simplex_index, self.dim, self.n, self.dist.*);
                for (0..self.dim + 1) |i| {
                    diam = @max(diam, self.dist.get(v, self.vertices[i]));
                }

                // Coefficient: (-1)^vertex_slot for oriented coboundary
                const coeff: i8 = if (self.vertex_slot % 2 == 0) 1 else -1;

                // Advance to next candidate
                if (self.position > 0 and self.position > lower) {
                    self.position -= 1;
                } else {
                    self.advanceSlot();
                }

                return SimplexEntry.init_(cofacet_index, diam, coeff);
            }

            self.advanceSlot();
        }
        return null;
    }

    /// Move to the next insertion slot, updating idx_above and idx_below.
    fn advanceSlot(self: *CoboundaryEnumerator) void {
        if (self.vertex_slot <= self.dim) {
            const v_at_slot = self.vertices[self.vertex_slot];
            const k_above = self.dim + 1 - self.vertex_slot;
            self.idx_above += binomial(v_at_slot, k_above + 1);
            self.idx_below -= binomial(v_at_slot, k_above);
        }
        self.vertex_slot += 1;
        if (self.vertex_slot <= self.dim + 1) {
            const upper_val: usize = if (self.vertex_slot == 0)
                self.n
            else if (self.vertex_slot - 1 <= self.dim)
                self.vertices[self.vertex_slot - 1]
            else
                1;
            self.position = if (upper_val > 0) upper_val - 1 else 0;
        } else {
            self.done = true;
        }
    }
};

// ============================================================================
// PERSISTENCE DIAGRAM
// ============================================================================

/// A persistence pair (birth, death) in a given homological dimension.
pub const PersistencePair = struct {
    birth: f64,
    death: f64,
    dimension: usize,

    /// Persistence = death - birth. Infinite for essential classes.
    pub fn persistence(self: PersistencePair) f64 {
        return self.death - self.birth;
    }

    /// Whether this is an essential (infinite persistence) class.
    pub fn isEssential(self: PersistencePair) bool {
        return self.death == std.math.inf(f64);
    }
};

/// Collection of persistence pairs across all dimensions.
pub const PersistenceDiagram = struct {
    pairs: std.ArrayListUnmanaged(PersistencePair),
    max_dimension: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator) PersistenceDiagram {
        return .{
            .pairs = .{},
            .max_dimension = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PersistenceDiagram) void {
        self.pairs.deinit(self.allocator);
    }

    pub fn addPair(self: *PersistenceDiagram, birth: f64, death: f64, dim: usize) !void {
        try self.pairs.append(self.allocator, .{ .birth = birth, .death = death, .dimension = dim });
        self.max_dimension = @max(self.max_dimension, dim);
    }

    /// Return all pairs in a specific dimension.
    pub fn pairsInDimension(self: PersistenceDiagram, dim: usize, allocator: Allocator) ![]PersistencePair {
        var result: std.ArrayListUnmanaged(PersistencePair) = .{};
        for (self.pairs.items) |p| {
            if (p.dimension == dim) try result.append(allocator, p);
        }
        return result.toOwnedSlice(allocator);
    }

    /// Betti numbers: count of infinite-persistence pairs per dimension.
    pub fn bettiNumbers(self: PersistenceDiagram, allocator: Allocator) ![]usize {
        var max_dim: usize = 0;
        for (self.pairs.items) |p| max_dim = @max(max_dim, p.dimension);
        const betti = try allocator.alloc(usize, max_dim + 1);
        @memset(betti, 0);
        for (self.pairs.items) |p| {
            if (p.death == std.math.inf(f64)) betti[p.dimension] += 1;
        }
        return betti;
    }

    /// Count of finite (non-essential) pairs per dimension.
    pub fn finitePairsCount(self: PersistenceDiagram, dim: usize) usize {
        var count: usize = 0;
        for (self.pairs.items) |p| {
            if (p.dimension == dim and p.death != std.math.inf(f64)) count += 1;
        }
        return count;
    }
};

// ============================================================================
// UNION-FIND
// ============================================================================

/// Disjoint set / union-find with path compression and union by rank.
const UnionFind = struct {
    parent: []usize,
    rank: []usize,

    fn create(n: usize, allocator: Allocator) !UnionFind {
        const parent = try allocator.alloc(usize, n);
        const rank = try allocator.alloc(usize, n);
        for (0..n) |i| {
            parent[i] = i;
            rank[i] = 0;
        }
        return .{ .parent = parent, .rank = rank };
    }

    fn deinit(self: *UnionFind, allocator: Allocator) void {
        allocator.free(self.parent);
        allocator.free(self.rank);
    }

    fn find(self: *UnionFind, x: usize) usize {
        var cur = x;
        while (self.parent[cur] != cur) {
            self.parent[cur] = self.parent[self.parent[cur]];
            cur = self.parent[cur];
        }
        return cur;
    }

    /// Union two sets. Returns true if they were disjoint (merge happened).
    fn merge(self: *UnionFind, x: usize, y: usize) bool {
        const rx = self.find(x);
        const ry = self.find(y);
        if (rx == ry) return false;
        if (self.rank[rx] < self.rank[ry]) {
            self.parent[rx] = ry;
        } else if (self.rank[rx] > self.rank[ry]) {
            self.parent[ry] = rx;
        } else {
            self.parent[ry] = rx;
            self.rank[rx] += 1;
        }
        return true;
    }
};

// ============================================================================
// EDGES (for dimension 0)
// ============================================================================

const Edge = struct {
    u: usize,
    v: usize,
    weight: f64,

    fn lessThan(_: void, a: Edge, b: Edge) bool {
        if (a.weight != b.weight) return a.weight < b.weight;
        if (a.u != b.u) return a.u < b.u;
        return a.v < b.v;
    }
};

// ============================================================================
// RIPSER CONFIGURATION
// ============================================================================

/// Configuration for the Ripser computation.
pub const RipserConfig = struct {
    /// Maximum homological dimension to compute (default: H_0 and H_1).
    max_dimension: usize = 1,
    /// Maximum edge length (filtration threshold).
    max_edge_length: f64 = std.math.inf(f64),
    /// Minimum persistence to report (filters short-lived features).
    min_persistence: f64 = 0,
};

// ============================================================================
// SPARSE COLUMN TYPE
// ============================================================================

/// A sparse column in the coboundary matrix, stored as a list of simplex entries.
const SparseColumn = struct {
    entries: std.ArrayListUnmanaged(SimplexEntry),

    fn create() SparseColumn {
        return .{ .entries = .{} };
    }

    fn deinit(self: *SparseColumn, allocator: Allocator) void {
        self.entries.deinit(allocator);
    }

    /// Get the pivot (entry with largest index). Returns null if empty.
    fn pivot(self: SparseColumn) ?SimplexEntry {
        if (self.entries.items.len == 0) return null;
        var max_entry = self.entries.items[0];
        for (self.entries.items[1..]) |e| {
            if (e.index > max_entry.index) max_entry = e;
        }
        return max_entry;
    }

    /// Add another column to this one (mod-2 addition).
    /// Entries with the same index cancel out.
    fn addColumn(self: *SparseColumn, other: SparseColumn, allocator: Allocator) !void {
        var index_map = std.AutoHashMap(usize, CoeffAccum).init(allocator);
        defer index_map.deinit();

        for (self.entries.items) |e| {
            const gop = try index_map.getOrPut(e.index);
            if (gop.found_existing) {
                gop.value_ptr.coeff += e.coefficient;
                gop.value_ptr.diameter = @max(gop.value_ptr.diameter, e.diameter);
            } else {
                gop.value_ptr.* = .{ .coeff = e.coefficient, .diameter = e.diameter };
            }
        }
        for (other.entries.items) |e| {
            const gop = try index_map.getOrPut(e.index);
            if (gop.found_existing) {
                gop.value_ptr.coeff += e.coefficient;
                gop.value_ptr.diameter = @max(gop.value_ptr.diameter, e.diameter);
            } else {
                gop.value_ptr.* = .{ .coeff = e.coefficient, .diameter = e.diameter };
            }
        }

        self.entries.clearRetainingCapacity();
        var iter = index_map.iterator();
        while (iter.next()) |kv| {
            const c = @mod(kv.value_ptr.coeff, 2);
            if (c != 0) {
                try self.entries.append(allocator, SimplexEntry.init_(
                    kv.key_ptr.*,
                    kv.value_ptr.diameter,
                    @intCast(c),
                ));
            }
        }
    }
};

const CoeffAccum = struct {
    coeff: i32,
    diameter: f64,
};

// ============================================================================
// MAIN ALGORITHM
// ============================================================================

/// Compute persistent homology of a Vietoris-Rips filtration.
///
/// Given a distance matrix and configuration, returns the persistence diagram
/// containing all (birth, death) pairs for dimensions 0 through max_dimension.
pub fn computePersistence(dist: DistanceMatrix, config: RipserConfig, allocator: Allocator) !PersistenceDiagram {
    var diagram = PersistenceDiagram.init(allocator);
    errdefer diagram.deinit();
    const n = dist.n;

    if (n == 0) return diagram;

    // Dimension 0: connected components via Kruskal/union-find
    try computeDimension0(&diagram, dist, n, config, allocator);

    // Higher dimensions: coboundary matrix reduction
    for (1..config.max_dimension + 1) |dim| {
        try computeHigherDimension(&diagram, dist, n, dim, config, allocator);
    }

    return diagram;
}

/// Dimension 0: connected components.
fn computeDimension0(
    diagram: *PersistenceDiagram,
    dist: DistanceMatrix,
    n: usize,
    config: RipserConfig,
    allocator: Allocator,
) !void {
    if (n <= 1) {
        try diagram.addPair(0, std.math.inf(f64), 0);
        return;
    }

    const num_edges = n * (n - 1) / 2;
    var edges = try allocator.alloc(Edge, num_edges);
    defer allocator.free(edges);

    var idx: usize = 0;
    for (1..n) |i| {
        for (0..i) |j| {
            const w = dist.get(i, j);
            edges[idx] = .{ .u = j, .v = i, .weight = w };
            idx += 1;
        }
    }

    std.mem.sort(Edge, edges, {}, Edge.lessThan);

    var uf = try UnionFind.create(n, allocator);
    defer uf.deinit(allocator);

    var components: usize = n;
    for (edges) |e| {
        if (e.weight > config.max_edge_length) break;
        if (uf.merge(e.u, e.v)) {
            components -= 1;
            const pers = e.weight;
            if (pers > config.min_persistence) {
                try diagram.addPair(0, e.weight, 0);
            }
        }
    }

    for (0..components) |_| {
        try diagram.addPair(0, std.math.inf(f64), 0);
    }
}

/// Higher dimension (dim >= 1): coboundary matrix reduction.
fn computeHigherDimension(
    diagram: *PersistenceDiagram,
    dist: DistanceMatrix,
    n: usize,
    dim: usize,
    config: RipserConfig,
    allocator: Allocator,
) !void {
    const num_simplices = binomial(n, dim + 1);
    if (num_simplices == 0) return;

    // Enumerate simplices with diameter within threshold
    var simplices: std.ArrayListUnmanaged(SimplexEntry) = .{};
    defer simplices.deinit(allocator);

    for (0..num_simplices) |si| {
        const diam = getSimplexDiameter(si, dim, n, dist);
        if (diam <= config.max_edge_length) {
            try simplices.append(allocator, SimplexEntry.init_(si, diam, 1));
        }
    }

    // Sort by diameter, tie-break by index
    std.mem.sort(SimplexEntry, simplices.items, {}, struct {
        fn lessThan(_: void, a: SimplexEntry, b: SimplexEntry) bool {
            if (a.diameter != b.diameter) return a.diameter < b.diameter;
            return a.index < b.index;
        }
    }.lessThan);

    // Pivot map: cofacet index -> column index that has this pivot
    var pivot_column = std.AutoHashMap(usize, usize).init(allocator);
    defer pivot_column.deinit();

    // Cleared set: simplex indices whose columns are in the image of boundary
    var cleared = std.AutoHashMap(usize, void).init(allocator);
    defer cleared.deinit();

    // Stored reduced columns for reduction
    var reduced_columns = std.AutoHashMap(usize, SparseColumn).init(allocator);
    defer {
        var it = reduced_columns.valueIterator();
        while (it.next()) |col| {
            col.deinit(allocator);
        }
        reduced_columns.deinit();
    }

    for (simplices.items) |simplex| {
        if (cleared.contains(simplex.index)) continue;

        // Build coboundary column
        var column = SparseColumn.create();
        var column_owned = true;

        var coboundary = CoboundaryEnumerator.create(simplex.index, dim, n, &dist);
        while (coboundary.next()) |cofacet| {
            if (cofacet.diameter <= config.max_edge_length) {
                try column.entries.append(allocator, cofacet);
            }
        }

        // Column reduction
        var reduction_count: usize = 0;
        const max_reductions: usize = 1000;

        while (reduction_count < max_reductions) : (reduction_count += 1) {
            const piv = column.pivot() orelse break;

            if (reduced_columns.get(piv.index)) |existing| {
                try column.addColumn(existing, allocator);
            } else {
                // New pivot: record the pair
                const death = piv.diameter;
                const pers = death - simplex.diameter;
                if (pers > config.min_persistence) {
                    try diagram.addPair(simplex.diameter, death, dim);
                }
                try pivot_column.put(piv.index, simplex.index);
                try cleared.put(piv.index, {});
                try reduced_columns.put(piv.index, column);
                column_owned = false; // ownership transferred
                break;
            }
        }

        // If column reduced to zero and was originally non-empty: not essential
        // If coboundary was empty from the start: essential class
        if (column_owned) {
            if (column.entries.items.len == 0 and reduction_count == 0) {
                try diagram.addPair(simplex.diameter, std.math.inf(f64), dim);
            }
            column.deinit(allocator);
        }
    }
}

// ============================================================================
// SYRUP SERIALIZATION
// ============================================================================

/// Serialize a persistence diagram to a Syrup Value.
pub fn toSyrup(diagram: PersistenceDiagram, allocator: Allocator) !@import("syrup.zig").Value {
    const syrup = @import("syrup.zig");

    const pair_values = try allocator.alloc(syrup.Value, diagram.pairs.items.len);
    for (diagram.pairs.items, 0..) |pair, idx| {
        const entries = try allocator.alloc(syrup.Value.DictEntry, 3);
        entries[0] = .{
            .key = syrup.Value{ .symbol = "birth" },
            .value = syrup.Value{ .float = pair.birth },
        };
        entries[1] = .{
            .key = syrup.Value{ .symbol = "death" },
            .value = syrup.Value{ .float = pair.death },
        };
        entries[2] = .{
            .key = syrup.Value{ .symbol = "dim" },
            .value = syrup.Value{ .integer = @intCast(pair.dimension) },
        };
        pair_values[idx] = syrup.Value{ .dictionary = entries };
    }

    const label = try allocator.create(syrup.Value);
    label.* = syrup.Value{ .symbol = "persistence-diagram" };

    const fields = try allocator.alloc(syrup.Value, 2);
    fields[0] = syrup.Value{ .list = pair_values };
    fields[1] = syrup.Value{ .integer = @intCast(diagram.max_dimension) };

    return syrup.Value{ .record = .{ .label = label, .fields = fields } };
}

/// Serialize a distance matrix to a Syrup Value.
pub fn distanceMatrixToSyrup(dm: DistanceMatrix, allocator: Allocator) !@import("syrup.zig").Value {
    const syrup = @import("syrup.zig");

    const label = try allocator.create(syrup.Value);
    label.* = syrup.Value{ .symbol = "distance-matrix" };

    const dist_values = try allocator.alloc(syrup.Value, dm.distances.len);
    for (dm.distances, 0..) |d, idx| {
        dist_values[idx] = syrup.Value{ .float = d };
    }

    const fields = try allocator.alloc(syrup.Value, 2);
    fields[0] = syrup.Value{ .integer = @intCast(dm.n) };
    fields[1] = syrup.Value{ .list = dist_values };

    return syrup.Value{ .record = .{ .label = label, .fields = fields } };
}

// ============================================================================
// UTILITY
// ============================================================================

/// Create a distance matrix from flat coordinate data.
/// `coords` is [n * d] flat array, `n` points in `d` dimensions.
pub fn distanceMatrixFromFlat(coords: []const f64, n: usize, d: usize, allocator: Allocator) !DistanceMatrix {
    var dm = try DistanceMatrix.init(n, allocator);
    for (0..n) |i| {
        for (0..i) |j| {
            var sum: f64 = 0;
            for (0..d) |k| {
                const diff = coords[i * d + k] - coords[j * d + k];
                sum += diff * diff;
            }
            dm.set(i, j, @sqrt(sum));
        }
    }
    return dm;
}

// ============================================================================
// TESTS
// ============================================================================

test "binomial coefficient table" {
    try std.testing.expectEqual(@as(usize, 1), binomial(0, 0));
    try std.testing.expectEqual(@as(usize, 10), binomial(5, 2));
    try std.testing.expectEqual(@as(usize, 20), binomial(6, 3));
    try std.testing.expectEqual(@as(usize, 1), binomial(5, 5));
    try std.testing.expectEqual(@as(usize, 0), binomial(3, 5));
    try std.testing.expectEqual(@as(usize, 1), binomial(7, 0));
    try std.testing.expectEqual(@as(usize, 7), binomial(7, 1));
    try std.testing.expectEqual(@as(usize, 35), binomial(7, 3));
    try std.testing.expectEqual(@as(usize, 252), binomial(10, 5));
}

test "binomial overflow safety" {
    try std.testing.expectEqual(@as(usize, 0), binomial(MAX_N, 0));
    try std.testing.expectEqual(@as(usize, 0), binomial(0, MAX_K));
}

test "distance matrix basic" {
    const allocator = std.testing.allocator;
    var dm = try DistanceMatrix.init(4, allocator);
    defer dm.deinit(allocator);

    dm.set(0, 1, 1.0);
    dm.set(0, 2, 2.0);
    dm.set(1, 2, 1.5);
    dm.set(2, 3, 3.0);

    try std.testing.expectApproxEqAbs(@as(f64, 1.0), dm.get(0, 1), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), dm.get(1, 0), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), dm.get(0, 0), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), dm.get(3, 3), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), dm.get(0, 2), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), dm.get(2, 1), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), dm.get(3, 2), 1e-10);
}

test "distance matrix from flat coords" {
    const allocator = std.testing.allocator;
    const coords = [_]f64{ 0, 0, 3, 0, 0, 4 };
    var dm = try distanceMatrixFromFlat(&coords, 3, 2, allocator);
    defer dm.deinit(allocator);

    try std.testing.expectApproxEqAbs(@as(f64, 3.0), dm.get(0, 1), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), dm.get(0, 2), 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 5.0), dm.get(1, 2), 1e-10);
}

test "simplex vertices roundtrip" {
    var vertices: [2]usize = undefined;

    getSimplexVertices(5, 1, 4, &vertices);
    try std.testing.expectEqual(@as(usize, 3), vertices[0]);
    try std.testing.expectEqual(@as(usize, 2), vertices[1]);

    getSimplexVertices(0, 1, 4, &vertices);
    try std.testing.expectEqual(@as(usize, 1), vertices[0]);
    try std.testing.expectEqual(@as(usize, 0), vertices[1]);

    getSimplexVertices(3, 1, 4, &vertices);
    try std.testing.expectEqual(@as(usize, 3), vertices[0]);
    try std.testing.expectEqual(@as(usize, 0), vertices[1]);
}

test "simplex index roundtrip" {
    const n: usize = 6;
    const dim: usize = 2;
    const num_simplices = binomial(n, dim + 1);

    for (0..num_simplices) |idx| {
        var vertices: [3]usize = undefined;
        getSimplexVertices(idx, dim, n, &vertices);
        const recovered = getSimplexIndex(&vertices, dim);
        try std.testing.expectEqual(idx, recovered);
    }
}

test "simplex diameter" {
    const allocator = std.testing.allocator;
    var dm = try DistanceMatrix.init(4, allocator);
    defer dm.deinit(allocator);

    dm.set(0, 1, 1.0);
    dm.set(0, 2, 2.0);
    dm.set(0, 3, 3.0);
    dm.set(1, 2, 1.5);
    dm.set(1, 3, 2.5);
    dm.set(2, 3, 1.0);

    const edge_diam = getSimplexDiameter(5, 1, 4, dm);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), edge_diam, 1e-10);

    // Triangle {3,2,1}: index = C(3,3)+C(2,2)+C(1,1) = 1+1+1 = 3
    const tri_diam = getSimplexDiameter(3, 2, 4, dm);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), tri_diam, 1e-10);
}

test "persistence of 3 equidistant points" {
    const allocator = std.testing.allocator;

    var dm = try DistanceMatrix.init(3, allocator);
    defer dm.deinit(allocator);

    dm.set(0, 1, 1.0);
    dm.set(0, 2, 1.0);
    dm.set(1, 2, 1.0);

    var diagram = try computePersistence(dm, .{ .max_dimension = 1 }, allocator);
    defer diagram.deinit();

    const betti = try diagram.bettiNumbers(allocator);
    defer allocator.free(betti);

    try std.testing.expectEqual(@as(usize, 1), betti[0]);
}

test "persistence of 4 points on square" {
    const allocator = std.testing.allocator;

    var dm = try DistanceMatrix.init(4, allocator);
    defer dm.deinit(allocator);

    dm.set(0, 1, 1.0);
    dm.set(1, 2, 1.0);
    dm.set(2, 3, 1.0);
    dm.set(0, 3, 1.0);
    dm.set(0, 2, @sqrt(2.0));
    dm.set(1, 3, @sqrt(2.0));

    var diagram = try computePersistence(dm, .{ .max_dimension = 1 }, allocator);
    defer diagram.deinit();

    const betti = try diagram.bettiNumbers(allocator);
    defer allocator.free(betti);

    try std.testing.expectEqual(@as(usize, 1), betti[0]);
}

test "persistence pair properties" {
    const p1 = PersistencePair{ .birth = 1.0, .death = 3.0, .dimension = 1 };
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), p1.persistence(), 1e-10);
    try std.testing.expect(!p1.isEssential());

    const p2 = PersistencePair{ .birth = 0.0, .death = std.math.inf(f64), .dimension = 0 };
    try std.testing.expect(p2.isEssential());
    try std.testing.expect(p2.persistence() == std.math.inf(f64));
}

test "union-find basic" {
    const allocator = std.testing.allocator;
    var uf = try UnionFind.create(5, allocator);
    defer uf.deinit(allocator);

    try std.testing.expect(uf.find(0) != uf.find(1));
    try std.testing.expect(uf.merge(0, 1));
    try std.testing.expectEqual(uf.find(0), uf.find(1));

    try std.testing.expect(uf.merge(2, 3));
    try std.testing.expectEqual(uf.find(2), uf.find(3));
    try std.testing.expect(uf.find(0) != uf.find(2));

    try std.testing.expect(uf.merge(1, 3));
    try std.testing.expectEqual(uf.find(0), uf.find(3));
    try std.testing.expect(!uf.merge(0, 2));
}

test "coboundary enumerator produces cofacets" {
    const allocator = std.testing.allocator;

    var dm = try DistanceMatrix.init(3, allocator);
    defer dm.deinit(allocator);

    dm.set(0, 1, 1.0);
    dm.set(0, 2, 1.0);
    dm.set(1, 2, 1.0);

    var cob = CoboundaryEnumerator.create(0, 1, 3, &dm);
    var count: usize = 0;
    while (cob.next()) |_| {
        count += 1;
    }
    try std.testing.expect(count >= 1);
}

test "persistence diagram pairs in dimension" {
    const allocator = std.testing.allocator;
    var diagram = PersistenceDiagram.init(allocator);
    defer diagram.deinit();

    try diagram.addPair(0, 1.0, 0);
    try diagram.addPair(0, std.math.inf(f64), 0);
    try diagram.addPair(1.0, 2.0, 1);
    try diagram.addPair(1.5, 3.0, 1);

    const h0_pairs = try diagram.pairsInDimension(0, allocator);
    defer allocator.free(h0_pairs);
    try std.testing.expectEqual(@as(usize, 2), h0_pairs.len);

    const h1_pairs = try diagram.pairsInDimension(1, allocator);
    defer allocator.free(h1_pairs);
    try std.testing.expectEqual(@as(usize, 2), h1_pairs.len);

    try std.testing.expectEqual(@as(usize, 1), diagram.finitePairsCount(0));
    try std.testing.expectEqual(@as(usize, 2), diagram.finitePairsCount(1));
}

test "empty point cloud" {
    const allocator = std.testing.allocator;
    var dm = try DistanceMatrix.init(0, allocator);
    defer dm.deinit(allocator);

    var diagram = try computePersistence(dm, .{ .max_dimension = 1 }, allocator);
    defer diagram.deinit();

    try std.testing.expectEqual(@as(usize, 0), diagram.pairs.items.len);
}

test "single point" {
    const allocator = std.testing.allocator;
    var dm = try DistanceMatrix.init(1, allocator);
    defer dm.deinit(allocator);

    var diagram = try computePersistence(dm, .{ .max_dimension = 1 }, allocator);
    defer diagram.deinit();

    const betti = try diagram.bettiNumbers(allocator);
    defer allocator.free(betti);
    try std.testing.expectEqual(@as(usize, 1), betti[0]);
}

test "two points" {
    const allocator = std.testing.allocator;
    var dm = try DistanceMatrix.init(2, allocator);
    defer dm.deinit(allocator);

    dm.set(0, 1, 5.0);

    var diagram = try computePersistence(dm, .{ .max_dimension = 1 }, allocator);
    defer diagram.deinit();

    const betti = try diagram.bettiNumbers(allocator);
    defer allocator.free(betti);
    try std.testing.expectEqual(@as(usize, 1), betti[0]);

    var found_finite = false;
    for (diagram.pairs.items) |p| {
        if (p.dimension == 0 and p.death != std.math.inf(f64)) {
            try std.testing.expectApproxEqAbs(@as(f64, 5.0), p.death, 1e-10);
            found_finite = true;
        }
    }
    try std.testing.expect(found_finite);
}

test "max edge length threshold" {
    const allocator = std.testing.allocator;
    var dm = try DistanceMatrix.init(3, allocator);
    defer dm.deinit(allocator);

    dm.set(0, 1, 1.0);
    dm.set(0, 2, 10.0);
    dm.set(1, 2, 10.0);

    var diagram = try computePersistence(dm, .{
        .max_dimension = 0,
        .max_edge_length = 5.0,
    }, allocator);
    defer diagram.deinit();

    const betti = try diagram.bettiNumbers(allocator);
    defer allocator.free(betti);
    try std.testing.expectEqual(@as(usize, 2), betti[0]);
}

test "persistence diagram betti numbers" {
    const allocator = std.testing.allocator;
    var diagram = PersistenceDiagram.init(allocator);
    defer diagram.deinit();

    try diagram.addPair(0, std.math.inf(f64), 0);
    try diagram.addPair(0, std.math.inf(f64), 0);
    try diagram.addPair(0, 1.0, 0);
    try diagram.addPair(1.0, std.math.inf(f64), 1);

    const betti = try diagram.bettiNumbers(allocator);
    defer allocator.free(betti);

    try std.testing.expectEqual(@as(usize, 2), betti[0]);
    try std.testing.expectEqual(@as(usize, 1), betti[1]);
}
