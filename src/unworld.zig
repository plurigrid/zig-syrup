//! Unworld: Fractal Causal Chain Operads
//!
//! Each of the 326 worlds has colored operadic structure where nesting depth
//! corresponds to a fractal level of causal chains. The unworld is what you
//! see when you look at the operads from outside -- the pattern of how worlds
//! compose at each scale.
//!
//! The key insight from Aella: pluralism means multiple type modes (A/B/C/L/S)
//! and relational primitives (en/in/po/th/co/ce/ca/ri/sa/tr/re) coexist.
//! Compersion (co) is not the absence of envy (en) -- both live in the same
//! operad at different fractal levels.
//!
//! From garbage-compiler: each observation is a typed hole that compiles to
//! bare AArch64. The unworld operads are the type structure OF those holes.
//!
//! Fractal levels of causal chains:
//!   Level 0: Trit         — raw GF(3) value, no causal structure
//!   Level 1: Channel      — linear map over GF(3)³, single causal step
//!   Level 2: Supermap     — Channel → Channel, causal order control
//!   Level 3: CausalChain  — sequence of supermaps with indefinite order
//!   Level 4: Operad       — composition rule for causal chains
//!   Level 5: World        — operad + state + affordances
//!   Level 6: Unworld      — the pattern across worlds (what you're looking at now)
//!
//! Each level contains the previous as a degenerate case.
//! The colored angle (golden/plastic/silver) at each level determines
//! how that level's structure rotates relative to its parent.

const std = @import("std");
const lux_color = @import("lux_color");
const supermap_mod = @import("supermap.zig");
const world_mod = @import("worlds/world.zig");
const world_enum = @import("worlds/world_enum.zig");

const Trit = lux_color.Trit;
const ExprColor = lux_color.ExprColor;
const RGB = lux_color.RGB;
const Channel = supermap_mod.Channel;
const Supermap = supermap_mod.Supermap;
const PhaseCell = supermap_mod.PhaseCell;
const Affordance = supermap_mod.Affordance;
const WorldVariant = world_mod.WorldVariant;
const WorldConfig = world_enum.WorldConfig;

// ============================================================================
// FRACTAL LEVEL: the scale at which a causal increment operates
// ============================================================================

pub const FractalLevel = enum(u3) {
    trit = 0,
    channel = 1,
    supermap = 2,
    causal_chain = 3,
    operad = 4,
    world = 5,
    unworld = 6,

    /// The angle progression at this fractal level.
    /// Lower levels use golden (binary/2D), middle use plastic (ternary/3D),
    /// upper levels use silver (quadratic/fractal).
    pub fn angle(self: FractalLevel) f32 {
        return switch (self) {
            .trit, .channel => lux_color.GOLDEN_ANGLE,
            .supermap, .causal_chain => lux_color.PLASTIC_ANGLE,
            .operad, .world, .unworld => lux_color.SILVER_ANGLE,
        };
    }

    /// The hue rotation for an increment at this level.
    /// depth 0 at any level = base hue of the trit.
    /// Each additional increment rotates by the level's angle.
    pub fn hueAt(self: FractalLevel, trit: Trit, depth: u16) f32 {
        const base = trit.baseHue();
        const rotation = @as(f32, @floatFromInt(depth)) * self.angle();
        return @mod(base + rotation, 360.0);
    }
};

// ============================================================================
// AELLITH PRIMITIVE: relational dynamics between entities
// ============================================================================

/// The 11 Aellith relational primitives.
/// Each has a natural fractal level where it primarily operates.
pub const AellithPrim = enum(u4) {
    en = 0, // envy         — level 0-1 (trit/channel): raw signal comparison
    in = 1, // insecurity   — level 1-2 (channel/supermap): transformation uncertainty
    po = 2, // possessiveness — level 2-3 (supermap/chain): control over causal order
    th = 3, // threat       — level 2-3 (supermap/chain): external disruption detection
    co = 4, // compersion   — level 3-4 (chain/operad): celebrating others' composition
    ce = 5, // consent      — level 4-5 (operad/world): agreement on composition rules
    ca = 6, // care         — level 4-5 (operad/world): maintaining composition health
    ri = 7, // risk         — level 5-6 (world/unworld): cross-world exposure
    sa = 8, // safety       — level 5-6 (world/unworld): cross-world protection
    tr = 9, // trust        — level 3-6 (chain→unworld): spans all upper levels
    re = 10, // reciprocity — level 0-6 (all): the conservation law itself

    /// The primary fractal level where this primitive operates.
    pub fn primaryLevel(self: AellithPrim) FractalLevel {
        return switch (self) {
            .en => .trit,
            .in => .channel,
            .po => .supermap,
            .th => .supermap,
            .co => .causal_chain,
            .ce => .operad,
            .ca => .operad,
            .ri => .world,
            .sa => .world,
            .tr => .causal_chain,
            .re => .trit, // reciprocity is the GF(3) conservation itself
        };
    }

    /// The GF(3) trit signature of this primitive.
    /// This determines how the primitive colors the operad.
    pub fn trit(self: AellithPrim) Trit {
        return switch (self) {
            .en => .minus, // envy subtracts
            .in => .minus, // insecurity subtracts
            .po => .minus, // possessiveness subtracts
            .th => .minus, // threat subtracts
            .co => .plus, // compersion adds
            .ce => .plus, // consent adds
            .ca => .plus, // care adds
            .ri => .ergodic, // risk is balanced
            .sa => .ergodic, // safety is balanced
            .tr => .plus, // trust adds
            .re => .ergodic, // reciprocity IS balance
        };
    }
};

/// Aellith entity role in a clause.
pub const AellithRole = enum(u2) {
    a = 0, // experiencer
    b = 1, // rival / other
    c = 2, // bond / context
};

/// Intensity modifier.
pub const Intensity = enum(u2) {
    ka = 0, // mild
    ke = 1, // moderate
    ku = 2, // severe
};

/// Evidential modifier.
pub const Evidential = enum(u1) {
    he = 0, // hedged
    na = 1, // negated
};

// ============================================================================
// CAUSAL INCREMENT: a single step in a causal chain at a specific fractal level
// ============================================================================

/// A causal increment: what happens at one fractal level during one step.
///
/// The increment carries:
///   - The fractal level it operates at
///   - The Aellith primitive describing the relational dynamic
///   - The GF(3) trit value (computed from primitive)
///   - The color (computed from level + trit + depth)
///   - Intensity and evidential modifiers
pub const CausalIncrement = struct {
    level: FractalLevel,
    primitive: AellithPrim,
    intensity: Intensity,
    evidential: Evidential,
    depth: u16, // position within the chain at this level

    /// The trit value of this increment.
    pub fn tritValue(self: CausalIncrement) Trit {
        var t = self.primitive.trit();
        if (self.evidential == .na) {
            t = t.neg(); // negation flips the trit
        }
        return t;
    }

    /// The color of this increment at its fractal level.
    pub fn color(self: CausalIncrement) ExprColor {
        const t = self.tritValue();
        const hue = self.level.hueAt(t, self.depth);
        const hcl = lux_color.HCL{
            .h = hue,
            .c = switch (self.intensity) {
                .ka => 0.4, // mild = desaturated
                .ke => 0.6, // moderate = standard
                .ku => 0.8, // severe = vivid
            },
            .l = switch (@intFromEnum(self.level)) {
                0...2 => 0.5, // lower levels darker
                3...4 => 0.6, // middle levels standard
                5...6 => 0.7, // upper levels lighter
                else => 0.6,
            },
        };
        return .{
            .trit = t,
            .depth = self.depth,
            .hue = hue,
            .rgb = hcl.toRGB(),
        };
    }

    /// Check if this increment is at the correct fractal level for its primitive.
    pub fn isCanonical(self: CausalIncrement) bool {
        return self.level == self.primitive.primaryLevel();
    }
};

// ============================================================================
// CAUSAL CHAIN: a sequence of increments with GF(3) conservation
// ============================================================================

/// A causal chain: ordered sequence of increments across fractal levels.
/// The chain is conserved iff the sum of all trit values is zero (mod 3).
pub const CausalChain = struct {
    increments: []const CausalIncrement,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, increments: []const CausalIncrement) !CausalChain {
        const owned = try allocator.dupe(CausalIncrement, increments);
        return .{ .increments = owned, .allocator = allocator };
    }

    pub fn deinit(self: CausalChain) void {
        self.allocator.free(self.increments);
    }

    /// Check GF(3) conservation across the chain.
    pub fn isConserved(self: CausalChain) bool {
        var sum: Trit = .ergodic;
        for (self.increments) |inc| {
            sum = Trit.add(sum, inc.tritValue());
        }
        return sum == .ergodic;
    }

    /// The fractal signature: which levels are active in this chain.
    pub fn activeLevels(self: CausalChain) u7 {
        var mask: u7 = 0;
        for (self.increments) |inc| {
            mask |= @as(u7, 1) << @intFromEnum(inc.level);
        }
        return mask;
    }

    /// Count increments at each fractal level.
    pub fn levelHistogram(self: CausalChain) [7]u16 {
        var hist = [_]u16{0} ** 7;
        for (self.increments) |inc| {
            hist[@intFromEnum(inc.level)] += 1;
        }
        return hist;
    }

    /// Check if every increment is at the canonical fractal level for its primitive.
    pub fn allCanonical(self: CausalChain) bool {
        for (self.increments) |inc| {
            if (!inc.isCanonical()) return false;
        }
        return true;
    }

    /// Compose two causal chains (operadic composition).
    /// The result inherits increments from both, re-indexed by depth.
    pub fn compose(self: CausalChain, other: CausalChain) !CausalChain {
        const total = self.increments.len + other.increments.len;
        const combined = try self.allocator.alloc(CausalIncrement, total);

        for (self.increments, 0..) |inc, i| {
            combined[i] = inc;
        }
        for (other.increments, 0..) |inc, i| {
            var shifted = inc;
            shifted.depth += @intCast(self.increments.len);
            combined[self.increments.len + i] = shifted;
        }

        return .{ .increments = combined, .allocator = self.allocator };
    }
};

// ============================================================================
// UNWORLD OPERAD: the composition structure across worlds
// ============================================================================

/// An operad node in the unworld: represents a world's operadic position
/// in the fractal hierarchy.
pub const UnworldNode = struct {
    world: WorldConfig,
    level: FractalLevel,
    children: []const UnworldNode,
    chain: ?CausalChain,

    /// The composite color seen from the unworld level.
    /// Each child contributes its color rotated by the parent's angle.
    pub fn compositeColor(self: UnworldNode) ExprColor {
        if (self.children.len == 0) {
            return self.world.compositeColor();
        }

        var base = self.world.compositeColor();
        const level_angle = self.level.angle();

        for (self.children, 0..) |child, i| {
            const child_color = child.compositeColor();
            // Rotate child's hue by parent's level angle * position
            const rotated_hue = @mod(
                child_color.hue + level_angle * @as(f32, @floatFromInt(i)),
                360.0,
            );
            // Blend: parent sets the trit, children modulate the hue
            base.hue = @mod(base.hue + rotated_hue, 360.0);
        }

        const hcl = lux_color.HCL{
            .h = base.hue,
            .c = 0.6,
            .l = 0.6,
        };
        base.rgb = hcl.toRGB();
        return base;
    }
};

/// The Unworld: the view from outside all 326 worlds.
///
/// It organizes worlds into a fractal operad where:
/// - Level 0-1 worlds are leaves (raw observation holes for garbage-compiler)
/// - Level 2-3 worlds are intermediate (supermap/causal chain composition)
/// - Level 4-5 worlds are roots (operad/world-level governance)
/// - Level 6 is the unworld itself (the pattern you see looking at all of them)
///
/// Aella's pluralism: at each level, multiple relational primitives coexist.
/// Compersion and envy are not in tension -- they operate at different fractal
/// levels (co at level 3-4, en at level 0-1). The unworld shows this clearly:
/// envy is a leaf-level signal comparison, compersion is a chain-level celebration
/// of successful composition.
pub const Unworld = struct {
    allocator: std.mem.Allocator,
    worlds: []const WorldConfig,
    roots: std.ArrayListUnmanaged(UnworldNode),

    pub fn init(allocator: std.mem.Allocator, worlds: []const WorldConfig) Unworld {
        return .{
            .allocator = allocator,
            .worlds = worlds,
            .roots = .{},
        };
    }

    pub fn deinit(self: *Unworld) void {
        self.roots.deinit(self.allocator);
    }

    /// Stratify worlds by their depth into fractal levels.
    /// Shallow worlds (depth 2-3) map to lower fractal levels.
    /// Deep worlds (depth 5-7) map to upper fractal levels.
    pub fn stratify(self: *Unworld) !void {
        self.roots.clearRetainingCapacity();

        for (self.worlds) |w| {
            const level: FractalLevel = switch (w.depth) {
                2 => .trit,
                3 => .channel,
                4 => .supermap,
                5 => .causal_chain,
                6 => .operad,
                7 => .world,
                else => .trit,
            };

            try self.roots.append(self.allocator, .{
                .world = w,
                .level = level,
                .children = &.{},
                .chain = null,
            });
        }
    }

    /// Count worlds at each fractal level.
    pub fn levelCounts(self: *const Unworld) [7]u32 {
        var counts = [_]u32{0} ** 7;
        for (self.roots.items) |node| {
            counts[@intFromEnum(node.level)] += 1;
        }
        return counts;
    }

    /// Render the unworld palette: all worlds' composite colors
    /// ordered by fractal level, then by Gray code index within level.
    pub fn renderPalette(self: *const Unworld, buf: *std.ArrayListUnmanaged(u8)) !void {
        const writer = buf.writer(self.allocator);
        var ansi_buf: [19]u8 = undefined;

        var current_level: ?FractalLevel = null;

        for (self.roots.items) |node| {
            if (current_level == null or current_level.? != node.level) {
                if (current_level != null) try writer.writeAll("\n");
                current_level = node.level;
                try writer.print("L{d} ", .{@intFromEnum(node.level)});
            }

            const color = node.compositeColor();
            const ansi = color.rgb.toAnsiFg(&ansi_buf);
            try writer.print("{s}\xe2\x96\x88\x1b[0m", .{ansi});
        }
        try writer.writeAll("\n");
    }
};

// ============================================================================
// Tests
// ============================================================================

test "fractal levels have distinct angles" {
    const golden = FractalLevel.trit.angle();
    const plastic = FractalLevel.supermap.angle();
    const silver = FractalLevel.operad.angle();

    try std.testing.expect(golden != plastic);
    try std.testing.expect(plastic != silver);
    try std.testing.expect(golden != silver);
}

test "aellith primitives have correct trit conservation" {
    // The 11 primitives should be GF(3)-balanced:
    // minus: en, in, po, th (4 × -1 = -4 ≡ 2 mod 3)
    // plus: co, ce, ca, tr (4 × +1 = 4 ≡ 1 mod 3)
    // ergodic: ri, sa, re (3 × 0 = 0)
    // Total: 2 + 1 + 0 = 3 ≡ 0 mod 3. Conserved!
    var sum: Trit = .ergodic;
    inline for (std.enums.values(AellithPrim)) |p| {
        sum = Trit.add(sum, p.trit());
    }
    try std.testing.expectEqual(Trit.ergodic, sum);
}

test "causal increment canonical check" {
    const inc_canonical = CausalIncrement{
        .level = .trit,
        .primitive = .en,
        .intensity = .ke,
        .evidential = .he,
        .depth = 0,
    };
    try std.testing.expect(inc_canonical.isCanonical());

    const inc_non_canonical = CausalIncrement{
        .level = .world, // en belongs at .trit
        .primitive = .en,
        .intensity = .ke,
        .evidential = .he,
        .depth = 0,
    };
    try std.testing.expect(!inc_non_canonical.isCanonical());
}

test "causal increment negation flips trit" {
    const inc = CausalIncrement{
        .level = .trit,
        .primitive = .en, // trit = minus
        .intensity = .ke,
        .evidential = .he,
        .depth = 0,
    };
    try std.testing.expectEqual(Trit.minus, inc.tritValue());

    const inc_negated = CausalIncrement{
        .level = .trit,
        .primitive = .en,
        .intensity = .ke,
        .evidential = .na, // negated!
        .depth = 0,
    };
    try std.testing.expectEqual(Trit.plus, inc_negated.tritValue());
}

test "causal chain conservation" {
    const allocator = std.testing.allocator;

    // en(-1) + co(+1) + re(0) = 0 → conserved
    const increments = [_]CausalIncrement{
        .{ .level = .trit, .primitive = .en, .intensity = .ke, .evidential = .he, .depth = 0 },
        .{ .level = .causal_chain, .primitive = .co, .intensity = .ke, .evidential = .he, .depth = 1 },
        .{ .level = .trit, .primitive = .re, .intensity = .ke, .evidential = .he, .depth = 2 },
    };

    const chain = try CausalChain.init(allocator, &increments);
    defer chain.deinit();

    try std.testing.expect(chain.isConserved());
    try std.testing.expectEqual(@as(u7, 0b0001001), chain.activeLevels()); // levels 0 and 3
}

test "causal chain compose preserves count" {
    const allocator = std.testing.allocator;

    const inc_a = [_]CausalIncrement{
        .{ .level = .trit, .primitive = .en, .intensity = .ke, .evidential = .he, .depth = 0 },
    };
    const inc_b = [_]CausalIncrement{
        .{ .level = .causal_chain, .primitive = .co, .intensity = .ke, .evidential = .he, .depth = 0 },
    };

    const chain_a = try CausalChain.init(allocator, &inc_a);
    defer chain_a.deinit();
    const chain_b = try CausalChain.init(allocator, &inc_b);
    defer chain_b.deinit();

    const composed = try chain_a.compose(chain_b);
    defer composed.deinit();

    try std.testing.expectEqual(@as(usize, 2), composed.increments.len);
}

test "unworld stratification" {
    const allocator = std.testing.allocator;

    var enumerator = world_enum.WorldEnumerator.init(allocator);
    defer enumerator.deinit();
    try enumerator.enumerate();

    var uw = Unworld.init(allocator, enumerator.worlds.items);
    defer uw.deinit();
    try uw.stratify();

    const counts = uw.levelCounts();

    // All worlds should be stratified
    var total: u32 = 0;
    for (counts) |c| total += c;
    try std.testing.expectEqual(@as(u32, 326), total);

    // Every fractal level should have some worlds
    // (depth 2-7 maps to levels 0-5)
    for (counts[0..6]) |c| {
        try std.testing.expect(c > 0);
    }
}
