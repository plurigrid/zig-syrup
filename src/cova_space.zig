//! Computational Topology: Simplicial & Cubical Complexes with Homology
//!
//! Zig port of the cova-space Rust crate (https://github.com/harnesslabs/cova).
//! Leverages Zig's comptime generics, explicit allocators, and error unions.
//!
//! Core types:
//!   - Simplex: k-dimensional simplex defined by sorted vertices
//!   - Cube: k-dimensional cube defined by 2^k vertices
//!   - Complex(T): generic cell complex with automatic closure
//!   - Chain(T, R): formal sums with coefficients in ring R
//!   - Homology(R): result of homology computation (Betti numbers + generators)
//!
//! Field types for coefficients:
//!   - Z2: integers mod 2 (Boolean field)
//!   - Rational: exact rational arithmetic

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

// ============================================================================
// Field types for homology computation
// ============================================================================

/// Z/2Z field (Boolean). The simplest field for homology.
pub const Z2 = struct {
    val: u1,

    pub const zero = Z2{ .val = 0 };
    pub const one = Z2{ .val = 1 };

    pub fn add(a: Z2, b: Z2) Z2 {
        return .{ .val = a.val ^ b.val };
    }
    pub fn mul(a: Z2, b: Z2) Z2 {
        return .{ .val = a.val & b.val };
    }
    pub fn neg(a: Z2) Z2 {
        return a; // -1 = 1 in Z/2Z
    }
    pub fn inv(a: Z2) ?Z2 {
        return if (a.val == 1) Z2{ .val = 1 } else null;
    }
    pub fn isZero(a: Z2) bool {
        return a.val == 0;
    }
    pub fn eql(a: Z2, b: Z2) bool {
        return a.val == b.val;
    }
    pub fn fromI32(v: i32) Z2 {
        const m: u1 = @truncate(@as(u32, @bitCast(@mod(v, 2) +% 2)) % 2);
        return .{ .val = m };
    }
    pub fn sub(a: Z2, b: Z2) Z2 {
        return add(a, b); // a - b = a + b in Z/2Z
    }
};

/// Rational number field for exact homology.
pub const Rational = struct {
    num: i64,
    den: i64,

    pub const zero = Rational{ .num = 0, .den = 1 };
    pub const one = Rational{ .num = 1, .den = 1 };

    fn gcd(a_in: i64, b_in: i64) i64 {
        var a = if (a_in < 0) -a_in else a_in;
        var b = if (b_in < 0) -b_in else b_in;
        while (b != 0) {
            const t = b;
            b = @mod(a, b);
            a = t;
        }
        return if (a == 0) 1 else a;
    }

    fn reduce(num: i64, den: i64) Rational {
        if (num == 0) return .{ .num = 0, .den = 1 };
        const g = gcd(num, den);
        const sign: i64 = if (den < 0) -1 else 1;
        return .{ .num = @divTrunc(num * sign, g), .den = @divTrunc(den * sign, g) };
    }

    pub fn add(a: Rational, b: Rational) Rational {
        return reduce(a.num * b.den + b.num * a.den, a.den * b.den);
    }
    pub fn sub(a: Rational, b: Rational) Rational {
        return reduce(a.num * b.den - b.num * a.den, a.den * b.den);
    }
    pub fn mul(a: Rational, b: Rational) Rational {
        return reduce(a.num * b.num, a.den * b.den);
    }
    pub fn neg(a: Rational) Rational {
        return .{ .num = -a.num, .den = a.den };
    }
    pub fn inv(a: Rational) ?Rational {
        if (a.num == 0) return null;
        return reduce(a.den, a.num);
    }
    pub fn isZero(a: Rational) bool {
        return a.num == 0;
    }
    pub fn eql(a: Rational, b: Rational) bool {
        return a.num * b.den == b.num * a.den;
    }
    pub fn fromI32(v: i32) Rational {
        return .{ .num = @intCast(v), .den = 1 };
    }
};

// ============================================================================
// Dense matrix over a generic field (for homology computation)
// ============================================================================

pub fn Matrix(comptime F: type) type {
    return struct {
        const Self = @This();
        data: []F,
        rows: usize,
        cols: usize,
        allocator: Allocator,

        pub fn init(allocator: Allocator, rows: usize, cols: usize) !Self {
            const data = try allocator.alloc(F, rows * cols);
            @memset(data, F.zero);
            return .{ .data = data, .rows = rows, .cols = cols, .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.data);
        }

        pub fn get(self: *const Self, r: usize, c: usize) F {
            return self.data[r * self.cols + c];
        }

        pub fn set(self: *Self, r: usize, c: usize, val: F) void {
            self.data[r * self.cols + c] = val;
        }

        /// Gaussian elimination to row echelon form.
        /// Returns the rank.
        pub fn rowEchelon(self: *Self) usize {
            var pivot_row: usize = 0;
            var col: usize = 0;
            while (col < self.cols and pivot_row < self.rows) {
                // Find pivot
                var found: ?usize = null;
                for (pivot_row..self.rows) |r| {
                    if (!self.get(r, col).isZero()) {
                        found = r;
                        break;
                    }
                }
                if (found) |pr| {
                    // Swap rows
                    if (pr != pivot_row) {
                        for (0..self.cols) |c2| {
                            const tmp = self.get(pivot_row, c2);
                            self.set(pivot_row, c2, self.get(pr, c2));
                            self.set(pr, c2, tmp);
                        }
                    }
                    // Scale pivot row
                    const piv = self.get(pivot_row, col);
                    if (piv.inv()) |piv_inv| {
                        for (0..self.cols) |c2| {
                            self.set(pivot_row, c2, F.mul(self.get(pivot_row, c2), piv_inv));
                        }
                    }
                    // Eliminate below
                    for (pivot_row + 1..self.rows) |r| {
                        const factor = self.get(r, col);
                        if (!factor.isZero()) {
                            for (0..self.cols) |c2| {
                                self.set(r, c2, F.sub(self.get(r, c2), F.mul(factor, self.get(pivot_row, c2))));
                            }
                        }
                    }
                    pivot_row += 1;
                }
                col += 1;
            }
            return pivot_row;
        }

        /// Compute kernel basis vectors. Returns list of column vectors (as slices).
        pub fn kernelBasis(self: *const Self, allocator: Allocator) !std.ArrayList([]F) {
            var work = try Self.init(allocator, self.rows, self.cols);
            defer work.deinit();
            @memcpy(work.data, self.data);

            const rank = work.rowEchelon();

            // Back-substitute to reduced row echelon
            var piv_r: usize = rank;
            while (piv_r > 0) {
                piv_r -= 1;
                // Find pivot column in this row
                var piv_c: usize = 0;
                while (piv_c < work.cols) : (piv_c += 1) {
                    if (!work.get(piv_r, piv_c).isZero()) break;
                }
                if (piv_c >= work.cols) continue;
                // Eliminate above
                for (0..piv_r) |r| {
                    const factor = work.get(r, piv_c);
                    if (!factor.isZero()) {
                        for (0..work.cols) |c2| {
                            work.set(r, c2, F.sub(work.get(r, c2), F.mul(factor, work.get(piv_r, c2))));
                        }
                    }
                }
            }

            // Identify pivot columns
            var pivot_cols = try allocator.alloc(bool, self.cols);
            defer allocator.free(pivot_cols);
            @memset(pivot_cols, false);

            var pivot_col_for_row = try allocator.alloc(usize, rank);
            defer allocator.free(pivot_col_for_row);

            for (0..rank) |r| {
                for (0..work.cols) |c| {
                    if (!work.get(r, c).isZero()) {
                        pivot_cols[c] = true;
                        pivot_col_for_row[r] = c;
                        break;
                    }
                }
            }

            // Free columns give kernel vectors
            var result: std.ArrayList([]F) = .empty;
            for (0..self.cols) |c| {
                if (!pivot_cols[c]) {
                    const vec = try allocator.alloc(F, self.cols);
                    @memset(vec, F.zero);
                    vec[c] = F.one;
                    for (0..rank) |r| {
                        vec[pivot_col_for_row[r]] = F.neg(work.get(r, c));
                    }
                    try result.append(allocator, vec);
                }
            }
            return result;
        }

        /// Compute column space rank (= image dimension).
        pub fn imageRank(self: *const Self, allocator: Allocator) !usize {
            var work = try Self.init(allocator, self.rows, self.cols);
            defer work.deinit();
            @memcpy(work.data, self.data);
            return work.rowEchelon();
        }
    };
}

// ============================================================================
// Simplex
// ============================================================================

pub const Simplex = struct {
    vertices: []const usize,
    dim: usize,
    id: ?usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator, vertices_in: []const usize) !Simplex {
        assert(vertices_in.len > 0);
        const verts = try allocator.dupe(usize, vertices_in);
        std.mem.sort(usize, verts, {}, std.sort.asc(usize));
        // Check distinct
        for (1..verts.len) |i| {
            assert(verts[i] != verts[i - 1]);
        }
        return .{
            .vertices = verts,
            .dim = verts.len - 1,
            .id = null,
            .allocator = allocator,
        };
    }

    pub fn initWithDim(allocator: Allocator, dim: usize, vertices_in: []const usize) !Simplex {
        assert(vertices_in.len == dim + 1);
        return init(allocator, vertices_in);
    }

    pub fn deinit(self: *Simplex) void {
        self.allocator.free(@constCast(self.vertices));
    }

    pub fn clone(self: *const Simplex, allocator: Allocator) !Simplex {
        return .{
            .vertices = try allocator.dupe(usize, self.vertices),
            .dim = self.dim,
            .id = self.id,
            .allocator = allocator,
        };
    }

    pub fn withId(self: *const Simplex, new_id: usize) !Simplex {
        var copy = try self.clone(self.allocator);
        copy.id = new_id;
        return copy;
    }

    pub fn dimension(self: *const Simplex) usize {
        return self.dim;
    }

    pub fn sameContent(self: *const Simplex, other: *const Simplex) bool {
        if (self.dim != other.dim) return false;
        return std.mem.eql(usize, self.vertices, other.vertices);
    }

    /// Compute (dim-1)-dimensional faces by omitting each vertex.
    pub fn faces(self: *const Simplex, allocator: Allocator) !std.ArrayList(Simplex) {
        var result: std.ArrayList(Simplex) = .empty;
        if (self.dim == 0) return result;
        for (0..self.vertices.len) |skip| {
            const face_verts = try allocator.alloc(usize, self.vertices.len - 1);
            var j: usize = 0;
            for (0..self.vertices.len) |i| {
                if (i != skip) {
                    face_verts[j] = self.vertices[i];
                    j += 1;
                }
            }
            try result.append(allocator, .{
                .vertices = face_verts,
                .dim = self.dim - 1,
                .id = null,
                .allocator = allocator,
            });
        }
        return result;
    }

    /// Boundary with orientations: (-1)^i for omitting vertex i.
    pub fn boundaryWithOrientations(self: *const Simplex, allocator: Allocator) !std.ArrayList(FaceOrientation(Simplex)) {
        var result: std.ArrayList(FaceOrientation(Simplex)) = .empty;
        if (self.dim == 0) return result;
        for (0..self.vertices.len) |i| {
            const face_verts = try allocator.alloc(usize, self.vertices.len - 1);
            var j: usize = 0;
            for (0..self.vertices.len) |k| {
                if (k != i) {
                    face_verts[j] = self.vertices[k];
                    j += 1;
                }
            }
            const orientation: i32 = if (i % 2 == 0) 1 else -1;
            try result.append(allocator, .{
                .face = .{
                    .vertices = face_verts,
                    .dim = self.dim - 1,
                    .id = null,
                    .allocator = allocator,
                },
                .orientation = orientation,
            });
        }
        return result;
    }

    /// Lexicographic ordering for stable sorting.
    pub fn order(self: *const Simplex, other: *const Simplex) std.math.Order {
        const min_len = @min(self.vertices.len, other.vertices.len);
        for (0..min_len) |i| {
            if (self.vertices[i] < other.vertices[i]) return .lt;
            if (self.vertices[i] > other.vertices[i]) return .gt;
        }
        return std.math.order(self.vertices.len, other.vertices.len);
    }

    pub fn lessThan(_: void, a: Simplex, b: Simplex) bool {
        return a.order(&b) == .lt;
    }
};

// ============================================================================
// Cube
// ============================================================================

pub const Cube = struct {
    vertices: []const usize,
    dim: usize,
    id: ?usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator, dim: usize, vertices_in: []const usize) !Cube {
        const expected: usize = @as(usize, 1) << @intCast(dim);
        assert(vertices_in.len == expected);
        return .{
            .vertices = try allocator.dupe(usize, vertices_in),
            .dim = dim,
            .id = null,
            .allocator = allocator,
        };
    }

    pub fn vertex(allocator: Allocator, v: usize) !Cube {
        return init(allocator, 0, &[_]usize{v});
    }

    pub fn edge(allocator: Allocator, v0: usize, v1: usize) !Cube {
        return init(allocator, 1, &[_]usize{ v0, v1 });
    }

    pub fn square(allocator: Allocator, vs: [4]usize) !Cube {
        return init(allocator, 2, &vs);
    }

    pub fn deinit(self: *Cube) void {
        self.allocator.free(@constCast(self.vertices));
    }

    pub fn clone(self: *const Cube, allocator: Allocator) !Cube {
        return .{
            .vertices = try allocator.dupe(usize, self.vertices),
            .dim = self.dim,
            .id = self.id,
            .allocator = allocator,
        };
    }

    pub fn withId(self: *const Cube, new_id: usize) !Cube {
        var copy = try self.clone(self.allocator);
        copy.id = new_id;
        return copy;
    }

    pub fn dimension(self: *const Cube) usize {
        return self.dim;
    }

    pub fn sameContent(self: *const Cube, other: *const Cube) bool {
        if (self.dim != other.dim) return false;
        return std.mem.eql(usize, self.vertices, other.vertices);
    }

    /// Compute (dim-1)-dimensional faces by fixing each coordinate to 0 and 1.
    pub fn faces(self: *const Cube, allocator: Allocator) !std.ArrayList(Cube) {
        var result: std.ArrayList(Cube) = .empty;
        if (self.dim == 0) return result;
        const k = self.dim;
        const face_size: usize = @as(usize, 1) << @intCast(k - 1);
        for (0..k) |coord| {
            for ([_]u1{ 0, 1 }) |bit_value| {
                const face_verts = try allocator.alloc(usize, face_size);
                var j: usize = 0;
                for (0..self.vertices.len) |vi| {
                    if (((vi >> @intCast(coord)) & 1) == bit_value) {
                        face_verts[j] = self.vertices[vi];
                        j += 1;
                    }
                }
                if (j == face_size) {
                    try result.append(allocator, .{
                        .vertices = face_verts,
                        .dim = k - 1,
                        .id = null,
                        .allocator = allocator,
                    });
                } else {
                    allocator.free(face_verts);
                }
            }
        }
        return result;
    }

    /// Cubical boundary: sum_i (-1)^i (face_{x_i=1} - face_{x_i=0}).
    pub fn boundaryWithOrientations(self: *const Cube, allocator: Allocator) !std.ArrayList(FaceOrientation(Cube)) {
        var result: std.ArrayList(FaceOrientation(Cube)) = .empty;
        if (self.dim == 0) return result;
        const k = self.dim;
        const face_size: usize = @as(usize, 1) << @intCast(k - 1);
        for (0..k) |coord| {
            inline for (.{ .{ @as(u1, 0), @as(i32, -1) }, .{ @as(u1, 1), @as(i32, 1) } }) |pair| {
                const bit_value = pair[0];
                const base_sign = pair[1];
                const face_verts = try allocator.alloc(usize, face_size);
                var j: usize = 0;
                for (0..self.vertices.len) |vi| {
                    if (((vi >> @intCast(coord)) & 1) == bit_value) {
                        face_verts[j] = self.vertices[vi];
                        j += 1;
                    }
                }
                if (j == face_size) {
                    const orientation: i32 = base_sign * (if (coord % 2 == 0) @as(i32, 1) else @as(i32, -1));
                    try result.append(allocator, .{
                        .face = .{
                            .vertices = face_verts,
                            .dim = k - 1,
                            .id = null,
                            .allocator = allocator,
                        },
                        .orientation = orientation,
                    });
                } else {
                    allocator.free(face_verts);
                }
            }
        }
        return result;
    }

    pub fn order(self: *const Cube, other: *const Cube) std.math.Order {
        const dim_cmp = std.math.order(self.dim, other.dim);
        if (dim_cmp != .eq) return dim_cmp;
        const min_len = @min(self.vertices.len, other.vertices.len);
        for (0..min_len) |i| {
            if (self.vertices[i] < other.vertices[i]) return .lt;
            if (self.vertices[i] > other.vertices[i]) return .gt;
        }
        return std.math.order(self.vertices.len, other.vertices.len);
    }

    pub fn lessThan(_: void, a: Cube, b: Cube) bool {
        return a.order(&b) == .lt;
    }
};

// ============================================================================
// Generic helpers
// ============================================================================

pub fn FaceOrientation(comptime T: type) type {
    return struct {
        face: T,
        orientation: i32,
    };
}

// ============================================================================
// Complex(T) — generic cell complex
// ============================================================================

pub fn Complex(comptime T: type) type {
    return struct {
        const Self = @This();

        elements: std.AutoHashMap(usize, T),
        /// Adjacency: for each element id, store ids of its direct faces.
        face_rel: std.AutoHashMap(usize, std.ArrayList(usize)),
        /// Reverse: for each element id, store ids of elements it is a face of.
        coface_rel: std.AutoHashMap(usize, std.ArrayList(usize)),
        next_id: usize,
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{
                .elements = std.AutoHashMap(usize, T).init(allocator),
                .face_rel = std.AutoHashMap(usize, std.ArrayList(usize)).init(allocator),
                .coface_rel = std.AutoHashMap(usize, std.ArrayList(usize)).init(allocator),
                .next_id = 0,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            // Free all stored elements
            var it = self.elements.iterator();
            while (it.next()) |entry| {
                var elem = entry.value_ptr.*;
                elem.deinit();
            }
            self.elements.deinit();

            var fit = self.face_rel.valueIterator();
            while (fit.next()) |list| {
                var l = list.*;
                l.deinit(self.allocator);
            }
            self.face_rel.deinit();

            var cit = self.coface_rel.valueIterator();
            while (cit.next()) |list| {
                var l = list.*;
                l.deinit(self.allocator);
            }
            self.coface_rel.deinit();
        }

        fn findEquivalent(self: *const Self, element: *const T) ?usize {
            var it = self.elements.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.sameContent(element)) {
                    return entry.key_ptr.*;
                }
            }
            return null;
        }

        /// Add an element with automatic closure (all faces included).
        /// Returns the id assigned to the element.
        pub fn joinElement(self: *Self, element: T) !usize {
            // Dedup check
            if (self.findEquivalent(&element)) |existing_id| {
                // Caller passed ownership; free it.
                var e = element;
                e.deinit();
                return existing_id;
            }

            const eid = self.next_id;
            self.next_id += 1;

            // Compute faces, recursively add them
            var face_list = try element.faces(self.allocator);
            defer face_list.deinit(self.allocator);

            var face_ids: std.ArrayList(usize) = .empty;

            for (face_list.items) |face| {
                const fid = try self.joinElement(face);
                try face_ids.append(self.allocator, fid);
                // Register coface relation
                const cofaces = self.coface_rel.getPtr(fid);
                if (cofaces) |cf| {
                    try cf.append(self.allocator, eid);
                } else {
                    var new_list: std.ArrayList(usize) = .empty;
                    try new_list.append(self.allocator, eid);
                    try self.coface_rel.put(fid, new_list);
                }
            }

            try self.face_rel.put(eid, face_ids);

            // Store element with id set
            var stored = try element.withId(eid);
            _ = &stored;
            // Free the original (caller-owned)
            var orig = element;
            orig.deinit();
            try self.elements.put(eid, stored);

            // Ensure coface entry exists
            if (!self.coface_rel.contains(eid)) {
                const empty_list: std.ArrayList(usize) = .empty;
                try self.coface_rel.put(eid, empty_list);
            }

            return eid;
        }

        pub fn getElement(self: *const Self, id: usize) ?*const T {
            return if (self.elements.getPtr(id)) |ptr| ptr else null;
        }

        pub fn elementsOfDimension(self: *const Self, allocator: Allocator, dim: usize) !std.ArrayList(T) {
            var result: std.ArrayList(T) = .empty;
            var it = self.elements.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.dimension() == dim) {
                    try result.append(allocator, try entry.value_ptr.clone(allocator));
                }
            }
            // Sort for deterministic ordering
            std.mem.sort(T, result.items, {}, T.lessThan);
            return result;
        }

        pub fn maxDimension(self: *const Self) usize {
            var max_d: usize = 0;
            var it = self.elements.iterator();
            while (it.next()) |entry| {
                max_d = @max(max_d, entry.value_ptr.dimension());
            }
            return max_d;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.elements.count() == 0;
        }

        pub fn directFaces(self: *const Self, id: usize) []const usize {
            if (self.face_rel.getPtr(id)) |list| {
                return list.items;
            }
            return &.{};
        }

        pub fn directCofaces(self: *const Self, id: usize) []const usize {
            if (self.coface_rel.getPtr(id)) |list| {
                return list.items;
            }
            return &.{};
        }

        // ----------------------------------------------------------------
        // Homology computation
        // ----------------------------------------------------------------

        /// Build boundary matrix del_k: C_k -> C_{k-1} over field F.
        pub fn boundaryMatrix(self: *const Self, comptime F: type, allocator: Allocator, k: usize) !Matrix(F) {
            var domain = try self.elementsOfDimension(allocator, k);
            defer {
                for (domain.items) |*e| e.deinit();
                domain.deinit(allocator);
            }
            var codomain = try self.elementsOfDimension(allocator, if (k == 0) 0 else k - 1);
            defer {
                for (codomain.items) |*e| e.deinit();
                codomain.deinit(allocator);
            }

            if (k == 0 or domain.items.len == 0 or codomain.items.len == 0) {
                return Matrix(F).init(allocator, codomain.items.len, domain.items.len);
            }

            var mat = try Matrix(F).init(allocator, codomain.items.len, domain.items.len);

            for (domain.items, 0..) |*elem, col| {
                var bnd = try elem.boundaryWithOrientations(allocator);
                defer {
                    for (bnd.items) |*fo| fo.face.deinit();
                    bnd.deinit(allocator);
                }
                for (bnd.items) |*fo| {
                    // Find matching codomain element
                    for (codomain.items, 0..) |*cod, row| {
                        if (fo.face.sameContent(cod)) {
                            mat.set(row, col, F.fromI32(fo.orientation));
                            break;
                        }
                    }
                }
            }

            return mat;
        }

        /// Compute homology H_k over field F.
        pub fn homology(self: *const Self, comptime F: type, allocator: Allocator, k: usize) !Homology(F) {
            var k_elems = try self.elementsOfDimension(allocator, k);
            defer {
                for (k_elems.items) |*e| e.deinit();
                k_elems.deinit(allocator);
            }

            if (k_elems.items.len == 0) {
                return Homology(F).trivial(k);
            }

            // Cycles = ker(del_k)
            var cycle_rank: usize = 0;
            if (k == 0) {
                cycle_rank = k_elems.items.len; // Z_0 = C_0
            } else {
                var del_k = try self.boundaryMatrix(F, allocator, k);
                defer del_k.deinit();
                var ker = try del_k.kernelBasis(allocator);
                defer {
                    for (ker.items) |v| allocator.free(v);
                    ker.deinit(allocator);
                }
                cycle_rank = ker.items.len;
            }

            // Boundaries = im(del_{k+1})
            var del_kp1 = try self.boundaryMatrix(F, allocator, k + 1);
            defer del_kp1.deinit();
            const boundary_rank = try del_kp1.imageRank(allocator);

            const betti = if (cycle_rank >= boundary_rank) cycle_rank - boundary_rank else 0;

            return .{
                .dim = k,
                .betti_number = betti,
            };
        }
    };
}

pub fn Homology(comptime F: type) type {
    _ = F;
    return struct {
        dim: usize,
        betti_number: usize,

        pub fn trivial(dim: usize) @This() {
            return .{ .dim = dim, .betti_number = 0 };
        }
    };
}

// ============================================================================
// Chain(T, R) — formal sums of elements with coefficients
// ============================================================================

pub fn Chain(comptime T: type, comptime R: type) type {
    return struct {
        const Self = @This();
        items: std.ArrayList(T),
        coefficients: std.ArrayList(R),
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{
                .items = .empty,
                .coefficients = .empty,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.items.items) |*item| item.deinit();
            self.items.deinit(self.allocator);
            self.coefficients.deinit(self.allocator);
        }

        pub fn fromSingle(allocator: Allocator, item: T, coeff: R) !Self {
            var s = init(allocator);
            try s.items.append(allocator, item);
            try s.coefficients.append(allocator, coeff);
            return s;
        }

        /// Add another chain, combining like terms and removing zeros.
        pub fn addChain(self: *Self, other: *Self) !void {
            for (other.items.items, other.coefficients.items) |*o_item, o_coeff| {
                var found = false;
                for (self.items.items, 0..) |*s_item, idx| {
                    if (o_item.sameContent(s_item)) {
                        self.coefficients.items[idx] = R.add(self.coefficients.items[idx], o_coeff);
                        o_item.deinit();
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try self.items.append(self.allocator, o_item.*);
                    try self.coefficients.append(self.allocator, o_coeff);
                }
            }
            // Remove zero terms
            var i: usize = 0;
            while (i < self.coefficients.items.len) {
                if (self.coefficients.items[i].isZero()) {
                    self.items.items[i].deinit();
                    _ = self.items.orderedRemove(i);
                    _ = self.coefficients.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
            // Clear other without freeing (items moved or freed above)
            other.items.clearRetainingCapacity();
            other.coefficients.clearRetainingCapacity();
        }

        /// Compute boundary of this chain (requires elements to have boundaryWithOrientations).
        pub fn boundary(self: *const Self, allocator: Allocator) !Self {
            var result = init(allocator);
            for (self.items.items, self.coefficients.items) |*item, coeff| {
                var bnd = try item.boundaryWithOrientations(allocator);
                defer bnd.deinit(allocator);
                for (bnd.items) |*fo| {
                    const scaled_coeff = R.mul(coeff, R.fromI32(fo.orientation));
                    if (scaled_coeff.isZero()) {
                        fo.face.deinit();
                        continue;
                    }
                    // Try to combine with existing
                    var found = false;
                    for (result.items.items, 0..) |*ri, idx| {
                        if (fo.face.sameContent(ri)) {
                            result.coefficients.items[idx] = R.add(result.coefficients.items[idx], scaled_coeff);
                            fo.face.deinit();
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try result.items.append(allocator, fo.face);
                        try result.coefficients.append(allocator, scaled_coeff);
                    }
                }
            }
            // Remove zeros
            var i: usize = 0;
            while (i < result.coefficients.items.len) {
                if (result.coefficients.items[i].isZero()) {
                    result.items.items[i].deinit();
                    _ = result.items.orderedRemove(i);
                    _ = result.coefficients.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
            return result;
        }
    };
}

// Type aliases
pub const SimplicialComplex = Complex(Simplex);
pub const CubicalComplex = Complex(Cube);

// ============================================================================
// Tests
// ============================================================================

test "simplex construction" {
    const alloc = std.testing.allocator;
    var s = try Simplex.init(alloc, &[_]usize{ 2, 0, 1 });
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 2), s.dim);
    try std.testing.expectEqualSlices(usize, &[_]usize{ 0, 1, 2 }, s.vertices);
    try std.testing.expectEqual(@as(?usize, null), s.id);
}

test "simplex faces" {
    const alloc = std.testing.allocator;
    var s = try Simplex.init(alloc, &[_]usize{ 0, 1, 2 });
    defer s.deinit();
    var fs = try s.faces(alloc);
    defer {
        for (fs.items) |*f| f.deinit();
        fs.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 3), fs.items.len);
    for (fs.items) |*f| {
        try std.testing.expectEqual(@as(usize, 1), f.dim);
    }
}

test "simplex same_content" {
    const alloc = std.testing.allocator;
    var s1 = try Simplex.init(alloc, &[_]usize{ 0, 1 });
    defer s1.deinit();
    var s2 = try Simplex.init(alloc, &[_]usize{ 1, 0 }); // reversed
    defer s2.deinit();
    var s3 = try Simplex.init(alloc, &[_]usize{ 0, 2 });
    defer s3.deinit();
    try std.testing.expect(s1.sameContent(&s2));
    try std.testing.expect(!s1.sameContent(&s3));
}

test "cube creation" {
    const alloc = std.testing.allocator;
    var c = try Cube.edge(alloc, 10, 11);
    defer c.deinit();
    try std.testing.expectEqual(@as(usize, 1), c.dim);
    try std.testing.expectEqual(@as(usize, 2), c.vertices.len);
}

test "cube faces" {
    const alloc = std.testing.allocator;
    var sq = try Cube.square(alloc, .{ 0, 1, 2, 3 });
    defer sq.deinit();
    var fs = try sq.faces(alloc);
    defer {
        for (fs.items) |*f| f.deinit();
        fs.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 4), fs.items.len);
    for (fs.items) |*f| {
        try std.testing.expectEqual(@as(usize, 1), f.dim);
    }
}

test "simplicial complex: triangle closure" {
    const alloc = std.testing.allocator;
    var cx = SimplicialComplex.init(alloc);
    defer cx.deinit();

    const tri = try Simplex.initWithDim(alloc, 2, &[_]usize{ 0, 1, 2 });
    _ = try cx.joinElement(tri);

    var d2 = try cx.elementsOfDimension(alloc, 2);
    defer {
        for (d2.items) |*e| e.deinit();
        d2.deinit(alloc);
    }
    var d1 = try cx.elementsOfDimension(alloc, 1);
    defer {
        for (d1.items) |*e| e.deinit();
        d1.deinit(alloc);
    }
    var d0 = try cx.elementsOfDimension(alloc, 0);
    defer {
        for (d0.items) |*e| e.deinit();
        d0.deinit(alloc);
    }

    try std.testing.expectEqual(@as(usize, 1), d2.items.len);
    try std.testing.expectEqual(@as(usize, 3), d1.items.len);
    try std.testing.expectEqual(@as(usize, 3), d0.items.len);
}

test "simplicial complex: deduplication" {
    const alloc = std.testing.allocator;
    var cx = SimplicialComplex.init(alloc);
    defer cx.deinit();

    const e1 = try Simplex.init(alloc, &[_]usize{ 0, 1 });
    const id1 = try cx.joinElement(e1);
    const e2 = try Simplex.init(alloc, &[_]usize{ 0, 1 });
    const id2 = try cx.joinElement(e2);

    try std.testing.expectEqual(id1, id2);
}

test "cubical complex: square closure" {
    const alloc = std.testing.allocator;
    var cx = CubicalComplex.init(alloc);
    defer cx.deinit();

    const sq = try Cube.square(alloc, .{ 0, 1, 2, 3 });
    _ = try cx.joinElement(sq);

    var d2 = try cx.elementsOfDimension(alloc, 2);
    defer {
        for (d2.items) |*e| e.deinit();
        d2.deinit(alloc);
    }
    var d1 = try cx.elementsOfDimension(alloc, 1);
    defer {
        for (d1.items) |*e| e.deinit();
        d1.deinit(alloc);
    }
    var d0 = try cx.elementsOfDimension(alloc, 0);
    defer {
        for (d0.items) |*e| e.deinit();
        d0.deinit(alloc);
    }

    try std.testing.expectEqual(@as(usize, 1), d2.items.len);
    try std.testing.expectEqual(@as(usize, 4), d1.items.len);
    try std.testing.expectEqual(@as(usize, 4), d0.items.len);
}

test "homology: point (Z2)" {
    const alloc = std.testing.allocator;
    var cx = SimplicialComplex.init(alloc);
    defer cx.deinit();

    const pt = try Simplex.init(alloc, &[_]usize{0});
    _ = try cx.joinElement(pt);

    const h0 = try cx.homology(Z2, alloc, 0);
    try std.testing.expectEqual(@as(usize, 1), h0.betti_number);

    const h1 = try cx.homology(Z2, alloc, 1);
    try std.testing.expectEqual(@as(usize, 0), h1.betti_number);
}

test "homology: circle (triangle boundary, Z2)" {
    const alloc = std.testing.allocator;
    var cx = SimplicialComplex.init(alloc);
    defer cx.deinit();

    const e01 = try Simplex.init(alloc, &[_]usize{ 0, 1 });
    _ = try cx.joinElement(e01);
    const e12 = try Simplex.init(alloc, &[_]usize{ 1, 2 });
    _ = try cx.joinElement(e12);
    const e02 = try Simplex.init(alloc, &[_]usize{ 0, 2 });
    _ = try cx.joinElement(e02);

    const h0 = try cx.homology(Z2, alloc, 0);
    try std.testing.expectEqual(@as(usize, 1), h0.betti_number);

    const h1 = try cx.homology(Z2, alloc, 1);
    try std.testing.expectEqual(@as(usize, 1), h1.betti_number);
}

test "homology: filled triangle (Z2)" {
    const alloc = std.testing.allocator;
    var cx = SimplicialComplex.init(alloc);
    defer cx.deinit();

    const tri = try Simplex.initWithDim(alloc, 2, &[_]usize{ 0, 1, 2 });
    _ = try cx.joinElement(tri);

    const h0 = try cx.homology(Z2, alloc, 0);
    try std.testing.expectEqual(@as(usize, 1), h0.betti_number);

    const h1 = try cx.homology(Z2, alloc, 1);
    try std.testing.expectEqual(@as(usize, 0), h1.betti_number);
}

test "homology: sphere surface S2 (Z2)" {
    const alloc = std.testing.allocator;
    var cx = SimplicialComplex.init(alloc);
    defer cx.deinit();

    // Tetrahedron boundary = 4 triangles
    const f1 = try Simplex.initWithDim(alloc, 2, &[_]usize{ 0, 1, 2 });
    _ = try cx.joinElement(f1);
    const f2 = try Simplex.initWithDim(alloc, 2, &[_]usize{ 0, 1, 3 });
    _ = try cx.joinElement(f2);
    const f3 = try Simplex.initWithDim(alloc, 2, &[_]usize{ 0, 2, 3 });
    _ = try cx.joinElement(f3);
    const f4 = try Simplex.initWithDim(alloc, 2, &[_]usize{ 1, 2, 3 });
    _ = try cx.joinElement(f4);

    const h0 = try cx.homology(Z2, alloc, 0);
    try std.testing.expectEqual(@as(usize, 1), h0.betti_number);

    const h1 = try cx.homology(Z2, alloc, 1);
    try std.testing.expectEqual(@as(usize, 0), h1.betti_number);

    const h2 = try cx.homology(Z2, alloc, 2);
    try std.testing.expectEqual(@as(usize, 1), h2.betti_number);
}

test "homology: circle (Rational)" {
    const alloc = std.testing.allocator;
    var cx = SimplicialComplex.init(alloc);
    defer cx.deinit();

    const e01 = try Simplex.init(alloc, &[_]usize{ 0, 1 });
    _ = try cx.joinElement(e01);
    const e12 = try Simplex.init(alloc, &[_]usize{ 1, 2 });
    _ = try cx.joinElement(e12);
    const e02 = try Simplex.init(alloc, &[_]usize{ 0, 2 });
    _ = try cx.joinElement(e02);

    const h0 = try cx.homology(Rational, alloc, 0);
    try std.testing.expectEqual(@as(usize, 1), h0.betti_number);

    const h1 = try cx.homology(Rational, alloc, 1);
    try std.testing.expectEqual(@as(usize, 1), h1.betti_number);
}

test "chain: boundary squared is zero (simplicial)" {
    const alloc = std.testing.allocator;
    var cx = SimplicialComplex.init(alloc);
    defer cx.deinit();

    const tri = try Simplex.initWithDim(alloc, 2, &[_]usize{ 0, 1, 2 });
    const tri_id = try cx.joinElement(tri);

    const tri_elem = cx.getElement(tri_id).?;
    const tri_copy = try tri_elem.clone(alloc);

    var chain = try Chain(Simplex, Rational).fromSingle(alloc, tri_copy, Rational.one);
    defer chain.deinit();

    var bnd1 = try chain.boundary(alloc);
    defer bnd1.deinit();

    var bnd2 = try bnd1.boundary(alloc);
    defer bnd2.deinit();

    // del^2 = 0
    try std.testing.expectEqual(@as(usize, 0), bnd2.items.items.len);
}

test "cubical homology: filled square (Z2)" {
    const alloc = std.testing.allocator;
    var cx = CubicalComplex.init(alloc);
    defer cx.deinit();

    const sq = try Cube.square(alloc, .{ 0, 1, 2, 3 });
    _ = try cx.joinElement(sq);

    const h0 = try cx.homology(Z2, alloc, 0);
    try std.testing.expectEqual(@as(usize, 1), h0.betti_number);

    const h1 = try cx.homology(Z2, alloc, 1);
    try std.testing.expectEqual(@as(usize, 0), h1.betti_number);
}

test "cubical homology: square boundary / circle (Z2)" {
    const alloc = std.testing.allocator;
    var cx = CubicalComplex.init(alloc);
    defer cx.deinit();

    // 4 edges forming a cycle
    const e1 = try Cube.edge(alloc, 0, 1);
    _ = try cx.joinElement(e1);
    const e2 = try Cube.edge(alloc, 1, 2);
    _ = try cx.joinElement(e2);
    const e3 = try Cube.edge(alloc, 2, 3);
    _ = try cx.joinElement(e3);
    const e4 = try Cube.edge(alloc, 3, 0);
    _ = try cx.joinElement(e4);

    const h0 = try cx.homology(Z2, alloc, 0);
    try std.testing.expectEqual(@as(usize, 1), h0.betti_number);

    const h1 = try cx.homology(Z2, alloc, 1);
    try std.testing.expectEqual(@as(usize, 1), h1.betti_number);
}

test "Z2 arithmetic" {
    try std.testing.expect(Z2.add(Z2.one, Z2.one).isZero());
    try std.testing.expect(Z2.mul(Z2.one, Z2.one).eql(Z2.one));
    try std.testing.expect(Z2.neg(Z2.one).eql(Z2.one));
    try std.testing.expect(Z2.fromI32(-1).eql(Z2.one));
}

test "Rational arithmetic" {
    const half = Rational{ .num = 1, .den = 2 };
    const third = Rational{ .num = 1, .den = 3 };
    const sum = Rational.add(half, third);
    try std.testing.expect(sum.eql(Rational{ .num = 5, .den = 6 }));
    const neg = Rational.neg(half);
    try std.testing.expect(neg.eql(Rational{ .num = -1, .den = 2 }));
    const prod = Rational.mul(half, third);
    try std.testing.expect(prod.eql(Rational{ .num = 1, .den = 6 }));
    const inv_half = Rational.inv(half).?;
    try std.testing.expect(inv_half.eql(Rational{ .num = 2, .den = 1 }));
}

test "Matrix kernel (Z2)" {
    const alloc = std.testing.allocator;
    // 2x3 matrix: [[1,0,1],[0,1,1]] over Z2
    // kernel should be span{(1,1,1)}
    var m = try Matrix(Z2).init(alloc, 2, 3);
    defer m.deinit();
    m.set(0, 0, Z2.one);
    m.set(0, 2, Z2.one);
    m.set(1, 1, Z2.one);
    m.set(1, 2, Z2.one);

    var ker = try m.kernelBasis(alloc);
    defer {
        for (ker.items) |v| alloc.free(v);
        ker.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 1), ker.items.len);
    // The kernel vector: col 2 is free, so vec = (1,1,1) in Z2
    try std.testing.expect(ker.items[0][0].eql(Z2.one));
    try std.testing.expect(ker.items[0][1].eql(Z2.one));
    try std.testing.expect(ker.items[0][2].eql(Z2.one));
}
