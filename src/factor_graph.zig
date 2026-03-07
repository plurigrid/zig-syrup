//! Factor Graph Extension for Partial Information Decomposition (PID)
//!
//! Extends propagator.zig (Radul-Sussman pairwise propagators) with:
//! - FactorNode: connects K >= 2 cells via joint constraint functions
//! - Message passing: variable-to-factor and factor-to-variable (sum-product style)
//! - PID decomposition: redundant / unique / synergistic information per factor
//! - Synergy detection: when full K-input factor produces Value but no (K-1) subset can
//!
//! Reference: Thomas F. Varley, "Partial Information Decomposition of Neural Connectivity"
//! (PNAS 2023) — synergy lives in 3+ point interactions, requires factor graphs not
//! pairwise propagators.
//!
//! Lattice mapping:
//!   Nothing    = no information (unmeasured)
//!   Value      = redundant or unique information (at least one source informs)
//!   Contradiction = synergy detection point (different subsets disagree)
//!
//! The magenta phenomenon: synergy is the color with no wavelength — it exists
//! only when L-cones and S-cones fire together without M-cone activation.
//! No single source produces it; it emerges from the combination.

const std = @import("std");
const propagator = @import("propagator.zig");

const CellValue = propagator.CellValue;
const MergeFn = propagator.MergeFn;
const Cell = propagator.Cell;
const latticeMerge = propagator.latticeMerge;
const defaultMerge = propagator.defaultMerge;

// =============================================================================
// PID Decomposition
// =============================================================================

/// Partial Information Decomposition for a single factor.
/// Decomposes the information flowing through a K-input factor into:
///   redundancy: information ALL inputs share about the output
///   unique[i]:  information ONLY input i has about the output
///   synergy:    information that exists ONLY in the full combination
pub const PIDAtom = struct {
    redundancy: f32 = 0,
    unique: [max_factor_arity]f32 = [_]f32{0} ** max_factor_arity,
    synergy: f32 = 0,
    arity: u32 = 0,

    pub fn total(self: PIDAtom) f32 {
        var sum: f32 = self.redundancy + self.synergy;
        for (0..self.arity) |i| {
            sum += self.unique[i];
        }
        return sum;
    }

    pub fn synergyRatio(self: PIDAtom) f32 {
        const t = self.total();
        if (t == 0) return 0;
        return self.synergy / t;
    }
};

pub const max_factor_arity: u32 = 8;

// =============================================================================
// Message: belief passed between variable and factor
// =============================================================================

/// Message in sum-product belief propagation.
/// For f32 cells, a message is a distribution summary (mean + confidence).
pub const Message = struct {
    mean: f32 = 0,
    confidence: f32 = 0,

    pub fn uninformative() Message {
        return .{ .mean = 0, .confidence = 0 };
    }

    pub fn fromValue(v: f32) Message {
        return .{ .mean = v, .confidence = 1.0 };
    }

    pub fn combine(a: Message, b: Message) Message {
        const total_conf = a.confidence + b.confidence;
        if (total_conf == 0) return uninformative();
        return .{
            .mean = (a.mean * a.confidence + b.mean * b.confidence) / total_conf,
            .confidence = @min(total_conf, 1.0),
        };
    }

    pub fn divergence(a: Message, b: Message) f32 {
        const mean_diff = a.mean - b.mean;
        const conf_diff = a.confidence - b.confidence;
        return @sqrt(mean_diff * mean_diff + conf_diff * conf_diff);
    }
};

// =============================================================================
// Joint Function types
// =============================================================================

/// A joint function takes K cell values and returns a single output value.
/// Returns null if insufficient information to compute.
pub const JointFn = *const fn (inputs: []const CellValue(f32)) ?f32;

/// A marginal function: given K cell values and index i, returns the marginal
/// message from factor to variable i. Used in factor-to-variable message passing.
pub const MarginalFn = *const fn (inputs: []const CellValue(f32), target_idx: u32) Message;

// =============================================================================
// FactorNode: connects K cells with a joint constraint
// =============================================================================

pub const FactorNode = struct {
    const Self = @This();

    name: []const u8,
    variables: std.ArrayListUnmanaged(*Cell(f32, latticeMerge(f32))),
    joint_fn: JointFn,
    marginal_fn: ?MarginalFn,
    output: ?*Cell(f32, latticeMerge(f32)),
    allocator: std.mem.Allocator,

    // Message buffers: var_to_factor[i] = message from variable i to this factor
    var_to_factor: [max_factor_arity]Message = [_]Message{Message.uninformative()} ** max_factor_arity,
    // factor_to_var[i] = message from this factor to variable i
    factor_to_var: [max_factor_arity]Message = [_]Message{Message.uninformative()} ** max_factor_arity,

    // Cached PID decomposition
    pid: PIDAtom = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        joint_fn: JointFn,
        marginal_fn: ?MarginalFn,
        output: ?*Cell(f32, latticeMerge(f32)),
    ) Self {
        return .{
            .name = name,
            .variables = std.ArrayListUnmanaged(*Cell(f32, latticeMerge(f32))){},
            .joint_fn = joint_fn,
            .marginal_fn = marginal_fn,
            .output = output,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.variables.deinit(self.allocator);
    }

    pub fn addVariable(self: *Self, cell: *Cell(f32, latticeMerge(f32))) !void {
        try self.variables.append(self.allocator, cell);
        self.pid.arity = @intCast(self.variables.items.len);
    }

    pub fn arity(self: *const Self) u32 {
        return @intCast(self.variables.items.len);
    }

    /// Collect current cell values from all connected variables.
    fn gatherInputs(self: *const Self, buf: []CellValue(f32)) void {
        for (self.variables.items, 0..) |cell, i| {
            buf[i] = cell.get_cell_value();
        }
    }

    /// Run the joint function on all inputs. Write result to output cell if present.
    pub fn evaluate(self: *Self) !void {
        var inputs: [max_factor_arity]CellValue(f32) = undefined;
        self.gatherInputs(inputs[0..self.arity()]);

        if (self.joint_fn(inputs[0..self.arity()])) |result| {
            if (self.output) |out| {
                try out.set_content(result);
            }
        }
    }

    /// Update variable-to-factor messages from current cell states.
    pub fn updateVarToFactor(self: *Self) void {
        for (self.variables.items, 0..) |cell, i| {
            self.var_to_factor[i] = switch (cell.get_cell_value()) {
                .nothing => Message.uninformative(),
                .value => |v| Message.fromValue(v),
                .contradiction => Message{ .mean = 0, .confidence = 0 },
            };
        }
    }

    /// Update factor-to-variable messages using the marginal function.
    pub fn updateFactorToVar(self: *Self) void {
        if (self.marginal_fn) |mfn| {
            var inputs: [max_factor_arity]CellValue(f32) = undefined;
            self.gatherInputs(inputs[0..self.arity()]);

            for (0..self.arity()) |i| {
                self.factor_to_var[i] = mfn(inputs[0..self.arity()], @intCast(i));
            }
        }
    }

    /// Compute PID decomposition by evaluating subsets.
    /// Synergy = joint produces value but no (K-1) subset can.
    pub fn computePID(self: *Self) PIDAtom {
        const k = self.arity();
        if (k == 0) return .{};

        var inputs: [max_factor_arity]CellValue(f32) = undefined;
        self.gatherInputs(inputs[0..k]);

        // Full joint evaluation
        const full_result = self.joint_fn(inputs[0..k]);
        const full_has_value = full_result != null;

        // Evaluate each leave-one-out subset
        var subset_results: [max_factor_arity]bool = [_]bool{false} ** max_factor_arity;
        var any_subset_has_value = false;
        var all_subsets_have_value = true;
        var subset_values: [max_factor_arity]?f32 = [_]?f32{null} ** max_factor_arity;

        for (0..k) |leave_out| {
            // Create subset with one variable masked to Nothing
            var subset: [max_factor_arity]CellValue(f32) = undefined;
            for (0..k) |j| {
                subset[j] = if (j == leave_out)
                    CellValue(f32){ .nothing = {} }
                else
                    inputs[j];
            }
            subset_values[leave_out] = self.joint_fn(subset[0..k]);
            subset_results[leave_out] = subset_values[leave_out] != null;
            if (subset_results[leave_out]) {
                any_subset_has_value = true;
            } else {
                all_subsets_have_value = false;
            }
        }

        // Evaluate individual variables alone
        var individual_results: [max_factor_arity]bool = [_]bool{false} ** max_factor_arity;
        var individual_values: [max_factor_arity]?f32 = [_]?f32{null} ** max_factor_arity;

        for (0..k) |solo| {
            var solo_input: [max_factor_arity]CellValue(f32) = undefined;
            for (0..k) |j| {
                solo_input[j] = if (j == solo)
                    inputs[j]
                else
                    CellValue(f32){ .nothing = {} };
            }
            individual_values[solo] = self.joint_fn(solo_input[0..k]);
            individual_results[solo] = individual_values[solo] != null;
        }

        var pid = PIDAtom{ .arity = k };

        if (full_has_value) {
            if (!any_subset_has_value) {
                // No subset suffices => pure synergy
                pid.synergy = 1.0;
            } else if (all_subsets_have_value) {
                // All subsets produce SOME value => redundancy exists.
                // Qualitative redundancy: fraction of subsets that produce output.
                // This IS the defining property: any single source suffices.
                const k_f = @as(f32, @floatFromInt(k));
                var subsets_producing: f32 = 0;
                for (0..k) |i| {
                    if (subset_results[i]) subsets_producing += 1;
                }
                pid.redundancy = subsets_producing / k_f;

                // Unique[i] = quantitative difference when variable i is removed.
                // Normalized by full result magnitude to keep in [0,1].
                if (full_result) |fv| {
                    const fv_abs = @max(@abs(fv), 0.001);
                    for (0..k) |i| {
                        if (subset_values[i]) |sv| {
                            const diff = @abs(sv - fv) / fv_abs;
                            if (diff > 0.001) {
                                pid.unique[i] = @min(diff / k_f, 1.0 / k_f);
                            }
                        }
                    }
                }

                // Check if individuals alone can produce output (redundancy test)
                var individuals_producing: u32 = 0;
                for (0..k) |i| {
                    if (individual_results[i]) individuals_producing += 1;
                }
                // If individual variables alone can also produce output,
                // that reinforces redundancy. If not, some synergy is present.
                if (individuals_producing < k) {
                    // Not every variable alone suffices; partial synergy
                    const non_solo = @as(f32, @floatFromInt(k - individuals_producing));
                    pid.synergy = non_solo / k_f * 0.5;
                    pid.redundancy = @max(0, pid.redundancy - pid.synergy);
                }
            } else {
                // Mixed: some subsets work, some don't
                const k_f = @as(f32, @floatFromInt(k));
                var needed_count: u32 = 0;
                for (0..k) |i| {
                    if (!subset_results[i]) {
                        // Removing variable i breaks the computation => i is necessary
                        pid.unique[i] = 1.0 / k_f;
                        needed_count += 1;
                    }
                }
                if (needed_count >= 2) {
                    // Multiple variables are individually necessary => synergy
                    pid.synergy = @as(f32, @floatFromInt(needed_count)) / k_f;
                }
                // Whatever subsets do produce => partial redundancy
                if (any_subset_has_value) {
                    pid.redundancy = 1.0 - pid.synergy;
                    for (0..k) |i| {
                        pid.redundancy -= pid.unique[i];
                    }
                    pid.redundancy = @max(0, pid.redundancy);
                }
            }
        }

        self.pid = pid;
        return pid;
    }
};

// =============================================================================
// FactorGraph: collection of variables and factors with message passing
// =============================================================================

pub const FactorGraph = struct {
    const Self = @This();
    const LCell = Cell(f32, latticeMerge(f32));

    cells: std.ArrayListUnmanaged(*LCell),
    factors: std.ArrayListUnmanaged(*FactorNode),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .cells = std.ArrayListUnmanaged(*LCell){},
            .factors = std.ArrayListUnmanaged(*FactorNode){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.cells.deinit(self.allocator);
        self.factors.deinit(self.allocator);
    }

    pub fn addCell(self: *Self, cell: *LCell) !void {
        try self.cells.append(self.allocator, cell);
    }

    pub fn addFactor(self: *Self, factor: *FactorNode) !void {
        try self.factors.append(self.allocator, factor);
    }

    /// One round of belief propagation: update all messages.
    pub fn propagate(self: *Self) !void {
        // Variable → Factor messages
        for (self.factors.items) |factor| {
            factor.updateVarToFactor();
        }
        // Factor → Variable messages
        for (self.factors.items) |factor| {
            factor.updateFactorToVar();
        }
        // Evaluate all factor joint functions
        for (self.factors.items) |factor| {
            try factor.evaluate();
        }
    }

    /// Run belief propagation for N iterations or until convergence.
    pub fn propagateUntilConvergence(self: *Self, max_iters: u32, tolerance: f32) !u32 {
        var iter: u32 = 0;
        while (iter < max_iters) : (iter += 1) {
            // Snapshot current messages
            var max_delta: f32 = 0;

            try self.propagate();

            // Check convergence via message change
            for (self.factors.items) |factor| {
                for (0..factor.arity()) |i| {
                    const old = factor.var_to_factor[i];
                    const cur_cell = factor.variables.items[i];
                    const new_msg: Message = switch (cur_cell.get_cell_value()) {
                        .nothing => Message.uninformative(),
                        .value => |v| Message.fromValue(v),
                        .contradiction => Message{ .mean = 0, .confidence = 0 },
                    };
                    const delta = Message.divergence(old, new_msg);
                    if (delta > max_delta) max_delta = delta;
                }
            }

            if (max_delta < tolerance) break;
        }
        return iter;
    }

    /// Compute PID for all factors, return total synergy across the graph.
    pub fn computeAllPID(self: *Self) f32 {
        var total_synergy: f32 = 0;
        for (self.factors.items) |factor| {
            const pid = factor.computePID();
            total_synergy += pid.synergy;
        }
        return total_synergy;
    }

    /// Detect factors with synergy above threshold (the "magenta detectors").
    pub fn detectSynergy(self: *Self, threshold: f32) !std.ArrayListUnmanaged(*FactorNode) {
        var synergistic = std.ArrayListUnmanaged(*FactorNode){};
        for (self.factors.items) |factor| {
            const pid = factor.computePID();
            if (pid.synergy >= threshold) {
                try synergistic.append(self.allocator, factor);
            }
        }
        return synergistic;
    }
};

// =============================================================================
// Built-in Joint Functions
// =============================================================================

/// AND gate: requires ALL inputs to have values. Returns their product.
/// Pure synergy when K >= 3: removing any input yields Nothing.
pub fn jointAnd(inputs: []const CellValue(f32)) ?f32 {
    var product: f32 = 1.0;
    for (inputs) |inp| {
        switch (inp) {
            .value => |v| product *= v,
            else => return null,
        }
    }
    return product;
}

/// OR gate: requires ANY input to have a value. Returns their sum.
/// Pure redundancy: any single input suffices.
pub fn jointOr(inputs: []const CellValue(f32)) ?f32 {
    var sum: f32 = 0;
    var any_value = false;
    for (inputs) |inp| {
        switch (inp) {
            .value => |v| {
                sum += v;
                any_value = true;
            },
            else => {},
        }
    }
    return if (any_value) sum else null;
}

/// XOR gate: requires ALL inputs, returns 1 if odd number are > 0.5.
/// Classic synergy: no single input reveals the output.
pub fn jointXor(inputs: []const CellValue(f32)) ?f32 {
    var count_high: u32 = 0;
    for (inputs) |inp| {
        switch (inp) {
            .value => |v| {
                if (v > 0.5) count_high += 1;
            },
            else => return null,
        }
    }
    return if (count_high % 2 == 1) @as(f32, 1.0) else @as(f32, 0.0);
}

/// Threshold gate: fires (returns 1.0) only when the mean of ALL inputs
/// exceeds a threshold. Partial synergy: individual inputs contribute
/// but the threshold crossing requires their combination.
pub fn jointThreshold(inputs: []const CellValue(f32)) ?f32 {
    var sum: f32 = 0;
    var count: u32 = 0;
    for (inputs) |inp| {
        switch (inp) {
            .value => |v| {
                sum += v;
                count += 1;
            },
            else => return null,
        }
    }
    if (count == 0) return null;
    const mean = sum / @as(f32, @floatFromInt(count));
    return if (mean > 0.5) @as(f32, 1.0) else @as(f32, 0.0);
}

/// Magenta detector: fires when inputs[0] (L-cone/red) and inputs[2] (S-cone/blue)
/// are high but inputs[1] (M-cone/green) is low. The synesthetic factor.
pub fn jointMagenta(inputs: []const CellValue(f32)) ?f32 {
    if (inputs.len < 3) return null;
    const l_cone = switch (inputs[0]) {
        .value => |v| v,
        else => return null,
    };
    const m_cone = switch (inputs[1]) {
        .value => |v| v,
        else => return null,
    };
    const s_cone = switch (inputs[2]) {
        .value => |v| v,
        else => return null,
    };
    // Magenta = L-cone high + S-cone high + M-cone low
    if (l_cone > 0.5 and s_cone > 0.5 and m_cone < 0.3) {
        return 1.0;
    }
    return 0.0;
}

/// Average marginal: factor-to-variable message is the average of all OTHER variables.
pub fn averageMarginal(inputs: []const CellValue(f32), target_idx: u32) Message {
    var sum: f32 = 0;
    var count: u32 = 0;
    for (inputs, 0..) |inp, i| {
        if (i == target_idx) continue;
        switch (inp) {
            .value => |v| {
                sum += v;
                count += 1;
            },
            else => {},
        }
    }
    if (count == 0) return Message.uninformative();
    return Message.fromValue(sum / @as(f32, @floatFromInt(count)));
}

// =============================================================================
// GF(3) Trit Integration
// =============================================================================

/// Map PID decomposition to GF(3) trit.
///   synergy-dominant  => PLUS  (+1) — generative, emergent
///   redundancy-dominant => MINUS (-1) — compressive, shared
///   unique-dominant   => ERGODIC (0) — individual, conserved
pub fn pidToTrit(pid: PIDAtom) i2 {
    var max_unique: f32 = 0;
    for (0..pid.arity) |i| {
        if (pid.unique[i] > max_unique) max_unique = pid.unique[i];
    }
    if (pid.synergy >= pid.redundancy and pid.synergy >= max_unique) return 1; // PLUS
    if (pid.redundancy >= pid.synergy and pid.redundancy >= max_unique) return -1; // MINUS
    return 0; // ERGODIC
}

// =============================================================================
// Tests
// =============================================================================

test "PIDAtom total and ratio" {
    var pid = PIDAtom{ .arity = 3 };
    pid.redundancy = 0.3;
    pid.unique[0] = 0.1;
    pid.unique[1] = 0.1;
    pid.unique[2] = 0.1;
    pid.synergy = 0.4;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), pid.total(), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), pid.synergyRatio(), 0.001);
}

test "Message combine weighted average" {
    const a = Message.fromValue(1.0);
    const b = Message.fromValue(3.0);
    const c = Message.combine(a, b);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), c.mean, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), c.confidence, 0.001);
}

test "Message divergence" {
    const a = Message.fromValue(0.0);
    const b = Message.fromValue(1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), Message.divergence(a, b), 0.001);
}

test "jointAnd pure synergy" {
    const allocator = std.testing.allocator;
    const LCell = Cell(f32, latticeMerge(f32));

    var c1 = LCell.init(allocator, "x1");
    defer c1.deinit();
    var c2 = LCell.init(allocator, "x2");
    defer c2.deinit();
    var c3 = LCell.init(allocator, "x3");
    defer c3.deinit();
    var out = LCell.init(allocator, "out");
    defer out.deinit();

    var factor = FactorNode.init(allocator, "and3", jointAnd, averageMarginal, &out);
    defer factor.deinit();
    try factor.addVariable(&c1);
    try factor.addVariable(&c2);
    try factor.addVariable(&c3);

    // All inputs set => AND fires
    try c1.set_content(0.8);
    try c2.set_content(0.9);
    try c3.set_content(0.7);
    try factor.evaluate();
    try std.testing.expectApproxEqAbs(@as(f32, 0.504), out.get_content().?, 0.001);

    // PID: AND requires all inputs => synergy
    const pid = factor.computePID();
    try std.testing.expect(pid.synergy > 0);
}

test "jointOr pure redundancy" {
    const allocator = std.testing.allocator;
    const LCell = Cell(f32, latticeMerge(f32));

    var c1 = LCell.init(allocator, "x1");
    defer c1.deinit();
    var c2 = LCell.init(allocator, "x2");
    defer c2.deinit();

    var factor = FactorNode.init(allocator, "or2", jointOr, null, null);
    defer factor.deinit();
    try factor.addVariable(&c1);
    try factor.addVariable(&c2);

    try c1.set_content(1.0);
    try c2.set_content(2.0);

    // PID: OR works with any single input => redundancy
    const pid = factor.computePID();
    try std.testing.expect(pid.redundancy > 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0), pid.synergy, 0.001);
}

test "jointXor classic synergy" {
    const allocator = std.testing.allocator;
    const LCell = Cell(f32, latticeMerge(f32));

    var c1 = LCell.init(allocator, "bit1");
    defer c1.deinit();
    var c2 = LCell.init(allocator, "bit2");
    defer c2.deinit();
    var out = LCell.init(allocator, "xor_out");
    defer out.deinit();

    var factor = FactorNode.init(allocator, "xor", jointXor, null, &out);
    defer factor.deinit();
    try factor.addVariable(&c1);
    try factor.addVariable(&c2);

    try c1.set_content(0.8);
    try c2.set_content(0.3);
    try factor.evaluate();
    // 0.8 > 0.5, 0.3 <= 0.5 => 1 high => odd => 1.0
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out.get_content().?, 0.001);

    // XOR is the canonical synergy: removing either input makes output unpredictable
    const pid = factor.computePID();
    try std.testing.expect(pid.synergy > 0);
}

test "jointMagenta cone detector" {
    const allocator = std.testing.allocator;
    const LCell = Cell(f32, latticeMerge(f32));

    var l_cone = LCell.init(allocator, "L_cone");
    defer l_cone.deinit();
    var m_cone = LCell.init(allocator, "M_cone");
    defer m_cone.deinit();
    var s_cone = LCell.init(allocator, "S_cone");
    defer s_cone.deinit();
    var out = LCell.init(allocator, "magenta_out");
    defer out.deinit();

    var factor = FactorNode.init(allocator, "magenta", jointMagenta, null, &out);
    defer factor.deinit();
    try factor.addVariable(&l_cone);
    try factor.addVariable(&m_cone);
    try factor.addVariable(&s_cone);

    // Magenta: L high, M low, S high
    try l_cone.set_content(0.9);
    try m_cone.set_content(0.1);
    try s_cone.set_content(0.8);
    try factor.evaluate();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), out.get_content().?, 0.001);

    // PID should show synergy (requires all 3 cones in specific pattern)
    const pid = factor.computePID();
    try std.testing.expect(pid.synergy > 0);
}

test "pidToTrit mapping" {
    var synergistic = PIDAtom{ .arity = 2 };
    synergistic.synergy = 0.8;
    synergistic.redundancy = 0.1;
    try std.testing.expectEqual(@as(i2, 1), pidToTrit(synergistic));

    var redundant = PIDAtom{ .arity = 2 };
    redundant.redundancy = 0.8;
    redundant.synergy = 0.1;
    try std.testing.expectEqual(@as(i2, -1), pidToTrit(redundant));

    var unique_dom = PIDAtom{ .arity = 2 };
    unique_dom.unique[0] = 0.8;
    unique_dom.synergy = 0.1;
    unique_dom.redundancy = 0.1;
    try std.testing.expectEqual(@as(i2, 0), pidToTrit(unique_dom));
}

test "FactorGraph synergy detection" {
    const allocator = std.testing.allocator;
    const LCell = Cell(f32, latticeMerge(f32));

    // Build a small graph: 3 variables, 1 AND factor (synergistic), 1 OR factor (redundant)
    var c1 = LCell.init(allocator, "v1");
    defer c1.deinit();
    var c2 = LCell.init(allocator, "v2");
    defer c2.deinit();
    var c3 = LCell.init(allocator, "v3");
    defer c3.deinit();

    var and_factor = FactorNode.init(allocator, "and", jointAnd, null, null);
    defer and_factor.deinit();
    try and_factor.addVariable(&c1);
    try and_factor.addVariable(&c2);
    try and_factor.addVariable(&c3);

    var or_factor = FactorNode.init(allocator, "or", jointOr, null, null);
    defer or_factor.deinit();
    try or_factor.addVariable(&c1);
    try or_factor.addVariable(&c2);

    var graph = FactorGraph.init(allocator);
    defer graph.deinit();
    try graph.addCell(&c1);
    try graph.addCell(&c2);
    try graph.addCell(&c3);
    try graph.addFactor(&and_factor);
    try graph.addFactor(&or_factor);

    try c1.set_content(0.8);
    try c2.set_content(0.9);
    try c3.set_content(0.7);

    const total_synergy = graph.computeAllPID();
    try std.testing.expect(total_synergy > 0);

    // AND should be flagged as synergistic, OR should not
    var synergistic = try graph.detectSynergy(0.5);
    defer synergistic.deinit(allocator);

    var found_and = false;
    for (synergistic.items) |f| {
        if (std.mem.eql(u8, f.name, "and")) found_and = true;
    }
    try std.testing.expect(found_and);
}
