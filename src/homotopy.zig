//! Homotopy Continuation for Polynomial Systems
//!
//! Zig implementation inspired by HomotopyContinuation.jl with:
//! - Syrup serialization for distributed computation
//! - ACSet.jl JSON compatibility for categorical data
//! - GF(3) trit tracking for path classification
//!
//! Key concepts:
//! - Start System: Easy-to-solve system with known solutions
//! - Target System: The system we want to solve
//! - Homotopy: H(x,t) = (1-t)·G(x) + t·F(x), t ∈ [0,1]
//! - Path Tracking: Follow solutions from t=0 to t=1
//!
//! Reference: https://www.juliahomotopycontinuation.org/

const std = @import("std");
const syrup = @import("syrup");
const continuation = @import("continuation");
const linalg = @import("linalg.zig");
const Allocator = std.mem.Allocator;

// ============================================================================
// COMPLEX NUMBERS (for polynomial roots)
// ============================================================================

pub const Complex = struct {
    re: f64,
    im: f64,

    pub const zero = Complex{ .re = 0, .im = 0 };
    pub const one = Complex{ .re = 1, .im = 0 };
    pub const i = Complex{ .re = 0, .im = 1 };

    pub fn init(re: f64, im: f64) Complex {
        return .{ .re = re, .im = im };
    }

    pub fn add(a: Complex, b: Complex) Complex {
        return .{ .re = a.re + b.re, .im = a.im + b.im };
    }

    pub fn sub(a: Complex, b: Complex) Complex {
        return .{ .re = a.re - b.re, .im = a.im - b.im };
    }

    pub fn mul(a: Complex, b: Complex) Complex {
        return .{
            .re = a.re * b.re - a.im * b.im,
            .im = a.re * b.im + a.im * b.re,
        };
    }

    pub fn scale(a: Complex, s: f64) Complex {
        return .{ .re = a.re * s, .im = a.im * s };
    }

    pub fn conj(a: Complex) Complex {
        return .{ .re = a.re, .im = -a.im };
    }

    pub fn div(a: Complex, b: Complex) Complex {
        const denom = b.re * b.re + b.im * b.im;
        if (denom == 0) return .{ .re = std.math.inf(f64), .im = std.math.inf(f64) };
        return .{
            .re = (a.re * b.re + a.im * b.im) / denom,
            .im = (a.im * b.re - a.re * b.im) / denom,
        };
    }

    pub fn abs(a: Complex) f64 {
        return @sqrt(a.re * a.re + a.im * a.im);
    }

    pub fn arg(a: Complex) f64 {
        return std.math.atan2(a.im, a.re);
    }

    pub fn exp(a: Complex) Complex {
        const r = @exp(a.re);
        return .{ .re = r * @cos(a.im), .im = r * @sin(a.im) };
    }

    pub fn toSyrup(self: Complex, allocator: Allocator) !syrup.Value {
        const entries = try allocator.alloc(syrup.Value.DictEntry, 2);
        entries[0] = .{
            .key = syrup.Value{ .symbol = "re" },
            .value = syrup.Value{ .float = self.re },
        };
        entries[1] = .{
            .key = syrup.Value{ .symbol = "im" },
            .value = syrup.Value{ .float = self.im },
        };
        return syrup.Value{ .dictionary = entries };
    }

    pub fn fromSyrup(val: syrup.Value) ?Complex {
        if (val != .dictionary) return null;
        var re: ?f64 = null;
        var im: ?f64 = null;
        for (val.dictionary) |entry| {
            if (entry.key == .symbol) {
                if (std.mem.eql(u8, entry.key.symbol, "re")) {
                    re = if (entry.value == .float) entry.value.float else null;
                } else if (std.mem.eql(u8, entry.key.symbol, "im")) {
                    im = if (entry.value == .float) entry.value.float else null;
                }
            }
        }
        if (re != null and im != null) {
            return Complex{ .re = re.?, .im = im.? };
        }
        return null;
    }
};

// ============================================================================
// POLYNOMIAL REPRESENTATION
// ============================================================================

/// Monomial: coefficient * x_0^e_0 * x_1^e_1 * ... * x_n^e_n
pub const Monomial = struct {
    coeff: Complex,
    exponents: []const u32, // exponent for each variable

    pub fn evaluate(self: Monomial, vars: []const Complex) Complex {
        var result = self.coeff;
        for (self.exponents, 0..) |exp, i| {
            if (i >= vars.len) break;
            var power = Complex.one;
            for (0..exp) |_| {
                power = Complex.mul(power, vars[i]);
            }
            result = Complex.mul(result, power);
        }
        return result;
    }

    pub fn degree(self: Monomial) u32 {
        var sum: u32 = 0;
        for (self.exponents) |e| sum += e;
        return sum;
    }

    pub fn toSyrup(self: Monomial, allocator: Allocator) !syrup.Value {
        var exp_values = try allocator.alloc(syrup.Value, self.exponents.len);
        for (self.exponents, 0..) |e, idx| {
            exp_values[idx] = syrup.Value{ .integer = @intCast(e) };
        }

        const entries = try allocator.alloc(syrup.Value.DictEntry, 2);
        entries[0] = .{
            .key = syrup.Value{ .symbol = "coeff" },
            .value = try self.coeff.toSyrup(allocator),
        };
        entries[1] = .{
            .key = syrup.Value{ .symbol = "exp" },
            .value = syrup.Value{ .list = exp_values },
        };
        return syrup.Value{ .dictionary = entries };
    }
};

/// Polynomial: sum of monomials
pub const Polynomial = struct {
    monomials: []const Monomial,
    num_vars: usize,

    pub fn evaluate(self: Polynomial, vars: []const Complex) Complex {
        var result = Complex.zero;
        for (self.monomials) |mono| {
            result = Complex.add(result, mono.evaluate(vars));
        }
        return result;
    }

    pub fn degree(self: Polynomial) u32 {
        var max_deg: u32 = 0;
        for (self.monomials) |mono| {
            max_deg = @max(max_deg, mono.degree());
        }
        return max_deg;
    }

    pub fn toSyrup(self: Polynomial, allocator: Allocator) !syrup.Value {
        var mono_values = try allocator.alloc(syrup.Value, self.monomials.len);
        for (self.monomials, 0..) |mono, idx| {
            mono_values[idx] = try mono.toSyrup(allocator);
        }

        const entries = try allocator.alloc(syrup.Value.DictEntry, 2);
        entries[0] = .{
            .key = syrup.Value{ .symbol = "monomials" },
            .value = syrup.Value{ .list = mono_values },
        };
        entries[1] = .{
            .key = syrup.Value{ .symbol = "num_vars" },
            .value = syrup.Value{ .integer = @intCast(self.num_vars) },
        };
        return syrup.Value{ .dictionary = entries };
    }
};

/// System of polynomials F = (f_1, ..., f_n)
pub const PolynomialSystem = struct {
    polynomials: []const Polynomial,
    num_vars: usize,

    pub fn evaluate(self: PolynomialSystem, vars: []const Complex, allocator: Allocator) ![]Complex {
        var results = try allocator.alloc(Complex, self.polynomials.len);
        for (self.polynomials, 0..) |poly, idx| {
            results[idx] = poly.evaluate(vars);
        }
        return results;
    }

    /// Compute Jacobian matrix J[i][j] = df_i/dx_j evaluated at vars
    pub fn jacobian(self: PolynomialSystem, vars: []const Complex, allocator: Allocator) ![][]Complex {
        const n = self.polynomials.len;
        const m = self.num_vars;
        var J = try linalg.allocMatrix(n, m, allocator);

        for (self.polynomials, 0..) |poly, i_poly| {
            for (0..m) |j_var| {
                var deriv = Complex.zero;
                for (poly.monomials) |mono| {
                    if (j_var < mono.exponents.len and mono.exponents[j_var] > 0) {
                        // d/dx_j (c * x_0^e0 * ... * x_j^ej * ...) = c * ej * x_0^e0 * ... * x_j^(ej-1) * ...
                        var term = Complex.scale(mono.coeff, @as(f64, @floatFromInt(mono.exponents[j_var])));
                        for (mono.exponents, 0..) |exp_val, k| {
                            if (k == j_var) {
                                // x_j^(ej-1)
                                if (exp_val > 1) {
                                    var power = Complex.one;
                                    for (0..exp_val - 1) |_| {
                                        power = Complex.mul(power, vars[k]);
                                    }
                                    term = Complex.mul(term, power);
                                }
                                // if exp_val == 1, derivative contributes factor 1 (already in coeff)
                            } else if (k < vars.len) {
                                var power = Complex.one;
                                for (0..exp_val) |_| {
                                    power = Complex.mul(power, vars[k]);
                                }
                                term = Complex.mul(term, power);
                            }
                        }
                        deriv = Complex.add(deriv, term);
                    }
                }
                J[i_poly][j_var] = deriv;
            }
        }
        return J;
    }

    pub fn toSyrup(self: PolynomialSystem, allocator: Allocator) !syrup.Value {
        var poly_values = try allocator.alloc(syrup.Value, self.polynomials.len);
        for (self.polynomials, 0..) |poly, idx| {
            poly_values[idx] = try poly.toSyrup(allocator);
        }

        const entries = try allocator.alloc(syrup.Value.DictEntry, 2);
        entries[0] = .{
            .key = syrup.Value{ .symbol = "polynomials" },
            .value = syrup.Value{ .list = poly_values },
        };
        entries[1] = .{
            .key = syrup.Value{ .symbol = "num_vars" },
            .value = syrup.Value{ .integer = @intCast(self.num_vars) },
        };
        return syrup.Value{ .dictionary = entries };
    }
};

// ============================================================================
// HOMOTOPY H(x,t) = (1-t)·G(x) + t·F(x)
// ============================================================================

/// Homotopy connecting start system G to target system F
pub const Homotopy = struct {
    start: PolynomialSystem, // G(x) - easy to solve
    target: PolynomialSystem, // F(x) - what we want
    gamma: Complex, // random complex number for regularity

    /// Evaluate H(x,t) = (1-t)·γ·G(x) + t·F(x)
    pub fn evaluate(self: Homotopy, vars: []const Complex, t: f64, allocator: Allocator) ![]Complex {
        const start_vals = try self.start.evaluate(vars, allocator);
        defer allocator.free(start_vals);
        const target_vals = try self.target.evaluate(vars, allocator);

        const one_minus_t = 1.0 - t;
        for (start_vals, target_vals, 0..) |s, tgt, idx| {
            // H_i = (1-t)·γ·G_i + t·F_i
            const scaled_start = Complex.mul(Complex.scale(s, one_minus_t), self.gamma);
            const scaled_target = Complex.scale(tgt, t);
            target_vals[idx] = Complex.add(scaled_start, scaled_target);
        }

        return target_vals;
    }

    pub fn toSyrup(self: Homotopy, allocator: Allocator) !syrup.Value {
        const entries = try allocator.alloc(syrup.Value.DictEntry, 3);
        entries[0] = .{
            .key = syrup.Value{ .symbol = "start" },
            .value = try self.start.toSyrup(allocator),
        };
        entries[1] = .{
            .key = syrup.Value{ .symbol = "target" },
            .value = try self.target.toSyrup(allocator),
        };
        entries[2] = .{
            .key = syrup.Value{ .symbol = "gamma" },
            .value = try self.gamma.toSyrup(allocator),
        };
        return syrup.Value{ .dictionary = entries };
    }
};

// ============================================================================
// PATH TRACKING
// ============================================================================

/// Status of a tracked path
pub const PathStatus = enum {
    tracking, // Still following the path
    success, // Reached t=1 successfully
    diverged, // Path went to infinity
    singular, // Hit a singular point
    min_step, // Step size too small

    pub fn toTrit(self: PathStatus) continuation.Trit {
        return switch (self) {
            .success => .plus,
            .tracking => .zero,
            .diverged, .singular, .min_step => .minus,
        };
    }

    pub fn toSyrup(self: PathStatus) syrup.Value {
        return syrup.Value{ .symbol = @tagName(self) };
    }
};

/// Result of tracking a single path
pub const PathResult = struct {
    start_solution: []const Complex,
    end_solution: []const Complex,
    status: PathStatus,
    steps_taken: usize,
    t_final: f64,
    trit: continuation.Trit,

    pub fn toSyrup(self: PathResult, allocator: Allocator) !syrup.Value {
        var start_vals = try allocator.alloc(syrup.Value, self.start_solution.len);
        for (self.start_solution, 0..) |c, idx| {
            start_vals[idx] = try c.toSyrup(allocator);
        }

        var end_vals = try allocator.alloc(syrup.Value, self.end_solution.len);
        for (self.end_solution, 0..) |c, idx| {
            end_vals[idx] = try c.toSyrup(allocator);
        }

        const entries = try allocator.alloc(syrup.Value.DictEntry, 5);
        entries[0] = .{
            .key = syrup.Value{ .symbol = "start" },
            .value = syrup.Value{ .list = start_vals },
        };
        entries[1] = .{
            .key = syrup.Value{ .symbol = "end" },
            .value = syrup.Value{ .list = end_vals },
        };
        entries[2] = .{
            .key = syrup.Value{ .symbol = "status" },
            .value = self.status.toSyrup(),
        };
        entries[3] = .{
            .key = syrup.Value{ .symbol = "steps" },
            .value = syrup.Value{ .integer = @intCast(self.steps_taken) },
        };
        entries[4] = .{
            .key = syrup.Value{ .symbol = "trit" },
            .value = self.trit.toSyrup(),
        };

        return syrup.Value{ .dictionary = entries };
    }
};

/// Path tracker configuration
pub const TrackerConfig = struct {
    max_steps: usize = 10000,
    initial_step_size: f64 = 0.1,
    min_step_size: f64 = 1e-14,
    max_step_size: f64 = 0.5,
    tolerance: f64 = 1e-10,
    infinity_threshold: f64 = 1e8,
};

/// Euler-Newton predictor-corrector path tracker
pub const PathTracker = struct {
    homotopy: Homotopy,
    config: TrackerConfig,
    allocator: Allocator,

    pub fn init(homotopy: Homotopy, config: TrackerConfig, allocator: Allocator) PathTracker {
        return .{
            .homotopy = homotopy,
            .config = config,
            .allocator = allocator,
        };
    }

    /// Track a single path from start solution at t=0 to t=1
    pub fn track(self: *PathTracker, start_solution: []const Complex) !PathResult {
        const current = try self.allocator.alloc(Complex, start_solution.len);
        defer self.allocator.free(current);
        @memcpy(current, start_solution);

        var t: f64 = 0.0;
        var step_size = self.config.initial_step_size;
        var steps: usize = 0;
        var status: PathStatus = .tracking;

        while (t < 1.0 and steps < self.config.max_steps) {
            // Check for divergence
            var max_abs: f64 = 0;
            for (current) |c| {
                max_abs = @max(max_abs, Complex.abs(c));
            }
            if (max_abs > self.config.infinity_threshold) {
                status = .diverged;
                break;
            }

            // RK4 predictor
            const dt = @min(step_size, 1.0 - t);

            const k1 = try self.tangentVector(current, t) orelse {
                step_size *= 0.5;
                if (step_size < self.config.min_step_size) {
                    status = .singular;
                    break;
                }
                continue;
            };
            defer self.allocator.free(k1);

            // tmp = x + dt/2 * k1
            var tmp = try self.allocator.alloc(Complex, current.len);
            defer self.allocator.free(tmp);
            for (current, k1, 0..) |c, k, idx| {
                tmp[idx] = Complex.add(c, Complex.scale(k, dt * 0.5));
            }

            const k2 = try self.tangentVector(tmp, t + dt * 0.5) orelse {
                step_size *= 0.5;
                if (step_size < self.config.min_step_size) {
                    status = .singular;
                    break;
                }
                continue;
            };
            defer self.allocator.free(k2);

            // tmp = x + dt/2 * k2
            for (current, k2, 0..) |c, k, idx| {
                tmp[idx] = Complex.add(c, Complex.scale(k, dt * 0.5));
            }

            const k3 = try self.tangentVector(tmp, t + dt * 0.5) orelse {
                step_size *= 0.5;
                if (step_size < self.config.min_step_size) {
                    status = .singular;
                    break;
                }
                continue;
            };
            defer self.allocator.free(k3);

            // tmp = x + dt * k3
            for (current, k3, 0..) |c, k, idx| {
                tmp[idx] = Complex.add(c, Complex.scale(k, dt));
            }

            const k4 = try self.tangentVector(tmp, t + dt) orelse {
                step_size *= 0.5;
                if (step_size < self.config.min_step_size) {
                    status = .singular;
                    break;
                }
                continue;
            };
            defer self.allocator.free(k4);

            // x_predicted = x + (k1 + 2*k2 + 2*k3 + k4) * dt/6
            var predicted = try self.allocator.alloc(Complex, current.len);
            defer self.allocator.free(predicted);
            for (current, 0..) |c, idx| {
                const weighted = Complex.add(
                    Complex.add(k1[idx], Complex.scale(k2[idx], 2.0)),
                    Complex.add(Complex.scale(k3[idx], 2.0), k4[idx]),
                );
                predicted[idx] = Complex.add(c, Complex.scale(weighted, dt / 6.0));
            }

            // Corrector step (Newton iteration)
            const corrected = try self.allocator.alloc(Complex, current.len);
            defer self.allocator.free(corrected);
            @memcpy(corrected, predicted);

            const newton_success = try self.newtonCorrector(corrected, t + dt);
            if (!newton_success) {
                step_size *= 0.5;
                if (step_size < self.config.min_step_size) {
                    status = .min_step;
                    break;
                }
                continue;
            }

            // Accept step
            @memcpy(current, corrected);
            t += dt;
            steps += 1;

            // Adaptive step size based on error estimate: ||k4 - k3|| as proxy
            var err: f64 = 0;
            for (0..current.len) |idx| {
                const diff = Complex.sub(k4[idx], k3[idx]);
                err += diff.re * diff.re + diff.im * diff.im;
            }
            err = @sqrt(err) * dt;

            if (err < self.config.tolerance * 0.1) {
                step_size = @min(step_size * 1.5, self.config.max_step_size);
            } else if (err > self.config.tolerance) {
                step_size *= 0.5;
            }
        }

        if (status == .tracking and t >= 1.0 - self.config.tolerance) {
            status = .success;
        }

        // Copy final solution
        const end_solution = try self.allocator.alloc(Complex, current.len);
        @memcpy(end_solution, current);

        const start_copy = try self.allocator.alloc(Complex, start_solution.len);
        @memcpy(start_copy, start_solution);

        return PathResult{
            .start_solution = start_copy,
            .end_solution = end_solution,
            .status = status,
            .steps_taken = steps,
            .t_final = t,
            .trit = status.toTrit(),
        };
    }

    /// Newton corrector iteration using Jacobian + LU solve
    fn newtonCorrector(self: *PathTracker, x: []Complex, t: f64) !bool {
        const max_iters = 10;
        const n = x.len;
        var iter: usize = 0;

        const perm = try self.allocator.alloc(usize, n);
        defer self.allocator.free(perm);
        const dx = try self.allocator.alloc(Complex, n);
        defer self.allocator.free(dx);
        const neg_h = try self.allocator.alloc(Complex, n);
        defer self.allocator.free(neg_h);

        while (iter < max_iters) : (iter += 1) {
            const h_val = try self.homotopy.evaluate(x, t, self.allocator);
            defer self.allocator.free(h_val);

            // Check convergence: ||H(x,t)||
            var norm_sq: f64 = 0;
            for (h_val) |h| norm_sq += h.re * h.re + h.im * h.im;
            if (@sqrt(norm_sq) < self.config.tolerance) return true;

            // Compute Jacobian of the homotopy w.r.t. x
            // J_H = (1-t)*gamma*J_G + t*J_F
            const J_start = try self.homotopy.start.jacobian(x, self.allocator);
            defer linalg.freeMatrix(J_start, self.allocator);
            const J_target = try self.homotopy.target.jacobian(x, self.allocator);
            defer linalg.freeMatrix(J_target, self.allocator);

            var J = try linalg.allocMatrix(n, n, self.allocator);
            defer linalg.freeMatrix(J, self.allocator);

            const one_minus_t = 1.0 - t;
            for (0..n) |i| {
                for (0..n) |j| {
                    const scaled_start = Complex.mul(Complex.scale(J_start[i][j], one_minus_t), self.homotopy.gamma);
                    const scaled_target = Complex.scale(J_target[i][j], t);
                    J[i][j] = Complex.add(scaled_start, scaled_target);
                }
            }

            // Solve J * dx = -H(x,t)
            for (h_val, 0..) |h, idx| neg_h[idx] = Complex.scale(h, -1.0);

            linalg.luDecompose(n, J, perm) catch return false;
            linalg.luSolve(n, J, perm, neg_h, dx);

            // Update: x += dx
            for (x, dx) |*xi, dxi| xi.* = Complex.add(xi.*, dxi);
        }
        return false;
    }

    /// Compute tangent vector: dx/dt = -J_H^{-1} * (dH/dt)
    fn tangentVector(self: *PathTracker, x: []const Complex, t: f64) !?[]Complex {
        const n = x.len;

        // dH/dt = -gamma*G(x) + F(x)
        const g_val = try self.homotopy.start.evaluate(x, self.allocator);
        defer self.allocator.free(g_val);
        const f_val = try self.homotopy.target.evaluate(x, self.allocator);
        defer self.allocator.free(f_val);

        var dHdt = try self.allocator.alloc(Complex, n);
        defer self.allocator.free(dHdt);
        for (0..n) |i| {
            dHdt[i] = Complex.sub(f_val[i], Complex.mul(self.homotopy.gamma, g_val[i]));
        }

        // J_H = (1-t)*gamma*J_G + t*J_F
        const J_start = try self.homotopy.start.jacobian(x, self.allocator);
        defer linalg.freeMatrix(J_start, self.allocator);
        const J_target = try self.homotopy.target.jacobian(x, self.allocator);
        defer linalg.freeMatrix(J_target, self.allocator);

        var J = try linalg.allocMatrix(n, n, self.allocator);
        defer linalg.freeMatrix(J, self.allocator);

        const one_minus_t = 1.0 - t;
        for (0..n) |i| {
            for (0..n) |j| {
                const s = Complex.mul(Complex.scale(J_start[i][j], one_minus_t), self.homotopy.gamma);
                const tgt = Complex.scale(J_target[i][j], t);
                J[i][j] = Complex.add(s, tgt);
            }
        }

        // Solve J * result = -dHdt
        var neg_dHdt = try self.allocator.alloc(Complex, n);
        defer self.allocator.free(neg_dHdt);
        for (0..n) |i| neg_dHdt[i] = Complex.scale(dHdt[i], -1.0);

        const perm = try self.allocator.alloc(usize, n);
        defer self.allocator.free(perm);
        const result = try self.allocator.alloc(Complex, n);

        linalg.luDecompose(n, J, perm) catch {
            self.allocator.free(result);
            return null;
        };
        linalg.luSolve(n, J, perm, neg_dHdt, result);

        return result;
    }

    /// Track all paths from start solutions
    pub fn trackAll(self: *PathTracker, start_solutions: []const []const Complex) ![]PathResult {
        var results = try self.allocator.alloc(PathResult, start_solutions.len);
        for (start_solutions, 0..) |sol, idx| {
            results[idx] = try self.track(sol);
        }
        return results;
    }
};

// ============================================================================
// ACSET SERIALIZATION (ACSet.jl compatible JSON)
// ============================================================================

/// ACSet schema for homotopy continuation data
pub const HomotopyACSet = struct {
    /// Object types in the schema
    pub const Ob = enum {
        Solution,
        Path,
        System,
        Variable,
    };

    /// Morphism (foreign key) types
    pub const Hom = enum {
        start_sol, // Path → Solution (start)
        end_sol, // Path → Solution (end)
        system, // Path → System
    };

    /// Attribute types
    pub const AttrType = enum {
        Complex,
        Status,
        Trit,
        Float,
        Int,
    };

    allocator: Allocator,

    // Tables
    solutions: std.ArrayListUnmanaged(SolutionRow),
    paths: std.ArrayListUnmanaged(PathRow),
    systems: std.ArrayListUnmanaged(SystemRow),

    pub const SolutionRow = struct {
        _id: usize,
        values: []const Complex,
    };

    pub const PathRow = struct {
        _id: usize,
        start_sol: usize, // FK to Solution
        end_sol: usize, // FK to Solution
        system: usize, // FK to System
        status: PathStatus,
        steps: usize,
        trit: continuation.Trit,
    };

    pub const SystemRow = struct {
        _id: usize,
        num_vars: usize,
        num_polys: usize,
        degrees: []const u32,
    };

    pub fn init(allocator: Allocator) HomotopyACSet {
        return .{
            .allocator = allocator,
            .solutions = .{},
            .paths = .{},
            .systems = .{},
        };
    }

    pub fn deinit(self: *HomotopyACSet) void {
        self.solutions.deinit(self.allocator);
        self.paths.deinit(self.allocator);
        self.systems.deinit(self.allocator);
    }

    /// Add a solution and return its ID
    pub fn addSolution(self: *HomotopyACSet, values: []const Complex) !usize {
        const id = self.solutions.items.len + 1;
        try self.solutions.append(self.allocator, .{ ._id = id, .values = values });
        return id;
    }

    /// Add a system and return its ID
    pub fn addSystem(self: *HomotopyACSet, sys: PolynomialSystem) !usize {
        const id = self.systems.items.len + 1;
        var degrees = try self.allocator.alloc(u32, sys.polynomials.len);
        for (sys.polynomials, 0..) |poly, idx| {
            degrees[idx] = poly.degree();
        }
        try self.systems.append(self.allocator, .{
            ._id = id,
            .num_vars = sys.num_vars,
            .num_polys = sys.polynomials.len,
            .degrees = degrees,
        });
        return id;
    }

    /// Add a path result
    pub fn addPath(self: *HomotopyACSet, result: PathResult, system_id: usize) !usize {
        const start_id = try self.addSolution(result.start_solution);
        const end_id = try self.addSolution(result.end_solution);
        const id = self.paths.items.len + 1;
        try self.paths.append(self.allocator, .{
            ._id = id,
            .start_sol = start_id,
            .end_sol = end_id,
            .system = system_id,
            .status = result.status,
            .steps = result.steps_taken,
            .trit = result.trit,
        });
        return id;
    }

    /// Export to ACSet.jl compatible JSON
    pub fn toJson(self: HomotopyACSet, allocator: Allocator) ![]const u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        const writer = buf.writer(allocator);

        try writer.writeAll("{\n");

        // Schema
        try writer.writeAll("  \"Ob\": [\"Solution\", \"Path\", \"System\"],\n");
        try writer.writeAll("  \"Hom\": [\n");
        try writer.writeAll("    {\"name\": \"start_sol\", \"dom\": \"Path\", \"codom\": \"Solution\"},\n");
        try writer.writeAll("    {\"name\": \"end_sol\", \"dom\": \"Path\", \"codom\": \"Solution\"},\n");
        try writer.writeAll("    {\"name\": \"system\", \"dom\": \"Path\", \"codom\": \"System\"}\n");
        try writer.writeAll("  ],\n");
        try writer.writeAll("  \"AttrType\": [\"Complex\", \"Status\", \"Trit\", \"Int\"],\n");
        try writer.writeAll("  \"Attr\": [\n");
        try writer.writeAll("    {\"name\": \"values\", \"dom\": \"Solution\", \"codom\": \"Complex\"},\n");
        try writer.writeAll("    {\"name\": \"status\", \"dom\": \"Path\", \"codom\": \"Status\"},\n");
        try writer.writeAll("    {\"name\": \"trit\", \"dom\": \"Path\", \"codom\": \"Trit\"},\n");
        try writer.writeAll("    {\"name\": \"steps\", \"dom\": \"Path\", \"codom\": \"Int\"}\n");
        try writer.writeAll("  ],\n");

        // Tables
        try writer.writeAll("  \"tables\": {\n");

        // Solutions
        try writer.writeAll("    \"Solution\": [\n");
        for (self.solutions.items, 0..) |sol, idx| {
            try std.fmt.format(writer, "      {{\"_id\": {d}, \"values\": [", .{sol._id});
            for (sol.values, 0..) |c, vidx| {
                try std.fmt.format(writer, "{{\"re\": {d}, \"im\": {d}}}", .{ c.re, c.im });
                if (vidx < sol.values.len - 1) try writer.writeAll(", ");
            }
            try writer.writeAll("]}");
            if (idx < self.solutions.items.len - 1) try writer.writeAll(",");
            try writer.writeAll("\n");
        }
        try writer.writeAll("    ],\n");

        // Paths
        try writer.writeAll("    \"Path\": [\n");
        for (self.paths.items, 0..) |path, idx| {
            try std.fmt.format(writer,
                \\      {{"_id": {d}, "start_sol": {d}, "end_sol": {d}, "system": {d}, "status": "{s}", "trit": {d}, "steps": {d}}}
            , .{
                path._id,
                path.start_sol,
                path.end_sol,
                path.system,
                @tagName(path.status),
                @as(i8, @intFromEnum(path.trit)),
                path.steps,
            });
            if (idx < self.paths.items.len - 1) try writer.writeAll(",");
            try writer.writeAll("\n");
        }
        try writer.writeAll("    ],\n");

        // Systems
        try writer.writeAll("    \"System\": [\n");
        for (self.systems.items, 0..) |sys, idx| {
            try std.fmt.format(writer, "      {{\"_id\": {d}, \"num_vars\": {d}, \"num_polys\": {d}, \"degrees\": [", .{ sys._id, sys.num_vars, sys.num_polys });
            for (sys.degrees, 0..) |d, didx| {
                try std.fmt.format(writer, "{d}", .{d});
                if (didx < sys.degrees.len - 1) try writer.writeAll(", ");
            }
            try writer.writeAll("]}");
            if (idx < self.systems.items.len - 1) try writer.writeAll(",");
            try writer.writeAll("\n");
        }
        try writer.writeAll("    ]\n");

        try writer.writeAll("  }\n");
        try writer.writeAll("}\n");

        return buf.toOwnedSlice(allocator);
    }

    /// Convert to Syrup value
    pub fn toSyrup(self: HomotopyACSet, allocator: Allocator) !syrup.Value {
        // Build solutions list
        var sol_list = try allocator.alloc(syrup.Value, self.solutions.items.len);
        for (self.solutions.items, 0..) |sol, idx| {
            var vals = try allocator.alloc(syrup.Value, sol.values.len);
            for (sol.values, 0..) |c, vidx| {
                vals[vidx] = try c.toSyrup(allocator);
            }
            const entries = try allocator.alloc(syrup.Value.DictEntry, 2);
            entries[0] = .{ .key = syrup.Value{ .symbol = "_id" }, .value = syrup.Value{ .integer = @intCast(sol._id) } };
            entries[1] = .{ .key = syrup.Value{ .symbol = "values" }, .value = syrup.Value{ .list = vals } };
            sol_list[idx] = syrup.Value{ .dictionary = entries };
        }

        // Build paths list
        var path_list = try allocator.alloc(syrup.Value, self.paths.items.len);
        for (self.paths.items, 0..) |path, idx| {
            const entries = try allocator.alloc(syrup.Value.DictEntry, 6);
            entries[0] = .{ .key = syrup.Value{ .symbol = "_id" }, .value = syrup.Value{ .integer = @intCast(path._id) } };
            entries[1] = .{ .key = syrup.Value{ .symbol = "start_sol" }, .value = syrup.Value{ .integer = @intCast(path.start_sol) } };
            entries[2] = .{ .key = syrup.Value{ .symbol = "end_sol" }, .value = syrup.Value{ .integer = @intCast(path.end_sol) } };
            entries[3] = .{ .key = syrup.Value{ .symbol = "system" }, .value = syrup.Value{ .integer = @intCast(path.system) } };
            entries[4] = .{ .key = syrup.Value{ .symbol = "status" }, .value = path.status.toSyrup() };
            entries[5] = .{ .key = syrup.Value{ .symbol = "trit" }, .value = path.trit.toSyrup() };
            path_list[idx] = syrup.Value{ .dictionary = entries };
        }

        // Build root record
        const label = try allocator.create(syrup.Value);
        label.* = syrup.Value{ .symbol = "homotopy-acset" };

        const fields = try allocator.alloc(syrup.Value, 3);
        fields[0] = syrup.Value{ .list = sol_list };
        fields[1] = syrup.Value{ .list = path_list };
        fields[2] = syrup.Value{ .integer = @intCast(self.systems.items.len) };

        return syrup.Value{ .record = .{ .label = label, .fields = fields } };
    }
};

// ============================================================================
// TOTAL DEGREE START SYSTEM
// ============================================================================

/// Generate a total degree start system for a given target
/// G_i(x) = x_i^d_i - 1 where d_i is the degree of f_i
pub fn totalDegreeStartSystem(target: PolynomialSystem, allocator: Allocator) !PolynomialSystem {
    var polys = try allocator.alloc(Polynomial, target.polynomials.len);

    for (target.polynomials, 0..) |poly, idx| {
        const deg = poly.degree();

        // Create x_i^d_i - 1
        var monomials = try allocator.alloc(Monomial, 2);

        // x_i^d_i term
        var exp1 = try allocator.alloc(u32, target.num_vars);
        @memset(exp1, 0);
        if (idx < target.num_vars) {
            exp1[idx] = deg;
        }
        monomials[0] = .{ .coeff = Complex.one, .exponents = exp1 };

        // -1 term
        const exp2 = try allocator.alloc(u32, target.num_vars);
        @memset(exp2, 0);
        monomials[1] = .{ .coeff = Complex.init(-1, 0), .exponents = exp2 };

        polys[idx] = .{ .monomials = monomials, .num_vars = target.num_vars };
    }

    return .{ .polynomials = polys, .num_vars = target.num_vars };
}

/// Generate all start solutions for total degree system
/// Solutions are d_1 × d_2 × ... × d_n roots of unity
pub fn totalDegreeStartSolutions(system: PolynomialSystem, allocator: Allocator) ![][]Complex {
    // Count total solutions
    var total: usize = 1;
    for (system.polynomials) |poly| {
        total *= poly.degree();
    }

    var solutions = try allocator.alloc([]Complex, total);

    // Generate all combinations of roots of unity
    var indices = try allocator.alloc(usize, system.polynomials.len);
    @memset(indices, 0);

    for (0..total) |sol_idx| {
        var sol = try allocator.alloc(Complex, system.num_vars);

        for (0..system.num_vars) |var_idx| {
            if (var_idx < system.polynomials.len) {
                const deg = system.polynomials[var_idx].degree();
                const angle = 2.0 * std.math.pi * @as(f64, @floatFromInt(indices[var_idx])) / @as(f64, @floatFromInt(deg));
                sol[var_idx] = Complex.init(@cos(angle), @sin(angle));
            } else {
                sol[var_idx] = Complex.one;
            }
        }

        solutions[sol_idx] = sol;

        // Increment indices (like counting in mixed radix)
        var carry: usize = 1;
        for (0..system.polynomials.len) |i| {
            if (carry == 0) break;
            indices[i] += carry;
            const deg = system.polynomials[i].degree();
            if (indices[i] >= deg) {
                indices[i] = 0;
                carry = 1;
            } else {
                carry = 0;
            }
        }
    }

    allocator.free(indices);
    return solutions;
}

// ============================================================================
// CONVENIENCE: solve()
// ============================================================================

/// Solve a polynomial system using homotopy continuation
pub fn solve(target: PolynomialSystem, allocator: Allocator) !HomotopyACSet {
    // Generate start system
    const start = try totalDegreeStartSystem(target, allocator);

    // Generate start solutions
    const start_solutions = try totalDegreeStartSolutions(start, allocator);

    // Create homotopy with random gamma
    var buf: [8]u8 = undefined;
    std.crypto.random.bytes(&buf);
    const rand_re = @as(f64, @floatFromInt(std.mem.readInt(u32, buf[0..4], .little))) / @as(f64, @floatFromInt(std.math.maxInt(u32)));
    const rand_im = @as(f64, @floatFromInt(std.mem.readInt(u32, buf[4..8], .little))) / @as(f64, @floatFromInt(std.math.maxInt(u32)));

    const homotopy = Homotopy{
        .start = start,
        .target = target,
        .gamma = Complex.exp(Complex.init(0, 2.0 * std.math.pi * rand_re)).scale(0.9 + 0.2 * rand_im),
    };

    // Track all paths
    var tracker = PathTracker.init(homotopy, .{}, allocator);
    const results = try tracker.trackAll(start_solutions);

    // Build ACSet
    var acset = HomotopyACSet.init(allocator);
    const sys_id = try acset.addSystem(target);

    for (results) |result| {
        _ = try acset.addPath(result, sys_id);
    }

    return acset;
}

// ============================================================================
// TESTS
// ============================================================================

test "complex arithmetic" {
    const a = Complex.init(1, 2);
    const b = Complex.init(3, 4);

    const sum = Complex.add(a, b);
    try std.testing.expectApproxEqAbs(@as(f64, 4), sum.re, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 6), sum.im, 1e-10);

    const prod = Complex.mul(a, b);
    // (1+2i)(3+4i) = 3 + 4i + 6i + 8i² = 3 + 10i - 8 = -5 + 10i
    try std.testing.expectApproxEqAbs(@as(f64, -5), prod.re, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 10), prod.im, 1e-10);
}

test "monomial evaluation" {
    const allocator = std.testing.allocator;

    // 2*x^2*y
    var exp = [_]u32{ 2, 1 };
    const mono = Monomial{
        .coeff = Complex.init(2, 0),
        .exponents = &exp,
    };

    const vars = [_]Complex{ Complex.init(3, 0), Complex.init(2, 0) }; // x=3, y=2
    const result = mono.evaluate(&vars);

    // 2 * 3^2 * 2 = 2 * 9 * 2 = 36
    try std.testing.expectApproxEqAbs(@as(f64, 36), result.re, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0), result.im, 1e-10);

    _ = allocator;
}

test "acset json export" {
    const allocator = std.testing.allocator;

    var acset = HomotopyACSet.init(allocator);
    defer acset.deinit();

    const sol1 = [_]Complex{ Complex.init(1, 0), Complex.init(0, 1) };
    _ = try acset.addSolution(&sol1);

    const json = try acset.toJson(allocator);
    defer allocator.free(json);

    // Check that it contains expected schema elements
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Ob\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Solution\"") != null);
}

test "complex division roundtrip" {
    const a = Complex.init(3, 4);
    const b = Complex.init(1, 2);

    // a / b * b ≈ a
    const quotient = Complex.div(a, b);
    const product = Complex.mul(quotient, b);
    try std.testing.expectApproxEqAbs(@as(f64, 3), product.re, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 4), product.im, 1e-10);
}

test "Euler identity: exp(i*pi) approx -1" {
    const i_pi = Complex.init(0, std.math.pi);
    const result = Complex.exp(i_pi);
    try std.testing.expectApproxEqAbs(@as(f64, -1.0), result.re, 1e-10);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.im, 1e-10);
}

test "polynomial degree calculation" {
    // p(x,y) = 3*x^2*y + 2*x*y^3 -> degree 4
    var exp1 = [_]u32{ 2, 1 };
    var exp2 = [_]u32{ 1, 3 };
    const monomials = [_]Monomial{
        .{ .coeff = Complex.init(3, 0), .exponents = &exp1 },
        .{ .coeff = Complex.init(2, 0), .exponents = &exp2 },
    };
    const poly = Polynomial{ .monomials = &monomials, .num_vars = 2 };
    try std.testing.expectEqual(@as(u32, 4), poly.degree());
}

test "monomial degree sum" {
    var exp = [_]u32{ 2, 3, 1 }; // x^2 * y^3 * z^1 = degree 6
    const mono = Monomial{ .coeff = Complex.one, .exponents = &exp };
    try std.testing.expectEqual(@as(u32, 6), mono.degree());
}

test "total degree start system generation" {
    const allocator = std.testing.allocator;

    // Target: x^2 - 1 (degree 2, 1 variable)
    var target_exp1 = [_]u32{2};
    var target_exp2 = [_]u32{0};
    const target_monos = [_]Monomial{
        .{ .coeff = Complex.one, .exponents = &target_exp1 },
        .{ .coeff = Complex.init(-1, 0), .exponents = &target_exp2 },
    };
    const target_poly = Polynomial{ .monomials = &target_monos, .num_vars = 1 };
    const target = PolynomialSystem{ .polynomials = &[_]Polynomial{target_poly}, .num_vars = 1 };

    const start = try totalDegreeStartSystem(target, allocator);

    // Start system should have same structure
    try std.testing.expectEqual(@as(usize, 1), start.polynomials.len);
    try std.testing.expectEqual(@as(u32, 2), start.polynomials[0].degree());

    // Clean up
    for (start.polynomials) |poly| {
        for (poly.monomials) |mono| {
            allocator.free(mono.exponents);
        }
        allocator.free(poly.monomials);
    }
    allocator.free(start.polynomials);
}

test "start solutions are roots of unity" {
    const allocator = std.testing.allocator;

    // System of degree 2 in 1 var -> 2 solutions (roots of x^2 - 1)
    var exp1 = [_]u32{2};
    var exp2 = [_]u32{0};
    const monos = [_]Monomial{
        .{ .coeff = Complex.one, .exponents = &exp1 },
        .{ .coeff = Complex.init(-1, 0), .exponents = &exp2 },
    };
    const poly = Polynomial{ .monomials = &monos, .num_vars = 1 };
    const system = PolynomialSystem{ .polynomials = &[_]Polynomial{poly}, .num_vars = 1 };

    const solutions = try totalDegreeStartSolutions(system, allocator);
    defer {
        for (solutions) |sol| allocator.free(sol);
        allocator.free(solutions);
    }

    try std.testing.expectEqual(@as(usize, 2), solutions.len);

    // Each solution should be a root of unity: |z| ≈ 1
    for (solutions) |sol| {
        const mag = Complex.abs(sol[0]);
        try std.testing.expectApproxEqAbs(@as(f64, 1.0), mag, 1e-10);
    }
}

test "PathStatus to Trit mapping" {
    try std.testing.expectEqual(continuation.Trit.plus, PathStatus.success.toTrit());
    try std.testing.expectEqual(continuation.Trit.zero, PathStatus.tracking.toTrit());
    try std.testing.expectEqual(continuation.Trit.minus, PathStatus.diverged.toTrit());
    try std.testing.expectEqual(continuation.Trit.minus, PathStatus.singular.toTrit());
    try std.testing.expectEqual(continuation.Trit.minus, PathStatus.min_step.toTrit());
}

test "HomotopyACSet syrup contains expected labels" {
    const allocator = std.testing.allocator;

    var acset = HomotopyACSet.init(allocator);
    defer acset.deinit();

    const sol = [_]Complex{Complex.init(1, 0)};
    _ = try acset.addSolution(&sol);

    const syrup_val = try acset.toSyrup(allocator);
    defer syrup_val.deinitContainers(allocator);
    // Should be a record with label "homotopy-acset"
    try std.testing.expectEqual(syrup.Value.record, std.meta.activeTag(syrup_val));
    const label = syrup_val.record.label.*;
    try std.testing.expectEqualStrings("homotopy-acset", label.symbol);
}
