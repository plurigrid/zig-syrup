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
const syrup = @import("syrup.zig");
const continuation = @import("continuation.zig");
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
        const entries = try allocator.alloc(syrup.DictEntry, 2);
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

        const entries = try allocator.alloc(syrup.DictEntry, 2);
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

        const entries = try allocator.alloc(syrup.DictEntry, 2);
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

    pub fn toSyrup(self: PolynomialSystem, allocator: Allocator) !syrup.Value {
        var poly_values = try allocator.alloc(syrup.Value, self.polynomials.len);
        for (self.polynomials, 0..) |poly, idx| {
            poly_values[idx] = try poly.toSyrup(allocator);
        }

        const entries = try allocator.alloc(syrup.DictEntry, 2);
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
        const entries = try allocator.alloc(syrup.DictEntry, 3);
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

        const entries = try allocator.alloc(syrup.DictEntry, 5);
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

            // Predictor step (Euler)
            const dt = @min(step_size, 1.0 - t);
            var predicted = try self.allocator.alloc(Complex, current.len);
            defer self.allocator.free(predicted);

            // Simple Euler prediction: x(t+dt) ≈ x(t) + dt * dx/dt
            // For now, just step forward (full implementation needs Jacobian)
            for (current, 0..) |c, idx| {
                // Simplified: perturb slightly in direction of solution
                predicted[idx] = Complex.add(c, Complex.scale(Complex.init(0.01, 0.01), dt));
            }

            // Corrector step (Newton iteration)
            const corrected = try self.allocator.alloc(Complex, current.len);
            defer self.allocator.free(corrected);
            @memcpy(corrected, predicted);

            const newton_success = try self.newtonCorrector(corrected, t + dt);
            if (!newton_success) {
                // Reduce step size and retry
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

            // Adaptive step size
            step_size = @min(step_size * 1.2, self.config.max_step_size);
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

    /// Newton corrector iteration
    fn newtonCorrector(self: *PathTracker, x: []Complex, t: f64) !bool {
        const max_iters = 10;
        var iter: usize = 0;

        while (iter < max_iters) : (iter += 1) {
            const h_val = try self.homotopy.evaluate(x, t, self.allocator);
            defer self.allocator.free(h_val);

            // Check convergence
            var norm: f64 = 0;
            for (h_val) |h| {
                norm += Complex.abs(h) * Complex.abs(h);
            }
            norm = @sqrt(norm);

            if (norm < self.config.tolerance) {
                return true;
            }

            // Simplified Newton step (would need Jacobian for full implementation)
            for (x, h_val) |*xi, hi| {
                // x_new = x - J^(-1) * H(x)
                // Simplified: just subtract a small multiple of H
                xi.* = Complex.sub(xi.*, Complex.scale(hi, 0.1));
            }
        }

        return false;
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
    solutions: std.ArrayList(SolutionRow),
    paths: std.ArrayList(PathRow),
    systems: std.ArrayList(SystemRow),

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
            .solutions = std.ArrayList(SolutionRow).init(allocator),
            .paths = std.ArrayList(PathRow).init(allocator),
            .systems = std.ArrayList(SystemRow).init(allocator),
        };
    }

    pub fn deinit(self: *HomotopyACSet) void {
        self.solutions.deinit();
        self.paths.deinit();
        self.systems.deinit();
    }

    /// Add a solution and return its ID
    pub fn addSolution(self: *HomotopyACSet, values: []const Complex) !usize {
        const id = self.solutions.items.len + 1;
        try self.solutions.append(.{ ._id = id, .values = values });
        return id;
    }

    /// Add a system and return its ID
    pub fn addSystem(self: *HomotopyACSet, sys: PolynomialSystem) !usize {
        const id = self.systems.items.len + 1;
        var degrees = try self.allocator.alloc(u32, sys.polynomials.len);
        for (sys.polynomials, 0..) |poly, idx| {
            degrees[idx] = poly.degree();
        }
        try self.systems.append(.{
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
        try self.paths.append(.{
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
        var buf = std.ArrayList(u8).init(allocator);
        const writer = buf.writer();

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

        return buf.toOwnedSlice();
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
            const entries = try allocator.alloc(syrup.DictEntry, 2);
            entries[0] = .{ .key = syrup.Value{ .symbol = "_id" }, .value = syrup.Value{ .integer = @intCast(sol._id) } };
            entries[1] = .{ .key = syrup.Value{ .symbol = "values" }, .value = syrup.Value{ .list = vals } };
            sol_list[idx] = syrup.Value{ .dictionary = entries };
        }

        // Build paths list
        var path_list = try allocator.alloc(syrup.Value, self.paths.items.len);
        for (self.paths.items, 0..) |path, idx| {
            const entries = try allocator.alloc(syrup.DictEntry, 6);
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
