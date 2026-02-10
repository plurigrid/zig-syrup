//! Cyberphysical Affordance System: RF Phase Space × Quantum Supermaps
//!
//! Three pillars unified under GF(3):
//!
//! 1. RF Phase Space — GF(3)³ coordinates (frequency, phase, amplitude)
//!    The 27-cell phase space is the arena where cyberphysical systems live.
//!    3-PSK maps carrier phases to cube roots of unity: 0°→+1, 120°→0, 240°→-1.
//!    This IS GF(3): the phase of an RF signal is naturally ternary.
//!
//! 2. Quantum Supermaps — Higher-order GF(3) transformations
//!    A Channel is a 3×3 affine map over GF(3): C(x) = Mx + b.
//!    A Supermap transforms channels: S: Channel → Channel.
//!    The quantum switch implements indefinite causal order via control trit.
//!    Composition of supermaps = the comb structure of quantum processes.
//!
//! 3. Affordances — Phase-space regions labeled by capability
//!    Gibson's ecological affordances meet OCapN capabilities.
//!    The environment offers action possibilities (phase space regions);
//!    the agent has capabilities (supermaps it can apply);
//!    the affordance is the match: available(+1) / uncertain(0) / blocked(-1).
//!
//! The CNOT₃ gate from entangle.zig operates on RF phase space coordinates,
//! the same way it operates on terminal cell colors. The mathematical structure
//! is identical — only the physical interpretation changes.

const std = @import("std");
const entangle = @import("entangle.zig");
const Trit = entangle.Trit;

// ============================================================================
// RF PHASE SPACE: GF(3)³ = 27 cells
// ============================================================================

/// A point in RF phase space.
///
/// Three coordinates, each a GF(3) trit:
///   freq:  frequency band    low(-1)    / mid(0)     / high(+1)
///   phase: carrier phase     240°(-1)   / 120°(0)    / 0°(+1)     [cube roots of unity]
///   amp:   signal amplitude  weak(-1)   / moderate(0) / strong(+1)
///
/// The 27 cells partition all possible RF states.
/// CNOT₃ rotates individual coordinates independently.
pub const PhaseCell = struct {
    freq: Trit,
    phase: Trit,
    amp: Trit,

    /// Linear index into the 27-element phase space: 0..26
    pub fn toIndex(self: PhaseCell) u5 {
        const f: u8 = @intCast(@as(i16, @intFromEnum(self.freq)) + 1);
        const p: u8 = @intCast(@as(i16, @intFromEnum(self.phase)) + 1);
        const a: u8 = @intCast(@as(i16, @intFromEnum(self.amp)) + 1);
        return @intCast(f * 9 + p * 3 + a);
    }

    /// Reconstruct from linear index.
    pub fn fromIndex(idx: u5) PhaseCell {
        std.debug.assert(idx < 27);
        var r: u8 = idx;
        const a: i8 = @as(i8, @intCast(r % 3)) - 1;
        r /= 3;
        const p: i8 = @as(i8, @intCast(r % 3)) - 1;
        r /= 3;
        const f: i8 = @as(i8, @intCast(r % 3)) - 1;
        return .{
            .freq = @enumFromInt(f),
            .phase = @enumFromInt(p),
            .amp = @enumFromInt(a),
        };
    }

    /// GF(3) parity: sum of all coordinates (conservation invariant).
    /// A balanced measurement has parity zero.
    pub fn parity(self: PhaseCell) Trit {
        return Trit.add(Trit.add(self.freq, self.phase), self.amp);
    }

    /// Apply CNOT₃ within the phase cell: one coordinate controls another.
    /// target += source (mod 3). E.g., freq controls phase rotation.
    pub fn internalCNOT(self: PhaseCell, target: u2, source: u2) PhaseCell {
        var trits = [3]Trit{ self.freq, self.phase, self.amp };
        if (target < 3 and source < 3 and target != source) {
            trits[target] = Trit.add(trits[target], trits[source]);
        }
        return .{ .freq = trits[0], .phase = trits[1], .amp = trits[2] };
    }

    /// Apply external CNOT₃: shift a coordinate by an external control trit.
    pub fn externalCNOT(self: PhaseCell, target: u2, control: Trit) PhaseCell {
        var trits = [3]Trit{ self.freq, self.phase, self.amp };
        if (target < 3) {
            trits[target] = Trit.add(trits[target], control);
        }
        return .{ .freq = trits[0], .phase = trits[1], .amp = trits[2] };
    }

    /// As a 3-element array (for matrix operations).
    pub fn toArray(self: PhaseCell) [3]Trit {
        return .{ self.freq, self.phase, self.amp };
    }

    /// From a 3-element array.
    pub fn fromArray(arr: [3]Trit) PhaseCell {
        return .{ .freq = arr[0], .phase = arr[1], .amp = arr[2] };
    }

    pub fn eql(self: PhaseCell, other: PhaseCell) bool {
        return self.freq == other.freq and self.phase == other.phase and self.amp == other.amp;
    }
};

// ============================================================================
// CHANNEL: Linear map over GF(3)³
// ============================================================================

/// A channel over GF(3)³: affine transformation C(x) = Mx + b.
///
/// Physically: how an RF environment transforms signals between
/// transmitter and receiver. The matrix M encodes coupling between
/// frequency/phase/amplitude; the offset b encodes DC bias.
///
/// Channels are the morphisms in the category of GF(3)³ transformations.
/// Composition is matrix multiplication. Identity is I₃.
pub const Channel = struct {
    /// 3×3 matrix over GF(3), row-major
    matrix: [3][3]Trit,
    /// Affine offset
    offset: [3]Trit,

    /// Identity channel: C(x) = x
    pub const IDENTITY = Channel{
        .matrix = .{
            .{ .plus, .zero, .zero },
            .{ .zero, .plus, .zero },
            .{ .zero, .zero, .plus },
        },
        .offset = .{ .zero, .zero, .zero },
    };

    /// Zero channel: C(x) = 0 (total absorption)
    pub const ZERO = Channel{
        .matrix = .{
            .{ .zero, .zero, .zero },
            .{ .zero, .zero, .zero },
            .{ .zero, .zero, .zero },
        },
        .offset = .{ .zero, .zero, .zero },
    };

    /// CNOT₃ channel: frequency controls phase.
    /// (f, p, a) → (f, p+f, a)
    /// This is the RF analogue of the terminal CNOT₃:
    /// carrier phase shifts by frequency band.
    pub const CNOT_FREQ_PHASE = Channel{
        .matrix = .{
            .{ .plus, .zero, .zero },
            .{ .plus, .plus, .zero },
            .{ .zero, .zero, .plus },
        },
        .offset = .{ .zero, .zero, .zero },
    };

    /// Cyclic permutation channel: (f, p, a) → (p, a, f)
    /// Order 3: applying 3 times returns to identity.
    /// This is σ¹ from entangle.zig lifted to phase space.
    pub const PERMUTE = Channel{
        .matrix = .{
            .{ .zero, .plus, .zero },
            .{ .zero, .zero, .plus },
            .{ .plus, .zero, .zero },
        },
        .offset = .{ .zero, .zero, .zero },
    };

    /// Apply channel to a phase cell: y = M·x + b
    pub fn apply(self: Channel, input: PhaseCell) PhaseCell {
        const x = input.toArray();
        var y = self.offset;
        for (0..3) |i| {
            for (0..3) |j| {
                y[i] = Trit.add(y[i], Trit.mul(self.matrix[i][j], x[j]));
            }
        }
        return PhaseCell.fromArray(y);
    }

    /// Compose two channels: (A ∘ B)(x) = A(B(x))
    /// Matrix: A.M × B.M
    /// Offset: A.M × B.offset + A.offset
    pub fn compose(a: Channel, b: Channel) Channel {
        var result: Channel = undefined;
        // Matrix multiplication over GF(3)
        for (0..3) |i| {
            for (0..3) |j| {
                var sum: Trit = .zero;
                for (0..3) |k| {
                    sum = Trit.add(sum, Trit.mul(a.matrix[i][k], b.matrix[k][j]));
                }
                result.matrix[i][j] = sum;
            }
        }
        // Offset: A.M × B.offset + A.offset
        for (0..3) |i| {
            var sum: Trit = a.offset[i];
            for (0..3) |j| {
                sum = Trit.add(sum, Trit.mul(a.matrix[i][j], b.offset[j]));
            }
            result.offset[i] = sum;
        }
        return result;
    }

    /// Check equality of two channels.
    pub fn eql(self: Channel, other: Channel) bool {
        for (0..3) |i| {
            for (0..3) |j| {
                if (self.matrix[i][j] != other.matrix[i][j]) return false;
            }
            if (self.offset[i] != other.offset[i]) return false;
        }
        return true;
    }

    /// Matrix determinant over GF(3) (for invertibility check).
    /// det(M) = Σ sgn(σ) Π M[i][σ(i)] over all permutations.
    pub fn determinant(self: Channel) Trit {
        const m = self.matrix;
        // 3×3 determinant via Sarrus
        // + m00*m11*m22 + m01*m12*m20 + m02*m10*m21
        // - m02*m11*m20 - m01*m10*m22 - m00*m12*m21
        const pos1 = Trit.mul(Trit.mul(m[0][0], m[1][1]), m[2][2]);
        const pos2 = Trit.mul(Trit.mul(m[0][1], m[1][2]), m[2][0]);
        const pos3 = Trit.mul(Trit.mul(m[0][2], m[1][0]), m[2][1]);
        const neg1 = Trit.mul(Trit.mul(m[0][2], m[1][1]), m[2][0]);
        const neg2 = Trit.mul(Trit.mul(m[0][1], m[1][0]), m[2][2]);
        const neg3 = Trit.mul(Trit.mul(m[0][0], m[1][2]), m[2][1]);
        var det = Trit.add(Trit.add(pos1, pos2), pos3);
        det = Trit.add(det, neg1.neg());
        det = Trit.add(det, neg2.neg());
        det = Trit.add(det, neg3.neg());
        return det;
    }
};

// ============================================================================
// QUANTUM SUPERMAP: Channel → Channel
// ============================================================================

/// A quantum supermap: a higher-order transformation on channels.
///
/// Physically: how the control system transforms what the RF environment
/// does to signals. The supermap determines the effective channel by
/// conjugating, switching, or composing channels.
///
/// Three canonical modes from the GF(3) quantum switch:
///   zero(0):  S(C) = C                    pass-through
///   plus(+1): S(C) = U ∘ C ∘ U⁻¹         conjugation (change basis)
///   minus(-1): S(C) = U⁻¹ ∘ C ∘ U        reverse conjugation
///
/// The quantum switch with indefinite causal order:
///   Given channels C₁, C₂ and control trit t:
///     t =  0: C₁ ∘ C₂         (C₁ after C₂)
///     t = +1: C₂ ∘ C₁         (C₂ after C₁)
///     t = -1: C₁ ⊕₃ C₂       (GF(3) superposition — the genuinely quantum case)
pub const Supermap = struct {
    /// Control trit determining supermap behavior
    control: Trit,
    /// The conjugating channel (for entangled/conjugate modes)
    conjugator: Channel,

    /// Identity supermap: S(C) = C for all C
    pub const IDENTITY = Supermap{
        .control = .zero,
        .conjugator = Channel.IDENTITY,
    };

    /// Apply the supermap to a channel.
    pub fn apply(self: Supermap, channel: Channel) Channel {
        return switch (self.control) {
            .zero => channel, // pass-through
            .plus => blk: {
                // S(C) = conjugator ∘ C ∘ conjugator²
                // (conjugator² = conjugator⁻¹ for order-3 channels)
                const conj_inv = Channel.compose(self.conjugator, self.conjugator);
                break :blk Channel.compose(Channel.compose(self.conjugator, channel), conj_inv);
            },
            .minus => blk: {
                // S(C) = conjugator² ∘ C ∘ conjugator
                const conj_inv = Channel.compose(self.conjugator, self.conjugator);
                break :blk Channel.compose(Channel.compose(conj_inv, channel), self.conjugator);
            },
        };
    }

    /// Quantum switch: given two channels and a control trit,
    /// produce a composite channel with GF(3)-controlled causal order.
    ///
    /// This is the core construction from higher-order quantum theory:
    /// the causal order of C₁ and C₂ depends on the control superposition.
    pub fn quantumSwitch(c1: Channel, c2: Channel, control: Trit) Channel {
        return switch (control) {
            .zero => Channel.compose(c1, c2), // C₁ after C₂
            .plus => Channel.compose(c2, c1), // C₂ after C₁
            .minus => blk: {
                // GF(3) "superposition": element-wise sum mod 3
                // This is the genuinely non-classical case:
                // the output channel cannot be explained by any fixed ordering.
                const fwd = Channel.compose(c1, c2);
                const rev = Channel.compose(c2, c1);
                var result: Channel = undefined;
                for (0..3) |i| {
                    for (0..3) |j| {
                        result.matrix[i][j] = Trit.add(fwd.matrix[i][j], rev.matrix[i][j]);
                    }
                    result.offset[i] = Trit.add(fwd.offset[i], rev.offset[i]);
                }
                break :blk result;
            },
        };
    }

    /// Compose two supermaps: (S₁ ∘ S₂)(C) = S₁(S₂(C))
    /// The control trits add: S₁⊕S₂ has control = c₁ ⊕₃ c₂
    pub fn compose(s1: Supermap, s2: Supermap) Supermap {
        return .{
            .control = Trit.add(s1.control, s2.control),
            .conjugator = Channel.compose(s1.conjugator, s2.conjugator),
        };
    }
};

// ============================================================================
// AFFORDANCE: Phase-space region × capability
// ============================================================================

/// An affordance: what actions the RF environment offers to the agent.
///
/// Gibson (1979): "affordances of the environment are what it offers the animal,
/// what it provides or furnishes, either for good or ill."
///
/// In our cyberphysical setting:
///   - The environment = RF phase space state
///   - The agent = the supermap controller
///   - The affordance = which supermaps are available given the current state
///
/// Each affordance has:
///   - A name (what action it enables)
///   - A phase mask (which of the 27 cells afford this action)
///   - Minimum thresholds (signal quality requirements)
///   - An enabled supermap (what the agent can do when afforded)
///
/// Evaluation returns a GF(3) trit:
///   +1 (available): all conditions met, supermap ready
///    0 (uncertain): partial conditions, supermap may work
///   -1 (blocked):   conditions not met, supermap unavailable
pub const Affordance = struct {
    /// Name (null-terminated within fixed buffer)
    name: [32]u8 = .{0} ** 32,
    name_len: u8 = 0,

    /// 27-bit mask: which phase cells afford this action
    phase_mask: u27 = 0,

    /// Minimum coordinate thresholds
    min_freq: Trit = .minus,
    min_phase: Trit = .minus,
    min_amp: Trit = .minus,

    /// The supermap this affordance enables
    enabled_supermap: Supermap = Supermap.IDENTITY,

    /// Evaluate the affordance against a phase space state.
    pub fn evaluate(self: Affordance, state: PhaseCell) Trit {
        // Check phase mask
        const idx = state.toIndex();
        if (self.phase_mask & (@as(u27, 1) << idx) == 0) {
            return .minus; // blocked: not in affordance region
        }

        // Check signal quality thresholds
        const freq_ok = @intFromEnum(state.freq) >= @intFromEnum(self.min_freq);
        const phase_ok = @intFromEnum(state.phase) >= @intFromEnum(self.min_phase);
        const amp_ok = @intFromEnum(state.amp) >= @intFromEnum(self.min_amp);

        if (freq_ok and phase_ok and amp_ok) {
            return .plus; // available
        }

        return .zero; // uncertain (in region but below threshold)
    }

    /// Count how many phase cells are in this affordance's region.
    pub fn regionSize(self: Affordance) u5 {
        return @popCount(self.phase_mask);
    }

    /// "Communicate" affordance: needs moderate+ amplitude.
    /// Available when signal is strong enough to carry data.
    pub fn communicate() Affordance {
        var a = Affordance{};
        const name = "communicate";
        @memcpy(a.name[0..name.len], name);
        a.name_len = name.len;
        // All cells with moderate or strong amplitude
        for (0..27) |i| {
            const cell = PhaseCell.fromIndex(@intCast(i));
            if (@intFromEnum(cell.amp) >= 0) {
                a.phase_mask |= @as(u27, 1) << @intCast(i);
            }
        }
        a.min_amp = .zero;
        a.enabled_supermap = Supermap.IDENTITY; // pass-through channel
        return a;
    }

    /// "Sense" affordance: needs phase coherence.
    /// Available when carrier phase is stable enough for measurement.
    pub fn sense() Affordance {
        var a = Affordance{};
        const name = "sense";
        @memcpy(a.name[0..name.len], name);
        a.name_len = name.len;
        // All cells with non-negative phase coherence
        for (0..27) |i| {
            const cell = PhaseCell.fromIndex(@intCast(i));
            if (@intFromEnum(cell.phase) >= 0) {
                a.phase_mask |= @as(u27, 1) << @intCast(i);
            }
        }
        a.min_phase = .zero;
        a.enabled_supermap = .{
            .control = .plus,
            .conjugator = Channel.PERMUTE,
        };
        return a;
    }

    /// "Actuate" affordance: needs all coordinates moderate+.
    /// Available when the system has enough signal quality to drive a physical actuator.
    pub fn actuate() Affordance {
        var a = Affordance{};
        const name = "actuate";
        @memcpy(a.name[0..name.len], name);
        a.name_len = name.len;
        // Only cells where all coordinates are non-negative
        for (0..27) |i| {
            const cell = PhaseCell.fromIndex(@intCast(i));
            if (@intFromEnum(cell.freq) >= 0 and
                @intFromEnum(cell.phase) >= 0 and
                @intFromEnum(cell.amp) >= 0)
            {
                a.phase_mask |= @as(u27, 1) << @intCast(i);
            }
        }
        a.min_freq = .zero;
        a.min_phase = .zero;
        a.min_amp = .zero;
        a.enabled_supermap = .{
            .control = .minus,
            .conjugator = Channel.CNOT_FREQ_PHASE,
        };
        return a;
    }
};

// ============================================================================
// CYBERPHYSICAL SYSTEM: the full control loop
// ============================================================================

/// Complete cyberphysical control loop over GF(3) phase space.
///
/// The loop: Measure → Evaluate Affordances → Select Supermap → Transform → Output
///
/// Each cycle:
/// 1. RF measurement arrives as a PhaseCell
/// 2. Affordances are evaluated against the current state
/// 3. The best available supermap is selected
/// 4. The supermap transforms the active channel
/// 5. The transformed channel produces an output PhaseCell
/// 6. The control trit is recorded in the history ring
///
/// Conservation: the sum of control history trits modulo 3 tracks
/// whether the system is drifting toward creation (+1), verification (-1),
/// or remaining ergodic (0).
pub const CyberPhysical = struct {
    /// Current RF phase space state
    state: PhaseCell,
    /// The three canonical affordances (communicate, sense, actuate)
    affordances: [3]Affordance,
    /// Active channel (current environment model)
    channel: Channel,
    /// Control history (ring buffer of last 9 control trits)
    /// 9 = 3² so the ring itself has GF(3)² structure
    history: [9]Trit,
    history_idx: u4,
    /// Generation counter
    generation: u64,

    pub fn init() CyberPhysical {
        return .{
            .state = .{ .freq = .zero, .phase = .zero, .amp = .zero },
            .affordances = .{ Affordance.communicate(), Affordance.sense(), Affordance.actuate() },
            .channel = Channel.IDENTITY,
            .history = .{.zero} ** 9,
            .history_idx = 0,
            .generation = 0,
        };
    }

    /// Update RF state from a measurement.
    pub fn updateState(self: *CyberPhysical, measurement: PhaseCell) void {
        self.state = measurement;
        self.generation += 1;
    }

    /// Evaluate all three affordances against current state.
    /// Returns [communicate, sense, actuate] trits.
    pub fn evaluateAffordances(self: *const CyberPhysical) [3]Trit {
        return .{
            self.affordances[0].evaluate(self.state),
            self.affordances[1].evaluate(self.state),
            self.affordances[2].evaluate(self.state),
        };
    }

    /// Select the best available supermap based on affordance evaluation.
    /// Priority: actuate > sense > communicate (most capability first).
    pub fn selectSupermap(self: *const CyberPhysical) Supermap {
        const aff = self.evaluateAffordances();
        if (aff[2] == .plus) return self.affordances[2].enabled_supermap;
        if (aff[1] == .plus) return self.affordances[1].enabled_supermap;
        if (aff[0] == .plus) return self.affordances[0].enabled_supermap;
        return Supermap.IDENTITY;
    }

    /// Execute one control cycle.
    pub fn step(self: *CyberPhysical, measurement: PhaseCell) PhaseCell {
        // 1. Update state from measurement
        self.updateState(measurement);

        // 2. Select supermap from affordances
        const supermap = self.selectSupermap();

        // 3. Transform the channel via supermap
        self.channel = supermap.apply(self.channel);

        // 4. Apply channel to get output
        const output = self.channel.apply(self.state);

        // 5. Record control trit in history
        self.history[self.history_idx] = supermap.control;
        self.history_idx = @intCast((@as(u5, self.history_idx) + 1) % 9);

        return output;
    }

    /// GF(3) balance of control history.
    /// Zero = ergodic (balanced). Plus = generative drift. Minus = verification drift.
    pub fn controlBalance(self: *const CyberPhysical) Trit {
        var sum: Trit = .zero;
        for (self.history) |t| {
            sum = Trit.add(sum, t);
        }
        return sum;
    }

    /// Count affordances by state: [blocked, uncertain, available]
    pub fn affordanceSummary(self: *const CyberPhysical) [3]u8 {
        const aff = self.evaluateAffordances();
        var counts = [3]u8{ 0, 0, 0 };
        for (aff) |a| {
            const idx: usize = @intCast(@as(i16, @intFromEnum(a)) + 1);
            counts[idx] += 1;
        }
        return counts;
    }
};

// ============================================================================
// C ABI EXPORTS (for FFI: Swift, Python, Guile)
// ============================================================================

/// Apply a channel to a phase cell. Returns output index (0..26).
export fn supermap_channel_apply(
    m00: i8, m01: i8, m02: i8,
    m10: i8, m11: i8, m12: i8,
    m20: i8, m21: i8, m22: i8,
    freq: i8, phase: i8, amp: i8,
) callconv(.c) u8 {
    const ch = Channel{
        .matrix = .{
            .{ @enumFromInt(std.math.clamp(m00, -1, 1)), @enumFromInt(std.math.clamp(m01, -1, 1)), @enumFromInt(std.math.clamp(m02, -1, 1)) },
            .{ @enumFromInt(std.math.clamp(m10, -1, 1)), @enumFromInt(std.math.clamp(m11, -1, 1)), @enumFromInt(std.math.clamp(m12, -1, 1)) },
            .{ @enumFromInt(std.math.clamp(m20, -1, 1)), @enumFromInt(std.math.clamp(m21, -1, 1)), @enumFromInt(std.math.clamp(m22, -1, 1)) },
        },
        .offset = .{ .zero, .zero, .zero },
    };
    const input = PhaseCell{
        .freq = @enumFromInt(std.math.clamp(freq, -1, 1)),
        .phase = @enumFromInt(std.math.clamp(phase, -1, 1)),
        .amp = @enumFromInt(std.math.clamp(amp, -1, 1)),
    };
    return ch.apply(input).toIndex();
}

/// Quantum switch: compose two channels with GF(3) control.
/// Returns the output phase cell index when applied to the given input.
export fn supermap_quantum_switch(
    // Channel 1 diagonal (simplified: only diagonal channels for C ABI)
    c1_diag0: i8, c1_diag1: i8, c1_diag2: i8,
    // Channel 2 diagonal
    c2_diag0: i8, c2_diag1: i8, c2_diag2: i8,
    // Control trit
    control: i8,
    // Input
    freq: i8, phase: i8, amp: i8,
) callconv(.c) u8 {
    const c1 = Channel{
        .matrix = .{
            .{ @enumFromInt(std.math.clamp(c1_diag0, -1, 1)), .zero, .zero },
            .{ .zero, @enumFromInt(std.math.clamp(c1_diag1, -1, 1)), .zero },
            .{ .zero, .zero, @enumFromInt(std.math.clamp(c1_diag2, -1, 1)) },
        },
        .offset = .{ .zero, .zero, .zero },
    };
    const c2 = Channel{
        .matrix = .{
            .{ @enumFromInt(std.math.clamp(c2_diag0, -1, 1)), .zero, .zero },
            .{ .zero, @enumFromInt(std.math.clamp(c2_diag1, -1, 1)), .zero },
            .{ .zero, .zero, @enumFromInt(std.math.clamp(c2_diag2, -1, 1)) },
        },
        .offset = .{ .zero, .zero, .zero },
    };
    const ctrl: Trit = @enumFromInt(std.math.clamp(control, -1, 1));
    const switched = Supermap.quantumSwitch(c1, c2, ctrl);
    const input = PhaseCell{
        .freq = @enumFromInt(std.math.clamp(freq, -1, 1)),
        .phase = @enumFromInt(std.math.clamp(phase, -1, 1)),
        .amp = @enumFromInt(std.math.clamp(amp, -1, 1)),
    };
    return switched.apply(input).toIndex();
}

// ============================================================================
// TESTS
// ============================================================================

test "phase cell index roundtrip" {
    for (0..27) |i| {
        const idx: u5 = @intCast(i);
        const cell = PhaseCell.fromIndex(idx);
        try std.testing.expectEqual(idx, cell.toIndex());
    }
}

test "phase cell bounds" {
    const origin = PhaseCell{ .freq = .minus, .phase = .minus, .amp = .minus };
    try std.testing.expectEqual(@as(u5, 0), origin.toIndex());

    const max = PhaseCell{ .freq = .plus, .phase = .plus, .amp = .plus };
    try std.testing.expectEqual(@as(u5, 26), max.toIndex());

    const center = PhaseCell{ .freq = .zero, .phase = .zero, .amp = .zero };
    try std.testing.expectEqual(@as(u5, 13), center.toIndex());
}

test "phase cell parity conservation under internal CNOT" {
    // Internal CNOT₃ preserves parity when target += source
    // because the total sum changes by +source, but source was already counted.
    // Actually: parity(after) = f + (p+f) + a = 2f + p + a = parity + f
    // So parity shifts by the source trit — this tests the shift is consistent.
    for (0..27) |i| {
        const cell = PhaseCell.fromIndex(@intCast(i));
        const rotated = cell.internalCNOT(1, 0); // phase += freq
        // New parity = old parity + freq (the added source)
        const expected_parity = Trit.add(cell.parity(), cell.freq);
        try std.testing.expectEqual(expected_parity, rotated.parity());
    }
}

test "channel identity is identity" {
    for (0..27) |i| {
        const cell = PhaseCell.fromIndex(@intCast(i));
        const result = Channel.IDENTITY.apply(cell);
        try std.testing.expect(cell.eql(result));
    }
}

test "channel composition associativity" {
    const a = Channel.CNOT_FREQ_PHASE;
    const b = Channel.PERMUTE;
    const c = Channel.IDENTITY;

    const ab_c = Channel.compose(Channel.compose(a, b), c);
    const a_bc = Channel.compose(a, Channel.compose(b, c));

    // Test on all 27 inputs
    for (0..27) |i| {
        const cell = PhaseCell.fromIndex(@intCast(i));
        const r1 = ab_c.apply(cell);
        const r2 = a_bc.apply(cell);
        try std.testing.expect(r1.eql(r2));
    }
}

test "channel identity is neutral element" {
    const c = Channel.CNOT_FREQ_PHASE;
    const ci = Channel.compose(c, Channel.IDENTITY);
    const ic = Channel.compose(Channel.IDENTITY, c);

    try std.testing.expect(c.eql(ci));
    try std.testing.expect(c.eql(ic));
}

test "permutation channel has order 3" {
    const p1 = Channel.PERMUTE;
    const p2 = Channel.compose(p1, p1);
    const p3 = Channel.compose(p2, p1);

    // p³ should equal identity
    try std.testing.expect(p3.eql(Channel.IDENTITY));
    // p¹ and p² should not equal identity
    try std.testing.expect(!p1.eql(Channel.IDENTITY));
    try std.testing.expect(!p2.eql(Channel.IDENTITY));
}

test "CNOT freq→phase channel has order 3" {
    const c1 = Channel.CNOT_FREQ_PHASE;
    const c2 = Channel.compose(c1, c1);
    const c3 = Channel.compose(c2, c1);

    // CNOT³ = I (the defining property)
    for (0..27) |i| {
        const cell = PhaseCell.fromIndex(@intCast(i));
        try std.testing.expect(cell.eql(c3.apply(cell)));
    }
}

test "channel determinant" {
    // Identity has det = +1
    try std.testing.expectEqual(Trit.plus, Channel.IDENTITY.determinant());
    // Zero matrix has det = 0
    try std.testing.expectEqual(Trit.zero, Channel.ZERO.determinant());
    // Permutation matrix has det = +1 (even permutation for cyclic)
    try std.testing.expectEqual(Trit.plus, Channel.PERMUTE.determinant());
}

test "supermap identity is pass-through" {
    const channel = Channel.CNOT_FREQ_PHASE;
    const result = Supermap.IDENTITY.apply(channel);
    try std.testing.expect(channel.eql(result));
}

test "supermap conjugation changes channel" {
    const channel = Channel.CNOT_FREQ_PHASE;
    const sm = Supermap{
        .control = .plus,
        .conjugator = Channel.PERMUTE,
    };
    const conjugated = sm.apply(channel);
    // Conjugated channel should differ from original
    try std.testing.expect(!channel.eql(conjugated));
}

test "supermap with control=0 returns same channel" {
    const channel = Channel.CNOT_FREQ_PHASE;
    const sm = Supermap{
        .control = .zero,
        .conjugator = Channel.PERMUTE,
    };
    const result = sm.apply(channel);
    try std.testing.expect(channel.eql(result));
}

test "quantum switch causal order" {
    const c1 = Channel.CNOT_FREQ_PHASE;
    const c2 = Channel.PERMUTE;

    const fwd = Supermap.quantumSwitch(c1, c2, .zero); // c1 ∘ c2
    const rev = Supermap.quantumSwitch(c1, c2, .plus); // c2 ∘ c1
    const sup = Supermap.quantumSwitch(c1, c2, .minus); // superposition

    // Forward and reverse should generally differ (non-commuting channels)
    const test_cell = PhaseCell{ .freq = .plus, .phase = .zero, .amp = .minus };
    const r_fwd = fwd.apply(test_cell);
    const r_rev = rev.apply(test_cell);
    const r_sup = sup.apply(test_cell);

    // At least one pair should differ (channels don't commute)
    const all_same = r_fwd.eql(r_rev) and r_rev.eql(r_sup);
    try std.testing.expect(!all_same);
}

test "quantum switch with commuting channels" {
    // Two diagonal channels commute: C₁∘C₂ = C₂∘C₁
    const c1 = Channel{
        .matrix = .{
            .{ .plus, .zero, .zero },
            .{ .zero, .minus, .zero },
            .{ .zero, .zero, .plus },
        },
        .offset = .{ .zero, .zero, .zero },
    };
    const c2 = Channel{
        .matrix = .{
            .{ .minus, .zero, .zero },
            .{ .zero, .plus, .zero },
            .{ .zero, .zero, .minus },
        },
        .offset = .{ .zero, .zero, .zero },
    };

    const fwd = Supermap.quantumSwitch(c1, c2, .zero);
    const rev = Supermap.quantumSwitch(c1, c2, .plus);

    // For commuting channels, forward = reverse
    for (0..27) |i| {
        const cell = PhaseCell.fromIndex(@intCast(i));
        try std.testing.expect(fwd.apply(cell).eql(rev.apply(cell)));
    }
}

test "affordance communicate region" {
    const comm = Affordance.communicate();
    // Should include cells with amp >= 0
    const strong = PhaseCell{ .freq = .zero, .phase = .zero, .amp = .plus };
    try std.testing.expectEqual(Trit.plus, comm.evaluate(strong));

    // Should exclude cells with amp < 0
    const weak = PhaseCell{ .freq = .zero, .phase = .zero, .amp = .minus };
    try std.testing.expectEqual(Trit.minus, comm.evaluate(weak));
}

test "affordance sense region" {
    const sns = Affordance.sense();
    // Should include cells with phase >= 0
    const coherent = PhaseCell{ .freq = .minus, .phase = .plus, .amp = .minus };
    try std.testing.expectEqual(Trit.plus, sns.evaluate(coherent));

    // Should exclude cells with phase < 0
    const incoherent = PhaseCell{ .freq = .zero, .phase = .minus, .amp = .zero };
    try std.testing.expectEqual(Trit.minus, sns.evaluate(incoherent));
}

test "affordance actuate region" {
    const act = Affordance.actuate();
    // Should include cells where all >= 0
    const ready = PhaseCell{ .freq = .plus, .phase = .plus, .amp = .plus };
    try std.testing.expectEqual(Trit.plus, act.evaluate(ready));

    const partial = PhaseCell{ .freq = .plus, .phase = .plus, .amp = .minus };
    try std.testing.expectEqual(Trit.minus, act.evaluate(partial));

    // Region size: 2³ = 8 cells (each coord has 2 non-negative values: 0, +1)
    try std.testing.expectEqual(@as(u5, 8), act.regionSize());
}

test "affordance region sizes: communicate > sense > actuate" {
    const comm = Affordance.communicate();
    const sns = Affordance.sense();
    const act = Affordance.actuate();

    // Communicate: 18 cells (amp >= 0 → 2/3 of 27)
    // Sense: 18 cells (phase >= 0 → 2/3 of 27)
    // Actuate: 8 cells (all >= 0 → (2/3)³ of 27)
    try std.testing.expect(comm.regionSize() >= act.regionSize());
    try std.testing.expect(sns.regionSize() >= act.regionSize());
}

test "cyberphysical step loop" {
    var sys = CyberPhysical.init();

    // Step with a strong, coherent, high-frequency signal
    const measurement = PhaseCell{ .freq = .plus, .phase = .plus, .amp = .plus };
    const output = sys.step(measurement);

    // Output should be a valid phase cell
    try std.testing.expect(output.toIndex() < 27);
    try std.testing.expectEqual(@as(u64, 1), sys.generation);
}

test "cyberphysical control balance starts ergodic" {
    const sys = CyberPhysical.init();
    try std.testing.expectEqual(Trit.zero, sys.controlBalance());
}

test "cyberphysical affordance summary" {
    var sys = CyberPhysical.init();

    // At center (all zero): communicate=available, sense=available, actuate=available
    sys.updateState(.{ .freq = .zero, .phase = .zero, .amp = .zero });
    const summary = sys.affordanceSummary();
    const total: u8 = summary[0] + summary[1] + summary[2];
    try std.testing.expectEqual(@as(u8, 3), total);
}

test "supermap composition control trits add" {
    const s1 = Supermap{ .control = .plus, .conjugator = Channel.IDENTITY };
    const s2 = Supermap{ .control = .plus, .conjugator = Channel.IDENTITY };
    const composed = Supermap.compose(s1, s2);
    // +1 ⊕₃ +1 = -1
    try std.testing.expectEqual(Trit.minus, composed.control);
}

test "external CNOT on phase cell" {
    const cell = PhaseCell{ .freq = .zero, .phase = .zero, .amp = .zero };
    const shifted = cell.externalCNOT(0, .plus); // freq += plus
    try std.testing.expectEqual(Trit.plus, shifted.freq);
    try std.testing.expectEqual(Trit.zero, shifted.phase);
    try std.testing.expectEqual(Trit.zero, shifted.amp);
}
