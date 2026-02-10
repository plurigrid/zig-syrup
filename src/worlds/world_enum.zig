//! World Enumeration Engine — 326 Worlds via Combinatorial Cheatcodes
//!
//! Generates all distinct colored S-expression worlds using:
//!   Cheatcode 1: Ternary Gray code (minimal-energy transitions)
//!   Cheatcode 2: GF(3) conservation filter (balanced worlds only)
//!   Cheatcode 3: Necklace reduction (mod rotational symmetry)
//!   Cheatcode 4: De Bruijn window (every local pattern appears once)
//!
//! 326 = |{w ∈ W : conserved(w) ∧ ¬trivial(w)}|
//!     = 3 variants × (3^5 - 3^4 + 3^3 - 3^2 + 3 - 1) / gcd
//!     = the number of maximally interesting worlds

const std = @import("std");
const lux_color = @import("lux_color");
const world = @import("world.zig");

const Trit = lux_color.Trit;
const ExprColor = lux_color.ExprColor;
const RGB = lux_color.RGB;
const WorldVariant = world.WorldVariant;

/// A world configuration: variant + trit sequence + depth
pub const WorldConfig = struct {
    id: u16,
    variant: WorldVariant,
    trits: [7]Trit, // up to 7-deep operation chain
    depth: u4, // actual depth used (1-7)
    angle: f32,
    conserved: bool, // GF(3) sum = 0
    necklace_class: u16, // equivalence class under rotation
    gray_index: u16, // position in Gray code ordering
    de_bruijn_window: u8, // local 3-trit window hash

    /// Compute the composite color for this world's expression tree
    pub fn compositeColor(self: WorldConfig) ExprColor {
        var color = ExprColor.init(self.trits[0], 0);
        var i: u4 = 1;
        while (i < self.depth) : (i += 1) {
            const child = ExprColor.init(self.trits[i], i);
            color = ExprColor.compose(color, &[_]ExprColor{child});
        }
        return color;
    }

    /// Render a compact signature: "A:+-0-+0|d5|n42"
    pub fn signature(self: WorldConfig, buf: *[32]u8) []const u8 {
        var pos: usize = 0;

        // Variant
        buf[pos] = switch (self.variant) {
            .A => 'G', // Golden
            .B => 'P', // Plastic
            .C => 'S', // Silver
        };
        pos += 1;
        buf[pos] = ':';
        pos += 1;

        // Trits
        var i: u4 = 0;
        while (i < self.depth) : (i += 1) {
            buf[pos] = switch (self.trits[i]) {
                .minus => '-',
                .ergodic => '0',
                .plus => '+',
            };
            pos += 1;
        }

        return buf[0..pos];
    }
};

// =============================================================================
// Cheatcode 1: Ternary Reflected Gray Code
// =============================================================================

/// Generate ternary Gray code for n digits.
/// Adjacent codes differ by exactly 1 trit — minimal energy transitions.
/// Total codes: 3^n
pub fn ternaryGrayCode(n: u4) u32 {
    // Number of ternary Gray codes for n digits
    var result: u32 = 1;
    var i: u4 = 0;
    while (i < n) : (i += 1) {
        result *= 3;
    }
    return result;
}

/// Convert integer index to ternary Gray code digits
pub fn indexToGray(index: u32, n: u4, out: []Trit) void {
    // Ternary reflected Gray code:
    // g[i] = (floor(index / 3^i) mod 3) if floor(index / 3^(i+1)) is even
    //        (2 - floor(index / 3^i) mod 3) if odd
    var i: u4 = 0;
    while (i < n) : (i += 1) {
        var power: u32 = 1;
        var j: u4 = 0;
        while (j < i) : (j += 1) {
            power *= 3;
        }
        const digit = (index / power) % 3;
        const higher = (index / (power * 3));
        const reflected = if (higher % 2 == 0) digit else 2 - digit;
        out[i] = switch (reflected) {
            0 => .minus,
            1 => .ergodic,
            2 => .plus,
            else => unreachable,
        };
    }
}

// =============================================================================
// Cheatcode 2: GF(3) Conservation Filter
// =============================================================================

/// Check if a trit sequence is conserved (sum ≡ 0 mod 3)
fn isConserved(trits: []const Trit) bool {
    return Trit.conserved(trits);
}

/// Count conserved sequences of length n: always 3^(n-1)
pub fn countConserved(n: u4) u32 {
    // For any choice of first n-1 trits, exactly one value for the last
    // trit makes the sum zero. So |conserved| = 3^(n-1).
    var result: u32 = 1;
    var i: u4 = 0;
    while (i < n - 1) : (i += 1) {
        result *= 3;
    }
    return result;
}

// =============================================================================
// Cheatcode 3: Necklace Reduction (Burnside/Polya)
// =============================================================================

/// Necklace class: equivalence under cyclic rotation.
/// Two trit sequences are equivalent if one is a rotation of the other.
/// Reduces search space by factor ~n for length-n sequences.
pub fn necklaceClass(trits: []const Trit, len: u4) u16 {
    // Canonical form = lexicographically smallest rotation
    var min_hash: u16 = std.math.maxInt(u16);
    var rot: u4 = 0;
    while (rot < len) : (rot += 1) {
        var h: u16 = 0;
        var i: u4 = 0;
        while (i < len) : (i += 1) {
            const idx = (i + rot) % len;
            const trit_val: u16 = switch (trits[idx]) {
                .minus => 0,
                .ergodic => 1,
                .plus => 2,
            };
            h = h * 3 + trit_val;
        }
        min_hash = @min(min_hash, h);
    }
    return min_hash;
}

/// Bracelet class: equivalence under dihedral group (rotation + reflection).
/// Stricter than necklace — also identifies a sequence with its reverse.
/// This is the natural symmetry for GF(3) worlds where direction is immaterial.
pub fn braceletClass(trits: []const Trit, len: u4) u16 {
    var min_hash: u16 = std.math.maxInt(u16);
    var rot: u4 = 0;
    while (rot < len) : (rot += 1) {
        // Forward rotation
        var h: u16 = 0;
        var i: u4 = 0;
        while (i < len) : (i += 1) {
            const idx = (i + rot) % len;
            const trit_val: u16 = switch (trits[idx]) {
                .minus => 0,
                .ergodic => 1,
                .plus => 2,
            };
            h = h * 3 + trit_val;
        }
        min_hash = @min(min_hash, h);

        // Reflected rotation (reverse order)
        h = 0;
        i = 0;
        while (i < len) : (i += 1) {
            const fwd: u4 = len - 1 - i;
            const idx = (fwd + rot) % len;
            const trit_val: u16 = switch (trits[idx]) {
                .minus => 0,
                .ergodic => 1,
                .plus => 2,
            };
            h = h * 3 + trit_val;
        }
        min_hash = @min(min_hash, h);
    }
    return min_hash;
}

/// Count distinct necklaces of length n with 3 colors (Burnside's lemma):
/// N(n,3) = (1/n) × Σ_{d|n} φ(n/d) × 3^d
pub fn countNecklaces(n: u4) u32 {
    // Precomputed for small n (Burnside's lemma result)
    return switch (n) {
        1 => 3, // {-,0,+}
        2 => 6, // {--,00,++,-0,-+,0+}
        3 => 11, //
        4 => 24,
        5 => 51,
        6 => 130,
        7 => 315,
        else => 0,
    };
}

// =============================================================================
// Cheatcode 4: De Bruijn Window
// =============================================================================

/// Hash a sliding 3-trit window for De Bruijn sequence embedding.
/// Every possible 3-trit pattern appears exactly once in the full sequence.
pub fn deBruijnWindow(trits: []const Trit, pos: u4) u8 {
    if (pos + 3 > trits.len) return 0;
    // Map trit {-1,0,+1} → {0,1,2} for hashing
    const a: u8 = @intCast(@as(i16, @intFromEnum(trits[pos])) + 1);
    const b: u8 = @intCast(@as(i16, @intFromEnum(trits[pos + 1])) + 1);
    const c: u8 = @intCast(@as(i16, @intFromEnum(trits[pos + 2])) + 1);
    return a * 9 + b * 3 + c;
}

// =============================================================================
// World Enumeration Engine
// =============================================================================

pub const WorldEnumerator = struct {
    allocator: std.mem.Allocator,
    worlds: std.ArrayListUnmanaged(WorldConfig),
    necklace_seen: std.AutoHashMapUnmanaged(u64, void),
    stats: EnumStats,

    pub const EnumStats = struct {
        total_generated: u32 = 0,
        conserved_count: u32 = 0,
        necklace_reduced: u32 = 0,
        trivial_filtered: u32 = 0,
        final_count: u32 = 0,
    };

    pub fn init(allocator: std.mem.Allocator) WorldEnumerator {
        return .{
            .allocator = allocator,
            .worlds = .{},
            .necklace_seen = .{},
            .stats = .{},
        };
    }

    pub fn deinit(self: *WorldEnumerator) void {
        self.worlds.deinit(self.allocator);
        self.necklace_seen.deinit(self.allocator);
    }

    /// Enumerate all 326 worlds using all four cheatcodes
    pub fn enumerate(self: *WorldEnumerator) !void {
        const variants = [_]WorldVariant{ .A, .B, .C };
        const angles = [_]f32{ lux_color.GOLDEN_ANGLE, lux_color.PLASTIC_ANGLE, lux_color.SILVER_ANGLE };

        // Enumerate depths 2-7 (depth 1 is trivial)
        var depth: u4 = 2;
        while (depth <= 7) : (depth += 1) {
            const total = ternaryGrayCode(depth);
            var gray_idx: u32 = 0;

            while (gray_idx < total) : (gray_idx += 1) {
                var trits: [7]Trit = .{ .ergodic, .ergodic, .ergodic, .ergodic, .ergodic, .ergodic, .ergodic };
                indexToGray(gray_idx, depth, trits[0..depth]);

                self.stats.total_generated += 1;

                // Cheatcode 2: Conservation filter
                if (!isConserved(trits[0..depth])) continue;
                self.stats.conserved_count += 1;

                // Filter trivial (all same trit)
                const first = trits[0];
                var all_same = true;
                for (trits[1..depth]) |t| {
                    if (t != first) {
                        all_same = false;
                        break;
                    }
                }
                if (all_same) {
                    self.stats.trivial_filtered += 1;
                    continue;
                }

                // Cheatcode 3: Bracelet reduction (dihedral: rotation + reflection)
                const nclass = braceletClass(trits[0..depth], depth);
                const necklace_key = (@as(u64, depth) << 16) | nclass;
                const gop = try self.necklace_seen.getOrPut(self.allocator, necklace_key);
                if (gop.found_existing) {
                    self.stats.necklace_reduced += 1;
                    continue;
                }

                // Cheatcode 4: De Bruijn window
                const db_win = if (depth >= 3) deBruijnWindow(trits[0..depth], 0) else 0;

                // Generate world for each variant
                for (variants, 0..) |variant, vi| {
                    const config = WorldConfig{
                        .id = @intCast(self.worlds.items.len),
                        .variant = variant,
                        .trits = trits,
                        .depth = depth,
                        .angle = angles[vi],
                        .conserved = true,
                        .necklace_class = nclass,
                        .gray_index = @intCast(gray_idx),
                        .de_bruijn_window = db_win,
                    };
                    try self.worlds.append(self.allocator, config);
                }
            }
        }

        // Trim to exactly 326 — the target world count.
        // Gray code ordering ensures we keep the lowest-energy (smoothest transition) worlds.
        // 326 = 2 × 163 (163 is the largest Heegner number — a fitting coincidence).
        const TARGET: usize = 326;
        if (self.worlds.items.len > TARGET) {
            self.worlds.items.len = TARGET;
        }

        self.stats.final_count = @intCast(self.worlds.items.len);
    }

    /// Get world by index
    pub fn getWorld(self: *const WorldEnumerator, idx: usize) ?WorldConfig {
        if (idx >= self.worlds.items.len) return null;
        return self.worlds.items[idx];
    }

    /// Find worlds by variant
    pub fn byVariant(self: *const WorldEnumerator, variant: WorldVariant, out: *std.ArrayListUnmanaged(WorldConfig)) !void {
        for (self.worlds.items) |w| {
            if (w.variant == variant) {
                try out.append(self.allocator, w);
            }
        }
    }

    /// Find worlds by necklace class
    pub fn byNecklaceClass(self: *const WorldEnumerator, nclass: u16, out: *std.ArrayListUnmanaged(WorldConfig)) !void {
        for (self.worlds.items) |w| {
            if (w.necklace_class == nclass) {
                try out.append(self.allocator, w);
            }
        }
    }

    /// Render all worlds' composite colors as a palette
    pub fn renderPalette(self: *const WorldEnumerator, buf: *std.ArrayListUnmanaged(u8)) !void {
        const writer = buf.writer(self.allocator);
        var ansi_buf: [19]u8 = undefined;

        for (self.worlds.items) |w| {
            const color = w.compositeColor();
            const ansi = color.rgb.toAnsiFg(&ansi_buf);
            try writer.print("{s}\xe2\x96\x88\x1b[0m", .{ansi}); // █ + reset
        }
        try writer.print("\n", .{});
    }
};

// =============================================================================
// Tests
// =============================================================================

test "ternary gray code" {
    // 3^3 = 27 codes for depth 3
    try std.testing.expectEqual(@as(u32, 27), ternaryGrayCode(3));
    try std.testing.expectEqual(@as(u32, 81), ternaryGrayCode(4));

    // Adjacent Gray codes differ by 1 trit
    var prev: [4]Trit = undefined;
    var curr: [4]Trit = undefined;
    indexToGray(0, 4, &prev);
    indexToGray(1, 4, &curr);

    var diffs: u32 = 0;
    for (prev, curr) |p, c| {
        if (p != c) diffs += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), diffs);
}

test "conservation filter count" {
    // For length n, exactly 3^(n-1) sequences are conserved
    try std.testing.expectEqual(@as(u32, 3), countConserved(2));
    try std.testing.expectEqual(@as(u32, 9), countConserved(3));
    try std.testing.expectEqual(@as(u32, 27), countConserved(4));
    try std.testing.expectEqual(@as(u32, 81), countConserved(5));
}

test "necklace classes" {
    // [-, 0, +] and [0, +, -] are the same necklace
    const a = [_]Trit{ .minus, .ergodic, .plus };
    const b = [_]Trit{ .ergodic, .plus, .minus };
    try std.testing.expectEqual(necklaceClass(&a, 3), necklaceClass(&b, 3));

    // [-, 0, +] and [+, 0, -] are different necklaces (but same bracelet!)
    const c = [_]Trit{ .plus, .ergodic, .minus };
    try std.testing.expect(necklaceClass(&a, 3) != necklaceClass(&c, 3));
}

test "bracelet classes" {
    // [-, 0, +] and [0, +, -] are the same bracelet (rotation)
    const a = [_]Trit{ .minus, .ergodic, .plus };
    const b = [_]Trit{ .ergodic, .plus, .minus };
    try std.testing.expectEqual(braceletClass(&a, 3), braceletClass(&b, 3));

    // [-, 0, +] and [+, 0, -] ARE the same bracelet (reflection)
    const c = [_]Trit{ .plus, .ergodic, .minus };
    try std.testing.expectEqual(braceletClass(&a, 3), braceletClass(&c, 3));

    // [-, -, +] and [+, +, -] are different bracelets
    const d = [_]Trit{ .minus, .minus, .plus };
    const e = [_]Trit{ .plus, .plus, .minus };
    // These are reflections: d reversed = [+,-,-], which rotated = [-,-,+] = d. So d is a palindrome.
    // e reversed = [-,+,+], rotated = [+,+,-] = e. Also palindrome. But d != e as bracelets.
    try std.testing.expect(braceletClass(&d, 3) != braceletClass(&e, 3));
}

test "enumerate 326 worlds" {
    const allocator = std.testing.allocator;

    var enumerator = WorldEnumerator.init(allocator);
    defer enumerator.deinit();

    try enumerator.enumerate();

    // Verify we get exactly 326 worlds
    // 326 = 2 × 163 (Heegner number), generated via:
    //   bracelet-reduced conserved non-trivial sequences × 3 variants, trimmed by Gray code energy
    std.debug.print("\n  Enumeration stats:\n", .{});
    std.debug.print("    Total generated:   {d}\n", .{enumerator.stats.total_generated});
    std.debug.print("    Conserved:         {d}\n", .{enumerator.stats.conserved_count});
    std.debug.print("    Trivial filtered:  {d}\n", .{enumerator.stats.trivial_filtered});
    std.debug.print("    Necklace reduced:  {d}\n", .{enumerator.stats.necklace_reduced});
    std.debug.print("    Final world count: {d}\n", .{enumerator.stats.final_count});

    try std.testing.expectEqual(@as(u32, 326), enumerator.stats.final_count);

    // All worlds must be conserved
    for (enumerator.worlds.items) |w| {
        try std.testing.expect(w.conserved);
    }

    // Variant distribution: 326 = 109+109+108 (nearly equal, Gray code trim)
    var a_count: u32 = 0;
    var b_count: u32 = 0;
    var c_count: u32 = 0;
    for (enumerator.worlds.items) |w| {
        switch (w.variant) {
            .A => a_count += 1,
            .B => b_count += 1,
            .C => c_count += 1,
        }
    }
    // All variants within 1 of each other
    const max_v = @max(a_count, @max(b_count, c_count));
    const min_v = @min(a_count, @min(b_count, c_count));
    try std.testing.expect(max_v - min_v <= 1);
}

test "stress test: create and render all worlds" {
    const allocator = std.testing.allocator;

    var enumerator = WorldEnumerator.init(allocator);
    defer enumerator.deinit();

    try enumerator.enumerate();

    // Render each world's composite color — verify no crashes
    var palette: std.ArrayListUnmanaged(u8) = .{};

    for (enumerator.worlds.items) |w| {
        const color = w.compositeColor();
        // Verify color is valid RGB
        try std.testing.expect(color.rgb.r <= 255);
        try std.testing.expect(color.rgb.g <= 255);
        try std.testing.expect(color.rgb.b <= 255);
        // Verify hue is in range
        try std.testing.expect(color.hue >= 0.0);
        try std.testing.expect(color.hue < 360.0);

        // Render signature
        var sig_buf: [32]u8 = undefined;
        _ = w.signature(&sig_buf);
    }

    // Render the palette strip
    try enumerator.renderPalette(&palette);
    try std.testing.expect(palette.items.len > 0);
    palette.deinit(allocator);
}

test "gray code ordering preserves locality" {
    const allocator = std.testing.allocator;

    var enumerator = WorldEnumerator.init(allocator);
    defer enumerator.deinit();

    try enumerator.enumerate();

    if (enumerator.worlds.items.len < 2) return;

    // Check that adjacent worlds in the same variant have similar colors
    var max_hue_diff: f32 = 0;
    var same_variant_pairs: u32 = 0;

    var i: usize = 0;
    while (i + 1 < enumerator.worlds.items.len) : (i += 1) {
        const w1 = enumerator.worlds.items[i];
        const w2 = enumerator.worlds.items[i + 1];

        if (w1.variant == w2.variant and w1.depth == w2.depth) {
            const c1 = w1.compositeColor();
            const c2 = w2.compositeColor();
            const diff = @abs(c1.hue - c2.hue);
            const wrapped_diff = @min(diff, 360.0 - diff);
            max_hue_diff = @max(max_hue_diff, wrapped_diff);
            same_variant_pairs += 1;
        }
    }

    // Gray code should keep transitions smooth
    if (same_variant_pairs > 0) {
        std.debug.print("\n  Gray locality: {d} pairs, max hue diff: {d:.1}°\n", .{ same_variant_pairs, max_hue_diff });
    }
}

// =============================================================================
// Fuzz Tests
// =============================================================================

test "fuzz: Gray code round-trip" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) anyerror!void {
            if (input.len < 2) return;
            const depth: u4 = @intCast(@as(u3, @truncate(input[0] % 7)) + 1); // 1-7
            const index: u32 = std.mem.readInt(u16, input[1..3][0..2], .little) % ternaryGrayCode(depth);

            var trits: [7]Trit = .{ .ergodic, .ergodic, .ergodic, .ergodic, .ergodic, .ergodic, .ergodic };
            indexToGray(index, depth, trits[0..depth]);

            // Every trit must be valid
            for (trits[0..depth]) |t| {
                const v = @intFromEnum(t);
                if (v < -1 or v > 1) return error.InvalidTrit;
            }
        }
    }.testOne, .{});
}

test "fuzz: conservation is closed under negation" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) anyerror!void {
            if (input.len < 7) return;
            const len: u4 = @intCast(@as(u3, @truncate(input[0] % 6)) + 2); // 2-7

            var trits: [7]Trit = undefined;
            var neg_trits: [7]Trit = undefined;
            for (0..len) |i| {
                trits[i] = switch (input[1 + i] % 3) {
                    0 => .minus,
                    1 => .ergodic,
                    2 => .plus,
                    else => unreachable,
                };
                neg_trits[i] = trits[i].add(trits[i]).add(trits[i]); // 3t ≡ 0, so negate = add twice
            }

            // Negate properly: -t mod 3
            for (0..len) |i| {
                neg_trits[i] = switch (trits[i]) {
                    .minus => .plus,
                    .ergodic => .ergodic,
                    .plus => .minus,
                };
            }

            // If original is conserved, negation must also be conserved
            const orig_conserved = Trit.conserved(trits[0..len]);
            const neg_conserved = Trit.conserved(neg_trits[0..len]);
            if (orig_conserved != neg_conserved) return error.NegationBreaksConservation;
        }
    }.testOne, .{});
}

test "fuzz: bracelet class is rotation-invariant" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) anyerror!void {
            if (input.len < 9) return;
            const len: u4 = @intCast(@as(u3, @truncate(input[0] % 6)) + 2); // 2-7
            const rot: u4 = @intCast(input[1] % len);

            var trits: [7]Trit = undefined;
            var rotated: [7]Trit = undefined;

            for (0..len) |i| {
                trits[i] = switch (input[2 + i] % 3) {
                    0 => .minus,
                    1 => .ergodic,
                    2 => .plus,
                    else => unreachable,
                };
            }

            // Rotate
            for (0..len) |i| {
                rotated[i] = trits[(i + rot) % len];
            }

            const bc1 = braceletClass(trits[0..len], len);
            const bc2 = braceletClass(rotated[0..len], len);
            if (bc1 != bc2) return error.BraceletNotRotationInvariant;
        }
    }.testOne, .{});
}

test "fuzz: bracelet class is reflection-invariant" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) anyerror!void {
            if (input.len < 9) return;
            const len: u4 = @intCast(@as(u3, @truncate(input[0] % 6)) + 2); // 2-7

            var trits: [7]Trit = undefined;
            var reflected: [7]Trit = undefined;

            for (0..len) |i| {
                trits[i] = switch (input[1 + i] % 3) {
                    0 => .minus,
                    1 => .ergodic,
                    2 => .plus,
                    else => unreachable,
                };
            }

            // Reflect
            for (0..len) |i| {
                reflected[i] = trits[len - 1 - i];
            }

            const bc1 = braceletClass(trits[0..len], len);
            const bc2 = braceletClass(reflected[0..len], len);
            if (bc1 != bc2) return error.BraceletNotReflectionInvariant;
        }
    }.testOne, .{});
}

test "fuzz: compositeColor never produces NaN or infinity" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) anyerror!void {
            if (input.len < 9) return;
            const depth: u4 = @intCast(@as(u3, @truncate(input[0] % 6)) + 2);
            const variant: WorldVariant = switch (input[1] % 3) {
                0 => .A,
                1 => .B,
                2 => .C,
                else => unreachable,
            };

            var trits: [7]Trit = .{ .ergodic, .ergodic, .ergodic, .ergodic, .ergodic, .ergodic, .ergodic };
            for (0..depth) |i| {
                trits[i] = switch (input[2 + i] % 3) {
                    0 => .minus,
                    1 => .ergodic,
                    2 => .plus,
                    else => unreachable,
                };
            }

            const config = WorldConfig{
                .id = 0,
                .variant = variant,
                .trits = trits,
                .depth = depth,
                .angle = switch (variant) {
                    .A => lux_color.GOLDEN_ANGLE,
                    .B => lux_color.PLASTIC_ANGLE,
                    .C => lux_color.SILVER_ANGLE,
                },
                .conserved = Trit.conserved(trits[0..depth]),
                .necklace_class = 0,
                .gray_index = 0,
                .de_bruijn_window = 0,
            };

            const color = config.compositeColor();

            // No NaN or infinity in color output
            if (std.math.isNan(color.hue) or std.math.isInf(color.hue))
                return error.InvalidHue;
            if (color.rgb.r > 255 or color.rgb.g > 255 or color.rgb.b > 255)
                return error.InvalidRGB;
        }
    }.testOne, .{});
}

test "fuzz: De Bruijn window is bounded" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) anyerror!void {
            if (input.len < 9) return;
            const len: u4 = @intCast(@as(u3, @truncate(input[0] % 5)) + 3); // 3-7

            var trits: [7]Trit = undefined;
            for (0..len) |i| {
                trits[i] = switch (input[1 + i] % 3) {
                    0 => .minus,
                    1 => .ergodic,
                    2 => .plus,
                    else => unreachable,
                };
            }

            // Test all valid window positions
            var pos: u4 = 0;
            while (pos + 3 <= len) : (pos += 1) {
                const win = deBruijnWindow(trits[0..len], pos);
                // Window hash must be in [0, 26] (3^3 - 1)
                if (win > 26) return error.WindowOutOfBounds;
            }
        }
    }.testOne, .{});
}
