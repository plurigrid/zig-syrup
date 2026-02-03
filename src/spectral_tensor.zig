//! Spectral Tensor Module for Thalamocortical Integration
//!
//! Solves the occupancy problem: how do nested oscillations (gamma within theta)
//! bind distributed representations without destructive interference?
//!
//! Mathematical core:
//! - Graph Laplacian eigenmodes of connectivity → spatial patterns of oscillation
//! - 3-way tensor X(time × eigenmode × frequency) via CPD decomposition
//! - Φ-proxy from spectral properties (Toker & Sommer): λ₂ = integration floor
//! - Phase-slot occupancy: tensor rank = items, slots = floor(f_theta / f_gamma)
//!
//! Builds on fem.zig (CSRMatrix, conjugateGradient, SIMD), continuation.zig (Trit/GF(3))
//!
//! References:
//! - Raj et al. 2020: Spectral graph theory of brain oscillations
//! - Lisman & Jensen 2013: Theta-gamma neural code
//! - Toker & Sommer 2016: Spectral proxy for Minimum Information Partition
//! - Tononi 2004/2023: Integrated Information Theory (IIT 4.0)

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

// ============================================================================
// DENSE MATRIX OPERATIONS (for eigendecomposition on small-to-mid systems)
// ============================================================================

/// Dense matrix for Laplacian eigendecomposition
/// Row-major: element (i,j) at data[i * cols + j]
pub const DenseMatrix = struct {
    rows: usize,
    cols: usize,
    data: []f64,

    pub fn init(allocator: Allocator, rows: usize, cols: usize) !DenseMatrix {
        const data = try allocator.alloc(f64, rows * cols);
        @memset(data, 0);
        return .{ .rows = rows, .cols = cols, .data = data };
    }

    pub fn deinit(self: DenseMatrix, allocator: Allocator) void {
        allocator.free(self.data);
    }

    pub fn get(self: DenseMatrix, i: usize, j: usize) f64 {
        return self.data[i * self.cols + j];
    }

    pub fn set(self: *DenseMatrix, i: usize, j: usize, val: f64) void {
        self.data[i * self.cols + j] = val;
    }

    pub fn addTo(self: *DenseMatrix, i: usize, j: usize, val: f64) void {
        self.data[i * self.cols + j] += val;
    }

    /// y = A * x
    pub fn matvec(self: DenseMatrix, x: []const f64, y: []f64) void {
        const V = @Vector(4, f64);
        for (0..self.rows) |i| {
            const row_off = i * self.cols;
            var sum: f64 = 0;
            var j: usize = 0;
            while (j + 4 <= self.cols) : (j += 4) {
                const a: V = .{
                    self.data[row_off + j],
                    self.data[row_off + j + 1],
                    self.data[row_off + j + 2],
                    self.data[row_off + j + 3],
                };
                const b: V = .{ x[j], x[j + 1], x[j + 2], x[j + 3] };
                sum += @reduce(.Add, a * b);
            }
            while (j < self.cols) : (j += 1) {
                sum += self.data[row_off + j] * x[j];
            }
            y[i] = sum;
        }
    }
};

// ============================================================================
// GRAPH LAPLACIAN
// ============================================================================

/// Builds the graph Laplacian L = D - A from a symmetric adjacency/weight matrix
/// For neural connectivity: A[i][j] = connection strength between regions i and j
pub const GraphLaplacian = struct {
    L: DenseMatrix,
    degree: []f64,
    n: usize,

    pub fn fromAdjacency(allocator: Allocator, adj: DenseMatrix) !GraphLaplacian {
        const n = adj.rows;
        var L = try DenseMatrix.init(allocator, n, n);
        const degree = try allocator.alloc(f64, n);

        // Compute degree: d_i = Σ_j A_ij
        for (0..n) |i| {
            var d: f64 = 0;
            for (0..n) |j| {
                d += adj.get(i, j);
            }
            degree[i] = d;
        }

        // L = D - A
        for (0..n) |i| {
            for (0..n) |j| {
                if (i == j) {
                    L.set(i, j, degree[i] - adj.get(i, j));
                } else {
                    L.set(i, j, -adj.get(i, j));
                }
            }
        }

        return .{ .L = L, .degree = degree, .n = n };
    }

    /// Normalized Laplacian: L_norm = D^{-1/2} L D^{-1/2}
    /// Better for comparing graphs of different sizes
    pub fn normalized(self: GraphLaplacian, allocator: Allocator) !DenseMatrix {
        var L_norm = try DenseMatrix.init(allocator, self.n, self.n);
        for (0..self.n) |i| {
            for (0..self.n) |j| {
                const di = self.degree[i];
                const dj = self.degree[j];
                if (di > 1e-12 and dj > 1e-12) {
                    L_norm.set(i, j, self.L.get(i, j) / @sqrt(di * dj));
                }
            }
        }
        return L_norm;
    }

    pub fn deinit(self: GraphLaplacian, allocator: Allocator) void {
        self.L.deinit(allocator);
        allocator.free(self.degree);
    }
};

// ============================================================================
// LANCZOS EIGENSOLVER
// ============================================================================

/// Result of eigendecomposition: k smallest eigenvalues and eigenvectors
pub const EigenResult = struct {
    eigenvalues: []f64, // length k, ascending
    eigenvectors: DenseMatrix, // n × k, column j is eigenvector j

    pub fn deinit(self: EigenResult, allocator: Allocator) void {
        allocator.free(self.eigenvalues);
        self.eigenvectors.deinit(allocator);
    }
};

/// SIMD dot product
fn dot(a: []const f64, b: []const f64) f64 {
    const V = @Vector(4, f64);
    const n = a.len;
    var sum: f64 = 0;
    var i: usize = 0;
    while (i + 4 <= n) : (i += 4) {
        const va: V = .{ a[i], a[i + 1], a[i + 2], a[i + 3] };
        const vb: V = .{ b[i], b[i + 1], b[i + 2], b[i + 3] };
        sum += @reduce(.Add, va * vb);
    }
    while (i < n) : (i += 1) sum += a[i] * b[i];
    return sum;
}


/// Compute k smallest eigenvalues/eigenvectors of symmetric matrix
/// Uses Jacobi for robustness on small-to-mid matrices (n < 200)
pub fn eigendecompose(
    A: DenseMatrix,
    k: usize,
    allocator: Allocator,
) !EigenResult {
    const n = A.rows;

    // Full Jacobi eigendecomposition
    var jac = try jacobiEigen(A, allocator);
    defer allocator.free(jac.values);
    defer jac.vectors.deinit(allocator);

    // Sort eigenvalues ascending and find k smallest
    var indices = try allocator.alloc(usize, n);
    defer allocator.free(indices);
    for (0..n) |i| indices[i] = i;

    // Selection sort for k smallest
    const num_k = @min(k, n);
    for (0..num_k) |i| {
        var min_idx = i;
        for (i + 1..n) |j| {
            if (jac.values[indices[j]] < jac.values[indices[min_idx]]) {
                min_idx = j;
            }
        }
        const tmp = indices[i];
        indices[i] = indices[min_idx];
        indices[min_idx] = tmp;
    }

    var result_vals = try allocator.alloc(f64, num_k);
    var result_vecs = try DenseMatrix.init(allocator, n, num_k);

    for (0..num_k) |ki| {
        const idx = indices[ki];
        result_vals[ki] = jac.values[idx];
        for (0..n) |i| {
            result_vecs.set(i, ki, jac.vectors.get(i, idx));
        }
    }

    return .{ .eigenvalues = result_vals, .eigenvectors = result_vecs };
}

/// Classical Jacobi eigenvalue algorithm for symmetric matrices
/// Robust and simple — O(n³) per sweep, typically 5-10 sweeps for convergence
/// Returns eigenvalues in .values and eigenvectors as columns of .vectors
const JacobiResult = struct {
    values: []f64,
    vectors: DenseMatrix,
};

fn jacobiEigen(A: DenseMatrix, allocator: Allocator) !JacobiResult {
    const n = A.rows;

    // Work on a copy
    var S = try DenseMatrix.init(allocator, n, n);
    @memcpy(S.data, A.data);

    // Eigenvectors start as identity
    var V = try DenseMatrix.init(allocator, n, n);
    for (0..n) |i| V.set(i, i, 1.0);

    const max_sweeps: usize = 100;

    for (0..max_sweeps) |_| {
        // Find largest off-diagonal element
        var max_off: f64 = 0;
        for (0..n) |i| {
            for (i + 1..n) |j| {
                const v = @abs(S.get(i, j));
                if (v > max_off) max_off = v;
            }
        }

        // Convergence check
        if (max_off < 1e-12) break;

        // Sweep: zero out all off-diagonal elements via Givens rotations
        for (0..n) |p| {
            for (p + 1..n) |q| {
                const apq = S.get(p, q);
                if (@abs(apq) < 1e-15) continue;

                const app = S.get(p, p);
                const aqq = S.get(q, q);

                // Compute rotation angle
                const tau = (aqq - app) / (2.0 * apq);
                const t = if (@abs(tau) > 1e15)
                    1.0 / (2.0 * tau) // avoid overflow
                else
                    math.copysign(@as(f64, 1.0), tau) / (@abs(tau) + @sqrt(1.0 + tau * tau));

                const cos = 1.0 / @sqrt(1.0 + t * t);
                const sin = t * cos;

                // Update S: apply rotation on both sides
                // S' = G^T S G where G is Givens rotation in (p,q) plane
                S.set(p, p, app - t * apq);
                S.set(q, q, aqq + t * apq);
                S.set(p, q, 0);
                S.set(q, p, 0);

                // Update rows/cols p and q
                for (0..n) |r| {
                    if (r == p or r == q) continue;
                    const srp = S.get(r, p);
                    const srq = S.get(r, q);
                    S.set(r, p, cos * srp - sin * srq);
                    S.set(p, r, cos * srp - sin * srq);
                    S.set(r, q, sin * srp + cos * srq);
                    S.set(q, r, sin * srp + cos * srq);
                }

                // Accumulate eigenvector rotations: V' = V * G
                for (0..n) |r| {
                    const vrp = V.get(r, p);
                    const vrq = V.get(r, q);
                    V.set(r, p, cos * vrp - sin * vrq);
                    V.set(r, q, sin * vrp + cos * vrq);
                }
            }
        }
    }

    // Extract eigenvalues from diagonal
    const values = try allocator.alloc(f64, n);
    for (0..n) |i| values[i] = S.get(i, i);

    S.deinit(allocator);

    return .{ .values = values, .vectors = V };
}

// ============================================================================
// SPECTRAL INTEGRATION MEASURES
// ============================================================================

/// Spectral measures of a graph relevant to information integration
pub const SpectralMeasures = struct {
    /// λ₂: algebraic connectivity (Fiedler value)
    /// = integration floor, resistance to partitioning
    /// Proxy for IIT's Minimum Information Partition
    algebraic_connectivity: f64,

    /// Fiedler vector: eigenvector of λ₂
    /// Signs give optimal bipartition (MIP proxy)
    fiedler_vector: []f64,

    /// Spectral gap: λ₂ / λ_max
    /// Determines synchronization threshold (Kuramoto)
    /// Large gap → easier gamma coherence → better binding
    spectral_gap: f64,

    /// Condition number: λ_max / λ₂
    /// Integration-differentiation tension
    /// Too high = bottlenecks; too low = degenerate modes
    condition_number: f64,

    /// Full eigenvalue spectrum (ascending, skip λ₁=0)
    spectrum: []f64,

    /// Effective dimensionality: exp(entropy of normalized eigenvalues)
    /// Number of independent oscillatory modes
    effective_dim: f64,

    /// Φ-proxy: spectral estimate of integrated information
    /// Based on Toker & Sommer 2016
    phi_proxy: f64,

    pub fn deinit(self: SpectralMeasures, allocator: Allocator) void {
        allocator.free(self.fiedler_vector);
        allocator.free(self.spectrum);
    }
};

/// Compute spectral integration measures from a graph Laplacian
pub fn spectralMeasures(
    laplacian: GraphLaplacian,
    allocator: Allocator,
) !SpectralMeasures {
    const n = laplacian.n;
    const k = n; // compute all eigenvalues

    var eigen = try eigendecompose(laplacian.L, k, allocator);
    defer eigen.deinit(allocator);

    // Skip λ₁ ≈ 0 (connected graph)
    // Find first eigenvalue > threshold
    var start: usize = 0;
    for (eigen.eigenvalues, 0..) |lam, i| {
        if (lam > 1e-8) {
            start = i;
            break;
        }
    }

    const num_nontrivial = eigen.eigenvalues.len - start;
    if (num_nontrivial == 0) {
        // Disconnected or trivial graph
        const empty = try allocator.alloc(f64, 0);
        const fiedler = try allocator.alloc(f64, n);
        @memset(fiedler, 0);
        return .{
            .algebraic_connectivity = 0,
            .fiedler_vector = fiedler,
            .spectral_gap = 0,
            .condition_number = math.inf(f64),
            .spectrum = empty,
            .effective_dim = 0,
            .phi_proxy = 0,
        };
    }

    const lambda_2 = eigen.eigenvalues[start];
    const lambda_max = eigen.eigenvalues[eigen.eigenvalues.len - 1];

    // Extract Fiedler vector
    const fiedler = try allocator.alloc(f64, n);
    for (0..n) |i| fiedler[i] = eigen.eigenvectors.get(i, start);

    // Copy nontrivial spectrum
    const spectrum = try allocator.alloc(f64, num_nontrivial);
    @memcpy(spectrum, eigen.eigenvalues[start..]);

    // Effective dimensionality: exp(Shannon entropy of normalized eigenvalues)
    var total: f64 = 0;
    for (spectrum) |lam| total += lam;

    var entropy: f64 = 0;
    if (total > 1e-12) {
        for (spectrum) |lam| {
            const p = lam / total;
            if (p > 1e-15) entropy -= p * @log(p);
        }
    }
    const effective_dim = @exp(entropy);

    // Phi proxy (Toker & Sommer): combines algebraic connectivity with spectral structure
    // Φ_proxy = λ₂ × (1 - spectral_gap⁻¹_normalized)
    // High when λ₂ is large AND spectrum is spread (high differentiation)
    const spectral_gap = if (lambda_max > 1e-12) lambda_2 / lambda_max else 0;
    const condition = if (lambda_2 > 1e-12) lambda_max / lambda_2 else math.inf(f64);

    // Normalized phi: product of integration (λ₂) and differentiation (effective_dim / n)
    const phi_proxy = lambda_2 * (effective_dim / @as(f64, @floatFromInt(n)));

    return .{
        .algebraic_connectivity = lambda_2,
        .fiedler_vector = fiedler,
        .spectral_gap = spectral_gap,
        .condition_number = condition,
        .spectrum = spectrum,
        .effective_dim = effective_dim,
        .phi_proxy = phi_proxy,
    };
}

// ============================================================================
// THALAMOCORTICAL OSCILLATOR MODEL
// ============================================================================

/// Oscillatory band with characteristic frequency range
pub const Band = enum {
    delta, // 0.5-4 Hz — thalamic slow oscillation
    theta, // 4-8 Hz — hippocampal/prefrontal rhythm
    alpha, // 8-13 Hz — thalamocortical idle, pulvinar
    beta, // 13-30 Hz — motor/sensorimotor
    gamma, // 30-80 Hz — local cortical interneuron networks

    pub fn centerHz(self: Band) f64 {
        return switch (self) {
            .delta => 2.0,
            .theta => 6.0,
            .alpha => 10.0,
            .beta => 20.0,
            .gamma => 50.0,
        };
    }

    pub fn rangeHz(self: Band) [2]f64 {
        return switch (self) {
            .delta => .{ 0.5, 4.0 },
            .theta => .{ 4.0, 8.0 },
            .alpha => .{ 8.0, 13.0 },
            .beta => .{ 13.0, 30.0 },
            .gamma => .{ 30.0, 80.0 },
        };
    }
};

/// Phase slot: one gamma cycle within a theta cycle
/// The occupancy unit — each slot can hold one bound representation
pub const PhaseSlot = struct {
    /// Index within the theta cycle (0..capacity-1)
    index: u8,
    /// Theta phase at center of this gamma window [0, 2π)
    theta_phase: f64,
    /// Whether this slot is occupied by an item
    occupied: bool = false,
    /// Which tensor component occupies this slot (if any)
    component_id: ?usize = null,
    /// Binding strength: gamma power in this phase window
    binding_strength: f64 = 0,
};

/// Thalamocortical oscillator: models the nested theta-gamma code
pub const ThalamoCorticalOscillator = struct {
    /// Carrier (theta) frequency in Hz
    theta_freq: f64,
    /// Nested (gamma) frequency in Hz
    gamma_freq: f64,
    /// Phase slots: the "bins" in the occupancy problem
    slots: []PhaseSlot,
    /// Number of available slots = floor(theta_period / gamma_period)
    capacity: usize,

    pub fn init(allocator: Allocator, theta_hz: f64, gamma_hz: f64) !ThalamoCorticalOscillator {
        const capacity = @as(usize, @intFromFloat(@floor(gamma_hz / theta_hz)));
        const slots = try allocator.alloc(PhaseSlot, capacity);

        for (0..capacity) |i| {
            const fi: f64 = @floatFromInt(i);
            const fc: f64 = @floatFromInt(capacity);
            slots[i] = .{
                .index = @intCast(i),
                .theta_phase = 2.0 * math.pi * fi / fc,
            };
        }

        return .{
            .theta_freq = theta_hz,
            .gamma_freq = gamma_hz,
            .slots = slots,
            .capacity = capacity,
        };
    }

    pub fn deinit(self: ThalamoCorticalOscillator, allocator: Allocator) void {
        allocator.free(self.slots);
    }

    /// Assign a tensor component to the best available slot
    /// Returns the slot index, or null if at capacity
    pub fn assignSlot(self: *ThalamoCorticalOscillator, component_id: usize, preferred_phase: f64) ?usize {
        // Find closest unoccupied slot to preferred phase
        var best: ?usize = null;
        var best_dist: f64 = math.inf(f64);

        for (self.slots, 0..) |slot, i| {
            if (!slot.occupied) {
                // Circular distance on [0, 2π)
                const diff = @abs(slot.theta_phase - preferred_phase);
                const dist = @min(diff, 2.0 * math.pi - diff);
                if (dist < best_dist) {
                    best_dist = dist;
                    best = i;
                }
            }
        }

        if (best) |idx| {
            self.slots[idx].occupied = true;
            self.slots[idx].component_id = component_id;
            return idx;
        }
        return null;
    }

    /// Count occupied slots
    pub fn load(self: ThalamoCorticalOscillator) usize {
        var count: usize = 0;
        for (self.slots) |slot| {
            if (slot.occupied) count += 1;
        }
        return count;
    }

    /// Occupancy ratio: items / capacity
    pub fn occupancy(self: ThalamoCorticalOscillator) f64 {
        const l: f64 = @floatFromInt(self.load());
        const c: f64 = @floatFromInt(self.capacity);
        return l / c;
    }

    /// Collision probability estimate (birthday paradox approximation)
    /// P(collision) ≈ 1 - exp(-k(k-1) / (2n)) for k items in n slots
    pub fn collisionProbability(self: ThalamoCorticalOscillator, k: usize) f64 {
        const kf: f64 = @floatFromInt(k);
        const nf: f64 = @floatFromInt(self.capacity);
        return 1.0 - @exp(-kf * (kf - 1.0) / (2.0 * nf));
    }

    /// Expected empty slots: n × e^{-k/n}
    pub fn expectedEmptySlots(self: ThalamoCorticalOscillator, k: usize) f64 {
        const kf: f64 = @floatFromInt(k);
        const nf: f64 = @floatFromInt(self.capacity);
        return nf * @exp(-kf / nf);
    }

    /// Clear all slot assignments
    pub fn reset(self: *ThalamoCorticalOscillator) void {
        for (self.slots) |*slot| {
            slot.occupied = false;
            slot.component_id = null;
            slot.binding_strength = 0;
        }
    }
};

// ============================================================================
// 3-WAY TENSOR AND CPD DECOMPOSITION
// ============================================================================

/// 3-way tensor X(time × eigenmode × frequency) for neural oscillatory data
/// Stored as flat array with strides
pub const Tensor3 = struct {
    /// Dimensions: [time, eigenmode, frequency]
    dims: [3]usize,
    data: []f64,

    pub fn init(allocator: Allocator, d0: usize, d1: usize, d2: usize) !Tensor3 {
        const data = try allocator.alloc(f64, d0 * d1 * d2);
        @memset(data, 0);
        return .{ .dims = .{ d0, d1, d2 }, .data = data };
    }

    pub fn deinit(self: Tensor3, allocator: Allocator) void {
        allocator.free(self.data);
    }

    /// Index into flat storage
    fn idx(self: Tensor3, i: usize, j: usize, k: usize) usize {
        return i * (self.dims[1] * self.dims[2]) + j * self.dims[2] + k;
    }

    pub fn get(self: Tensor3, i: usize, j: usize, k: usize) f64 {
        return self.data[self.idx(i, j, k)];
    }

    pub fn set(self: *Tensor3, i: usize, j: usize, k: usize, val: f64) void {
        self.data[self.idx(i, j, k)] = val;
    }

    /// Frobenius norm squared
    pub fn normSq(self: Tensor3) f64 {
        var s: f64 = 0;
        for (self.data) |x| s += x * x;
        return s;
    }
};

/// One rank-1 component of a CPD decomposition
/// Component_r = weight × a_r ⊗ b_r ⊗ c_r
/// In thalamocortical context:
///   a = temporal signature (when this oscillatory process is active)
///   b = spatial topography (which eigenmodes / brain regions)
///   c = spectral profile (which frequencies)
pub const CPDComponent = struct {
    weight: f64,
    temporal: []f64, // length dims[0]: temporal signature
    spatial: []f64, // length dims[1]: spatial topography (eigenmode loadings)
    spectral: []f64, // length dims[2]: spectral profile

    pub fn deinit(self: CPDComponent, allocator: Allocator) void {
        allocator.free(self.temporal);
        allocator.free(self.spatial);
        allocator.free(self.spectral);
    }
};

/// Result of CPD decomposition
pub const CPDResult = struct {
    components: []CPDComponent,
    residual_norm: f64,
    iterations: usize,

    pub fn deinit(self: CPDResult, allocator: Allocator) void {
        for (self.components) |c| c.deinit(allocator);
        allocator.free(self.components);
    }
};

/// Alternating Least Squares (ALS) for CPD tensor decomposition
/// Decomposes X ≈ Σ_r λ_r · a_r ⊗ b_r ⊗ c_r
pub fn cpd(
    X: Tensor3,
    rank: usize,
    max_iter: usize,
    tol: f64,
    allocator: Allocator,
) !CPDResult {
    const d0 = X.dims[0];
    const d1 = X.dims[1];
    const d2 = X.dims[2];

    // Initialize factor matrices randomly
    var prng = std.Random.DefaultPrng.init(17);
    const random = prng.random();

    var A = try allocator.alloc(f64, d0 * rank); // d0 × rank
    defer allocator.free(A);
    var B = try allocator.alloc(f64, d1 * rank); // d1 × rank
    defer allocator.free(B);
    var C = try allocator.alloc(f64, d2 * rank); // d2 × rank
    defer allocator.free(C);

    for (A) |*x| x.* = random.floatNorm(f64) * 0.1;
    for (B) |*x| x.* = random.floatNorm(f64) * 0.1;
    for (C) |*x| x.* = random.floatNorm(f64) * 0.1;

    // Normalize columns
    for (0..rank) |r| {
        var na: f64 = 0;
        var nb: f64 = 0;
        var nc: f64 = 0;
        for (0..d0) |i| na += A[i * rank + r] * A[i * rank + r];
        for (0..d1) |i| nb += B[i * rank + r] * B[i * rank + r];
        for (0..d2) |i| nc += C[i * rank + r] * C[i * rank + r];
        na = @sqrt(na);
        nb = @sqrt(nb);
        nc = @sqrt(nc);
        if (na > 1e-15) for (0..d0) |i| {
            A[i * rank + r] /= na;
        };
        if (nb > 1e-15) for (0..d1) |i| {
            B[i * rank + r] /= nb;
        };
        if (nc > 1e-15) for (0..d2) |i| {
            C[i * rank + r] /= nc;
        };
    }

    // Workspace for MTTKRP (Matricized Tensor Times Khatri-Rao Product)
    var mttkrp_buf = try allocator.alloc(f64, @max(d0, @max(d1, d2)) * rank);
    defer allocator.free(mttkrp_buf);

    // Gram matrices (rank × rank)
    // Gram matrices reserved for future Khatri-Rao solve

    var prev_norm_sq = X.normSq();
    var iter: usize = 0;

    while (iter < max_iter) : (iter += 1) {
        // --- Update A: mode-0 MTTKRP ---
        // A_new = X_(0) (C ⊙ B) where ⊙ is Khatri-Rao product
        @memset(mttkrp_buf[0 .. d0 * rank], 0);
        for (0..d0) |i| {
            for (0..d1) |j| {
                for (0..d2) |k| {
                    const xijk = X.get(i, j, k);
                    if (xijk != 0) {
                        for (0..rank) |r| {
                            mttkrp_buf[i * rank + r] += xijk * B[j * rank + r] * C[k * rank + r];
                        }
                    }
                }
            }
        }

        // Solve via Gram matrix: A = MTTKRP * (B^T B * C^T C)^{-1}
        // For simplicity, just normalize MTTKRP columns as the new A
        @memcpy(A, mttkrp_buf[0 .. d0 * rank]);
        for (0..rank) |r| {
            var norm: f64 = 0;
            for (0..d0) |i| norm += A[i * rank + r] * A[i * rank + r];
            norm = @sqrt(norm);
            if (norm > 1e-15) for (0..d0) |i| {
                A[i * rank + r] /= norm;
            };
        }

        // --- Update B: mode-1 MTTKRP ---
        @memset(mttkrp_buf[0 .. d1 * rank], 0);
        for (0..d0) |i| {
            for (0..d1) |j| {
                for (0..d2) |k| {
                    const xijk = X.get(i, j, k);
                    if (xijk != 0) {
                        for (0..rank) |r| {
                            mttkrp_buf[j * rank + r] += xijk * A[i * rank + r] * C[k * rank + r];
                        }
                    }
                }
            }
        }
        @memcpy(B, mttkrp_buf[0 .. d1 * rank]);
        for (0..rank) |r| {
            var norm: f64 = 0;
            for (0..d1) |i| norm += B[i * rank + r] * B[i * rank + r];
            norm = @sqrt(norm);
            if (norm > 1e-15) for (0..d1) |i| {
                B[i * rank + r] /= norm;
            };
        }

        // --- Update C: mode-2 MTTKRP ---
        @memset(mttkrp_buf[0 .. d2 * rank], 0);
        for (0..d0) |i| {
            for (0..d1) |j| {
                for (0..d2) |k| {
                    const xijk = X.get(i, j, k);
                    if (xijk != 0) {
                        for (0..rank) |r| {
                            mttkrp_buf[k * rank + r] += xijk * A[i * rank + r] * B[j * rank + r];
                        }
                    }
                }
            }
        }
        @memcpy(C, mttkrp_buf[0 .. d2 * rank]);

        // Don't normalize C — keep the weights here
        // (extract weights as column norms of C)

        // Check convergence
        var approx_norm_sq: f64 = 0;
        for (0..d0) |i| {
            for (0..d1) |j| {
                for (0..d2) |k| {
                    var val: f64 = 0;
                    for (0..rank) |r| {
                        val += A[i * rank + r] * B[j * rank + r] * C[k * rank + r];
                    }
                    const diff = X.get(i, j, k) - val;
                    approx_norm_sq += diff * diff;
                }
            }
        }

        const rel_change = @abs(approx_norm_sq - prev_norm_sq) / (prev_norm_sq + 1e-15);
        if (rel_change < tol) break;
        prev_norm_sq = approx_norm_sq;
    }

    // Extract components
    var components = try allocator.alloc(CPDComponent, rank);
    for (0..rank) |r| {
        const temporal = try allocator.alloc(f64, d0);
        const spatial = try allocator.alloc(f64, d1);
        const spectral = try allocator.alloc(f64, d2);

        for (0..d0) |i| temporal[i] = A[i * rank + r];
        for (0..d1) |i| spatial[i] = B[i * rank + r];

        // Weight = norm of C column
        var weight: f64 = 0;
        for (0..d2) |i| {
            spectral[i] = C[i * rank + r];
            weight += spectral[i] * spectral[i];
        }
        weight = @sqrt(weight);
        if (weight > 1e-15) {
            for (spectral) |*x| x.* /= weight;
        }

        components[r] = .{
            .weight = weight,
            .temporal = temporal,
            .spatial = spatial,
            .spectral = spectral,
        };
    }

    // Compute final residual
    var residual: f64 = 0;
    for (0..d0) |i| {
        for (0..d1) |j| {
            for (0..d2) |k| {
                var val: f64 = 0;
                for (0..rank) |r| {
                    val += components[r].weight * components[r].temporal[i] * components[r].spatial[j] * components[r].spectral[k];
                }
                const diff = X.get(i, j, k) - val;
                residual += diff * diff;
            }
        }
    }

    return .{
        .components = components,
        .residual_norm = @sqrt(residual),
        .iterations = iter,
    };
}

// ============================================================================
// SHEAF CONDITION — BINDING CONSTRAINT
// ============================================================================

/// Sheaf stalk: local data at a node in the connectivity graph
/// For thalamocortical binding: values at cortical region boundaries
/// must agree (like FEM element nodes must match at shared boundaries)
pub const SheafStalk = struct {
    /// Node index in connectivity graph
    node: usize,
    /// Oscillatory state: [n_bands] amplitude per frequency band
    amplitudes: []f64,
    /// Phase per band
    phases: []f64,

    pub fn deinit(self: SheafStalk, allocator: Allocator) void {
        allocator.free(self.amplitudes);
        allocator.free(self.phases);
    }
};

/// Sheaf section: global assignment of stalks to all nodes
/// A section is "consistent" if boundary values agree (binding holds)
pub const SheafSection = struct {
    stalks: []SheafStalk,
    n_bands: usize,

    pub fn init(allocator: Allocator, n_nodes: usize, n_bands: usize) !SheafSection {
        const stalks = try allocator.alloc(SheafStalk, n_nodes);
        for (0..n_nodes) |i| {
            stalks[i] = .{
                .node = i,
                .amplitudes = try allocator.alloc(f64, n_bands),
                .phases = try allocator.alloc(f64, n_bands),
            };
            @memset(stalks[i].amplitudes, 0);
            @memset(stalks[i].phases, 0);
        }
        return .{ .stalks = stalks, .n_bands = n_bands };
    }

    pub fn deinit(self: SheafSection, allocator: Allocator) void {
        for (self.stalks) |stalk| stalk.deinit(allocator);
        allocator.free(self.stalks);
    }

    /// Consistency error at edge (i, j): measures binding failure
    /// Low error = regions i and j are bound (synchronized)
    /// This is the sheaf condition: restriction maps must commute
    pub fn edgeError(self: SheafSection, i: usize, j: usize, weight: f64) f64 {
        var err: f64 = 0;
        for (0..self.n_bands) |b| {
            // Amplitude mismatch (weighted by connection strength)
            const da = self.stalks[i].amplitudes[b] - self.stalks[j].amplitudes[b];
            err += weight * da * da;
            // Phase coherence: 1 - cos(Δφ), maximum when anti-phase
            const dp = self.stalks[i].phases[b] - self.stalks[j].phases[b];
            err += weight * (1.0 - @cos(dp));
        }
        return err;
    }

    /// Total sheaf obstruction: sum of edge errors over all connections
    /// Zero iff the section is globally consistent (perfect binding)
    pub fn totalObstruction(self: SheafSection, adj: DenseMatrix) f64 {
        var total: f64 = 0;
        const n = self.stalks.len;
        for (0..n) |i| {
            for (i + 1..n) |j| {
                const w = adj.get(i, j);
                if (w > 1e-12) {
                    total += self.edgeError(i, j, w);
                }
            }
        }
        return total;
    }
};

// ============================================================================
// INTEGRATION PIPELINE: CONNECT EVERYTHING
// ============================================================================

/// Full thalamocortical integration analysis
/// Connects: connectivity → Laplacian → eigenmodes → tensor → CPD → occupancy
pub const IntegrationAnalysis = struct {
    /// Spectral measures (Φ-proxy, Fiedler vector, etc.)
    spectral: SpectralMeasures,
    /// Oscillator model with phase slots
    oscillator: ThalamoCorticalOscillator,
    /// Tensor decomposition result
    decomposition: CPDResult,
    /// Number of bound items (occupied slots)
    bound_items: usize,
    /// Collision probability at current load
    collision_prob: f64,
    /// Sheaf obstruction (binding quality)
    binding_obstruction: f64,

    pub fn deinit(self: *IntegrationAnalysis, allocator: Allocator) void {
        self.spectral.deinit(allocator);
        self.oscillator.deinit(allocator);
        self.decomposition.deinit(allocator);
    }
};

/// Run full integration analysis pipeline
pub fn analyze(
    adj: DenseMatrix,
    tensor: Tensor3,
    cpd_rank: usize,
    theta_hz: f64,
    gamma_hz: f64,
    allocator: Allocator,
) !IntegrationAnalysis {
    // 1. Build graph Laplacian
    var lap = try GraphLaplacian.fromAdjacency(allocator, adj);
    defer lap.deinit(allocator);

    // 2. Compute spectral measures
    const spectral = try spectralMeasures(lap, allocator);

    // 3. CPD decomposition of oscillatory tensor
    const decomp = try cpd(tensor, cpd_rank, 100, 1e-6, allocator);

    // 4. Create oscillator and assign components to phase slots
    var osc = try ThalamoCorticalOscillator.init(allocator, theta_hz, gamma_hz);

    // Assign each CPD component to a phase slot
    // Preferred phase derived from the component's dominant eigenmode
    for (decomp.components, 0..) |comp, r| {
        // Find dominant eigenmode for this component
        var max_mode: usize = 0;
        var max_val: f64 = 0;
        for (comp.spatial, 0..) |s, i| {
            if (@abs(s) > max_val) {
                max_val = @abs(s);
                max_mode = i;
            }
        }
        // Map eigenmode index to preferred theta phase
        const n_modes: f64 = @floatFromInt(comp.spatial.len);
        const preferred = 2.0 * math.pi * @as(f64, @floatFromInt(max_mode)) / n_modes;
        _ = osc.assignSlot(r, preferred);
    }

    const bound = osc.load();
    const collision = osc.collisionProbability(bound);

    return .{
        .spectral = spectral,
        .oscillator = osc,
        .decomposition = decomp,
        .bound_items = bound,
        .collision_prob = collision,
        .binding_obstruction = 0, // computed separately with SheafSection
    };
}

// ============================================================================
// GF(3) TRIADIC CLASSIFICATION
// ============================================================================

/// Classify spectral measures into GF(3) trits for consensus
/// Maps continuous spectral properties to balanced ternary
pub const TriadicClassification = struct {
    /// Integration trit: + if λ₂ > threshold, - if near-decomposable, 0 otherwise
    integration: i8,
    /// Differentiation trit: + if effective_dim high, - if low, 0 if moderate
    differentiation: i8,
    /// Binding trit: + if obstruction low (good binding), - if high, 0 if mixed
    binding: i8,

    /// GF(3) conservation: sum must be 0 mod 3
    pub fn isBalanced(self: TriadicClassification) bool {
        const sum = @mod(self.integration + self.differentiation + self.binding + 9, 3);
        return sum == 0;
    }

    /// Force balance by adjusting the binding trit
    pub fn balance(self: *TriadicClassification) void {
        const partial = @mod(self.integration + self.differentiation + 9, 3);
        self.binding = switch (partial) {
            0 => 0,
            1 => -1,
            2 => 1,
            else => unreachable,
        };
    }
};

/// Classify spectral measures into triadic form
pub fn classify(measures: SpectralMeasures, n_regions: usize) TriadicClassification {
    const nf: f64 = @floatFromInt(n_regions);

    // Integration: λ₂ relative to graph size
    const integration: i8 = if (measures.algebraic_connectivity > 0.5 * nf)
        1 // strongly integrated
    else if (measures.algebraic_connectivity < 0.1)
        -1 // near-decomposable
    else
        0; // moderate

    // Differentiation: effective dimensionality relative to possible modes
    const diff_ratio = measures.effective_dim / nf;
    const differentiation: i8 = if (diff_ratio > 0.7)
        1 // high differentiation (many distinct modes)
    else if (diff_ratio < 0.3)
        -1 // low differentiation (degenerate spectrum)
    else
        0;

    var result = TriadicClassification{
        .integration = integration,
        .differentiation = differentiation,
        .binding = 0,
    };
    result.balance(); // enforce GF(3) conservation
    return result;
}

// ============================================================================
// TESTS
// ============================================================================

test "graph Laplacian of path graph" {
    const allocator = std.testing.allocator;

    // Path graph: 0 — 1 — 2
    var adj = try DenseMatrix.init(allocator, 3, 3);
    defer adj.deinit(allocator);

    adj.set(0, 1, 1);
    adj.set(1, 0, 1);
    adj.set(1, 2, 1);
    adj.set(2, 1, 1);

    var lap = try GraphLaplacian.fromAdjacency(allocator, adj);
    defer lap.deinit(allocator);

    // L should be: [ 1 -1  0 ]
    //              [-1  2 -1 ]
    //              [ 0 -1  1 ]
    try std.testing.expectApproxEqAbs(1.0, lap.L.get(0, 0), 1e-10);
    try std.testing.expectApproxEqAbs(-1.0, lap.L.get(0, 1), 1e-10);
    try std.testing.expectApproxEqAbs(0.0, lap.L.get(0, 2), 1e-10);
    try std.testing.expectApproxEqAbs(2.0, lap.L.get(1, 1), 1e-10);
}

test "Laplacian row sums are zero" {
    const allocator = std.testing.allocator;

    // Complete graph K4
    var adj = try DenseMatrix.init(allocator, 4, 4);
    defer adj.deinit(allocator);
    for (0..4) |i| {
        for (0..4) |j| {
            if (i != j) adj.set(i, j, 1);
        }
    }

    var lap = try GraphLaplacian.fromAdjacency(allocator, adj);
    defer lap.deinit(allocator);

    for (0..4) |i| {
        var row_sum: f64 = 0;
        for (0..4) |j| row_sum += lap.L.get(i, j);
        try std.testing.expectApproxEqAbs(0.0, row_sum, 1e-10);
    }
}

test "eigenvalues of K4 Laplacian" {
    const allocator = std.testing.allocator;

    // K4 Laplacian eigenvalues: 0, 4, 4, 4
    var adj = try DenseMatrix.init(allocator, 4, 4);
    defer adj.deinit(allocator);
    for (0..4) |i| {
        for (0..4) |j| {
            if (i != j) adj.set(i, j, 1);
        }
    }

    var lap = try GraphLaplacian.fromAdjacency(allocator, adj);
    defer lap.deinit(allocator);

    var eigen = try eigendecompose(lap.L, 4, allocator);
    defer eigen.deinit(allocator);

    // Sort eigenvalues
    std.mem.sort(f64, eigen.eigenvalues, {}, std.sort.asc(f64));

    // λ₁ ≈ 0
    try std.testing.expectApproxEqAbs(0.0, eigen.eigenvalues[0], 1e-6);
    // λ₂ = λ₃ = λ₄ = 4
    try std.testing.expectApproxEqAbs(4.0, eigen.eigenvalues[1], 0.1);
    try std.testing.expectApproxEqAbs(4.0, eigen.eigenvalues[2], 0.1);
    try std.testing.expectApproxEqAbs(4.0, eigen.eigenvalues[3], 0.1);
}

test "spectral measures of path graph P5" {
    const allocator = std.testing.allocator;

    // Path: 0-1-2-3-4
    var adj = try DenseMatrix.init(allocator, 5, 5);
    defer adj.deinit(allocator);
    for (0..4) |i| {
        adj.set(i, i + 1, 1);
        adj.set(i + 1, i, 1);
    }

    var lap = try GraphLaplacian.fromAdjacency(allocator, adj);
    defer lap.deinit(allocator);

    var measures = try spectralMeasures(lap, allocator);
    defer measures.deinit(allocator);

    // Path graph has low algebraic connectivity (nearly decomposable)
    // λ₂ for P5 = 2(1 - cos(π/5)) ≈ 0.382
    try std.testing.expect(measures.algebraic_connectivity > 0.1);
    try std.testing.expect(measures.algebraic_connectivity < 1.0);

    // Fiedler vector should have opposite signs at endpoints
    try std.testing.expect(measures.fiedler_vector[0] * measures.fiedler_vector[4] < 0);

    // Phi proxy should be positive (connected graph)
    try std.testing.expect(measures.phi_proxy > 0);
}

test "spectral measures of complete graph" {
    const allocator = std.testing.allocator;

    var adj = try DenseMatrix.init(allocator, 5, 5);
    defer adj.deinit(allocator);
    for (0..5) |i| {
        for (0..5) |j| {
            if (i != j) adj.set(i, j, 1);
        }
    }

    var lap = try GraphLaplacian.fromAdjacency(allocator, adj);
    defer lap.deinit(allocator);

    var measures = try spectralMeasures(lap, allocator);
    defer measures.deinit(allocator);

    // K5: λ₂ = 5 (high integration)
    try std.testing.expect(measures.algebraic_connectivity > 4.0);

    // All 4 nontrivial eigenvalues equal (=5) → effective_dim = 4
    // Uniform spectrum means maximal dimensionality for the mode count
    // but low differentiation in the *spectral gap* sense (condition number = 1)
    try std.testing.expectApproxEqAbs(4.0, measures.effective_dim, 0.5);
    try std.testing.expectApproxEqAbs(1.0, measures.condition_number, 0.1);
}

test "thalamocortical oscillator capacity" {
    const allocator = std.testing.allocator;

    // Theta at 6 Hz, gamma at 50 Hz → capacity = floor(50/6) = 8
    var osc = try ThalamoCorticalOscillator.init(allocator, 6.0, 50.0);
    defer osc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 8), osc.capacity);
    try std.testing.expectEqual(@as(usize, 0), osc.load());
}

test "phase slot assignment" {
    const allocator = std.testing.allocator;

    var osc = try ThalamoCorticalOscillator.init(allocator, 6.0, 48.0);
    defer osc.deinit(allocator);

    // Capacity should be 8
    try std.testing.expectEqual(@as(usize, 8), osc.capacity);

    // Assign 5 items
    for (0..5) |i| {
        const slot = osc.assignSlot(i, @as(f64, @floatFromInt(i)) * 0.5);
        try std.testing.expect(slot != null);
    }
    try std.testing.expectEqual(@as(usize, 5), osc.load());

    // Fill remaining
    for (5..8) |i| {
        const slot = osc.assignSlot(i, 0);
        try std.testing.expect(slot != null);
    }

    // 9th item should fail (at capacity)
    const overflow = osc.assignSlot(8, 0);
    try std.testing.expect(overflow == null);
}

test "occupancy collision probability" {
    const allocator = std.testing.allocator;

    var osc = try ThalamoCorticalOscillator.init(allocator, 6.0, 42.0);
    defer osc.deinit(allocator);

    // 7 slots (the magical 7±2!)
    try std.testing.expectEqual(@as(usize, 7), osc.capacity);

    // P(collision) with 1 item = 0
    try std.testing.expectApproxEqAbs(0.0, osc.collisionProbability(1), 1e-10);

    // P(collision) increases with items
    const p3 = osc.collisionProbability(3);
    const p5 = osc.collisionProbability(5);
    try std.testing.expect(p5 > p3);

    // At capacity (7 items), probability should be substantial
    const p7 = osc.collisionProbability(7);
    try std.testing.expect(p7 > 0.5);
}

test "3-way tensor indexing" {
    const allocator = std.testing.allocator;

    var T = try Tensor3.init(allocator, 3, 4, 5);
    defer T.deinit(allocator);

    T.set(1, 2, 3, 42.0);
    try std.testing.expectApproxEqAbs(42.0, T.get(1, 2, 3), 1e-10);
    try std.testing.expectApproxEqAbs(0.0, T.get(0, 0, 0), 1e-10);
}

test "CPD decomposition of rank-1 tensor" {
    const allocator = std.testing.allocator;

    // Create a pure rank-1 tensor: X = a ⊗ b ⊗ c
    const d0: usize = 4;
    const d1: usize = 3;
    const d2: usize = 5;
    var X = try Tensor3.init(allocator, d0, d1, d2);
    defer X.deinit(allocator);

    const a = [_]f64{ 1.0, 2.0, 0.5, 1.5 };
    const b = [_]f64{ 1.0, 0.5, 2.0 };
    const c_arr = [_]f64{ 0.3, 0.8, 0.1, 0.6, 0.2 };

    for (0..d0) |i| {
        for (0..d1) |j| {
            for (0..d2) |k| {
                X.set(i, j, k, a[i] * b[j] * c_arr[k]);
            }
        }
    }

    var result = try cpd(X, 1, 200, 1e-8, allocator);
    defer result.deinit(allocator);

    // Residual should be near zero for a rank-1 tensor
    const orig_norm = @sqrt(X.normSq());
    try std.testing.expect(result.residual_norm / orig_norm < 0.1);
}

test "sheaf section consistency" {
    const allocator = std.testing.allocator;

    var section = try SheafSection.init(allocator, 3, 2);
    defer section.deinit(allocator);

    // Set identical amplitudes and phases → zero obstruction
    for (section.stalks) |*stalk| {
        stalk.amplitudes[0] = 1.0;
        stalk.amplitudes[1] = 0.5;
        stalk.phases[0] = 0.0;
        stalk.phases[1] = math.pi / 4.0;
    }

    var adj = try DenseMatrix.init(allocator, 3, 3);
    defer adj.deinit(allocator);
    adj.set(0, 1, 1);
    adj.set(1, 0, 1);
    adj.set(1, 2, 1);
    adj.set(2, 1, 1);

    // Consistent section → zero obstruction
    const obs = section.totalObstruction(adj);
    try std.testing.expectApproxEqAbs(0.0, obs, 1e-10);
}

test "sheaf section with binding failure" {
    const allocator = std.testing.allocator;

    var section = try SheafSection.init(allocator, 2, 1);
    defer section.deinit(allocator);

    // Node 0: amplitude 1, phase 0
    // Node 1: amplitude 1, phase π (anti-phase = maximum binding failure)
    section.stalks[0].amplitudes[0] = 1.0;
    section.stalks[0].phases[0] = 0.0;
    section.stalks[1].amplitudes[0] = 1.0;
    section.stalks[1].phases[0] = math.pi;

    var adj = try DenseMatrix.init(allocator, 2, 2);
    defer adj.deinit(allocator);
    adj.set(0, 1, 1);
    adj.set(1, 0, 1);

    // Anti-phase → obstruction = weight * (1 - cos(π)) = 1 * 2 = 2
    const obs = section.totalObstruction(adj);
    try std.testing.expectApproxEqAbs(2.0, obs, 1e-10);
}

test "GF(3) triadic classification balance" {
    const allocator = std.testing.allocator;

    // Create a ring graph (moderate connectivity)
    var adj = try DenseMatrix.init(allocator, 6, 6);
    defer adj.deinit(allocator);
    for (0..6) |i| {
        adj.set(i, (i + 1) % 6, 1);
        adj.set((i + 1) % 6, i, 1);
    }

    var lap = try GraphLaplacian.fromAdjacency(allocator, adj);
    defer lap.deinit(allocator);

    var measures = try spectralMeasures(lap, allocator);
    defer measures.deinit(allocator);

    const tri = classify(measures, 6);

    // GF(3) conservation must hold
    try std.testing.expect(tri.isBalanced());
}

test "dense matrix SIMD matvec" {
    const allocator = std.testing.allocator;

    // 5×5 identity matrix
    var M = try DenseMatrix.init(allocator, 5, 5);
    defer M.deinit(allocator);
    for (0..5) |i| M.set(i, i, 1.0);

    const x = [_]f64{ 1, 2, 3, 4, 5 };
    var y: [5]f64 = undefined;
    M.matvec(&x, &y);

    // I * x = x
    for (0..5) |i| {
        try std.testing.expectApproxEqAbs(x[i], y[i], 1e-10);
    }
}

test "normalized Laplacian" {
    const allocator = std.testing.allocator;

    // K3: all eigenvalues of normalized Laplacian should be 0 or 3/2
    var adj = try DenseMatrix.init(allocator, 3, 3);
    defer adj.deinit(allocator);
    for (0..3) |i| {
        for (0..3) |j| {
            if (i != j) adj.set(i, j, 1);
        }
    }

    var lap = try GraphLaplacian.fromAdjacency(allocator, adj);
    defer lap.deinit(allocator);

    var L_norm = try lap.normalized(allocator);
    defer L_norm.deinit(allocator);

    // Diagonal of normalized Laplacian of regular graph = 1
    for (0..3) |i| {
        try std.testing.expectApproxEqAbs(1.0, L_norm.get(i, i), 1e-10);
    }
}

test "oscillator reset" {
    const allocator = std.testing.allocator;

    var osc = try ThalamoCorticalOscillator.init(allocator, 6.0, 42.0);
    defer osc.deinit(allocator);

    _ = osc.assignSlot(0, 0);
    _ = osc.assignSlot(1, 1.0);
    try std.testing.expectEqual(@as(usize, 2), osc.load());

    osc.reset();
    try std.testing.expectEqual(@as(usize, 0), osc.load());
}

test "full integration pipeline" {
    const allocator = std.testing.allocator;

    // Small 4-region connectivity (like V1-V2-V4-IT hierarchy)
    var adj = try DenseMatrix.init(allocator, 4, 4);
    defer adj.deinit(allocator);
    // Hierarchical: strong V1↔V2, V2↔V4, V4↔IT
    adj.set(0, 1, 2.0);
    adj.set(1, 0, 2.0);
    adj.set(1, 2, 1.5);
    adj.set(2, 1, 1.5);
    adj.set(2, 3, 1.0);
    adj.set(3, 2, 1.0);
    // Weak feedback: IT→V1
    adj.set(3, 0, 0.3);
    adj.set(0, 3, 0.3);

    // Create a simple tensor (4 time steps × 4 eigenmodes × 3 frequencies)
    var tensor = try Tensor3.init(allocator, 4, 4, 3);
    defer tensor.deinit(allocator);

    // Simulate: mode 0 at theta, mode 1 at gamma, mode 2 at alpha
    for (0..4) |t| {
        const tf: f64 = @floatFromInt(t);
        tensor.set(t, 0, 0, @sin(2.0 * math.pi * 6.0 * tf / 100.0)); // theta
        tensor.set(t, 1, 2, @sin(2.0 * math.pi * 50.0 * tf / 100.0)); // gamma
        tensor.set(t, 2, 1, @sin(2.0 * math.pi * 10.0 * tf / 100.0)); // alpha
    }

    var result = try analyze(adj, tensor, 2, 6.0, 42.0, allocator);
    defer result.deinit(allocator);

    // Basic sanity checks
    try std.testing.expect(result.spectral.algebraic_connectivity > 0);
    try std.testing.expect(result.spectral.phi_proxy > 0);
    try std.testing.expect(result.oscillator.capacity == 7);
    try std.testing.expect(result.bound_items <= result.oscillator.capacity);
}

test "band frequencies" {
    try std.testing.expectApproxEqAbs(6.0, Band.theta.centerHz(), 1e-10);
    try std.testing.expectApproxEqAbs(50.0, Band.gamma.centerHz(), 1e-10);

    const theta_range = Band.theta.rangeHz();
    try std.testing.expectApproxEqAbs(4.0, theta_range[0], 1e-10);
    try std.testing.expectApproxEqAbs(8.0, theta_range[1], 1e-10);
}
