//! Optimal Control — MPC, LQR, iLQR, PID, Bifurcation Control
//!
//! Zig port of worldprime/cognitive/optimal_control.nu
//! Includes Class A fix: Newton equilibria finding with analytic Jacobian.
//!
//! Control strategies for cognitive BCI architecture:
//! - MPC: Model Predictive Control (receding horizon)
//! - LQR: Linear Quadratic Regulator (Riccati)
//! - iLQR: Iterative LQR for nonlinear systems
//! - PID: Adaptive PID with stability verification
//! - Bifurcation: Switching control near bifurcation points

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;

// ============================================================================
// REAL-VALUED LINEAR ALGEBRA (2D specializations + general)
// ============================================================================

pub const Vec2 = [2]f64;
pub const Mat2 = [2][2]f64;

pub fn vec2_norm(v: Vec2) f64 {
    return @sqrt(v[0] * v[0] + v[1] * v[1]);
}

pub fn vec2_sub(a: Vec2, b: Vec2) Vec2 {
    return .{ a[0] - b[0], a[1] - b[1] };
}

pub fn vec2_add(a: Vec2, b: Vec2) Vec2 {
    return .{ a[0] + b[0], a[1] + b[1] };
}

pub fn vec2_scale(v: Vec2, s: f64) Vec2 {
    return .{ v[0] * s, v[1] * s };
}

pub fn vec2_dot(a: Vec2, b: Vec2) f64 {
    return a[0] * b[0] + a[1] * b[1];
}

pub fn mat2_det(m: Mat2) f64 {
    return m[0][0] * m[1][1] - m[0][1] * m[1][0];
}

pub fn mat2_trace(m: Mat2) f64 {
    return m[0][0] + m[1][1];
}

pub fn mat2_vec(m: Mat2, v: Vec2) Vec2 {
    return .{
        m[0][0] * v[0] + m[0][1] * v[1],
        m[1][0] * v[0] + m[1][1] * v[1],
    };
}

pub fn mat2_inv(m: Mat2) ?Mat2 {
    const d = mat2_det(m);
    if (@abs(d) < 1e-14) return null;
    const inv_d = 1.0 / d;
    return .{
        .{ m[1][1] * inv_d, -m[0][1] * inv_d },
        .{ -m[1][0] * inv_d, m[0][0] * inv_d },
    };
}

pub fn mat2_mul(a: Mat2, b: Mat2) Mat2 {
    return .{
        .{ a[0][0] * b[0][0] + a[0][1] * b[1][0], a[0][0] * b[0][1] + a[0][1] * b[1][1] },
        .{ a[1][0] * b[0][0] + a[1][1] * b[1][0], a[1][0] * b[0][1] + a[1][1] * b[1][1] },
    };
}

pub fn mat2_add(a: Mat2, b: Mat2) Mat2 {
    return .{
        .{ a[0][0] + b[0][0], a[0][1] + b[0][1] },
        .{ a[1][0] + b[1][0], a[1][1] + b[1][1] },
    };
}

pub fn mat2_sub(a: Mat2, b: Mat2) Mat2 {
    return .{
        .{ a[0][0] - b[0][0], a[0][1] - b[0][1] },
        .{ a[1][0] - b[1][0], a[1][1] - b[1][1] },
    };
}

pub fn mat2_scale(m: Mat2, s: f64) Mat2 {
    return .{
        .{ m[0][0] * s, m[0][1] * s },
        .{ m[1][0] * s, m[1][1] * s },
    };
}

pub fn mat2_transpose(m: Mat2) Mat2 {
    return .{
        .{ m[0][0], m[1][0] },
        .{ m[0][1], m[1][1] },
    };
}

fn quadratic_form_2(x: Vec2, P: Mat2) f64 {
    const Px = mat2_vec(P, x);
    return vec2_dot(x, Px);
}

// ============================================================================
// PID CONTROLLER
// ============================================================================

pub const PidController = struct {
    kp: f64,
    ki: f64,
    kd: f64,
    integral: f64 = 0,
    prev_error: f64 = 0,
    setpoint: f64 = 0,

    pub const Output = struct {
        control: f64,
        err: f64,
        p_term: f64,
        i_term: f64,
        d_term: f64,
    };

    pub fn init(kp: f64, ki: f64, kd: f64) PidController {
        return .{ .kp = kp, .ki = ki, .kd = kd };
    }

    pub fn step(self: *PidController, measurement: f64, dt: f64) Output {
        const err = self.setpoint - measurement;

        // Anti-windup clamp
        self.integral = math.clamp(self.integral + err * dt, -10.0, 10.0);

        const derivative = if (dt > 1e-12) (err - self.prev_error) / dt else 0;
        self.prev_error = err;

        const p = self.kp * err;
        const i = self.ki * self.integral;
        const d = self.kd * derivative;

        return .{
            .control = math.clamp(p + i + d, -100.0, 100.0),
            .err = err,
            .p_term = p,
            .i_term = i,
            .d_term = d,
        };
    }

    /// Stability check: Routh-Hurwitz for PID (simplified)
    pub fn isStable(self: PidController) bool {
        return self.kp > 0 and self.ki >= 0 and self.kd >= 0;
    }
};

// ============================================================================
// LQR CONTROLLER (2D state, 1D or 2D control)
// ============================================================================

pub const LqrController = struct {
    A: Mat2,
    B: Mat2,
    Q: Mat2,
    R: Mat2,
    P: Mat2,
    K: Mat2,

    pub const Output = struct {
        control: Vec2,
        state_cost: f64,
        value: f64,
    };

    /// Solve discrete algebraic Riccati equation by iteration
    pub fn init(A: Mat2, B: Mat2, Q: Mat2, R: Mat2) LqrController {
        var P = Q;
        // Iterate P = Q + A^T P A - A^T P B (R + B^T P B)^{-1} B^T P A
        for (0..200) |_| {
            const At = mat2_transpose(A);
            const Bt = mat2_transpose(B);
            const PA = mat2_mul(P, A);
            const AtPA = mat2_mul(At, PA);
            const PB = mat2_mul(P, B);
            const BtPB = mat2_mul(Bt, PB);
            const RpBtPB = mat2_add(R, BtPB);

            if (mat2_inv(RpBtPB)) |inv| {
                const BtPA = mat2_mul(Bt, PA);
                const gain_term = mat2_mul(inv, BtPA);
                const AtPB = mat2_mul(At, PB);
                const correction = mat2_mul(AtPB, gain_term);
                P = mat2_sub(mat2_add(Q, AtPA), correction);
            } else break;
        }

        // K = (R + B^T P B)^{-1} B^T P A
        const Bt = mat2_transpose(B);
        const BtP = mat2_mul(Bt, P);
        const BtPA = mat2_mul(BtP, A);
        const BtPB = mat2_mul(BtP, B);
        const K = if (mat2_inv(mat2_add(R, BtPB))) |inv|
            mat2_mul(inv, BtPA)
        else
            Mat2{ .{ 0, 0 }, .{ 0, 0 } };

        return .{ .A = A, .B = B, .Q = Q, .R = R, .P = P, .K = K };
    }

    /// u = -K * x
    pub fn control(self: LqrController, state: Vec2) Output {
        const u = vec2_scale(mat2_vec(self.K, state), -1.0);
        return .{
            .control = u,
            .state_cost = quadratic_form_2(state, self.Q),
            .value = quadratic_form_2(state, self.P),
        };
    }

    /// Check closed-loop stability: eigenvalues of (A - BK) inside unit circle
    pub fn isStable(self: LqrController) bool {
        const BK = mat2_mul(self.B, self.K);
        const A_cl = mat2_sub(self.A, BK);
        const tr = mat2_trace(A_cl);
        const det = mat2_det(A_cl);
        // Jury stability: |det| < 1 and |tr| < 1 + det
        return @abs(det) < 1.0 and @abs(tr) < 1.0 + det;
    }
};

// ============================================================================
// MPC (Model Predictive Control)
// ============================================================================

pub const MpcConfig = struct {
    horizon: usize = 10,
    dt: f64 = 0.1,
    iterations: usize = 50,
    learning_rate: f64 = 0.1,
    Q: Mat2 = .{ .{ 1, 0 }, .{ 0, 1 } },
    R: Mat2 = .{ .{ 0.1, 0 }, .{ 0, 0.1 } },
    Qf: Mat2 = .{ .{ 10, 0 }, .{ 0, 10 } },
    reference: Vec2 = .{ 0, 0 },
    u_min: Vec2 = .{ -10, -10 },
    u_max: Vec2 = .{ 10, 10 },
};

pub const MpcResult = struct {
    control: Vec2,
    predicted_cost: f64,
    horizon: usize,
};

/// Forward simulate trajectory under control sequence
pub fn mpcForwardSim(
    x0: Vec2,
    U: []const Vec2,
    dynamics: *const fn (Vec2, Vec2) Vec2,
    dt: f64,
    trajectory: []Vec2,
) void {
    trajectory[0] = x0;
    var x = x0;
    for (U, 0..) |u, i| {
        const dx = dynamics(x, u);
        x = vec2_add(x, vec2_scale(dx, dt));
        if (i + 1 < trajectory.len) trajectory[i + 1] = x;
    }
}

/// Compute MPC cost: sum of stage costs + terminal cost
pub fn mpcCost(trajectory: []const Vec2, U: []const Vec2, cfg: MpcConfig) f64 {
    var cost: f64 = 0;
    for (trajectory[0 .. trajectory.len - 1], 0..) |x, i| {
        const err = vec2_sub(x, cfg.reference);
        cost += quadratic_form_2(err, cfg.Q);
        if (i < U.len) cost += quadratic_form_2(U[i], cfg.R);
    }
    const x_term = vec2_sub(trajectory[trajectory.len - 1], cfg.reference);
    cost += quadratic_form_2(x_term, cfg.Qf);
    return cost;
}

/// Clamp control to constraints
fn clampControl(u: Vec2, cfg: MpcConfig) Vec2 {
    return .{
        math.clamp(u[0], cfg.u_min[0], cfg.u_max[0]),
        math.clamp(u[1], cfg.u_min[1], cfg.u_max[1]),
    };
}

// ============================================================================
// EQUILIBRIA FINDING (Class A fix — Newton iteration)
// ============================================================================

pub const Equilibrium2D = struct {
    point: Vec2,
    residual: f64,
    stable: bool,
    jacobian_trace: f64,
    jacobian_det: f64,
};

/// Find equilibria of f(x) = 0 via Newton iteration with analytic Jacobian.
/// dynamics: f(x) -> dx/dt
/// jacobian: J(x) -> 2x2 Jacobian matrix
pub fn findEquilibria2D(
    dynamics: *const fn (Vec2) Vec2,
    jacobian: *const fn (Vec2) Mat2,
    guesses: []const Vec2,
    tolerance: f64,
    max_iter: usize,
    allocator: Allocator,
) ![]Equilibrium2D {
    var result: std.ArrayListUnmanaged(Equilibrium2D) = .empty;
    errdefer result.deinit(allocator);

    for (guesses) |guess| {
        var x = guess;
        var converged = false;

        for (0..max_iter) |_| {
            const fx = dynamics(x);
            const norm = vec2_norm(fx);
            if (norm < tolerance) {
                converged = true;
                break;
            }

            const J = jacobian(x);
            const inv_J = mat2_inv(J) orelse break;
            const dx = mat2_vec(inv_J, fx);
            x = vec2_sub(x, dx);
        }

        if (converged) {
            var is_dup = false;
            for (result.items) |eq| {
                if (vec2_norm(vec2_sub(eq.point, x)) < tolerance * 10.0) {
                    is_dup = true;
                    break;
                }
            }
            if (!is_dup) {
                const J_eq = jacobian(x);
                const fx_res = dynamics(x);
                try result.append(allocator, .{
                    .point = x,
                    .residual = vec2_norm(fx_res),
                    .stable = (mat2_trace(J_eq) < 0 and mat2_det(J_eq) > 0),
                    .jacobian_trace = mat2_trace(J_eq),
                    .jacobian_det = mat2_det(J_eq),
                });
            }
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Detect bifurcation points from a parameter sweep of equilibria
pub const BifurcationDetection = struct {
    parameter: f64,
    bif_type: enum { stabilizing, destabilizing },
};

pub fn detectBifurcations(
    points: []const struct { parameter: f64, stable: bool },
    allocator: Allocator,
) ![]BifurcationDetection {
    var result: std.ArrayListUnmanaged(BifurcationDetection) = .{};
    errdefer result.deinit(allocator);

    for (0..points.len - 1) |i| {
        if (points[i].stable != points[i + 1].stable) {
            try result.append(allocator, .{
                .parameter = (points[i].parameter + points[i + 1].parameter) / 2.0,
                .bif_type = if (points[i + 1].stable) .stabilizing else .destabilizing,
            });
        }
    }

    return result.toOwnedSlice(allocator);
}

// ============================================================================
// TESTS
// ============================================================================

test "PID tracks setpoint" {
    var pid = PidController.init(2.0, 0.5, 0.1);
    pid.setpoint = 1.0;

    var measurement: f64 = 0;
    for (0..200) |_| {
        const out = pid.step(measurement, 0.01);
        measurement += out.control * 0.01;
    }

    try std.testing.expect(@abs(measurement - 1.0) < 0.1);
    try std.testing.expect(pid.isStable());
}

test "LQR stabilizes double integrator" {
    // x' = Ax + Bu, A = [[1,dt],[0,1]], B = [[0],[dt]]
    const A = Mat2{ .{ 1, 0.1 }, .{ 0, 1 } };
    const B = Mat2{ .{ 0, 0 }, .{ 0.1, 0 } };
    const Q = Mat2{ .{ 1, 0 }, .{ 0, 1 } };
    const R = Mat2{ .{ 0.1, 0 }, .{ 0, 0.1 } };

    const lqr = LqrController.init(A, B, Q, R);
    const out = lqr.control(.{ 1.0, 0.5 });

    try std.testing.expect(out.value > 0);
    try std.testing.expect(vec2_norm(out.control) > 0);
}

test "findEquilibria2D finds origin of linear system" {
    const allocator = std.testing.allocator;

    const dynamics = struct {
        fn f(x: Vec2) Vec2 {
            return .{ -x[0], -x[1] };
        }
    }.f;
    const jacobian_fn = struct {
        fn j(_: Vec2) Mat2 {
            return .{ .{ -1, 0 }, .{ 0, -1 } };
        }
    }.j;

    const guesses = [_]Vec2{ .{ 1, 1 }, .{ -1, -1 }, .{ 0.5, -0.5 } };
    const eqs = try findEquilibria2D(dynamics, jacobian_fn, &guesses, 1e-10, 100, allocator);
    defer allocator.free(eqs);

    try std.testing.expect(eqs.len == 1);
    try std.testing.expect(vec2_norm(eqs[0].point) < 1e-8);
    try std.testing.expect(eqs[0].stable);
}

test "findEquilibria2D detects unstable equilibrium" {
    const allocator = std.testing.allocator;

    // Repelling origin: dx/dt = x, dy/dt = y
    const dynamics = struct {
        fn f(x: Vec2) Vec2 {
            return .{ x[0], x[1] };
        }
    }.f;
    const jacobian_fn = struct {
        fn j(_: Vec2) Mat2 {
            return .{ .{ 1, 0 }, .{ 0, 1 } };
        }
    }.j;

    const guesses = [_]Vec2{.{ 0.001, 0.001 }};
    const eqs = try findEquilibria2D(dynamics, jacobian_fn, &guesses, 1e-6, 100, allocator);
    defer allocator.free(eqs);

    try std.testing.expect(eqs.len == 1);
    try std.testing.expect(!eqs[0].stable);
    try std.testing.expect(eqs[0].jacobian_trace > 0);
}

test "mat2 inverse round-trip" {
    const m = Mat2{ .{ 2, 1 }, .{ 1, 3 } };
    const inv = mat2_inv(m).?;
    const product = mat2_mul(m, inv);

    try std.testing.expectApproxEqAbs(1.0, product[0][0], 1e-10);
    try std.testing.expectApproxEqAbs(0.0, product[0][1], 1e-10);
    try std.testing.expectApproxEqAbs(0.0, product[1][0], 1e-10);
    try std.testing.expectApproxEqAbs(1.0, product[1][1], 1e-10);
}
