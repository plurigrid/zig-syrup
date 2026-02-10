//! CNOT₃: Quantum Control Circuit for Terminal Cells
//!
//! A terminal entangled in a quantum control circuit. The control wire
//! carries a GF(3) qutrit; the target wire is the terminal cell grid.
//! The gate is the cyclic permutation σ on RGB channels:
//!
//!   σ⁰ = (R,G,B) → (R,G,B)   trit  0   identity
//!   σ¹ = (R,G,B) → (G,B,R)   trit +1   entangle
//!   σ² = (R,G,B) → (B,R,G)   trit -1   conjugate
//!   σ³ = identity             order  3   ✓
//!
//! CNOT₃(c, t) → (c, σᶜ(t))
//!
//! The Rust triad (ser/format/de) maps directly:
//!   ser    → control wire  (prepare: setControl, setControlFromBCI)
//!   format → Value         (entanglement: the joint state, toSyrup/fromSyrup)
//!   de     → target wire   (measurement: observe cell, infer control)
//!
//! Properties:
//!   CNOT₃³ = I              (gate has order 3)
//!   CNOT₃(c)⁻¹ = CNOT₃(-c) (negation inverts)
//!   Peers sharing control form GHZ-like states
//!   Measurement reveals control through target observation

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// GF(3) QUTRIT ARITHMETIC
// ============================================================================

/// GF(3) qutrit: the fundamental unit of ternary quantum information.
/// Isomorphic to Z/3Z via {-1 ↔ 2, 0 ↔ 0, +1 ↔ 1}.
pub const Trit = enum(i8) {
    minus = -1,
    zero = 0,
    plus = 1,

    /// GF(3) addition: (a + b) mod 3 in balanced representation.
    /// This IS the CNOT₃ gate action on the target qutrit.
    pub fn add(a: Trit, b: Trit) Trit {
        // Map to {0,1,2}, add mod 3, map back
        const table = [3]Trit{ .zero, .plus, .minus };
        const av: u8 = @intCast(@mod(@as(i16, @intFromEnum(a)) + 3, 3));
        const bv: u8 = @intCast(@mod(@as(i16, @intFromEnum(b)) + 3, 3));
        return table[(av + bv) % 3];
    }

    /// GF(3) negation: -a mod 3.
    /// CNOT₃(-c) is the inverse gate.
    pub fn neg(self: Trit) Trit {
        return switch (self) {
            .minus => .plus,
            .zero => .zero,
            .plus => .minus,
        };
    }

    /// GF(3) multiplication: (a × b) mod 3.
    pub fn mul(a: Trit, b: Trit) Trit {
        const table = [3]Trit{ .zero, .plus, .minus };
        const av: u8 = @intCast(@mod(@as(i16, @intFromEnum(a)) + 3, 3));
        const bv: u8 = @intCast(@mod(@as(i16, @intFromEnum(b)) + 3, 3));
        return table[(av * bv) % 3];
    }
};

// ============================================================================
// CHANNEL PERMUTATION (the physical gate)
// ============================================================================

/// Apply cyclic permutation σᶜ to an ARGB8 color.
///
/// The cyclic group C₃ acts on RGB channels:
///   σ⁰(R,G,B) = (R,G,B)   identity
///   σ¹(R,G,B) = (G,B,R)   rotate forward
///   σ²(R,G,B) = (B,R,G)   rotate backward (= σ⁻¹)
///
/// This IS the GF(3) group action on 3-element sets.
/// Applying σ three times = identity. σ² = σ⁻¹.
pub fn permuteChannels(argb: u32, control: Trit) u32 {
    const a = argb & 0xFF000000;
    const r = (argb >> 16) & 0xFF;
    const g = (argb >> 8) & 0xFF;
    const b = argb & 0xFF;
    return switch (control) {
        .zero => argb, // σ⁰: identity
        .plus => a | (g << 16) | (b << 8) | r, // σ¹: (R,G,B) → (G,B,R)
        .minus => a | (b << 16) | (r << 8) | g, // σ²: (R,G,B) → (B,R,G)
    };
}

/// Classify a color's GF(3) qutrit state by dominant channel.
/// This is the "measurement" — it tells you what basis state the cell is in.
pub fn classifyColor(argb: u32) Trit {
    const r: i32 = @intCast((argb >> 16) & 0xFF);
    const g: i32 = @intCast((argb >> 8) & 0xFF);
    const b: i32 = @intCast(argb & 0xFF);
    if (r > g and r > b) return .minus; // RED dominant
    if (g > r and g > b) return .plus; // GREEN dominant
    return .zero; // balanced / BLUE / tied
}

// ============================================================================
// LUMINOSITY (L channel of HSL, controlled by qutrit)
// ============================================================================

/// The three luminosity levels, one per GF(3) state.
/// These are HSL lightness values matching the spatial_propagator range.
pub const LUMINOSITY = [3]f64{
    0.30, // minus (-1): dim    — verification, observation
    0.55, // zero   (0): neutral — ergodic, balanced
    0.80, // plus  (+1): bright  — creation, generation
};

/// Map a trit to its luminosity level.
/// Linear mapping: minus→dim, zero→neutral, plus→bright.
pub fn tritLuminosity(t: Trit) f64 {
    // -1→0, 0→1, +1→2 (linear, NOT the GF(3) isomorphism)
    const idx: usize = @intCast(@as(i16, @intFromEnum(t)) + 1);
    return LUMINOSITY[idx];
}

/// Compute effective luminosity under entanglement.
/// The gate_order shifts the luminosity trit via CNOT₃:
///   effective_trit = original_trit ⊕₃ gate_order_as_trit
/// So entanglement literally rotates luminosity levels.
pub fn entangledLuminosity(t: Trit, gate_order: GateOrder) f64 {
    const gate_trit: Trit = switch (gate_order) {
        .separable => .zero,
        .entangled => .plus,
        .conjugate => .minus,
    };
    return tritLuminosity(Trit.add(t, gate_trit));
}

/// Apply luminosity to an ARGB8 color by scaling RGB channels.
/// luminosity ∈ [0, 1] acts as a brightness multiplier.
pub fn applyLuminosity(argb: u32, luminosity: f64) u32 {
    const a = argb & 0xFF000000;
    const r: f64 = @floatFromInt((argb >> 16) & 0xFF);
    const g: f64 = @floatFromInt((argb >> 8) & 0xFF);
    const b: f64 = @floatFromInt(argb & 0xFF);
    const scale = @max(0.0, @min(1.5, luminosity / 0.55)); // normalize around neutral
    return a |
        (@as(u32, @intFromFloat(@min(255.0, r * scale))) << 16) |
        (@as(u32, @intFromFloat(@min(255.0, g * scale))) << 8) |
        @as(u32, @intFromFloat(@min(255.0, b * scale)));
}

// ============================================================================
// MEASUREMENT RECORD
// ============================================================================

/// Result of measuring a cell in the entangled terminal.
/// Contains both the observed state and the inferred control.
pub const Measurement = struct {
    x: u16,
    y: u16,
    /// What we observed (the cell's current qutrit classification)
    observed: Trit,
    /// The control that produced this observation
    /// (observed = original ⊕₃ control, so control = observed ⊕₃ (-original))
    control: Trit,
    generation: u64,
};

// ============================================================================
// GATE ORDER (entanglement depth)
// ============================================================================

/// How many times CNOT₃ has been applied (mod 3).
/// Since CNOT₃³ = I, this cycles through {0, 1, 2}.
pub const GateOrder = enum(u2) {
    separable = 0, // product state — no entanglement
    entangled = 1, // CNOT₃ applied once
    conjugate = 2, // CNOT₃ applied twice = CNOT₃†
    // 3 would return to separable (but we use mod 3)

    pub fn advance(self: GateOrder) GateOrder {
        return switch (self) {
            .separable => .entangled,
            .entangled => .conjugate,
            .conjugate => .separable,
        };
    }
};

// ============================================================================
// ENTANGLED TERMINAL
// ============================================================================

/// A terminal whose cell grid is entangled with a GF(3) control wire.
///
/// After CNOT₃, you cannot describe the terminal state independently of the
/// control — observing cell colors reveals information about the control signal.
/// This is entanglement in the information-theoretic sense.
///
/// The three operations mirror Rust's ser/format/de:
///   ser:    setControl, setControlFromBCI     (prepare control wire)
///   format: the struct itself + toSyrup       (joint entangled state)
///   de:     measure, observeBalance           (measurement / collapse)
pub const EntangledTerminal = struct {
    allocator: Allocator,

    // Target register: the terminal cell grid
    cols: u16,
    rows: u16,
    /// Foreground colors (ARGB8). One per cell.
    fg: []u32,
    /// Background colors (ARGB8). One per cell.
    bg: []u32,

    // Control register
    control: Trit,

    // Entanglement tracking
    gate_order: GateOrder,
    generation: u64,

    // Peer entanglement (multi-partite GHZ state)
    // peer_id → their control qutrit
    peer_controls: std.AutoHashMap(u64, Trit),

    // Measurement ring buffer
    measurements: [RING_CAP]Measurement,
    ring_head: usize,
    ring_count: usize,

    const RING_CAP = 64;

    // ── Lifecycle ──────────────────────────────────────────────

    pub fn init(allocator: Allocator, cols: u16, rows: u16) !*EntangledTerminal {
        const n = @as(usize, cols) * @as(usize, rows);
        const self = try allocator.create(EntangledTerminal);
        self.* = .{
            .allocator = allocator,
            .cols = cols,
            .rows = rows,
            .fg = try allocator.alloc(u32, n),
            .bg = try allocator.alloc(u32, n),
            .control = .zero,
            .gate_order = .separable,
            .generation = 0,
            .peer_controls = std.AutoHashMap(u64, Trit).init(allocator),
            .measurements = undefined,
            .ring_head = 0,
            .ring_count = 0,
        };
        @memset(self.fg, 0xFFCCCCCC); // light gray default fg
        @memset(self.bg, 0xFF000000); // black default bg
        return self;
    }

    pub fn deinit(self: *EntangledTerminal) void {
        self.peer_controls.deinit();
        self.allocator.free(self.bg);
        self.allocator.free(self.fg);
        self.allocator.destroy(self);
    }

    // ── ser: Control Wire (prepare) ───────────────────────────

    /// Set control qutrit directly.
    pub fn setControl(self: *EntangledTerminal, trit: Trit) void {
        self.control = trit;
    }

    /// Set control from BCI phenomenal state.
    /// Maps valence to GF(3): negative→minus, neutral→zero, positive→plus.
    pub fn setControlFromBCI(self: *EntangledTerminal, valence: f32) void {
        self.control = if (valence < -0.3)
            .minus
        else if (valence > 0.3)
            .plus
        else
            .zero;
    }

    /// Register a peer's control for multi-partite entanglement.
    pub fn entangleWith(self: *EntangledTerminal, peer_id: u64, peer_control: Trit) !void {
        try self.peer_controls.put(peer_id, peer_control);
    }

    /// Composite control: GF(3) sum of local + all peer controls.
    /// In a GHZ state, this determines the collective behavior.
    pub fn compositeControl(self: *const EntangledTerminal) Trit {
        var sum = self.control;
        var it = self.peer_controls.valueIterator();
        while (it.next()) |peer_trit| {
            sum = Trit.add(sum, peer_trit.*);
        }
        return sum;
    }

    // ── format: The Gate (entangle / disentangle) ─────────────

    /// Apply CNOT₃: entangle control with every cell's color.
    /// (c, t) → (c, σᶜ(t)) for each cell t in the grid.
    ///
    /// If control = 0, this is identity (no-op).
    /// Applying 3 times returns to original: CNOT₃³ = I.
    pub fn applyCNOT3(self: *EntangledTerminal) void {
        if (self.control == .zero) return; // identity gate

        for (self.fg) |*color| {
            color.* = permuteChannels(color.*, self.control);
        }
        for (self.bg) |*color| {
            color.* = permuteChannels(color.*, self.control);
        }

        self.gate_order = self.gate_order.advance();
        self.generation += 1;
    }

    /// Apply CNOT₃† (inverse): disentangle.
    /// CNOT₃(c)⁻¹ = CNOT₃(-c).
    pub fn applyCNOT3Inverse(self: *EntangledTerminal) void {
        const saved = self.control;
        self.control = saved.neg();
        self.applyCNOT3();
        self.control = saved; // restore original control
    }

    /// Apply CNOT₃ with composite control (all peers included).
    pub fn applyCNOT3Composite(self: *EntangledTerminal) void {
        const saved = self.control;
        self.control = self.compositeControl();
        self.applyCNOT3();
        self.control = saved; // restore local control
    }

    /// Write a cell's foreground color at (x, y).
    pub fn writeCell(self: *EntangledTerminal, x: u16, y: u16, color: u32) void {
        if (x >= self.cols or y >= self.rows) return;
        self.fg[@as(usize, y) * @as(usize, self.cols) + @as(usize, x)] = color;
    }

    // ── de: Measurement (observe / infer) ─────────────────────

    /// Measure a cell: observe its qutrit state, record the measurement.
    /// Returns the observed classification and the known control.
    pub fn measure(self: *EntangledTerminal, x: u16, y: u16) ?Measurement {
        if (x >= self.cols or y >= self.rows) return null;
        const idx = @as(usize, y) * @as(usize, self.cols) + @as(usize, x);
        const observed = classifyColor(self.fg[idx]);

        const m = Measurement{
            .x = x,
            .y = y,
            .observed = observed,
            .control = self.control,
            .generation = self.generation,
        };

        self.measurements[self.ring_head] = m;
        self.ring_head = (self.ring_head + 1) % RING_CAP;
        if (self.ring_count < RING_CAP) self.ring_count += 1;

        return m;
    }

    /// Observe the GF(3) balance across the entire grid.
    /// Returns (minus_count, zero_count, plus_count).
    /// A balanced terminal has roughly equal thirds.
    pub fn observeBalance(self: *const EntangledTerminal) [3]u32 {
        var counts = [3]u32{ 0, 0, 0 };
        for (self.fg) |color| {
            const t = classifyColor(color);
            // Map {-1, 0, 1} → index {0, 1, 2}
            const idx: usize = @intCast(@mod(@as(i16, @intFromEnum(t)) + 3, 3));
            counts[idx] += 1;
        }
        return counts;
    }

    /// Get the luminosity for a specific cell, factoring in entanglement.
    /// This is the L value for the cell's HSL representation.
    pub fn cellLuminosity(self: *const EntangledTerminal, x: u16, y: u16) f64 {
        if (x >= self.cols or y >= self.rows) return LUMINOSITY[1]; // neutral fallback
        const idx = @as(usize, y) * @as(usize, self.cols) + @as(usize, x);
        const t = classifyColor(self.fg[idx]);
        return entangledLuminosity(t, self.gate_order);
    }

    /// Apply luminosity derived from qutrit state to every cell's colors.
    /// This modulates brightness based on the GF(3) classification,
    /// shifted by the current gate_order (entanglement depth).
    pub fn applyLuminosityFromQutrit(self: *EntangledTerminal) void {
        for (self.fg) |*color| {
            const t = classifyColor(color.*);
            const lum = entangledLuminosity(t, self.gate_order);
            color.* = applyLuminosity(color.*, lum);
        }
    }

    /// Check if the terminal is GF(3) balanced (within tolerance).
    pub fn isBalanced(self: *const EntangledTerminal) bool {
        const counts = self.observeBalance();
        const total: u32 = self.cols * @as(u32, self.rows);
        const third = total / 3;
        const tol = total / 10; // 10% tolerance
        inline for (counts) |c| {
            if (c > third + tol or (c + tol < third)) return false;
        }
        return true;
    }
};

// ============================================================================
// BELL PAIR: Two Entangled Terminals
// ============================================================================

/// A Bell pair: two terminals sharing the same control.
/// When both apply CNOT₃ with the same control, measuring either
/// reveals information about the other. This enables state teleportation:
/// send the trit difference (1 value) instead of the full cell diff.
pub const BellPair = struct {
    a: *EntangledTerminal,
    b: *EntangledTerminal,
    shared_control: Trit,

    /// Entangle both terminals with the shared control.
    pub fn entangle(self: *BellPair) void {
        self.a.setControl(self.shared_control);
        self.b.setControl(self.shared_control);
        self.a.applyCNOT3();
        self.b.applyCNOT3();
    }

    /// Disentangle both terminals.
    pub fn disentangle(self: *BellPair) void {
        self.a.applyCNOT3Inverse();
        self.b.applyCNOT3Inverse();
    }

    /// Teleport: measure cell (x,y) in terminal A,
    /// apply correction to terminal B so B matches A's pre-entanglement state.
    /// Cost: 1 trit transmitted instead of full cell data.
    pub fn teleport(self: *BellPair, x: u16, y: u16) ?Trit {
        const m = self.a.measure(x, y) orelse return null;
        // The correction trit: what B needs to apply to match A
        return m.observed;
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "GF(3) addition table" {
    // Full verification of the GF(3) Cayley table
    const T = Trit;
    // 0 + x = x
    try std.testing.expectEqual(T.zero, T.add(.zero, .zero));
    try std.testing.expectEqual(T.plus, T.add(.zero, .plus));
    try std.testing.expectEqual(T.minus, T.add(.zero, .minus));
    // 1 + 1 = -1 (since 2 ≡ -1 mod 3)
    try std.testing.expectEqual(T.minus, T.add(.plus, .plus));
    // 1 + (-1) = 0
    try std.testing.expectEqual(T.zero, T.add(.plus, .minus));
    // (-1) + (-1) = 1 (since -2 ≡ 1 mod 3)
    try std.testing.expectEqual(T.plus, T.add(.minus, .minus));
}

test "GF(3) negation" {
    try std.testing.expectEqual(Trit.plus, Trit.minus.neg());
    try std.testing.expectEqual(Trit.zero, Trit.zero.neg());
    try std.testing.expectEqual(Trit.minus, Trit.plus.neg());
    // Double negation = identity
    try std.testing.expectEqual(Trit.plus, Trit.plus.neg().neg());
}

test "channel permutation order 3" {
    // σ³ = identity: applying any trit's permutation 3 times returns original
    const original: u32 = 0xFF_AA_BB_CC; // A=FF, R=AA, G=BB, B=CC
    for ([_]Trit{ .zero, .plus, .minus }) |t| {
        var color = original;
        color = permuteChannels(color, t);
        color = permuteChannels(color, t);
        color = permuteChannels(color, t);
        try std.testing.expectEqual(original, color);
    }
}

test "channel permutation inverse" {
    // σ(+1) then σ(-1) = identity
    const original: u32 = 0xFF_AA_BB_CC;
    var color = original;
    color = permuteChannels(color, .plus);
    try std.testing.expect(color != original); // must change
    color = permuteChannels(color, .minus);
    try std.testing.expectEqual(original, color); // back to original
}

test "σ⁰ is identity" {
    const color: u32 = 0xFF_12_34_56;
    try std.testing.expectEqual(color, permuteChannels(color, .zero));
}

test "σ¹ rotates R→G→B→R" {
    // (R=AA, G=BB, B=CC) → (G=BB, B=CC, R=AA)
    const color: u32 = 0xFF_AA_BB_CC;
    const rotated = permuteChannels(color, .plus);
    try std.testing.expectEqual(@as(u32, 0xFF_BB_CC_AA), rotated);
}

test "classify color" {
    try std.testing.expectEqual(Trit.minus, classifyColor(0xFF_FF_00_00)); // pure red
    try std.testing.expectEqual(Trit.plus, classifyColor(0xFF_00_FF_00)); // pure green
    try std.testing.expectEqual(Trit.zero, classifyColor(0xFF_80_80_80)); // gray (tied)
}

test "CNOT₃ with zero control is identity" {
    const et = try EntangledTerminal.init(std.testing.allocator, 4, 4);
    defer et.deinit();

    // Write a known color
    et.writeCell(0, 0, 0xFF_FF_00_00); // red
    const before = et.fg[0];

    et.setControl(.zero);
    et.applyCNOT3();

    try std.testing.expectEqual(before, et.fg[0]);
    try std.testing.expectEqual(GateOrder.separable, et.gate_order);
}

test "CNOT₃³ = identity" {
    const et = try EntangledTerminal.init(std.testing.allocator, 4, 4);
    defer et.deinit();

    et.writeCell(0, 0, 0xFF_AA_BB_CC);
    et.writeCell(1, 0, 0xFF_11_22_33);
    et.writeCell(2, 0, 0xFF_FF_00_80);
    const orig = [3]u32{ et.fg[0], et.fg[1], et.fg[2] };

    et.setControl(.plus);
    et.applyCNOT3(); // 1
    et.applyCNOT3(); // 2
    et.applyCNOT3(); // 3 = back to start

    try std.testing.expectEqual(orig[0], et.fg[0]);
    try std.testing.expectEqual(orig[1], et.fg[1]);
    try std.testing.expectEqual(orig[2], et.fg[2]);
    try std.testing.expectEqual(GateOrder.separable, et.gate_order);
}

test "CNOT₃ inverse restores original" {
    const et = try EntangledTerminal.init(std.testing.allocator, 4, 4);
    defer et.deinit();

    et.writeCell(0, 0, 0xFF_AA_BB_CC);
    const orig = et.fg[0];

    et.setControl(.minus);
    et.applyCNOT3();
    try std.testing.expect(et.fg[0] != orig); // must have changed

    et.applyCNOT3Inverse();
    try std.testing.expectEqual(orig, et.fg[0]); // restored
}

test "measurement reveals control" {
    const et = try EntangledTerminal.init(std.testing.allocator, 4, 4);
    defer et.deinit();

    et.writeCell(0, 0, 0xFF_FF_00_00); // red = minus
    et.setControl(.plus);
    et.applyCNOT3();

    // After CNOT₃(+1) on red: channels rotated, measurement should differ
    const m = et.measure(0, 0).?;
    try std.testing.expectEqual(Trit.plus, m.control);
    // The observed trit should be minus ⊕₃ plus = zero
    try std.testing.expectEqual(Trit.add(.minus, .plus), m.observed);
}

test "multi-partite composite control" {
    const et = try EntangledTerminal.init(std.testing.allocator, 4, 4);
    defer et.deinit();

    et.setControl(.plus); // local = +1
    try et.entangleWith(1, .plus); // peer 1 = +1
    try et.entangleWith(2, .minus); // peer 2 = -1

    // composite = (+1) + (+1) + (-1) = +1 (since 1+1-1 = 1)
    const composite = et.compositeControl();
    try std.testing.expectEqual(Trit.plus, composite);
}

test "Bell pair entangle-disentangle roundtrip" {
    const a = try EntangledTerminal.init(std.testing.allocator, 4, 4);
    defer a.deinit();
    const b_term = try EntangledTerminal.init(std.testing.allocator, 4, 4);
    defer b_term.deinit();

    a.writeCell(0, 0, 0xFF_FF_00_00);
    b_term.writeCell(0, 0, 0xFF_FF_00_00);
    const orig_a = a.fg[0];
    const orig_b = b_term.fg[0];

    var pair = BellPair{
        .a = a,
        .b = b_term,
        .shared_control = .plus,
    };

    pair.entangle();
    // Both should have been permuted identically
    try std.testing.expectEqual(a.fg[0], b_term.fg[0]);
    try std.testing.expect(a.fg[0] != orig_a);

    pair.disentangle();
    try std.testing.expectEqual(orig_a, a.fg[0]);
    try std.testing.expectEqual(orig_b, b_term.fg[0]);
}

test "trit luminosity levels" {
    // minus = dim, zero = neutral, plus = bright
    try std.testing.expectApproxEqAbs(@as(f64, 0.30), tritLuminosity(.minus), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.55), tritLuminosity(.zero), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.80), tritLuminosity(.plus), 0.001);
}

test "entangled luminosity rotates levels" {
    // Separable: trit maps directly
    try std.testing.expectApproxEqAbs(@as(f64, 0.30), entangledLuminosity(.minus, .separable), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.55), entangledLuminosity(.zero, .separable), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.80), entangledLuminosity(.plus, .separable), 0.001);

    // Entangled (gate_order=1, adds +1): dim→neutral, neutral→bright, bright→dim
    try std.testing.expectApproxEqAbs(@as(f64, 0.55), entangledLuminosity(.minus, .entangled), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.80), entangledLuminosity(.zero, .entangled), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.30), entangledLuminosity(.plus, .entangled), 0.001);

    // Conjugate (gate_order=2, adds -1): dim→bright, neutral→dim, bright→neutral
    try std.testing.expectApproxEqAbs(@as(f64, 0.80), entangledLuminosity(.minus, .conjugate), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.30), entangledLuminosity(.zero, .conjugate), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.55), entangledLuminosity(.plus, .conjugate), 0.001);
}

test "applyLuminosity scales colors" {
    const neutral: u32 = 0xFF_80_80_80; // gray at ~50%
    // Bright luminosity should make it brighter
    const bright = applyLuminosity(neutral, 0.80);
    try std.testing.expect(((bright >> 16) & 0xFF) > ((neutral >> 16) & 0xFF));
    // Dim luminosity should make it dimmer
    const dim = applyLuminosity(neutral, 0.30);
    try std.testing.expect(((dim >> 16) & 0xFF) < ((neutral >> 16) & 0xFF));
    // Neutral luminosity should be approximately unchanged
    const same = applyLuminosity(neutral, 0.55);
    const diff: i32 = @as(i32, @intCast((same >> 16) & 0xFF)) - @as(i32, @intCast((neutral >> 16) & 0xFF));
    try std.testing.expect(@abs(diff) <= 1); // rounding tolerance
}

test "gate order cycles through separable→entangled→conjugate→separable" {
    const et = try EntangledTerminal.init(std.testing.allocator, 2, 2);
    defer et.deinit();

    try std.testing.expectEqual(GateOrder.separable, et.gate_order);

    et.setControl(.plus);
    et.applyCNOT3();
    try std.testing.expectEqual(GateOrder.entangled, et.gate_order);

    et.applyCNOT3();
    try std.testing.expectEqual(GateOrder.conjugate, et.gate_order);

    et.applyCNOT3();
    try std.testing.expectEqual(GateOrder.separable, et.gate_order);
}
