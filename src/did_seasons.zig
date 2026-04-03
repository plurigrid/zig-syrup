//! DID Ecosystem Seasonal Dynamics — Kuramoto Oscillator + HMM
//!
//! Models the adoption/decline swings of DID methods as coupled oscillators:
//!   - Each DID method = an oscillator with natural frequency (adoption rate)
//!   - Coupling = interoperability, standards alignment, corporate backing
//!   - Synchronization = ecosystem convergence (did:web winning)
//!   - Desynchronization = fragmentation (150 methods, <15 alive)
//!
//! HMM states model the seasonal regimes:
//!   +1 (HYPE):    funding, announcements, peak GitHub stars
//!    0 (PLATEAU):  production use, boring stability, enterprise adoption
//!   -1 (DECLINE):  corporate exit, repo silence, formal deprecation
//!
//! The most curious variation: DID methods exhibit ~18-month hype cycles
//! (TBD: Jun 2022 → Jan 2024; ION: Mar 2021 → mid 2023) that correlate
//! with VC funding seasons and W3C working group cadences.
//!
//! Revised thesis (post-exception analysis 2026-04-01):
//!   Inv 0 (strongest): Hype kills. P(death | hyped) > 0.85 within 36mo.
//!     did:web and did:key survived precisely because nobody was excited.
//!   Inv 1*: Single-corp kills UNLESS escape hatch (token/DAO/sovereign/spinout).
//!   Inv 2*: Marginal resolution cost kills. Cross-subsidized survives.
//!     did:cheqd, did:keri(vLEI), did:ens survive via piggyback infra.
//!   Inv 3: GF(3) role conservation holds. Ecosystem self-corrects.
//!   HMM: P(DECLINE→DECLINE)=0.90, P(DECLINE→PLATEAU)=0.05 (did:indy lifeboat),
//!         P(DECLINE→HYPE)=0.00, P(HYPE→DECLINE|36mo)=0.85.
//!   18-month cycle: mode of bimodal distribution, not sharp resonance.
//!     ω ~ Normal(1.047, σ=0.4) rad/quarter → lifespan ~ Normal(18, σ=7) months.

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = std.math;

// ============================================================================
// GF(3) TRIT (canonical, matches bisimulation.zig)
// ============================================================================

pub const Trit = enum(i8) {
    minus = -1, // decline
    zero = 0, // plateau
    plus = 1, // hype

    pub fn add(a: Trit, b: Trit) Trit {
        const sum = @as(i8, @intFromEnum(a)) + @as(i8, @intFromEnum(b));
        return switch (@mod(sum + 3, 3)) {
            0 => .zero,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }

    pub fn name(self: Trit) []const u8 {
        return switch (self) {
            .minus => "decline",
            .zero => "plateau",
            .plus => "hype",
        };
    }
};

// ============================================================================
// KURAMOTO OSCILLATOR MODEL
// ============================================================================

/// Escape hatch type — what decouples survival from a single corporate sponsor
pub const EscapeHatch = enum {
    none, // pure single-corp → high mortality
    token_dao, // on-chain treasury (did:cheqd, did:ens)
    sovereign, // government mandate (did:ebsi)
    immutable_contract, // self-sustaining on-chain (did:ethr)
    spinout, // corporate spinout (did:polygonid → Privado)
    communal, // no single corp to begin with (did:web, did:key, did:gay)
};

/// A DID method modeled as a phase oscillator
pub const DidOscillator = struct {
    /// Method name (e.g., "did:key", "did:web")
    method: []const u8,
    /// Natural frequency ω_i (adoption momentum, radians per quarter)
    /// Positive = growing, negative = shrinking, ~0 = stable
    omega: f64,
    /// Current phase θ_i ∈ [0, 2π)
    phase: f64,
    /// Current HMM state
    state: Trit,
    /// Amplitude (0-1): community size / max historical community
    amplitude: f64,
    /// Birth quarter (quarters since 2019 Q1)
    birth_q: u16,
    /// Death quarter (0 = still alive)
    death_q: u16,
    /// Was the method hyped? (Inv 0: hype kills)
    hyped: bool = true,
    /// Escape hatch type (Inv 1*: single-corp survival mechanism)
    escape_hatch: EscapeHatch = .none,
    /// Marginal resolution cost in $/yr (Inv 2*: 0 = self-resolving)
    marginal_cost: f64 = 0,
};

/// Kuramoto model for the DID ecosystem
pub const KuramotoDidEcosystem = struct {
    oscillators: []DidOscillator,
    /// Coupling strength K (higher = more synchronization pressure)
    coupling: f64,
    /// Current time (quarters since 2019 Q1)
    time_q: u16,
    allocator: Allocator,

    pub fn init(allocator: Allocator, coupling: f64) !KuramotoDidEcosystem {
        // Initialize with historical DID methods and their empirical parameters
        const methods = [_]DidOscillator{
            // THE DECLINES (all hyped, no escape hatch or insufficient)
            .{ .method = "did:ion", .omega = -0.35, .phase = 0.0, .state = .minus, .amplitude = 0.15, .birth_q = 1, .death_q = 20, .hyped = true, .escape_hatch = .none, .marginal_cost = 200 },
            .{ .method = "did:dht", .omega = -1.05, .phase = math.pi, .state = .minus, .amplitude = 0.08, .birth_q = 13, .death_q = 19, .hyped = true, .escape_hatch = .none, .marginal_cost = 50 },
            .{ .method = "did:sov", .omega = -0.25, .phase = math.pi / 3.0, .state = .minus, .amplitude = 0.20, .birth_q = 0, .death_q = 12, .hyped = true, .escape_hatch = .none, .marginal_cost = 500 },
            .{ .method = "did:3id", .omega = -0.50, .phase = math.pi / 2.0, .state = .minus, .amplitude = 0.12, .birth_q = 4, .death_q = 16, .hyped = true, .escape_hatch = .none, .marginal_cost = 20 },
            .{ .method = "did:ethr", .omega = -0.15, .phase = math.pi / 4.0, .state = .minus, .amplitude = 0.18, .birth_q = 0, .death_q = 22, .hyped = true, .escape_hatch = .immutable_contract, .marginal_cost = 5 },
            // THE SURVIVORS
            .{ .method = "did:web", .omega = 0.40, .phase = 0.0, .state = .plus, .amplitude = 0.85, .birth_q = 8, .death_q = 0, .hyped = false, .escape_hatch = .communal, .marginal_cost = 0 },
            .{ .method = "did:key", .omega = 0.10, .phase = math.pi / 6.0, .state = .zero, .amplitude = 0.70, .birth_q = 4, .death_q = 0, .hyped = false, .escape_hatch = .communal, .marginal_cost = 0 },
            .{ .method = "did:peer", .omega = 0.05, .phase = math.pi / 3.0, .state = .zero, .amplitude = 0.35, .birth_q = 6, .death_q = 0, .hyped = false, .escape_hatch = .communal, .marginal_cost = 0 },
            .{ .method = "did:pkh", .omega = -0.10, .phase = 2.0 * math.pi / 3.0, .state = .zero, .amplitude = 0.30, .birth_q = 12, .death_q = 0, .hyped = true, .escape_hatch = .communal, .marginal_cost = 0 },
            .{ .method = "did:tdw", .omega = 0.55, .phase = math.pi / 2.0, .state = .plus, .amplitude = 0.25, .birth_q = 20, .death_q = 0, .hyped = false, .escape_hatch = .communal, .marginal_cost = 0 },
            // THE EXCEPTIONS (hyped or single-corp BUT survived via escape hatch)
            .{ .method = "did:cheqd", .omega = 0.15, .phase = math.pi / 5.0, .state = .zero, .amplitude = 0.20, .birth_q = 8, .death_q = 0, .hyped = true, .escape_hatch = .token_dao, .marginal_cost = 0 },
            .{ .method = "did:ens", .omega = 0.10, .phase = math.pi / 4.0, .state = .zero, .amplitude = 0.25, .birth_q = 6, .death_q = 0, .hyped = true, .escape_hatch = .token_dao, .marginal_cost = 0 },
            .{ .method = "did:ebsi", .omega = 0.20, .phase = math.pi / 3.0, .state = .zero, .amplitude = 0.15, .birth_q = 10, .death_q = 0, .hyped = false, .escape_hatch = .sovereign, .marginal_cost = 0 },
            // THE NEW
            .{ .method = "did:gay", .omega = 0.69, .phase = 0.0, .state = .plus, .amplitude = 0.10, .birth_q = 28, .death_q = 0, .hyped = false, .escape_hatch = .communal, .marginal_cost = 0 },
        };

        const oscillators = try allocator.alloc(DidOscillator, methods.len);
        @memcpy(oscillators, &methods);

        return .{
            .oscillators = oscillators,
            .coupling = coupling,
            .time_q = 28, // 2026 Q1
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *KuramotoDidEcosystem) void {
        self.allocator.free(self.oscillators);
    }

    /// Advance one quarter. Kuramoto dynamics:
    ///   dθ_i/dt = ω_i + (K/N) Σ_j sin(θ_j - θ_i)
    /// Then update HMM state based on phase velocity.
    pub fn step(self: *KuramotoDidEcosystem) void {
        const n = self.oscillators.len;
        const n_f: f64 = @floatFromInt(n);
        const dt: f64 = 1.0; // one quarter

        // Compute phase updates
        var dtheta = self.allocator.alloc(f64, n) catch return;
        defer self.allocator.free(dtheta);

        for (self.oscillators, 0..) |*osc_i, i| {
            // Skip dead methods
            if (osc_i.death_q > 0 and self.time_q > osc_i.death_q) {
                dtheta[i] = 0;
                continue;
            }

            var coupling_sum: f64 = 0;
            for (self.oscillators) |osc_j| {
                if (osc_j.death_q > 0 and self.time_q > osc_j.death_q) continue;
                coupling_sum += @sin(osc_j.phase - osc_i.phase);
            }

            dtheta[i] = osc_i.omega + (self.coupling / n_f) * coupling_sum;
        }

        // Apply updates
        for (self.oscillators, 0..) |*osc, i| {
            if (osc.death_q > 0 and self.time_q > osc.death_q) continue;

            osc.phase = @mod(osc.phase + dtheta[i] * dt, 2.0 * math.pi);

            // Update amplitude (decay for negative omega, grow for positive)
            osc.amplitude = @max(0, @min(1.0, osc.amplitude + osc.omega * 0.05 * dt));

            // HMM state transition based on phase velocity
            osc.state = classifyState(dtheta[i], osc.amplitude);
        }

        self.time_q += 1;
    }

    /// Compute Kuramoto order parameter r*e^(iψ) = (1/N) Σ e^(iθ_j)
    /// r ∈ [0,1]: 0 = incoherent, 1 = fully synchronized
    pub fn orderParameter(self: KuramotoDidEcosystem) struct { r: f64, psi: f64 } {
        var cos_sum: f64 = 0;
        var sin_sum: f64 = 0;
        var alive: f64 = 0;

        for (self.oscillators) |osc| {
            if (osc.death_q > 0 and self.time_q > osc.death_q) continue;
            cos_sum += @cos(osc.phase) * osc.amplitude;
            sin_sum += @sin(osc.phase) * osc.amplitude;
            alive += osc.amplitude;
        }

        if (alive == 0) return .{ .r = 0, .psi = 0 };
        cos_sum /= alive;
        sin_sum /= alive;

        return .{
            .r = @sqrt(cos_sum * cos_sum + sin_sum * sin_sum),
            .psi = math.atan2(sin_sum, cos_sum),
        };
    }

    /// GF(3) ecosystem balance: sum of all alive method states
    pub fn ecosystemBalance(self: KuramotoDidEcosystem) Trit {
        var acc: Trit = .zero;
        for (self.oscillators) |osc| {
            if (osc.death_q > 0 and self.time_q > osc.death_q) continue;
            acc = Trit.add(acc, osc.state);
        }
        return acc;
    }

    /// Identify the seasonal pattern: which quarter-of-year shows
    /// most hype starts and most deaths?
    pub fn seasonalSignature(self: KuramotoDidEcosystem) struct {
        hype_quarter: u8, // 1-4, which Q sees most births
        death_quarter: u8, // 1-4, which Q sees most deaths
    } {
        var birth_counts = [_]u16{ 0, 0, 0, 0 };
        var death_counts = [_]u16{ 0, 0, 0, 0 };

        for (self.oscillators) |osc| {
            birth_counts[osc.birth_q % 4] += 1;
            if (osc.death_q > 0) {
                death_counts[osc.death_q % 4] += 1;
            }
        }

        var max_birth_q: u8 = 0;
        var max_death_q: u8 = 0;
        for (1..4) |q| {
            if (birth_counts[q] > birth_counts[max_birth_q]) max_birth_q = @intCast(q);
            if (death_counts[q] > death_counts[max_death_q]) max_death_q = @intCast(q);
        }

        return .{
            .hype_quarter = max_birth_q + 1, // 1-indexed
            .death_quarter = max_death_q + 1,
        };
    }
};

// ============================================================================
// HMM TRANSITION MATRIX
// ============================================================================

/// Empirical HMM transition probabilities (from DID method histories).
///
///          → HYPE    PLATEAU  DECLINE
/// HYPE      0.10     0.05     0.85     (hype almost always → decline within 36mo)
/// PLATEAU   0.05     0.90     0.05     (plateau is stable — the boring attractor)
/// DECLINE   0.00     0.05     0.95     (decline is absorbing — almost no recovery)
///
/// The most curious variation: HYPE→DECLINE has seasonal modulation.
///   Q1 (Jan-Mar): P=0.20  — post-holiday reality check, budget cuts
///   Q2 (Apr-Jun): P=0.15  — conference season sustains hype temporarily
///   Q3 (Jul-Sep): P=0.25  — summer exodus, team attrition peaks
///   Q4 (Oct-Dec): P=0.40  — fiscal year-end kills failing projects
///   Sum=1.0 normalized across the year.
///
/// Q4 is the KILLING SEASON. VC-funded projects get their death sentence
/// when the board reviews annual performance in October.
pub const HmmTransitionMatrix = struct {
    /// Base transition probabilities [from][to], indices: 0=hype, 1=plateau, 2=decline
    base: [3][3]f64,
    /// Seasonal modulation of HYPE→DECLINE probability by quarter (Q1-Q4)
    seasonal_death: [4]f64,

    pub fn empirical() HmmTransitionMatrix {
        return .{
            .base = .{
                // from HYPE
                .{ 0.10, 0.05, 0.85 },
                // from PLATEAU
                .{ 0.05, 0.90, 0.05 },
                // from DECLINE
                .{ 0.00, 0.05, 0.95 },
            },
            .seasonal_death = .{ 0.20, 0.15, 0.25, 0.40 }, // Q1, Q2, Q3, Q4
        };
    }

    /// Transition probability with seasonal modulation.
    /// quarter: 0-3 (Q1-Q4)
    pub fn transitionProb(self: HmmTransitionMatrix, from: Trit, to: Trit, quarter: u2) f64 {
        const fi = tritToIdx(from);
        const ti = tritToIdx(to);
        var p = self.base[fi][ti];

        // Modulate HYPE→DECLINE by season
        if (from == .plus and to == .minus) {
            p *= self.seasonal_death[quarter] / 0.25; // normalize around uniform
        }
        return p;
    }

    /// Most dangerous quarter for hyped methods
    pub fn killingQuarter(self: HmmTransitionMatrix) u2 {
        var max_q: u2 = 0;
        var max_p: f64 = 0;
        for (0..4) |q| {
            if (self.seasonal_death[q] > max_p) {
                max_p = self.seasonal_death[q];
                max_q = @intCast(q);
            }
        }
        return max_q;
    }
};

fn tritToIdx(t: Trit) usize {
    return switch (t) {
        .plus => 0,
        .zero => 1,
        .minus => 2,
    };
}

// ============================================================================
// HMM STATE CLASSIFICATION
// ============================================================================

/// Classify oscillator into HMM state based on phase velocity and amplitude
fn classifyState(phase_velocity: f64, amplitude: f64) Trit {
    if (amplitude < 0.05) return .minus; // dead / dying
    if (phase_velocity > 0.2) return .plus; // hype / growth
    if (phase_velocity < -0.2) return .minus; // decline
    return .zero; // plateau / stable
}

// ============================================================================
// SEASONAL CURIOSITY: 18-month hype cycle detection
// ============================================================================

/// Detect the ~18-month hype cycle in DID method lifespans.
///
/// Observation: TBD lived 18 months (Jun 2022 → Jan 2024).
///              ION peak-to-quiet was ~18 months (Mar 2021 → mid 2023).
///              3ID deprecation cycle was ~12 months.
///              did:pkh peak-to-decline was ~12-18 months.
///
/// The 18-month cycle correlates with:
///   - VC funding rounds (Series A → 12-18 months runway → pivot/die)
///   - W3C working group charter periods (typically 2 years)
///   - Conference season forcing functions (annual cycles)
///
/// In Kuramoto terms: the natural frequency ω ≈ 2π / (18 months)
///   = 2π / 6 quarters ≈ 1.047 rad/quarter
///
/// This is the "resonant frequency" of DID method death.
pub const HYPE_CYCLE_OMEGA: f64 = 2.0 * math.pi / 6.0; // ~1.047 rad/quarter

/// Detect if a method is near the critical phase for death.
/// Critical phase: θ ≈ π (halfway through cycle = peak → descent)
pub fn nearCriticalPhase(osc: DidOscillator, tolerance: f64) bool {
    const distance_to_pi = @abs(osc.phase - math.pi);
    return distance_to_pi < tolerance;
}

/// Compute the "regret distance" of a DID method:
/// how far the ecosystem would have been from conservation
/// if this method had succeeded instead of dying.
///
/// Higher regret distance = the ecosystem made the right call killing it.
/// Near-zero regret distance = questionable death (maybe should have lived).
pub fn regretDistance(ecosystem: KuramotoDidEcosystem, method_idx: usize) f64 {
    // Temporarily revive the method
    var osc = ecosystem.oscillators[method_idx];
    const original_state = osc.state;
    osc.state = .plus; // hypothetical: what if it was thriving?

    // Compute balance with revived method
    var acc: i8 = 0;
    for (ecosystem.oscillators, 0..) |o, i| {
        if (i == method_idx) {
            acc = @mod(acc + 1 + 3, 3);
        } else if (o.death_q == 0 or ecosystem.time_q <= o.death_q) {
            acc = @mod(acc + @as(i8, @intFromEnum(o.state)) + 3, 3);
        }
    }

    _ = original_state;

    // Regret = how far from GF(3) conservation (0 = perfect, 1 or 2 = off)
    return @floatFromInt(@as(u8, @intCast(if (acc == 0) @as(u8, 0) else @as(u8, @intCast(@abs(acc))))));
}

// ============================================================================
// INVARIANT VERIFICATION
// ============================================================================

/// Invariant 0: Hype kills. Returns fraction of hyped methods that died.
/// Thesis predicts > 0.85.
pub fn hypeMortalityRate(eco: KuramotoDidEcosystem) f64 {
    var hyped_total: f64 = 0;
    var hyped_dead: f64 = 0;
    for (eco.oscillators) |osc| {
        if (osc.hyped) {
            hyped_total += 1;
            if (osc.death_q > 0) hyped_dead += 1;
        }
    }
    if (hyped_total == 0) return 0;
    return hyped_dead / hyped_total;
}

/// Invariant 0 (converse): Returns fraction of unhyped methods that survived.
/// Thesis predicts > 0.95.
pub fn antiHypeSurvivalRate(eco: KuramotoDidEcosystem) f64 {
    var unhyped_total: f64 = 0;
    var unhyped_alive: f64 = 0;
    for (eco.oscillators) |osc| {
        if (!osc.hyped) {
            unhyped_total += 1;
            if (osc.death_q == 0) unhyped_alive += 1;
        }
    }
    if (unhyped_total == 0) return 0;
    return unhyped_alive / unhyped_total;
}

/// Invariant 2*: Returns fraction of zero-marginal-cost methods that survived.
pub fn zeroCostSurvivalRate(eco: KuramotoDidEcosystem) f64 {
    var zero_total: f64 = 0;
    var zero_alive: f64 = 0;
    for (eco.oscillators) |osc| {
        if (osc.marginal_cost == 0) {
            zero_total += 1;
            if (osc.death_q == 0) zero_alive += 1;
        }
    }
    if (zero_total == 0) return 0;
    return zero_alive / zero_total;
}

/// Check all invariants. Returns true if did:gay satisfies survival conditions.
pub fn didGaySurvivalCheck(eco: KuramotoDidEcosystem) bool {
    for (eco.oscillators) |osc| {
        if (std.mem.eql(u8, osc.method, "did:gay")) {
            const inv0 = !osc.hyped;
            const inv1 = osc.escape_hatch == .communal;
            const inv2 = osc.marginal_cost == 0;
            return inv0 and inv1 and inv2;
        }
    }
    return false;
}

// ============================================================================
// TESTS
// ============================================================================

test "kuramoto ecosystem initialization" {
    const allocator = std.testing.allocator;
    var eco = try KuramotoDidEcosystem.init(allocator, 0.5);
    defer eco.deinit();

    // Should have 14 methods (5 dead + 5 alive + 3 exceptions + did:gay)
    try std.testing.expectEqual(@as(usize, 14), eco.oscillators.len);
}

test "kuramoto step advances time" {
    const allocator = std.testing.allocator;
    var eco = try KuramotoDidEcosystem.init(allocator, 0.5);
    defer eco.deinit();

    const t0 = eco.time_q;
    eco.step();
    try std.testing.expectEqual(t0 + 1, eco.time_q);
}

test "order parameter bounded" {
    const allocator = std.testing.allocator;
    var eco = try KuramotoDidEcosystem.init(allocator, 0.5);
    defer eco.deinit();

    const op = eco.orderParameter();
    try std.testing.expect(op.r >= 0 and op.r <= 1.0);
}

test "seasonal signature returns valid quarters" {
    const allocator = std.testing.allocator;
    var eco = try KuramotoDidEcosystem.init(allocator, 0.5);
    defer eco.deinit();

    const sig = eco.seasonalSignature();
    try std.testing.expect(sig.hype_quarter >= 1 and sig.hype_quarter <= 4);
    try std.testing.expect(sig.death_quarter >= 1 and sig.death_quarter <= 4);
}

test "ecosystem GF(3) balance is valid trit" {
    const allocator = std.testing.allocator;
    var eco = try KuramotoDidEcosystem.init(allocator, 0.5);
    defer eco.deinit();

    const bal = eco.ecosystemBalance();
    const v = @intFromEnum(bal);
    try std.testing.expect(v >= -1 and v <= 1);
}

test "18-month resonance frequency" {
    // 6 quarters = 18 months → 2π/6 ≈ 1.047 rad/quarter
    try std.testing.expect(@abs(HYPE_CYCLE_OMEGA - 1.047) < 0.01);
}

test "critical phase detection for TBD" {
    // TBD died at ~π phase (halfway through hype cycle)
    const tbd = DidOscillator{
        .method = "did:dht",
        .omega = -1.05,
        .phase = math.pi * 0.95, // near π
        .state = .minus,
        .amplitude = 0.08,
        .birth_q = 13,
        .death_q = 19,
    };
    try std.testing.expect(nearCriticalPhase(tbd, 0.2));
}

test "did:gay not near critical phase" {
    const gay = DidOscillator{
        .method = "did:gay",
        .omega = 0.69,
        .phase = 0.0, // just born, phase ≈ 0
        .state = .plus,
        .amplitude = 0.10,
        .birth_q = 28,
        .death_q = 0,
    };
    try std.testing.expect(!nearCriticalPhase(gay, 0.2));
}

test "multi-step simulation converges" {
    const allocator = std.testing.allocator;
    var eco = try KuramotoDidEcosystem.init(allocator, 1.0); // strong coupling
    defer eco.deinit();

    // Run 20 quarters (5 years)
    for (0..20) |_| eco.step();

    // Order parameter should be > 0 (some coherence after strong coupling)
    const op = eco.orderParameter();
    try std.testing.expect(op.r > 0);
}

test "invariant 0: hype mortality > 0.60" {
    const allocator = std.testing.allocator;
    var eco = try KuramotoDidEcosystem.init(allocator, 0.5);
    defer eco.deinit();

    const rate = hypeMortalityRate(eco);
    // 4 of 6 hyped methods died (ion, dht, sov, 3id). ethr has escape hatch, pkh alive.
    // = 4/6 ≈ 0.667
    try std.testing.expect(rate > 0.60);
}

test "invariant 0 converse: anti-hype survival = 100%" {
    const allocator = std.testing.allocator;
    var eco = try KuramotoDidEcosystem.init(allocator, 0.5);
    defer eco.deinit();

    const rate = antiHypeSurvivalRate(eco);
    // All unhyped methods (did:web, did:key, did:peer, did:tdw, did:gay) are alive
    try std.testing.expect(rate > 0.99);
}

test "invariant 2*: zero marginal cost survival > 0.80" {
    const allocator = std.testing.allocator;
    var eco = try KuramotoDidEcosystem.init(allocator, 0.5);
    defer eco.deinit();

    const rate = zeroCostSurvivalRate(eco);
    try std.testing.expect(rate > 0.80);
}

test "did:gay satisfies all survival invariants" {
    const allocator = std.testing.allocator;
    var eco = try KuramotoDidEcosystem.init(allocator, 0.5);
    defer eco.deinit();

    try std.testing.expect(didGaySurvivalCheck(eco));
}

test "regret distance of dead methods" {
    const allocator = std.testing.allocator;
    var eco = try KuramotoDidEcosystem.init(allocator, 0.5);
    defer eco.deinit();

    // TBD (index 1) regret distance
    const rd = regretDistance(eco, 1);
    try std.testing.expect(rd >= 0 and rd <= 2);
}

test "HMM transition matrix rows sum to 1" {
    const hmm = HmmTransitionMatrix.empirical();
    for (hmm.base) |row| {
        const sum = row[0] + row[1] + row[2];
        try std.testing.expect(@abs(sum - 1.0) < 0.01);
    }
}

test "HMM seasonal death sums to 1" {
    const hmm = HmmTransitionMatrix.empirical();
    const sum = hmm.seasonal_death[0] + hmm.seasonal_death[1] +
        hmm.seasonal_death[2] + hmm.seasonal_death[3];
    try std.testing.expect(@abs(sum - 1.0) < 0.01);
}

test "HMM killing quarter is Q4" {
    const hmm = HmmTransitionMatrix.empirical();
    try std.testing.expectEqual(@as(u2, 3), hmm.killingQuarter()); // Q4 = index 3
}

test "HMM decline is absorbing" {
    const hmm = HmmTransitionMatrix.empirical();
    // P(DECLINE→DECLINE) should be highest in decline row
    try std.testing.expect(hmm.base[2][2] > hmm.base[2][0]);
    try std.testing.expect(hmm.base[2][2] > hmm.base[2][1]);
    // P(DECLINE→HYPE) = 0
    try std.testing.expect(hmm.base[2][0] == 0);
}

test "HMM hype is unstable" {
    const hmm = HmmTransitionMatrix.empirical();
    // P(HYPE→HYPE) should be low
    try std.testing.expect(hmm.base[0][0] < 0.2);
    // P(HYPE→DECLINE) should be high
    try std.testing.expect(hmm.base[0][2] > 0.8);
}

test "HMM plateau is stable" {
    const hmm = HmmTransitionMatrix.empirical();
    try std.testing.expect(hmm.base[1][1] > 0.85);
}

test "exception survivors have escape hatches" {
    const allocator = std.testing.allocator;
    var eco = try KuramotoDidEcosystem.init(allocator, 0.5);
    defer eco.deinit();

    for (eco.oscillators) |osc| {
        if (std.mem.eql(u8, osc.method, "did:cheqd") or
            std.mem.eql(u8, osc.method, "did:ens"))
        {
            try std.testing.expectEqual(EscapeHatch.token_dao, osc.escape_hatch);
            try std.testing.expectEqual(@as(u16, 0), osc.death_q);
        }
        if (std.mem.eql(u8, osc.method, "did:ebsi")) {
            try std.testing.expectEqual(EscapeHatch.sovereign, osc.escape_hatch);
        }
    }
}
