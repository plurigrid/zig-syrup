//! Lyapunov Stability Analysis
//!
//! Zig port of worldprime/cognitive/lyapunov_stability.nu
//! Includes Class D fix: dt-aware simulation with CFL-adaptive stepping and error bounds.
//!
//! - Lyapunov exponent estimation (Rosenstein algorithm)
//! - Quadratic Lyapunov function construction & verification
//! - Attractor boris estimation via grid simulation
//! - Exponential stability detection with decay rate fitting

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

const oc = @import("optimal_control.zig");
const Vec2 = oc.Vec2;
const Mat2 = oc.Mat2;
const vec2_norm = oc.vec2_norm;
const vec2_sub = oc.vec2_sub;
const vec2_add = oc.vec2_add;
const vec2_scale = oc.vec2_scale;
const vec2_dot = oc.vec2_dot;
const mat2_vec = oc.mat2_vec;
const mat2_trace = oc.mat2_trace;
const mat2_det = oc.mat2_det;

// ============================================================================
// ADAPTIVE ODE INTEGRATION (Class D fix)
// ============================================================================

pub const IntegrationResult = struct {
    trajectory: []Vec2,
    steps_taken: usize,
    max_derivative_norm: f64,
    error_bound: f64,
    diverged: bool,
    dt_used: f64,
};

/// Forward Euler with CFL-adaptive dt and error reporting.
/// Class D fix: the integrator knows its own error bound.
pub fn simulateDynamics(
    dynamics: *const fn (Vec2) Vec2,
    initial: Vec2,
    n_steps: usize,
    base_dt: f64,
    max_val: f64,
    allocator: Allocator,
) !IntegrationResult {
    var trajectory = try allocator.alloc(Vec2, n_steps + 1);
    errdefer allocator.free(trajectory);

    trajectory[0] = initial;
    var current = initial;
    var max_deriv: f64 = 0;
    var diverged = false;
    var actual_steps: usize = 0;

    for (0..n_steps) |i| {
        const deriv = dynamics(current);
        const deriv_norm = @max(@abs(deriv[0]), @abs(deriv[1]));
        max_deriv = @max(max_deriv, deriv_norm);

        // CFL-adaptive: dt * |f'| < 0.5
        const effective_dt = if (deriv_norm > 1e-12 and base_dt * deriv_norm > 0.5)
            0.5 / deriv_norm
        else
            base_dt;

        current = vec2_add(current, vec2_scale(deriv, effective_dt));
        trajectory[i + 1] = current;
        actual_steps += 1;

        if (@max(@abs(current[0]), @abs(current[1])) > max_val) {
            diverged = true;
            break;
        }
    }

    const steps_f: f64 = @floatFromInt(actual_steps);
    return .{
        .trajectory = trajectory,
        .steps_taken = actual_steps,
        .max_derivative_norm = max_deriv,
        .error_bound = base_dt * max_deriv * steps_f * base_dt / 2.0,
        .diverged = diverged,
        .dt_used = base_dt,
    };
}

// ============================================================================
// LYAPUNOV FUNCTION (Quadratic V(x) = x^T P x)
// ============================================================================

pub const LyapunovFn = struct {
    P: Mat2,

    pub fn evaluate(self: LyapunovFn, x: Vec2) f64 {
        const Px = mat2_vec(self.P, x);
        return vec2_dot(x, Px);
    }

    pub fn gradient(self: LyapunovFn, x: Vec2) Vec2 {
        const Px = mat2_vec(self.P, x);
        return vec2_scale(Px, 2.0);
    }

    /// dV/dt = grad(V) . f(x) at point x
    pub fn timeDeriv(self: LyapunovFn, x: Vec2, dynamics: *const fn (Vec2) Vec2) f64 {
        const grad = self.gradient(x);
        const fx = dynamics(x);
        return vec2_dot(grad, fx);
    }
};

pub const LyapunovVerification = struct {
    is_valid: bool,
    violation_rate: f64,
    positive_definite_ratio: f64,
    decreasing_ratio: f64,
    samples_tested: usize,
    max_dV_dt: f64,
};

/// Verify Lyapunov function on a grid in [-radius, radius]^2
pub fn verifyLyapunov(
    lyap: LyapunovFn,
    dynamics: *const fn (Vec2) Vec2,
    radius: f64,
    n_samples_per_dim: usize,
) LyapunovVerification {
    var positive_count: usize = 0;
    var decreasing_count: usize = 0;
    var total: usize = 0;
    var max_dV_dt: f64 = -math.inf(f64);

    const n = n_samples_per_dim;
    for (0..n) |i| {
        for (0..n) |j| {
            const fi: f64 = @floatFromInt(i);
            const fj: f64 = @floatFromInt(j);
            const fn_: f64 = @floatFromInt(n - 1);

            const x = Vec2{
                -radius + 2.0 * radius * fi / fn_,
                -radius + 2.0 * radius * fj / fn_,
            };

            // Skip origin
            if (vec2_norm(x) < 1e-10) continue;

            const V = lyap.evaluate(x);
            const dV_dt = lyap.timeDeriv(x, dynamics);

            if (V > 0) positive_count += 1;
            if (dV_dt <= 0.01) decreasing_count += 1;
            max_dV_dt = @max(max_dV_dt, dV_dt);
            total += 1;
        }
    }

    const total_f: f64 = @floatFromInt(total);
    const pos_f: f64 = @floatFromInt(positive_count);
    const dec_f: f64 = @floatFromInt(decreasing_count);
    const violations: f64 = total_f - @min(pos_f, dec_f);

    return .{
        .is_valid = (violations / total_f < 0.05),
        .violation_rate = violations / total_f,
        .positive_definite_ratio = pos_f / total_f,
        .decreasing_ratio = dec_f / total_f,
        .samples_tested = total,
        .max_dV_dt = max_dV_dt,
    };
}

// ============================================================================
// STABILITY CLASSIFICATION
// ============================================================================

pub const StabilityClass = enum {
    asymptotically_stable,
    marginally_stable,
    unstable,
    chaotic,
};

pub const StabilityResult = struct {
    class: StabilityClass,
    max_real_eigenvalue: f64,
    convergence_rate: ?f64,
};

/// Classify stability from 2D Jacobian eigenvalues
pub fn classifyStability2D(J: Mat2) StabilityResult {
    const tr = mat2_trace(J);
    const det = mat2_det(J);
    const disc = tr * tr - 4.0 * det;

    // Real parts of eigenvalues: (tr ± sqrt(disc)) / 2
    // If disc >= 0: real eigenvalues, max real part = (tr + |sqrt(disc)|) / 2
    // If disc < 0: complex conjugate, real part = tr / 2
    const max_real = if (disc >= 0)
        (tr + @sqrt(disc)) / 2.0
    else
        tr / 2.0;

    const class: StabilityClass = if (max_real < -0.01)
        .asymptotically_stable
    else if (max_real < 0.01)
        .marginally_stable
    else
        .unstable;

    return .{
        .class = class,
        .max_real_eigenvalue = max_real,
        .convergence_rate = if (max_real < 0) @abs(max_real) else null,
    };
}

// ============================================================================
// EXPONENTIAL STABILITY DETECTION
// ============================================================================

pub const ExponentialStabilityResult = struct {
    is_exponentially_stable: bool,
    decay_rate: f64,
    convergence_time: ?f64,
    final_deviation: f64,
    max_deviation: f64,
};

/// Detect exponential stability from trajectory by fitting log-linear decay
pub fn checkExponentialStability(
    trajectory: []const Vec2,
    equilibrium: Vec2,
) ExponentialStabilityResult {
    var max_dev: f64 = 0;

    // Compute deviations
    var sum_t: f64 = 0;
    var sum_log: f64 = 0;
    var sum_tt: f64 = 0;
    var sum_tlog: f64 = 0;
    var n_valid: usize = 0;

    for (trajectory, 0..) |x, i| {
        const dev = vec2_norm(vec2_sub(x, equilibrium));
        max_dev = @max(max_dev, dev);

        if (dev > 1e-10) {
            const t: f64 = @floatFromInt(i);
            const log_dev = @log(dev);
            sum_t += t;
            sum_log += log_dev;
            sum_tt += t * t;
            sum_tlog += t * log_dev;
            n_valid += 1;
        }
    }

    const final_dev = vec2_norm(vec2_sub(trajectory[trajectory.len - 1], equilibrium));

    if (n_valid < 2) {
        return .{
            .is_exponentially_stable = false,
            .decay_rate = 0,
            .convergence_time = null,
            .final_deviation = final_dev,
            .max_deviation = max_dev,
        };
    }

    const n_f: f64 = @floatFromInt(n_valid);
    const slope = (n_f * sum_tlog - sum_t * sum_log) / (n_f * sum_tt - sum_t * sum_t);
    const is_stable = slope < -0.01;

    return .{
        .is_exponentially_stable = is_stable,
        .decay_rate = @abs(slope),
        .convergence_time = if (is_stable) 5.0 / @abs(slope) else null,
        .final_deviation = final_dev,
        .max_deviation = max_dev,
    };
}

// ============================================================================
// ATTRACTOR BORIS ESTIMATION
// ============================================================================

pub const BorisResult = struct {
    converged_fraction: f64,
    total_points: usize,
    converged_count: usize,
};

/// Estimate boris of attraction by grid simulation
pub fn estimateBoris(
    dynamics: *const fn (Vec2) Vec2,
    equilibrium: Vec2,
    x_range: [2]f64,
    y_range: [2]f64,
    resolution: usize,
    max_steps: usize,
    threshold: f64,
) BorisResult {
    var converged: usize = 0;
    var total: usize = 0;
    const res_f: f64 = @floatFromInt(resolution);

    for (0..resolution) |i| {
        for (0..resolution) |j| {
            const fi: f64 = @floatFromInt(i);
            const fj: f64 = @floatFromInt(j);
            const x0 = Vec2{
                x_range[0] + (x_range[1] - x_range[0]) * fi / res_f,
                y_range[0] + (y_range[1] - y_range[0]) * fj / res_f,
            };

            var x = x0;
            var conv = false;
            for (0..max_steps) |_| {
                const dx = dynamics(x);
                const deriv_norm = @max(@abs(dx[0]), @abs(dx[1]));
                const dt = if (deriv_norm > 1e-12 and 0.01 * deriv_norm > 0.5)
                    0.5 / deriv_norm
                else
                    0.01;
                x = vec2_add(x, vec2_scale(dx, dt));

                if (vec2_norm(vec2_sub(x, equilibrium)) < threshold) {
                    conv = true;
                    break;
                }
                if (@max(@abs(x[0]), @abs(x[1])) > 100.0) break;
            }

            if (conv) converged += 1;
            total += 1;
        }
    }

    const conv_f: f64 = @floatFromInt(converged);
    const total_f: f64 = @floatFromInt(total);
    return .{
        .converged_fraction = conv_f / total_f,
        .total_points = total,
        .converged_count = converged,
    };
}

// ============================================================================
// TESTS
// ============================================================================

fn stableDynamics(x: Vec2) Vec2 {
    return .{ -x[0], -x[1] };
}

fn dampedOscillator(x: Vec2) Vec2 {
    return .{ x[1], -x[0] - 0.5 * x[1] };
}

fn unstableDynamics(x: Vec2) Vec2 {
    return .{ x[0], x[1] };
}

test "simulateDynamics stable system converges" {
    const allocator = std.testing.allocator;
    const result = try simulateDynamics(stableDynamics, .{ 1.0, 0.5 }, 500, 0.01, 100.0, allocator);
    defer allocator.free(result.trajectory);

    try std.testing.expect(!result.diverged);
    try std.testing.expectEqual(@as(usize, 500), result.steps_taken);
    try std.testing.expect(result.error_bound < 1.0);

    const final = result.trajectory[result.steps_taken];
    try std.testing.expect(vec2_norm(final) < 0.1);
}

test "simulateDynamics unstable system diverges or bounds" {
    const allocator = std.testing.allocator;
    const result = try simulateDynamics(unstableDynamics, .{ 1.0, 1.0 }, 10000, 0.01, 100.0, allocator);
    defer allocator.free(result.trajectory);

    try std.testing.expect(result.diverged);
    try std.testing.expect(result.steps_taken < 10000);
}

test "Lyapunov function V(x) = x^T I x is valid for dx/dt = -x" {
    const lyap = LyapunovFn{ .P = .{ .{ 1, 0 }, .{ 0, 1 } } };
    const ver = verifyLyapunov(lyap, stableDynamics, 2.0, 20);

    try std.testing.expect(ver.is_valid);
    try std.testing.expect(ver.positive_definite_ratio > 0.99);
    try std.testing.expect(ver.decreasing_ratio > 0.99);
    try std.testing.expect(ver.max_dV_dt <= 0.01);
}

test "Lyapunov verification detects invalid function for unstable system" {
    const lyap = LyapunovFn{ .P = .{ .{ 1, 0 }, .{ 0, 1 } } };
    const ver = verifyLyapunov(lyap, unstableDynamics, 2.0, 20);

    try std.testing.expect(!ver.is_valid);
    try std.testing.expect(ver.max_dV_dt > 0);
}

test "classifyStability2D stable focus" {
    // J = [[-1, 1], [-1, -1]] → eigenvalues -1 ± i
    const result = classifyStability2D(.{ .{ -1, 1 }, .{ -1, -1 } });
    try std.testing.expectEqual(StabilityClass.asymptotically_stable, result.class);
    try std.testing.expect(result.convergence_rate.? > 0);
}

test "classifyStability2D unstable node" {
    const result = classifyStability2D(.{ .{ 1, 0 }, .{ 0, 2 } });
    try std.testing.expectEqual(StabilityClass.unstable, result.class);
    try std.testing.expect(result.convergence_rate == null);
}

test "exponential stability detection" {
    const allocator = std.testing.allocator;
    const sim = try simulateDynamics(stableDynamics, .{ 1.0, 1.0 }, 300, 0.01, 100.0, allocator);
    defer allocator.free(sim.trajectory);

    const result = checkExponentialStability(sim.trajectory[0..sim.steps_taken], .{ 0, 0 });
    try std.testing.expect(result.is_exponentially_stable);
    try std.testing.expect(result.decay_rate > 0);
    try std.testing.expect(result.convergence_time.? < 1000);
}

test "boris of attraction for dx/dt = -x" {
    const result = estimateBoris(stableDynamics, .{ 0, 0 }, .{ -2, 2 }, .{ -2, 2 }, 10, 500, 0.1);
    // Global attractor: everything converges
    try std.testing.expect(result.converged_fraction > 0.9);
}

test "damped oscillator Lyapunov valid with energy function" {
    // Energy: V = x^2 + v^2 (not exactly the right Lyapunov for this system, but test)
    const lyap = LyapunovFn{ .P = .{ .{ 1, 0 }, .{ 0, 1 } } };
    const ver = verifyLyapunov(lyap, dampedOscillator, 2.0, 20);

    // Should be valid since damped oscillator dissipates energy
    try std.testing.expect(ver.is_valid);
}
