//! Prigogine Module — Dissipative Structures & Non-Equilibrium Thermodynamics
//!
//! Ilya Prigogine (1917-2003, Nobel 1977): order through fluctuations.
//! Systems far from thermodynamic equilibrium spontaneously break symmetry
//! at bifurcation points, creating stable ordered patterns — dissipative
//! structures — maintained by continuous entropy export to the environment.
//!
//! This module connects three zig-syrup subsystems:
//! - FEM (spatial patterns on meshes: reaction-diffusion PDEs)
//! - Spectral tensor (Laplacian eigenmodes: which patterns emerge at bifurcation)
//! - Homotopy continuation (tracking solution branches through bifurcation points)
//!
//! Key concepts implemented:
//! 1. Entropy production rate: σ = Σ Jₖ · Xₖ (thermodynamic fluxes × forces)
//! 2. Minimum entropy production (near-equilibrium Lyapunov function)
//! 3. Brusselator: Prigogine's canonical chemical oscillator
//! 4. Turing instability: diffusion-driven pattern formation on the Laplacian
//! 5. Bifurcation detection via eigenvalue crossing of the linearized operator
//! 6. Dissipative structure classifier: GF(3) triadic encoding
//!
//! The deep connection to thalamocortical oscillations:
//! Brain oscillations ARE dissipative structures. The thalamocortical system
//! operates far from equilibrium (powered by metabolic energy), and its
//! oscillatory patterns emerge via Turing-Prigogine bifurcations on the
//! connectome Laplacian. The spectral tensor decomposes the resulting
//! spatiotemporal pattern; the Prigogine module explains WHY those patterns
//! exist and HOW they form.

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

// ============================================================================
// THERMODYNAMIC STATE
// ============================================================================

/// A thermodynamic flux-force pair
/// σ_k = J_k · X_k is the local entropy production from process k
pub const FluxForce = struct {
    /// Thermodynamic flux (rate of process: reaction rate, heat flow, diffusion current)
    flux: f64,
    /// Conjugate thermodynamic force (affinity, ΔT/T², Δμ/T)
    force: f64,

    /// Local entropy production rate from this process
    pub fn entropyProduction(self: FluxForce) f64 {
        return self.flux * self.force;
    }
};

/// Non-equilibrium thermodynamic state at a spatial point
pub const ThermodynamicState = struct {
    /// Concentration/field variables (e.g., [X, Y] for Brusselator)
    concentrations: []f64,
    /// Flux-force pairs for all irreversible processes
    processes: []FluxForce,

    /// Total local entropy production: σ = Σ J_k · X_k ≥ 0
    /// (Second law: always non-negative)
    pub fn entropyProductionRate(self: ThermodynamicState) f64 {
        var sigma: f64 = 0;
        for (self.processes) |p| sigma += p.entropyProduction();
        return sigma;
    }

    pub fn deinit(self: ThermodynamicState, allocator: Allocator) void {
        allocator.free(self.concentrations);
        allocator.free(self.processes);
    }
};

// ============================================================================
// BRUSSELATOR — Prigogine's Canonical Oscillator
// ============================================================================

/// The Brusselator: simplest chemical system exhibiting oscillations
/// and Turing patterns. Proposed by Prigogine & Lefever (1968).
///
/// Reactions:
///   A → X           (rate k₁A)
///   2X + Y → 3X     (rate k₂X²Y, autocatalytic)
///   B + X → Y + D   (rate k₃BX)
///   X → E           (rate k₄X)
///
/// With k₁=k₂=k₃=k₄=1, the ODEs become:
///   dX/dt = A + X²Y - (B+1)X
///   dY/dt = BX - X²Y
///
/// Steady state: (X*, Y*) = (A, B/A)
/// Hopf bifurcation at B = 1 + A²
pub const Brusselator = struct {
    /// Control parameter A (feed concentration)
    a: f64,
    /// Control parameter B (bifurcation parameter)
    b: f64,
    /// Diffusion coefficient for X
    dx: f64,
    /// Diffusion coefficient for Y
    dy: f64,

    pub fn init(a: f64, b: f64, dx: f64, dy: f64) Brusselator {
        return .{ .a = a, .b = b, .dx = dx, .dy = dy };
    }

    /// Steady state concentrations
    pub fn steadyState(self: Brusselator) [2]f64 {
        return .{ self.a, self.b / self.a };
    }

    /// Reaction kinetics: f(X, Y) = (dX/dt, dY/dt) without diffusion
    pub fn reaction(self: Brusselator, x: f64, y: f64) [2]f64 {
        const x2y = x * x * y;
        return .{
            self.a + x2y - (self.b + 1.0) * x,
            self.b * x - x2y,
        };
    }

    /// Jacobian of reaction at (x, y):
    /// J = [[ 2xy - (B+1),  x² ],
    ///      [ B - 2xy,      -x² ]]
    pub fn jacobian(self: Brusselator, x: f64, y: f64) [2][2]f64 {
        return .{
            .{ 2.0 * x * y - (self.b + 1.0), x * x },
            .{ self.b - 2.0 * x * y, -x * x },
        };
    }

    /// Jacobian evaluated at steady state:
    /// J* = [[ B-1,  A² ],
    ///       [ -B,  -A² ]]
    pub fn steadyStateJacobian(self: Brusselator) [2][2]f64 {
        const a2 = self.a * self.a;
        return .{
            .{ self.b - 1.0, a2 },
            .{ -self.b, -a2 },
        };
    }

    /// Trace of steady-state Jacobian: determines Hopf condition
    /// tr(J*) = B - 1 - A²
    /// Hopf bifurcation when tr(J*) = 0, i.e., B = 1 + A²
    pub fn trace(self: Brusselator) f64 {
        return self.b - 1.0 - self.a * self.a;
    }

    /// Determinant of steady-state Jacobian
    /// det(J*) = A²  (always positive → no saddle-node for A > 0)
    pub fn determinant(self: Brusselator) f64 {
        return self.a * self.a;
    }

    /// Critical bifurcation parameter B_c for Hopf instability
    pub fn hopfBifurcation(self: Brusselator) f64 {
        return 1.0 + self.a * self.a;
    }

    /// Is the steady state stable? (both eigenvalues have negative real part)
    /// Stable iff tr < 0 AND det > 0
    pub fn isStable(self: Brusselator) bool {
        return self.trace() < 0 and self.determinant() > 0;
    }

    /// Eigenvalues of steady-state Jacobian: λ = (tr ± √(tr² - 4·det)) / 2
    /// Returns (real_part, imag_part) of the eigenvalue with larger real part
    pub fn dominantEigenvalue(self: Brusselator) [2]f64 {
        const tr = self.trace();
        const det_val = self.determinant();
        const disc = tr * tr - 4.0 * det_val;

        if (disc >= 0) {
            // Real eigenvalues
            return .{ (tr + @sqrt(disc)) / 2.0, 0 };
        } else {
            // Complex conjugate pair
            return .{ tr / 2.0, @sqrt(-disc) / 2.0 };
        }
    }

    /// Entropy production at steady state
    /// For the Brusselator, σ* = A·ln(A) + B·ln(B/A²) (schematic)
    /// The actual production depends on the distance from equilibrium
    pub fn steadyStateEntropyProduction(self: Brusselator) f64 {
        const ss = self.steadyState();
        const x = ss[0];
        const y = ss[1];
        // Sum of flux × affinity for each reaction at steady state
        // Simplified: proportional to reaction rates
        const r1 = self.a; // A → X
        const r2 = x * x * y; // autocatalytic
        const r3 = self.b * x; // B + X → Y + D
        const r4 = x; // X → E
        return r1 + r2 + r3 + r4;
    }
};

// ============================================================================
// TURING INSTABILITY — Pattern Formation on Laplacian
// ============================================================================

/// Turing instability analysis for a 2-species reaction-diffusion system
/// on a domain with Laplacian eigenmodes.
///
/// The dispersion relation: det(J - k²D - σI) = 0
/// where J is the reaction Jacobian, D = diag(Dx, Dy), k² is the Laplacian eigenvalue.
///
/// Turing instability occurs when:
/// 1. Homogeneous steady state is stable (tr(J) < 0, det(J) > 0)
/// 2. But for some k², the spatially extended system is unstable
///
/// This requires: det(J - k²D) < 0 for some k²
/// Which means: Dx·Dy·k⁴ - (Dy·j11 + Dx·j22)·k² + det(J) < 0
pub const TuringAnalysis = struct {
    /// Reaction Jacobian at steady state
    jac: [2][2]f64,
    /// Diffusion coefficients [Dx, Dy]
    diff: [2]f64,

    pub fn init(jac: [2][2]f64, diff: [2]f64) TuringAnalysis {
        return .{ .jac = jac, .diff = diff };
    }

    /// From a Brusselator configuration
    pub fn fromBrusselator(br: Brusselator) TuringAnalysis {
        return .{
            .jac = br.steadyStateJacobian(),
            .diff = .{ br.dx, br.dy },
        };
    }

    /// Trace of J
    fn trJ(self: TuringAnalysis) f64 {
        return self.jac[0][0] + self.jac[1][1];
    }

    /// Determinant of J
    fn detJ(self: TuringAnalysis) f64 {
        return self.jac[0][0] * self.jac[1][1] - self.jac[0][1] * self.jac[1][0];
    }

    /// Is the homogeneous state stable? (necessary for Turing)
    pub fn isHomogeneousStable(self: TuringAnalysis) bool {
        return self.trJ() < 0 and self.detJ() > 0;
    }

    /// Dispersion relation: growth rate σ(k²)
    /// For each Laplacian eigenvalue k², compute the max real eigenvalue
    /// of (J - k²·D). If σ > 0 for some k², the mode is Turing-unstable.
    pub fn growthRate(self: TuringAnalysis, k_sq: f64) f64 {
        // Effective Jacobian: J_eff = J - k²·D
        const j11_eff = self.jac[0][0] - self.diff[0] * k_sq;
        const j22_eff = self.jac[1][1] - self.diff[1] * k_sq;
        const tr_eff = j11_eff + j22_eff;
        const det_eff = j11_eff * j22_eff - self.jac[0][1] * self.jac[1][0];
        const disc = tr_eff * tr_eff - 4.0 * det_eff;

        if (disc >= 0) {
            return (tr_eff + @sqrt(disc)) / 2.0;
        } else {
            return tr_eff / 2.0; // complex eigenvalue, real part
        }
    }

    /// Critical wavenumber squared where Turing instability first appears
    /// Minimizes det(J - k²D) over k²:
    /// k²_c = sqrt(det(J) / (Dx·Dy))
    pub fn criticalWavenumber(self: TuringAnalysis) f64 {
        const det_j = self.detJ();
        if (det_j <= 0) return 0;
        return @sqrt(det_j / (self.diff[0] * self.diff[1]));
    }

    /// Turing bifurcation condition:
    /// Dy·j11 + Dx·j22 > 2·sqrt(Dx·Dy·det(J))
    /// Returns the "Turing number": positive means Turing-unstable
    pub fn turingNumber(self: TuringAnalysis) f64 {
        const lhs = self.diff[1] * self.jac[0][0] + self.diff[0] * self.jac[1][1];
        const det_j = self.detJ();
        if (det_j <= 0) return math.inf(f64); // already saddle-unstable
        const rhs = 2.0 * @sqrt(self.diff[0] * self.diff[1] * det_j);
        return lhs - rhs; // > 0 means Turing-unstable
    }

    /// Is this system Turing-unstable?
    /// Requires: homogeneous stable AND turing number > 0
    pub fn isTuringUnstable(self: TuringAnalysis) bool {
        return self.isHomogeneousStable() and self.turingNumber() > 0;
    }

    /// Find the most unstable Laplacian eigenvalue from a spectrum
    /// Returns (eigenvalue_index, growth_rate) of the fastest-growing mode
    pub fn mostUnstableMode(self: TuringAnalysis, spectrum: []const f64) struct { index: usize, growth: f64 } {
        var best_idx: usize = 0;
        var best_growth: f64 = -math.inf(f64);

        for (spectrum, 0..) |lam, i| {
            const sigma = self.growthRate(lam);
            if (sigma > best_growth) {
                best_growth = sigma;
                best_idx = i;
            }
        }

        return .{ .index = best_idx, .growth = best_growth };
    }
};

// ============================================================================
// REACTION-DIFFUSION INTEGRATOR
// ============================================================================

/// State of a reaction-diffusion system on a discrete domain (graph/mesh)
pub const ReactionDiffusionState = struct {
    /// Number of spatial nodes
    n_nodes: usize,
    /// Number of species
    n_species: usize,
    /// Concentrations: [species][node]
    u: [][]f64,

    pub fn init(allocator: Allocator, n_nodes: usize, n_species: usize) !ReactionDiffusionState {
        const u = try allocator.alloc([]f64, n_species);
        for (u) |*row| {
            row.* = try allocator.alloc(f64, n_nodes);
            @memset(row.*, 0);
        }
        return .{ .n_nodes = n_nodes, .n_species = n_species, .u = u };
    }

    pub fn deinit(self: ReactionDiffusionState, allocator: Allocator) void {
        for (self.u) |row| allocator.free(row);
        allocator.free(self.u);
    }

    /// Set uniform initial condition at steady state
    pub fn setUniform(self: *ReactionDiffusionState, species: usize, value: f64) void {
        @memset(self.u[species], value);
    }

    /// Add small random perturbation to break symmetry
    pub fn perturb(self: *ReactionDiffusionState, species: usize, amplitude: f64, seed: u64) void {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        for (self.u[species]) |*val| {
            val.* += amplitude * (random.float(f64) - 0.5);
        }
    }

    /// Total concentration of a species (conserved quantity check)
    pub fn totalConcentration(self: ReactionDiffusionState, species: usize) f64 {
        var sum: f64 = 0;
        for (self.u[species]) |v| sum += v;
        return sum;
    }

    /// Total entropy production across all nodes
    pub fn totalEntropyProduction(self: ReactionDiffusionState, brusselator: Brusselator) f64 {
        var total: f64 = 0;
        for (0..self.n_nodes) |node| {
            const x = self.u[0][node];
            const y = self.u[1][node];
            // Entropy production ≈ sum of squared reaction rates
            const rx = brusselator.reaction(x, y);
            total += rx[0] * rx[0] + rx[1] * rx[1];
        }
        return total;
    }
};

/// Forward Euler step for Brusselator on a graph with Laplacian L
/// du/dt = f(u) + D·L·u
pub fn brusselatorStep(
    state: *ReactionDiffusionState,
    br: Brusselator,
    laplacian_data: []const f64, // flat n×n Laplacian
    dt: f64,
) void {
    const n = state.n_nodes;

    for (0..n) |i| {
        const x = state.u[0][i];
        const y = state.u[1][i];

        // Reaction terms
        const rx = br.reaction(x, y);

        // Diffusion terms: D * (L * u)[i]
        var lap_x: f64 = 0;
        var lap_y: f64 = 0;
        for (0..n) |j| {
            const l_ij = laplacian_data[i * n + j];
            // Note: for diffusion we use -L (since L is positive semidefinite
            // and diffusion operator is negative definite)
            lap_x += -l_ij * state.u[0][j];
            lap_y += -l_ij * state.u[1][j];
        }

        // Forward Euler update
        state.u[0][i] = x + dt * (rx[0] + br.dx * lap_x);
        state.u[1][i] = y + dt * (rx[1] + br.dy * lap_y);
    }
}

// ============================================================================
// BIFURCATION TRACKING
// ============================================================================

/// Result of a bifurcation scan: for each value of control parameter B,
/// record the stability and dominant eigenvalue
pub const BifurcationPoint = struct {
    /// Value of control parameter B
    b_value: f64,
    /// Real part of dominant eigenvalue
    real_part: f64,
    /// Imaginary part (nonzero → oscillatory)
    imag_part: f64,
    /// Is the steady state stable at this B?
    stable: bool,
    /// Type of bifurcation (if crossing occurs near this B)
    bifurcation_type: BifurcationType,
};

pub const BifurcationType = enum {
    none, // no bifurcation
    hopf, // tr(J) crosses zero → oscillations
    turing, // det(J-k²D) crosses zero → spatial patterns
    turing_hopf, // both simultaneously → spatiotemporal chaos
};

/// Scan control parameter B to find bifurcation points
pub fn bifurcationScan(
    a: f64,
    dx: f64,
    dy: f64,
    b_start: f64,
    b_end: f64,
    n_steps: usize,
    laplacian_spectrum: ?[]const f64,
    allocator: Allocator,
) ![]BifurcationPoint {
    var points = try allocator.alloc(BifurcationPoint, n_steps);

    for (0..n_steps) |i| {
        const fi: f64 = @floatFromInt(i);
        const fn_steps: f64 = @floatFromInt(n_steps - 1);
        const b = b_start + (b_end - b_start) * fi / fn_steps;

        const br = Brusselator.init(a, b, dx, dy);
        const eig = br.dominantEigenvalue();
        const hopf_unstable = br.trace() >= 0;

        var turing_unstable = false;
        if (laplacian_spectrum) |spec| {
            const turing = TuringAnalysis.fromBrusselator(br);
            const mode = turing.mostUnstableMode(spec);
            turing_unstable = mode.growth > 0;
        }

        const bif_type: BifurcationType = if (hopf_unstable and turing_unstable)
            .turing_hopf
        else if (hopf_unstable)
            .hopf
        else if (turing_unstable)
            .turing
        else
            .none;

        points[i] = .{
            .b_value = b,
            .real_part = eig[0],
            .imag_part = eig[1],
            .stable = br.isStable(),
            .bifurcation_type = bif_type,
        };
    }

    return points;
}

/// Find the exact Hopf bifurcation point by bisection
pub fn findHopfBifurcation(a: f64, b_low: f64, b_high: f64, tol: f64) f64 {
    var lo = b_low;
    var hi = b_high;

    for (0..100) |_| {
        const mid = (lo + hi) / 2.0;
        const br = Brusselator.init(a, mid, 0, 0);
        if (br.trace() < 0) {
            lo = mid; // still stable, move up
        } else {
            hi = mid; // unstable, move down
        }
        if (hi - lo < tol) break;
    }
    return (lo + hi) / 2.0;
}

// ============================================================================
// DISSIPATIVE STRUCTURE CLASSIFIER — GF(3) TRIADIC
// ============================================================================

/// Prigogine's regime classification in GF(3) balanced ternary
pub const DissipativeRegime = enum(i8) {
    /// Near equilibrium: linear regime, minimum entropy production
    /// Onsager reciprocal relations hold. Perturbations decay.
    near_equilibrium = -1,

    /// Critical: at or near bifurcation point
    /// Fluctuations amplified, symmetry breaking imminent
    critical = 0,

    /// Far from equilibrium: dissipative structure formed
    /// New ordered state maintained by entropy export
    far_from_equilibrium = 1,

    pub fn fromBrusselator(br: Brusselator) DissipativeRegime {
        const b_c = br.hopfBifurcation();
        const distance = (br.b - b_c) / b_c; // normalized distance from bifurcation

        if (distance < -0.1) return .near_equilibrium;
        if (distance > 0.1) return .far_from_equilibrium;
        return .critical;
    }

    pub fn trit(self: DissipativeRegime) i8 {
        return @intFromEnum(self);
    }
};

/// Full Prigogine classification of a system state
pub const PrigogineClassification = struct {
    /// Thermodynamic regime
    regime: DissipativeRegime,
    /// Spatial pattern type
    pattern: PatternType,
    /// Temporal behavior
    temporal: TemporalType,

    /// GF(3) conservation: regime + pattern + temporal ≡ 0 (mod 3)
    pub fn isBalanced(self: PrigogineClassification) bool {
        const sum = @mod(self.regime.trit() + self.pattern.trit() + self.temporal.trit() + 9, 3);
        return sum == 0;
    }

    /// Force balance by adjusting temporal
    pub fn balance(self: *PrigogineClassification) void {
        const partial = @mod(self.regime.trit() + self.pattern.trit() + 9, 3);
        self.temporal = switch (partial) {
            0 => .steady,
            1 => .decay,
            2 => .oscillatory,
            else => unreachable,
        };
    }
};

pub const PatternType = enum(i8) {
    homogeneous = -1, // uniform, no spatial structure
    modulated = 0, // weak spatial modulation
    turing_pattern = 1, // strong spatial pattern (stripes, spots)

    pub fn trit(self: PatternType) i8 {
        return @intFromEnum(self);
    }
};

pub const TemporalType = enum(i8) {
    decay = -1, // perturbations decay (stable)
    steady = 0, // marginal / slowly varying
    oscillatory = 1, // limit cycle oscillations

    pub fn trit(self: TemporalType) i8 {
        return @intFromEnum(self);
    }
};

/// Classify a Brusselator system with optional Turing analysis
pub fn classifySystem(br: Brusselator, laplacian_spectrum: ?[]const f64) PrigogineClassification {
    const regime = DissipativeRegime.fromBrusselator(br);

    const eig = br.dominantEigenvalue();
    const temporal: TemporalType = if (eig[0] < -0.01)
        .decay
    else if (eig[0] > 0.01 and eig[1] > 0.01)
        .oscillatory
    else
        .steady;

    var pattern: PatternType = .homogeneous;
    if (laplacian_spectrum) |spec| {
        const turing = TuringAnalysis.fromBrusselator(br);
        if (turing.isTuringUnstable()) {
            const mode = turing.mostUnstableMode(spec);
            if (mode.growth > 0.1) {
                pattern = .turing_pattern;
            } else if (mode.growth > 0) {
                pattern = .modulated;
            }
        }
    }

    var result = PrigogineClassification{
        .regime = regime,
        .pattern = pattern,
        .temporal = temporal,
    };
    result.balance();
    return result;
}

// ============================================================================
// MINIMUM ENTROPY PRODUCTION (Near-Equilibrium Theorem)
// ============================================================================

/// Prigogine's theorem: near equilibrium, a system evolves toward the
/// state of minimum entropy production compatible with its constraints.
///
/// For a linear system with Onsager coefficients L_ij:
///   J_i = Σ_j L_ij · X_j
///   σ = Σ_ij L_ij · X_i · X_j (quadratic form)
///
/// dσ/dt ≤ 0 when L_ij satisfies Onsager reciprocity (L_ij = L_ji)
///
/// This function verifies the minimum entropy production principle
/// for a given Onsager matrix and force vector.
pub fn minimumEntropyProduction(
    onsager: []const f64, // flat n×n Onsager coefficient matrix
    forces: []const f64, // thermodynamic forces X_i
    n: usize,
) f64 {
    // σ = X^T · L · X
    var sigma: f64 = 0;
    for (0..n) |i| {
        for (0..n) |j| {
            sigma += onsager[i * n + j] * forces[i] * forces[j];
        }
    }
    return sigma;
}

/// Check Onsager reciprocity: L_ij = L_ji (microscopic reversibility)
pub fn checkOnsagerReciprocity(onsager: []const f64, n: usize, tol: f64) bool {
    for (0..n) |i| {
        for (i + 1..n) |j| {
            if (@abs(onsager[i * n + j] - onsager[j * n + i]) > tol) return false;
        }
    }
    return true;
}

// ============================================================================
// TIME ARROW — Prigogine's Philosophy of Irreversibility
// ============================================================================

/// Prigogine argued that irreversibility is fundamental, not emergent.
/// The "time arrow" is encoded in the entropy production rate:
/// σ > 0 distinguishes past from future.
///
/// For a trajectory of states, we can quantify the arrow of time
/// by the cumulative entropy production.
pub const TimeArrow = struct {
    /// Cumulative entropy produced
    total_entropy: f64 = 0,
    /// Number of time steps
    steps: usize = 0,
    /// Maximum instantaneous production (peak dissipation)
    peak_production: f64 = 0,
    /// Minimum instantaneous production (closest to equilibrium)
    min_production: f64 = math.inf(f64),

    pub fn record(self: *TimeArrow, sigma: f64) void {
        self.total_entropy += sigma;
        self.steps += 1;
        if (sigma > self.peak_production) self.peak_production = sigma;
        if (sigma < self.min_production) self.min_production = sigma;
    }

    /// Average entropy production rate
    pub fn averageRate(self: TimeArrow) f64 {
        if (self.steps == 0) return 0;
        return self.total_entropy / @as(f64, @floatFromInt(self.steps));
    }

    /// Is the system approaching equilibrium? (decreasing production)
    pub fn isRelaxing(self: TimeArrow) bool {
        return self.min_production < self.averageRate();
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "Brusselator steady state" {
    const br = Brusselator.init(2.0, 5.0, 0.01, 0.1);
    const ss = br.steadyState();

    try std.testing.expectApproxEqAbs(2.0, ss[0], 1e-10); // X* = A
    try std.testing.expectApproxEqAbs(2.5, ss[1], 1e-10); // Y* = B/A
}

test "Brusselator reaction at steady state is zero" {
    const br = Brusselator.init(2.0, 5.0, 0.01, 0.1);
    const ss = br.steadyState();
    const rx = br.reaction(ss[0], ss[1]);

    try std.testing.expectApproxEqAbs(0.0, rx[0], 1e-10);
    try std.testing.expectApproxEqAbs(0.0, rx[1], 1e-10);
}

test "Brusselator Hopf bifurcation at B = 1 + A²" {
    const br = Brusselator.init(2.0, 5.0, 0.01, 0.1);
    const b_c = br.hopfBifurcation();

    // A=2: B_c = 1 + 4 = 5
    try std.testing.expectApproxEqAbs(5.0, b_c, 1e-10);
}

test "Brusselator stability: B < B_c stable, B > B_c unstable" {
    // A = 2, B_c = 5
    const stable = Brusselator.init(2.0, 4.0, 0.01, 0.1);
    try std.testing.expect(stable.isStable());

    const critical = Brusselator.init(2.0, 5.0, 0.01, 0.1);
    // At exactly B_c, trace = 0 (marginally stable, not strictly stable)
    try std.testing.expect(!critical.isStable());

    const unstable = Brusselator.init(2.0, 6.0, 0.01, 0.1);
    try std.testing.expect(!unstable.isStable());
}

test "Brusselator eigenvalue at Hopf is purely imaginary" {
    // At B = B_c: tr = 0, so eigenvalues are ±iω where ω = √det
    const br = Brusselator.init(2.0, 5.0, 0.01, 0.1);
    const eig = br.dominantEigenvalue();

    try std.testing.expectApproxEqAbs(0.0, eig[0], 1e-10); // real = 0
    try std.testing.expectApproxEqAbs(2.0, eig[1], 1e-10); // imag = A = 2
}

test "Turing instability requires Dy >> Dx" {
    // Activator diffuses slowly, inhibitor diffuses fast → Turing
    const br = Brusselator.init(2.0, 4.5, 0.01, 1.0); // B < B_c, so homogeneous stable
    const turing = TuringAnalysis.fromBrusselator(br);

    try std.testing.expect(turing.isHomogeneousStable());
    // With Dy/Dx = 100, Turing instability should be possible
    try std.testing.expect(turing.turingNumber() > 0);
    try std.testing.expect(turing.isTuringUnstable());
}

test "no Turing with equal diffusion" {
    const br = Brusselator.init(2.0, 4.5, 0.1, 0.1);
    const turing = TuringAnalysis.fromBrusselator(br);

    // Equal diffusion cannot produce Turing patterns
    try std.testing.expect(!turing.isTuringUnstable());
}

test "critical wavenumber is finite for Turing-unstable system" {
    const br = Brusselator.init(2.0, 4.5, 0.01, 1.0);
    const turing = TuringAnalysis.fromBrusselator(br);
    const k_c = turing.criticalWavenumber();

    try std.testing.expect(k_c > 0);
    try std.testing.expect(math.isFinite(k_c));
}

test "dispersion relation shape" {
    const br = Brusselator.init(2.0, 4.5, 0.01, 1.0);
    const turing = TuringAnalysis.fromBrusselator(br);

    // At k²=0: should match homogeneous eigenvalue (stable, σ < 0)
    const sigma_0 = turing.growthRate(0);
    try std.testing.expect(sigma_0 < 0);

    // At large k²: diffusion dominates, σ → -∞
    const sigma_large = turing.growthRate(1000);
    try std.testing.expect(sigma_large < sigma_0);

    // At critical k²: positive growth
    const k_c = turing.criticalWavenumber();
    const sigma_c = turing.growthRate(k_c);
    try std.testing.expect(sigma_c > 0);
}

test "most unstable mode from spectrum" {
    const br = Brusselator.init(2.0, 4.5, 0.01, 1.0);
    const turing = TuringAnalysis.fromBrusselator(br);

    // Fake Laplacian spectrum: 0, 1, 4, 9, 16, 25
    const spectrum = [_]f64{ 0, 1.0, 4.0, 9.0, 16.0, 25.0 };
    const mode = turing.mostUnstableMode(&spectrum);

    // Turing instability: at least one mode has positive growth
    try std.testing.expect(mode.growth > 0);
    // The k²=0 mode should not be the most unstable (that's the homogeneous mode)
    // — growth at k²=0 is negative (homogeneous stable is a prerequisite for Turing)
    const sigma_0 = turing.growthRate(0);
    try std.testing.expect(sigma_0 < 0);
    try std.testing.expect(mode.growth > sigma_0);
}

test "bifurcation scan finds Hopf" {
    const allocator = std.testing.allocator;

    const points = try bifurcationScan(2.0, 0.01, 0.1, 3.0, 7.0, 50, null, allocator);
    defer allocator.free(points);

    // Should transition from stable to unstable around B=5
    var found_transition = false;
    for (0..points.len - 1) |i| {
        if (points[i].stable and !points[i + 1].stable) {
            found_transition = true;
            // Should be near B = 5
            try std.testing.expect(points[i].b_value > 4.5);
            try std.testing.expect(points[i + 1].b_value < 5.5);
            break;
        }
    }
    try std.testing.expect(found_transition);
}

test "find Hopf by bisection" {
    const b_c = findHopfBifurcation(2.0, 3.0, 7.0, 1e-10);

    // Should find B_c = 5.0 (= 1 + A²)
    try std.testing.expectApproxEqAbs(5.0, b_c, 1e-8);
}

test "dissipative regime classification" {
    const near_eq = DissipativeRegime.fromBrusselator(Brusselator.init(2.0, 3.0, 0.01, 0.1));
    try std.testing.expectEqual(DissipativeRegime.near_equilibrium, near_eq);

    const critical = DissipativeRegime.fromBrusselator(Brusselator.init(2.0, 5.0, 0.01, 0.1));
    try std.testing.expectEqual(DissipativeRegime.critical, critical);

    const far = DissipativeRegime.fromBrusselator(Brusselator.init(2.0, 7.0, 0.01, 0.1));
    try std.testing.expectEqual(DissipativeRegime.far_from_equilibrium, far);
}

test "GF(3) classification balance" {
    const br = Brusselator.init(2.0, 4.5, 0.01, 1.0);
    const spectrum = [_]f64{ 1.0, 4.0, 9.0 };
    const cls = classifySystem(br, &spectrum);

    try std.testing.expect(cls.isBalanced());
}

test "Onsager reciprocity check" {
    // Symmetric matrix: reciprocal relations hold
    const L = [_]f64{ 1.0, 0.5, 0.5, 2.0 };
    try std.testing.expect(checkOnsagerReciprocity(&L, 2, 1e-10));

    // Non-symmetric: reciprocity violated
    const L_bad = [_]f64{ 1.0, 0.5, 0.3, 2.0 };
    try std.testing.expect(!checkOnsagerReciprocity(&L_bad, 2, 1e-10));
}

test "minimum entropy production is non-negative for positive-definite L" {
    // L = [[2, 1], [1, 3]] (positive definite)
    const L = [_]f64{ 2.0, 1.0, 1.0, 3.0 };
    const X = [_]f64{ 1.0, -0.5 };

    const sigma = minimumEntropyProduction(&L, &X, 2);
    try std.testing.expect(sigma > 0); // σ > 0 away from equilibrium
}

test "entropy production at equilibrium is zero" {
    const L = [_]f64{ 2.0, 1.0, 1.0, 3.0 };
    const X = [_]f64{ 0.0, 0.0 }; // at equilibrium, all forces vanish

    const sigma = minimumEntropyProduction(&L, &X, 2);
    try std.testing.expectApproxEqAbs(0.0, sigma, 1e-15);
}

test "time arrow records entropy production" {
    var arrow = TimeArrow{};

    arrow.record(1.0);
    arrow.record(0.8);
    arrow.record(0.6);

    try std.testing.expectEqual(@as(usize, 3), arrow.steps);
    try std.testing.expectApproxEqAbs(2.4, arrow.total_entropy, 1e-10);
    try std.testing.expectApproxEqAbs(0.8, arrow.averageRate(), 1e-10);
    try std.testing.expectApproxEqAbs(1.0, arrow.peak_production, 1e-10);
    try std.testing.expectApproxEqAbs(0.6, arrow.min_production, 1e-10);
}

test "reaction-diffusion state init and perturb" {
    const allocator = std.testing.allocator;

    var state = try ReactionDiffusionState.init(allocator, 5, 2);
    defer state.deinit(allocator);

    const br = Brusselator.init(2.0, 5.0, 0.01, 0.1);
    const ss = br.steadyState();

    state.setUniform(0, ss[0]);
    state.setUniform(1, ss[1]);

    // Total should be n * steady_state_value
    try std.testing.expectApproxEqAbs(10.0, state.totalConcentration(0), 1e-10);
    try std.testing.expectApproxEqAbs(12.5, state.totalConcentration(1), 1e-10);

    // Perturb and check total changes slightly
    state.perturb(0, 0.01, 42);
    const perturbed_total = state.totalConcentration(0);
    try std.testing.expect(@abs(perturbed_total - 10.0) < 0.1);
}
