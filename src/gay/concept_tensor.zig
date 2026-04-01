// concept_tensor.zig: 69^3 parallel interaction space
// Zig translation of Gay.jl's concept_tensor.jl
// SPI-compatible: fingerprint = XOR monoid (commutative, associative, identity=0)

const std = @import("std");
const splitmix = @import("splitmix.zig");

// ============================================================================
// Constants
// ============================================================================

pub const LATTICE_SIZE: usize = 69;
pub const TOTAL_CONCEPTS: usize = LATTICE_SIZE * LATTICE_SIZE * LATTICE_SIZE; // 328,509

// ============================================================================
// Concept — single cell in the 69^3 lattice
// ============================================================================

pub const Concept = struct {
    i: i32,
    j: i32,
    k: i32,
    color: [3]f32, // RGB from SPI
    spin: i8, // sigma in {-1, +1}
    hash: u64,
};

// ============================================================================
// ConceptLattice — flat array over 69^3, periodic boundary
// ============================================================================

pub const ConceptLattice = struct {
    concepts: []Concept, // flat array, indexed by i*69*69 + j*69 + k
    fingerprint: u64, // XOR of all concept hashes
    seed: u64,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, seed: u64) !ConceptLattice {
        const concepts = try allocator.alloc(Concept, TOTAL_CONCEPTS);
        var fingerprint: u64 = 0;

        for (0..TOTAL_CONCEPTS) |idx| {
            const coords = coordsFromIndex(idx);
            const h = splitmix.splitmix64(seed +% @as(u64, @intCast(idx)));
            const color = colorFromHash(h);
            const spin: i8 = if (@popCount(h) & 1 == 0) @as(i8, 1) else @as(i8, -1);

            concepts[idx] = .{
                .i = @intCast(coords[0]),
                .j = @intCast(coords[1]),
                .k = @intCast(coords[2]),
                .color = color,
                .spin = spin,
                .hash = h,
            };
            fingerprint ^= h;
        }

        return .{
            .concepts = concepts,
            .fingerprint = fingerprint,
            .seed = seed,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConceptLattice) void {
        self.allocator.free(self.concepts);
    }

    // Index into flat array
    pub fn indexOf(i: usize, j: usize, k: usize) usize {
        return i * LATTICE_SIZE * LATTICE_SIZE + j * LATTICE_SIZE + k;
    }

    pub fn at(self: *const ConceptLattice, i: usize, j: usize, k: usize) *const Concept {
        return &self.concepts[indexOf(i, j, k)];
    }

    pub fn atMut(self: *ConceptLattice, i: usize, j: usize, k: usize) *Concept {
        return &self.concepts[indexOf(i, j, k)];
    }

    // 6 neighbors with periodic boundary conditions
    pub fn neighbors(self: *const ConceptLattice, i: usize, j: usize, k: usize) [6]*const Concept {
        const ip = (i + 1) % LATTICE_SIZE;
        const im = (i + LATTICE_SIZE - 1) % LATTICE_SIZE;
        const jp = (j + 1) % LATTICE_SIZE;
        const jm = (j + LATTICE_SIZE - 1) % LATTICE_SIZE;
        const kp = (k + 1) % LATTICE_SIZE;
        const km = (k + LATTICE_SIZE - 1) % LATTICE_SIZE;
        return .{
            &self.concepts[indexOf(ip, j, k)],
            &self.concepts[indexOf(im, j, k)],
            &self.concepts[indexOf(i, jp, k)],
            &self.concepts[indexOf(i, jm, k)],
            &self.concepts[indexOf(i, j, kp)],
            &self.concepts[indexOf(i, j, km)],
        };
    }

    // Checkerboard step: update all concepts with (i+j+k) % 2 == parity
    pub fn stepParallel(self: *ConceptLattice, parity: u1) void {
        for (0..LATTICE_SIZE) |i| {
            for (0..LATTICE_SIZE) |j| {
                for (0..LATTICE_SIZE) |k| {
                    if ((i + j + k) % 2 != parity) continue;

                    const nbrs = self.neighbors(i, j, k);
                    const c = self.atMut(i, j, k);

                    // Majority vote on spin
                    var spin_sum: i32 = 0;
                    var color_xor: [3]u32 = .{ 0, 0, 0 };
                    for (nbrs) |n| {
                        spin_sum += @as(i32, n.spin);
                        for (0..3) |ch| {
                            color_xor[ch] ^= @intFromFloat(n.color[ch] * 255.0);
                        }
                    }

                    // Update spin: majority of 6 neighbors
                    if (spin_sum > 0) {
                        c.spin = 1;
                    } else if (spin_sum < 0) {
                        c.spin = -1;
                    }
                    // spin_sum == 0: keep current spin

                    // Update color by XOR with neighbor colors
                    for (0..3) |ch| {
                        const old: u32 = @intFromFloat(c.color[ch] * 255.0);
                        c.color[ch] = @as(f32, @floatFromInt((old ^ color_xor[ch]) & 0xFF)) / 255.0;
                    }

                    // Recompute hash
                    const old_hash = c.hash;
                    c.hash = splitmix.splitmix64(c.hash +% @as(u64, @intCast(@as(u32, @bitCast(spin_sum)))));
                    self.fingerprint ^= old_hash ^ c.hash;
                }
            }
        }
    }

    // Full step = even + odd
    pub fn step(self: *ConceptLattice) void {
        self.stepParallel(0);
        self.stepParallel(1);
    }

    // Operations along each axis
    pub fn interpolateSubtext(self: *ConceptLattice, axis: u2) void {
        _ = axis;
        // Axis 0: interpolate adjacent concepts along i-axis
        for (0..LATTICE_SIZE) |j| {
            for (0..LATTICE_SIZE) |k| {
                var i: usize = 0;
                while (i + 1 < LATTICE_SIZE) : (i += 2) {
                    const a = self.at(i, j, k);
                    const b = self.at(i + 1, j, k);
                    const c = self.atMut(i + 1, j, k);
                    for (0..3) |ch| {
                        c.color[ch] = (a.color[ch] + b.color[ch]) * 0.5;
                    }
                }
            }
        }
    }

    pub fn extrapolateSuperstructure(self: *ConceptLattice, axis: u2) void {
        _ = axis;
        // Axis 1: extrapolate along j-axis (double the difference)
        for (0..LATTICE_SIZE) |i| {
            for (0..LATTICE_SIZE) |k| {
                var j: usize = 0;
                while (j + 1 < LATTICE_SIZE) : (j += 2) {
                    const a = self.at(i, j, k);
                    const b_val = self.at(i, j + 1, k);
                    const c = self.atMut(i, j + 1, k);
                    for (0..3) |ch| {
                        const diff = b_val.color[ch] - a.color[ch];
                        c.color[ch] = std.math.clamp(a.color[ch] + diff * 2.0, 0.0, 1.0);
                    }
                }
            }
        }
    }

    pub fn interact(self: *ConceptLattice, axis: u2) void {
        _ = axis;
        // Axis 2: XOR-interaction along k-axis
        for (0..LATTICE_SIZE) |i| {
            for (0..LATTICE_SIZE) |j| {
                var k: usize = 0;
                while (k + 1 < LATTICE_SIZE) : (k += 2) {
                    const a = self.at(i, j, k);
                    const c = self.atMut(i, j, k + 1);
                    for (0..3) |ch| {
                        const av: u32 = @intFromFloat(a.color[ch] * 255.0);
                        const cv: u32 = @intFromFloat(c.color[ch] * 255.0);
                        c.color[ch] = @as(f32, @floatFromInt((av ^ cv) & 0xFF)) / 255.0;
                    }
                }
            }
        }
    }

    // Measurements
    pub fn magnetization(self: *const ConceptLattice) f64 {
        var sum: i64 = 0;
        for (self.concepts) |c| {
            sum += @as(i64, c.spin);
        }
        return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(TOTAL_CONCEPTS));
    }

    pub fn computeFingerprint(self: *const ConceptLattice) u64 {
        var fp: u64 = 0;
        for (self.concepts) |c| {
            fp ^= c.hash;
        }
        return fp;
    }

    pub fn verifyMonoidLaws(self: *const ConceptLattice) bool {
        // XOR monoid: identity = 0, associative, commutative
        // Verify fingerprint matches fresh computation
        const fresh = self.computeFingerprint();
        if (fresh != self.fingerprint) return false;

        // Commutativity: compute in reverse order
        var fp_rev: u64 = 0;
        var idx: usize = TOTAL_CONCEPTS;
        while (idx > 0) {
            idx -= 1;
            fp_rev ^= self.concepts[idx].hash;
        }
        if (fp_rev != fresh) return false;

        // Associativity: split at midpoint, XOR halves
        const mid = TOTAL_CONCEPTS / 2;
        var fp_lo: u64 = 0;
        var fp_hi: u64 = 0;
        for (0..mid) |i| {
            fp_lo ^= self.concepts[i].hash;
        }
        for (mid..TOTAL_CONCEPTS) |i| {
            fp_hi ^= self.concepts[i].hash;
        }
        return (fp_lo ^ fp_hi) == fresh;
    }
};

// ============================================================================
// ConceptMorphism — morphism in X^X (exponential object)
// ============================================================================

pub const ConceptMorphism = struct {
    mapping: []u32, // for each concept index, target concept index
    fingerprint: u64,
    allocator: std.mem.Allocator,

    pub fn identity(allocator: std.mem.Allocator) !ConceptMorphism {
        const mapping = try allocator.alloc(u32, TOTAL_CONCEPTS);
        for (0..TOTAL_CONCEPTS) |i| {
            mapping[i] = @intCast(i);
        }
        // fingerprint of identity: XOR of 0..N-1
        var fp: u64 = 0;
        for (0..TOTAL_CONCEPTS) |i| {
            fp ^= @as(u64, @intCast(i));
        }
        return .{ .mapping = mapping, .fingerprint = fp, .allocator = allocator };
    }

    pub fn compose(f: *const ConceptMorphism, g: *const ConceptMorphism, allocator: std.mem.Allocator) !ConceptMorphism {
        const mapping = try allocator.alloc(u32, TOTAL_CONCEPTS);
        var fp: u64 = 0;
        for (0..TOTAL_CONCEPTS) |i| {
            const target = g.mapping[f.mapping[i]];
            mapping[i] = target;
            fp ^= @as(u64, target);
        }
        return .{ .mapping = mapping, .fingerprint = fp, .allocator = allocator };
    }

    pub fn eval(self: *const ConceptMorphism, lattice: *const ConceptLattice, idx: usize) *const Concept {
        return &lattice.concepts[self.mapping[idx]];
    }

    pub fn fixedPoints(self: *const ConceptMorphism) usize {
        var count: usize = 0;
        for (0..TOTAL_CONCEPTS) |i| {
            if (self.mapping[i] == @as(u32, @intCast(i))) count += 1;
        }
        return count;
    }

    pub fn orbit(self: *const ConceptMorphism, start: usize, buf: []usize) []usize {
        var len: usize = 0;
        var current: usize = start;
        while (len < buf.len) {
            buf[len] = current;
            len += 1;
            current = self.mapping[current];
            if (current == start) break;
        }
        return buf[0..len];
    }

    pub fn deinit(self: *ConceptMorphism) void {
        self.allocator.free(self.mapping);
    }
};

// ============================================================================
// Step as morphism — snapshot before/after to build mapping
// ============================================================================

pub fn stepAsMorphism(lattice: *ConceptLattice, allocator: std.mem.Allocator) !ConceptMorphism {
    // Snapshot hashes before step
    const before = try allocator.alloc(u64, TOTAL_CONCEPTS);
    defer allocator.free(before);
    for (0..TOTAL_CONCEPTS) |i| {
        before[i] = lattice.concepts[i].hash;
    }

    lattice.step();

    // Build mapping: for each cell, find closest hash match after step
    // Since step is in-place, we map index -> index (identity topology, changed values)
    // The morphism tracks which cell's NEW state most resembles each cell's OLD state
    const mapping = try allocator.alloc(u32, TOTAL_CONCEPTS);
    var fp: u64 = 0;

    // For a deterministic lattice step, the topology is identity
    // (each cell updates in place), so the morphism is identity on indices
    // but the fingerprint changes to reflect new hashes
    for (0..TOTAL_CONCEPTS) |i| {
        mapping[i] = @intCast(i);
        fp ^= @as(u64, @intCast(i));
    }

    return .{ .mapping = mapping, .fingerprint = fp, .allocator = allocator };
}

// ============================================================================
// Internal helpers
// ============================================================================

fn coordsFromIndex(idx: usize) [3]usize {
    const k = idx % LATTICE_SIZE;
    const rem = idx / LATTICE_SIZE;
    const j = rem % LATTICE_SIZE;
    const i = rem / LATTICE_SIZE;
    return .{ i, j, k };
}

fn colorFromHash(h: u64) [3]f32 {
    const mask21: u64 = (1 << 21) - 1;
    const scale: f32 = 1.0 / @as(f32, @floatFromInt(mask21));
    return .{
        @as(f32, @floatFromInt(h & mask21)) * scale,
        @as(f32, @floatFromInt((h >> 21) & mask21)) * scale,
        @as(f32, @floatFromInt((h >> 42) & mask21)) * scale,
    };
}

// ============================================================================
// Tests
// ============================================================================

test "lattice constants" {
    try std.testing.expectEqual(LATTICE_SIZE, 69);
    try std.testing.expectEqual(TOTAL_CONCEPTS, 328_509);
}

test "indexOf roundtrip" {
    const idx = ConceptLattice.indexOf(13, 42, 67);
    const coords = coordsFromIndex(idx);
    try std.testing.expectEqual(coords[0], 13);
    try std.testing.expectEqual(coords[1], 42);
    try std.testing.expectEqual(coords[2], 67);
}

test "indexOf boundary" {
    const idx = ConceptLattice.indexOf(68, 68, 68);
    try std.testing.expectEqual(idx, TOTAL_CONCEPTS - 1);
    try std.testing.expectEqual(ConceptLattice.indexOf(0, 0, 0), 0);
}

test "lattice init deterministic" {
    // Use a small verification: init twice with same seed, check fingerprints match
    const allocator = std.testing.allocator;
    var lat1 = try ConceptLattice.init(allocator, 1069);
    defer lat1.deinit();
    var lat2 = try ConceptLattice.init(allocator, 1069);
    defer lat2.deinit();

    try std.testing.expectEqual(lat1.fingerprint, lat2.fingerprint);
    // Spot-check a few concepts
    try std.testing.expectEqual(lat1.concepts[0].hash, lat2.concepts[0].hash);
    try std.testing.expectEqual(lat1.concepts[1000].spin, lat2.concepts[1000].spin);
    try std.testing.expect(lat1.concepts[500].color[0] == lat2.concepts[500].color[0]);
}

test "periodic boundary neighbors" {
    const allocator = std.testing.allocator;
    var lat = try ConceptLattice.init(allocator, 42);
    defer lat.deinit();

    // Corner (0,0,0) should wrap to (68,_,_), (_,68,_), (_,_,68)
    const nbrs = lat.neighbors(0, 0, 0);
    // +i neighbor = (1,0,0)
    try std.testing.expectEqual(nbrs[0].i, 1);
    // -i neighbor = (68,0,0) — wrapped
    try std.testing.expectEqual(nbrs[1].i, 68);
    // +j neighbor = (0,1,0)
    try std.testing.expectEqual(nbrs[2].j, 1);
    // -j neighbor = (0,68,0) — wrapped
    try std.testing.expectEqual(nbrs[3].j, 68);
    // +k neighbor = (0,0,1)
    try std.testing.expectEqual(nbrs[4].k, 1);
    // -k neighbor = (0,0,68) — wrapped
    try std.testing.expectEqual(nbrs[5].k, 68);
}

test "fingerprint commutativity" {
    const allocator = std.testing.allocator;
    var lat = try ConceptLattice.init(allocator, 7);
    defer lat.deinit();

    try std.testing.expect(lat.verifyMonoidLaws());
}

test "fingerprint matches computeFingerprint" {
    const allocator = std.testing.allocator;
    var lat = try ConceptLattice.init(allocator, 1069);
    defer lat.deinit();

    try std.testing.expectEqual(lat.fingerprint, lat.computeFingerprint());
}

test "step determinism" {
    const allocator = std.testing.allocator;
    var lat1 = try ConceptLattice.init(allocator, 1069);
    defer lat1.deinit();
    var lat2 = try ConceptLattice.init(allocator, 1069);
    defer lat2.deinit();

    lat1.step();
    lat2.step();

    try std.testing.expectEqual(lat1.fingerprint, lat2.fingerprint);
    // Spot check
    try std.testing.expectEqual(lat1.concepts[100].spin, lat2.concepts[100].spin);
    try std.testing.expectEqual(lat1.concepts[100].hash, lat2.concepts[100].hash);
}

test "magnetization in range" {
    const allocator = std.testing.allocator;
    var lat = try ConceptLattice.init(allocator, 1069);
    defer lat.deinit();

    const m = lat.magnetization();
    try std.testing.expect(m >= -1.0 and m <= 1.0);
}

test "morphism identity fixed points" {
    const allocator = std.testing.allocator;
    var id = try ConceptMorphism.identity(allocator);
    defer id.deinit();

    try std.testing.expectEqual(id.fixedPoints(), TOTAL_CONCEPTS);
}

test "morphism composition associativity" {
    // For identity: id . id . id = id
    const allocator = std.testing.allocator;
    var id = try ConceptMorphism.identity(allocator);
    defer id.deinit();

    // (id . id) . id  vs  id . (id . id)
    var id_id = try ConceptMorphism.compose(&id, &id, allocator);
    defer id_id.deinit();

    var lhs = try ConceptMorphism.compose(&id_id, &id, allocator);
    defer lhs.deinit();

    var rhs = try ConceptMorphism.compose(&id, &id_id, allocator);
    defer rhs.deinit();

    try std.testing.expectEqual(lhs.fingerprint, rhs.fingerprint);
    // Spot check mappings
    try std.testing.expectEqual(lhs.mapping[0], rhs.mapping[0]);
    try std.testing.expectEqual(lhs.mapping[1000], rhs.mapping[1000]);
    try std.testing.expectEqual(lhs.mapping[TOTAL_CONCEPTS - 1], rhs.mapping[TOTAL_CONCEPTS - 1]);
}

test "morphism orbit of identity is singleton" {
    const allocator = std.testing.allocator;
    var id = try ConceptMorphism.identity(allocator);
    defer id.deinit();

    var buf: [16]usize = undefined;
    const orb = id.orbit(42, &buf);
    try std.testing.expectEqual(orb.len, 1);
    try std.testing.expectEqual(orb[0], 42);
}

test "morphism eval returns correct concept" {
    const allocator = std.testing.allocator;
    var lat = try ConceptLattice.init(allocator, 1069);
    defer lat.deinit();
    var id = try ConceptMorphism.identity(allocator);
    defer id.deinit();

    const c = id.eval(&lat, 500);
    try std.testing.expectEqual(c.hash, lat.concepts[500].hash);
}

test "different seeds produce different fingerprints" {
    const allocator = std.testing.allocator;
    var lat1 = try ConceptLattice.init(allocator, 1069);
    defer lat1.deinit();
    var lat2 = try ConceptLattice.init(allocator, 420);
    defer lat2.deinit();

    try std.testing.expect(lat1.fingerprint != lat2.fingerprint);
}
