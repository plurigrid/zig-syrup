///! salon.zig — 3-Chair BCI Salon Installation
///!
///! Physical layout:
///!
///!     ┌─────────────────────────────────────────┐
///!     │              GRID DISPLAY                │
///!     │  ┌───┬───┬───┬───┬───┬───┬───┬───┬───┐  │
///!     │  │   │   │   │   │   │   │   │   │   │  │
///!     │  ├───┼───┼───┼───┼───┼───┼───┼───┼───┤  │
///!     │  │   │   │   │   │   │   │   │   │   │  │
///!     │  ├───┼───┼───┼───┼───┼───┼───┼───┼───┤  │
///!     │  │   │   │   │   │   │   │   │   │   │  │
///!     │  ├───┼───┼───┼───┼───┼───┼───┼───┼───┤  │
///!     │  │   │   │ A │ · │ B │   │   │   │   │  │
///!     │  ├───┼───┼───┼───┼───┼───┼───┼───┼───┤  │
///!     │  │   │   │   │ C │   │   │   │   │   │  │
///!     │  ├───┼───┼───┼───┼───┼───┼───┼───┼───┤  │
///!     │  │   │   │   │   │   │   │   │   │   │  │
///!     │  └───┴───┴───┴───┴───┴───┴───┴───┴───┘  │
///!     │                                          │
///!     │     🪑 A        🪑 B        🪑 C         │
///!     │   (PLUS)     (ERGODIC)    (MINUS)        │
///!     │   Fp1-O2      Fp1-O2      Fp1-O2        │
///!     └─────────────────────────────────────────┘
///!
///! Each chair has an 8-channel OpenBCI Cyton headset.
///! 3 chairs = 3 GF(3) roles = triadic balance.
///! The grid propagates color from all 3 BCI streams.
///!
///! Data flow:
///!   Cyton (250Hz) → FFT bands → Fisher-Rao → Phenomenal state
///!   → Syrup encode → Grid propagator → Cell dispatch → Display
///!
///! Wire format: all inter-component data is Syrup-canonical,
///! so every epoch has a deterministic CID regardless of origin chair.
const std = @import("std");
const syrup = @import("syrup.zig");

// ============================================================
// Chair: one participant's BCI session
// ============================================================

pub const ChairRole = enum(i2) {
    plus = 1, // Chair A: generator (+1)
    ergodic = 0, // Chair B: coordinator (0)
    minus = -1, // Chair C: validator (-1)

    pub fn color(self: ChairRole) RGB {
        return switch (self) {
            .plus => .{ .r = 0x3D, .g = 0xD9, .b = 0x8F }, // green
            .ergodic => .{ .r = 0xF5, .g = 0xD5, .b = 0x47 }, // yellow
            .minus => .{ .r = 0xE8, .g = 0x4C, .b = 0x3D }, // red
        };
    }

    pub fn label(self: ChairRole) []const u8 {
        return switch (self) {
            .plus => "A (generator)",
            .ergodic => "B (coordinator)",
            .minus => "C (validator)",
        };
    }
};

pub const RGB = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn lerp(a: RGB, b: RGB, t: f32) RGB {
        const tc = std.math.clamp(t, 0.0, 1.0);
        return .{
            .r = @intFromFloat(@as(f32, @floatFromInt(a.r)) * (1.0 - tc) + @as(f32, @floatFromInt(b.r)) * tc),
            .g = @intFromFloat(@as(f32, @floatFromInt(a.g)) * (1.0 - tc) + @as(f32, @floatFromInt(b.g)) * tc),
            .b = @intFromFloat(@as(f32, @floatFromInt(a.b)) * (1.0 - tc) + @as(f32, @floatFromInt(b.b)) * tc),
        };
    }

    pub fn hex(self: RGB) [7]u8 {
        var buf: [7]u8 = undefined;
        buf[0] = '#';
        const digits = "0123456789ABCDEF";
        buf[1] = digits[self.r >> 4];
        buf[2] = digits[self.r & 0xf];
        buf[3] = digits[self.g >> 4];
        buf[4] = digits[self.g & 0xf];
        buf[5] = digits[self.b >> 4];
        buf[6] = digits[self.b & 0xf];
        return buf;
    }
};

pub const BandPowers = struct {
    delta: f32 = 0,
    theta: f32 = 0,
    alpha: f32 = 0,
    beta: f32 = 0,
    gamma: f32 = 0,

    /// Normalize to probability simplex (sum = 1)
    pub fn toSimplex(self: BandPowers) BandPowers {
        const sum = self.delta + self.theta + self.alpha + self.beta + self.gamma;
        if (sum < 1e-10) return .{ .delta = 0.2, .theta = 0.2, .alpha = 0.2, .beta = 0.2, .gamma = 0.2 };
        return .{
            .delta = self.delta / sum,
            .theta = self.theta / sum,
            .alpha = self.alpha / sum,
            .beta = self.beta / sum,
            .gamma = self.gamma / sum,
        };
    }

    /// Shannon entropy of band distribution (bits)
    pub fn entropy(self: BandPowers) f32 {
        const s = self.toSimplex();
        var h: f32 = 0;
        const bands = [_]f32{ s.delta, s.theta, s.alpha, s.beta, s.gamma };
        for (bands) |p| {
            if (p > 1e-10) h -= p * @log(p) / @log(2.0);
        }
        return h;
    }

    /// Dominant band name
    pub fn dominant(self: BandPowers) []const u8 {
        const bands = [_]f32{ self.delta, self.theta, self.alpha, self.beta, self.gamma };
        const names = [_][]const u8{ "delta", "theta", "alpha", "beta", "gamma" };
        var best: usize = 0;
        for (bands[1..], 1..) |v, i| {
            if (v > bands[best]) best = i;
        }
        return names[best];
    }
};

/// Fisher-Rao geodesic distance on the 5-band probability simplex
/// d(p,q) = 2 * arccos(sum_i sqrt(p_i * q_i))
pub fn fisherRaoDistance(a: BandPowers, b: BandPowers) f32 {
    const pa = a.toSimplex();
    const pb = b.toSimplex();
    const a_arr = [_]f32{ pa.delta, pa.theta, pa.alpha, pa.beta, pa.gamma };
    const b_arr = [_]f32{ pb.delta, pb.theta, pb.alpha, pb.beta, pb.gamma };
    var dot: f32 = 0;
    for (a_arr, b_arr) |ai, bi| {
        dot += @sqrt(ai * bi);
    }
    dot = std.math.clamp(dot, -1.0, 1.0);
    return 2.0 * std.math.acos(dot);
}

pub const PhenomenalState = struct {
    phi: f32, // Fisher-Rao engagement angle [0, pi/2]
    valence: f32, // [-1, +1] from alpha dominance
    entropy: f32, // Shannon entropy of band distribution
    trit: i2, // GF(3) classification

    pub fn fromBands(bands: BandPowers, baseline: BandPowers) PhenomenalState {
        const simplex = bands.toSimplex();
        const d = fisherRaoDistance(bands, baseline);
        // phi: Fisher-Rao distance scaled to [0, pi/2]
        const phi = d * (std.math.pi / 4.0); // half of max distance
        // valence: alpha-dominance mapped to [-1, +1]
        const valence = 2.0 * simplex.alpha - 1.0;
        // entropy
        const ent = bands.entropy();
        // trit: entropy-based classification
        const trit: i2 = if (ent > 2.0) 1 else if (ent < 1.0) -1 else 0;
        return .{ .phi = phi, .valence = valence, .entropy = ent, .trit = trit };
    }

    /// Hue from valence: red(-1) → yellow(0) → green(+1)
    pub fn hue(self: PhenomenalState) f32 {
        return (self.valence + 1.0) * 60.0; // 0° red → 60° yellow → 120° green
    }

    /// Saturation from entropy (high entropy = vivid)
    pub fn saturation(self: PhenomenalState) f32 {
        return std.math.clamp(self.entropy / 2.32, 0.2, 1.0);
    }

    /// Lightness from phi (engaged = bright)
    pub fn lightness(self: PhenomenalState) f32 {
        return 0.3 + 0.5 * std.math.clamp(self.phi / (std.math.pi / 2.0), 0.0, 1.0);
    }

    pub fn toRgb(self: PhenomenalState) RGB {
        return hslToRgb(self.hue(), self.saturation(), self.lightness());
    }
};

pub const Chair = struct {
    role: ChairRole,
    bands: BandPowers,
    baseline: BandPowers,
    state: PhenomenalState,
    epoch: u32,
    channels: [8][]const u8,

    pub fn init(role: ChairRole) Chair {
        const resting = BandPowers{ .delta = 0.3, .theta = 0.3, .alpha = 0.8, .beta = 0.2, .gamma = 0.1 };
        return .{
            .role = role,
            .bands = resting,
            .baseline = resting,
            .state = PhenomenalState.fromBands(resting, resting),
            .epoch = 0,
            .channels = .{ "Fp1", "Fp2", "C3", "C4", "P3", "P4", "O1", "O2" },
        };
    }

    pub fn update(self: *Chair, new_bands: BandPowers) void {
        self.bands = new_bands;
        self.state = PhenomenalState.fromBands(new_bands, self.baseline);
        self.epoch += 1;
    }
};

// ============================================================
// Grid: the shared display surrounding the 3 chairs
// ============================================================

pub const GRID_COLS = 9;
pub const GRID_ROWS = 9;
pub const GRID_CELLS = GRID_COLS * GRID_ROWS;

pub const GridCell = struct {
    color: RGB,
    influence: [3]f32, // weight from each chair [A, B, C]
    trit: i2,
    active: bool,
};

pub const Grid = struct {
    cells: [GRID_CELLS]GridCell,
    chairs: [3]Chair,
    tick: u64,
    gf3_sum: i32,

    pub fn init() Grid {
        var g = Grid{
            .cells = undefined,
            .chairs = .{
                Chair.init(.plus),
                Chair.init(.ergodic),
                Chair.init(.minus),
            },
            .tick = 0,
            .gf3_sum = 0,
        };

        // Chair positions in the grid (row 6-7, centered)
        // A at (3,3), B at (4,3), C at (4,4) — triangle formation
        const chair_positions = [3][2]usize{ .{ 3, 3 }, .{ 4, 3 }, .{ 3, 4 } };

        // Compute influence weights based on distance to each chair
        for (0..GRID_CELLS) |i| {
            const col: f32 = @floatFromInt(i % GRID_COLS);
            const row: f32 = @floatFromInt(i / GRID_COLS);

            var influence: [3]f32 = undefined;
            var total: f32 = 0;
            for (chair_positions, 0..) |pos, c| {
                const cx: f32 = @floatFromInt(pos[0]);
                const cy: f32 = @floatFromInt(pos[1]);
                const dx = col - cx;
                const dy = row - cy;
                const dist = @sqrt(dx * dx + dy * dy) + 0.5; // +0.5 to avoid div/0
                influence[c] = 1.0 / (dist * dist); // inverse square falloff
                total += influence[c];
            }
            // Normalize
            for (&influence) |*w| w.* /= total;

            g.cells[i] = .{
                .color = .{ .r = 0, .g = 0, .b = 0 },
                .influence = influence,
                .trit = 0,
                .active = true,
            };
        }
        return g;
    }

    /// Update one chair's BCI data and recompute grid
    pub fn updateChair(self: *Grid, chair_idx: usize, bands: BandPowers) void {
        self.chairs[chair_idx].update(bands);
        self.propagate();
        self.tick += 1;
    }

    /// Propagate all 3 chair states into the grid
    pub fn propagate(self: *Grid) void {
        self.gf3_sum = 0;
        for (&self.cells) |*cell| {
            // Blend colors from all 3 chairs weighted by influence
            var r: f32 = 0;
            var g: f32 = 0;
            var b: f32 = 0;
            var trit_acc: f32 = 0;

            for (0..3) |c| {
                const rgb = self.chairs[c].state.toRgb();
                const w = cell.influence[c];
                r += @as(f32, @floatFromInt(rgb.r)) * w;
                g += @as(f32, @floatFromInt(rgb.g)) * w;
                b += @as(f32, @floatFromInt(rgb.b)) * w;
                trit_acc += @as(f32, @floatFromInt(self.chairs[c].state.trit)) * w;
            }

            cell.color = .{
                .r = @intFromFloat(std.math.clamp(r, 0, 255)),
                .g = @intFromFloat(std.math.clamp(g, 0, 255)),
                .b = @intFromFloat(std.math.clamp(b, 0, 255)),
            };

            // Classify cell trit by weighted average
            cell.trit = if (trit_acc > 0.33) 1 else if (trit_acc < -0.33) -1 else 0;
            self.gf3_sum += cell.trit;
        }
    }

    /// GF(3) distribution across the grid
    pub fn gf3Distribution(self: *const Grid) struct { plus: u32, ergodic: u32, minus: u32, balanced: bool } {
        var plus: u32 = 0;
        var erg: u32 = 0;
        var minus: u32 = 0;
        for (self.cells) |cell| {
            switch (cell.trit) {
                1 => plus += 1,
                0 => erg += 1,
                -1 => minus += 1,
                else => {},
            }
        }
        const total = @as(i32, @intCast(plus)) - @as(i32, @intCast(minus));
        return .{
            .plus = plus,
            .ergodic = erg,
            .minus = minus,
            .balanced = @mod(total, 3) == 0,
        };
    }

    /// Render grid as ANSI terminal block characters
    pub fn render(self: *const Grid, writer: anytype) !void {
        // Top border
        try writer.writeAll("\x1b[2J\x1b[H"); // clear + home
        try writer.writeAll("  Salon BCI Grid (");
        // Chair states
        for (self.chairs, 0..) |chair, i| {
            if (i > 0) try writer.writeAll(" | ");
            const h = chair.role.color().hex();
            try writer.print("\x1b[38;2;{d};{d};{d}m{s}\x1b[0m", .{
                chair.role.color().r,
                chair.role.color().g,
                chair.role.color().b,
                h[0..7],
            });
        }
        try writer.writeAll(")\n\n");

        // Grid cells as colored blocks
        for (0..GRID_ROWS) |row| {
            try writer.writeAll("  ");
            for (0..GRID_COLS) |col| {
                const cell = self.cells[row * GRID_COLS + col];
                try writer.print("\x1b[48;2;{d};{d};{d}m  \x1b[0m", .{
                    cell.color.r, cell.color.g, cell.color.b,
                });
            }
            try writer.writeAll("\n");
        }

        // Stats
        const dist = self.gf3Distribution();
        try writer.print("\n  GF(3): +{d} / 0:{d} / -{d}  balanced={}\n", .{
            dist.plus, dist.ergodic, dist.minus, dist.balanced,
        });
        try writer.print("  tick={d}  chairs: phi=[{d:.2},{d:.2},{d:.2}]  trits=[{d},{d},{d}]\n", .{
            self.tick,
            self.chairs[0].state.phi,
            self.chairs[1].state.phi,
            self.chairs[2].state.phi,
            self.chairs[0].state.trit,
            self.chairs[1].state.trit,
            self.chairs[2].state.trit,
        });
    }

    /// Encode current grid state as Syrup-compatible JSON for the CLI
    pub fn toJson(self: *const Grid, buf: []u8) ![]const u8 {
        var fbs = std.io.fixedBufferStream(buf);
        const w = fbs.writer();
        try w.writeAll("{\"tick\":");
        try writeUsize(w, self.tick);
        try w.writeAll(",\"gf3_sum\":");
        try writeI32(w, self.gf3_sum);
        try w.writeAll(",\"chairs\":[");
        for (self.chairs, 0..) |chair, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{{\"role\":{d},\"phi\":{d:.4},\"val\":{d:.4},\"ent\":{d:.4},\"trit\":{d},\"epoch\":{d}}}", .{
                @as(i8, @intCast(@intFromEnum(chair.role))),
                chair.state.phi,
                chair.state.valence,
                chair.state.entropy,
                @as(i8, chair.state.trit),
                chair.epoch,
            });
        }
        try w.writeAll("],\"grid\":[");
        for (self.cells, 0..) |cell, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("[{d},{d},{d},{d}]", .{ cell.color.r, cell.color.g, cell.color.b, @as(i8, cell.trit) });
        }
        try w.writeAll("]}");
        return fbs.getWritten();
    }
};

// ============================================================
// HSL → RGB conversion
// ============================================================

fn hslToRgb(h: f32, s: f32, l: f32) RGB {
    if (s < 0.001) {
        const v: u8 = @intFromFloat(l * 255.0);
        return .{ .r = v, .g = v, .b = v };
    }
    const q = if (l < 0.5) l * (1.0 + s) else l + s - l * s;
    const p = 2.0 * l - q;
    const hn = h / 360.0;
    return .{
        .r = hueToChannel(p, q, hn + 1.0 / 3.0),
        .g = hueToChannel(p, q, hn),
        .b = hueToChannel(p, q, hn - 1.0 / 3.0),
    };
}

fn hueToChannel(p: f32, q: f32, t_in: f32) u8 {
    var t = t_in;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    const v = if (t < 1.0 / 6.0)
        p + (q - p) * 6.0 * t
    else if (t < 1.0 / 2.0)
        q
    else if (t < 2.0 / 3.0)
        p + (q - p) * (2.0 / 3.0 - t) * 6.0
    else
        p;
    return @intFromFloat(std.math.clamp(v * 255.0, 0, 255));
}

fn writeUsize(writer: anytype, val: u64) !void {
    var tmp: [20]u8 = undefined;
    var n = val;
    var len: usize = 0;
    if (n == 0) {
        tmp[0] = '0';
        len = 1;
    } else {
        while (n > 0) : (len += 1) {
            tmp[len] = @intCast(n % 10 + '0');
            n /= 10;
        }
    }
    // Reverse
    var j: usize = 0;
    while (j < len / 2) : (j += 1) {
        const t = tmp[j];
        tmp[j] = tmp[len - 1 - j];
        tmp[len - 1 - j] = t;
    }
    try writer.writeAll(tmp[0..len]);
}

fn writeI32(writer: anytype, val: i32) !void {
    if (val < 0) {
        try writer.writeByte('-');
        try writeUsize(writer, @intCast(-val));
    } else {
        try writeUsize(writer, @intCast(val));
    }
}

// ============================================================
// Tests
// ============================================================

test "grid init has 81 cells" {
    const g = Grid.init();
    try std.testing.expectEqual(@as(usize, 81), g.cells.len);
}

test "chair roles sum to zero" {
    const sum = @as(i8, @intFromEnum(ChairRole.plus)) +
        @as(i8, @intFromEnum(ChairRole.ergodic)) +
        @as(i8, @intFromEnum(ChairRole.minus));
    try std.testing.expectEqual(@as(i8, 0), sum);
}

test "influence weights sum to 1" {
    const g = Grid.init();
    for (g.cells) |cell| {
        const sum = cell.influence[0] + cell.influence[1] + cell.influence[2];
        try std.testing.expect(@abs(sum - 1.0) < 0.01);
    }
}

test "resting state has low phi" {
    const chair = Chair.init(.plus);
    // Resting vs resting baseline → phi near 0
    try std.testing.expect(chair.state.phi < 0.1);
}

test "focused bands increase phi" {
    var chair = Chair.init(.plus);
    chair.update(.{ .delta = 0.1, .theta = 0.2, .alpha = 0.3, .beta = 0.7, .gamma = 0.5 });
    try std.testing.expect(chair.state.phi > 0.1);
}

test "grid propagate produces colors" {
    var g = Grid.init();
    g.updateChair(0, .{ .delta = 0.1, .theta = 0.2, .alpha = 0.3, .beta = 0.7, .gamma = 0.5 });
    g.updateChair(1, .{ .delta = 0.3, .theta = 0.3, .alpha = 0.8, .beta = 0.2, .gamma = 0.1 });
    g.updateChair(2, .{ .delta = 0.5, .theta = 0.9, .alpha = 0.4, .beta = 0.1, .gamma = 0.05 });
    // At least some cells should have non-zero color
    var nonzero: u32 = 0;
    for (g.cells) |cell| {
        if (cell.color.r > 0 or cell.color.g > 0 or cell.color.b > 0) nonzero += 1;
    }
    try std.testing.expect(nonzero > 40);
}

test "gf3 distribution covers all cells" {
    var g = Grid.init();
    g.propagate();
    const dist = g.gf3Distribution();
    try std.testing.expectEqual(@as(u32, GRID_CELLS), dist.plus + dist.ergodic + dist.minus);
}

test "fisher-rao distance is zero for identical" {
    const b = BandPowers{ .delta = 0.3, .theta = 0.3, .alpha = 0.8, .beta = 0.2, .gamma = 0.1 };
    const d = fisherRaoDistance(b, b);
    try std.testing.expect(d < 0.001);
}

test "fisher-rao distance is positive for different" {
    const a = BandPowers{ .delta = 0.3, .theta = 0.3, .alpha = 0.8, .beta = 0.2, .gamma = 0.1 };
    const b = BandPowers{ .delta = 0.1, .theta = 0.2, .alpha = 0.3, .beta = 0.7, .gamma = 0.5 };
    const d = fisherRaoDistance(a, b);
    try std.testing.expect(d > 0.1);
}

test "toJson roundtrip" {
    var g = Grid.init();
    g.updateChair(0, .{ .delta = 0.1, .theta = 0.2, .alpha = 0.9, .beta = 0.3, .gamma = 0.1 });
    var buf: [16384]u8 = undefined;
    const json = try g.toJson(&buf);
    // Should start with { and end with }
    try std.testing.expectEqual(@as(u8, '{'), json[0]);
    try std.testing.expectEqual(@as(u8, '}'), json[json.len - 1]);
    // Should contain "tick"
    try std.testing.expect(std.mem.indexOf(u8, json, "tick") != null);
}

test "band entropy maximal for uniform" {
    const uniform = BandPowers{ .delta = 1, .theta = 1, .alpha = 1, .beta = 1, .gamma = 1 };
    const ent = uniform.entropy();
    // log2(5) ≈ 2.322
    try std.testing.expect(@abs(ent - 2.322) < 0.01);
}

test "band entropy zero for pure" {
    const pure = BandPowers{ .delta = 0, .theta = 0, .alpha = 1, .beta = 0, .gamma = 0 };
    const ent = pure.entropy();
    try std.testing.expect(ent < 0.01);
}

test "rgb lerp midpoint" {
    const a = RGB{ .r = 0, .g = 0, .b = 0 };
    const b = RGB{ .r = 200, .g = 100, .b = 50 };
    const mid = RGB.lerp(a, b, 0.5);
    try std.testing.expectEqual(@as(u8, 100), mid.r);
    try std.testing.expectEqual(@as(u8, 50), mid.g);
    try std.testing.expectEqual(@as(u8, 25), mid.b);
}
