//! Continuation System for zig-syrup
//!
//! Implements resumable computation pipelines with Syrup serialization.
//! Bridges OCapN promise pipelining with AGM-style belief revision.
//!
//! Key concepts:
//! - ContinuationState: Serializable snapshot of computation progress
//! - Pipeline: Sequence of steps that can be paused/resumed
//! - Grove Spheres: Possible worlds for belief revision (branch-like)
//!
//! Reference: bafishka/src/continuation_engine.clj

const std = @import("std");
const syrup = @import("syrup");
const Allocator = std.mem.Allocator;

// ============================================================================
// CONTINUATION TYPES
// ============================================================================

/// Unique identifier for a continuation
pub const ContinuationId = struct {
    prefix: []const u8 = "cont",
    uuid: u128,

    pub fn generate() ContinuationId {
        var buf: [16]u8 = undefined;
        std.crypto.random.bytes(&buf);
        return .{ .uuid = std.mem.readInt(u128, &buf, .little) };
    }

    pub fn toString(self: ContinuationId, allocator: Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}-{x}", .{ self.prefix, self.uuid });
    }

    pub fn toSyrup(self: ContinuationId, allocator: Allocator) !syrup.Value {
        const str = try self.toString(allocator);
        return syrup.Value{ .string = str };
    }
};

/// Status of a continuation
pub const ContinuationStatus = enum {
    initialized,
    running,
    paused,
    completed,
    failed,

    pub fn toSyrup(self: ContinuationStatus) syrup.Value {
        return syrup.Value{ .symbol = @tagName(self) };
    }

    pub fn fromSymbol(s: []const u8) ?ContinuationStatus {
        return std.meta.stringToEnum(ContinuationStatus, s);
    }
};

/// GF(3) trit for balanced ternary logic
pub const Trit = enum(i8) {
    minus = -1,
    zero = 0,
    plus = 1,

    pub fn fromInt(i: i8) ?Trit {
        return switch (i) {
            -1 => .minus,
            0 => .zero,
            1 => .plus,
            else => null,
        };
    }

    pub fn toSyrup(self: Trit) syrup.Value {
        return switch (self) {
            .minus => syrup.Value{ .symbol = "-" },
            .zero => syrup.Value{ .symbol = "0" },
            .plus => syrup.Value{ .symbol = "+" },
        };
    }

    /// GF(3) addition
    pub fn add(a: Trit, b: Trit) Trit {
        const sum = @as(i8, @intFromEnum(a)) + @as(i8, @intFromEnum(b));
        return switch (@mod(sum + 3, 3)) {
            0 => .zero,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }

    /// GF(3) negation
    pub fn neg(self: Trit) Trit {
        return switch (self) {
            .minus => .plus,
            .zero => .zero,
            .plus => .minus,
        };
    }
};

/// A single step in a continuation pipeline
pub const Step = struct {
    name: []const u8,
    trit: Trit = .zero, // GF(3) classification: creation(+), ergodic(0), verification(-)
    state: ?syrup.Value = null,
    result: ?syrup.Value = null,
    error_msg: ?[]const u8 = null,

    pub fn toSyrup(self: Step, allocator: Allocator) !syrup.Value {
        var entries = std.ArrayListUnmanaged(syrup.Value.DictEntry){};
        defer entries.deinit(allocator);

        try entries.append(allocator, .{
            .key = syrup.Value{ .symbol = "name" },
            .value = syrup.Value{ .string = self.name },
        });
        try entries.append(allocator, .{
            .key = syrup.Value{ .symbol = "trit" },
            .value = self.trit.toSyrup(),
        });

        if (self.state) |s| {
            try entries.append(allocator, .{
                .key = syrup.Value{ .symbol = "state" },
                .value = s,
            });
        }
        if (self.result) |r| {
            try entries.append(allocator, .{
                .key = syrup.Value{ .symbol = "result" },
                .value = r,
            });
        }
        if (self.error_msg) |e| {
            try entries.append(allocator, .{
                .key = syrup.Value{ .symbol = "error" },
                .value = syrup.Value{ .string = e },
            });
        }

        return syrup.Value{ .dictionary = try entries.toOwnedSlice(allocator) };
    }
};

/// Serializable continuation state
pub const ContinuationState = struct {
    id: ContinuationId,
    steps: []const Step,
    current_step: usize = 0,
    status: ContinuationStatus = .initialized,
    metadata: ?syrup.Value = null,
    created_at: i64,
    updated_at: i64,

    /// Create a new continuation state
    pub fn init(allocator: Allocator, steps: []const Step) !ContinuationState {
        const now = std.time.timestamp();
        _ = allocator;
        return .{
            .id = ContinuationId.generate(),
            .steps = steps,
            .current_step = 0,
            .status = .initialized,
            .created_at = now,
            .updated_at = now,
        };
    }

    /// Serialize to Syrup record: <cont id steps current status metadata>
    pub fn toSyrup(self: ContinuationState, allocator: Allocator) !syrup.Value {
        var step_values = std.ArrayListUnmanaged(syrup.Value){};
        defer step_values.deinit(allocator);

        for (self.steps) |step| {
            try step_values.append(allocator, try step.toSyrup(allocator));
        }

        const fields = try allocator.alloc(syrup.Value, 6);
        fields[0] = try self.id.toSyrup(allocator);
        fields[1] = syrup.Value{ .list = try step_values.toOwnedSlice(allocator) };
        fields[2] = syrup.Value{ .integer = @intCast(self.current_step) };
        fields[3] = self.status.toSyrup();
        fields[4] = self.metadata orelse syrup.Value{ .null = {} };
        fields[5] = syrup.Value{ .integer = self.updated_at };

        const label = try allocator.create(syrup.Value);
        label.* = syrup.Value{ .symbol = "continuation" };

        return syrup.Value{ .record = .{ .label = label, .fields = fields } };
    }

    /// Check if continuation is resumable
    pub fn isResumable(self: ContinuationState) bool {
        return self.status == .paused or self.status == .initialized;
    }

    /// Check if all steps completed
    pub fn isComplete(self: ContinuationState) bool {
        return self.current_step >= self.steps.len;
    }
};

// ============================================================================
// GROVE SPHERES (Possible Worlds for Belief Revision)
// ============================================================================

/// A belief in the AGM sense - represented as a Syrup symbol
pub const Belief = struct {
    proposition: []const u8,
    entrenchment: i64 = 0, // Higher = more entrenched

    pub fn toSyrup(self: Belief) syrup.Value {
        return syrup.Value{ .symbol = self.proposition };
    }

    pub fn negate(self: Belief, allocator: Allocator) !Belief {
        const negated = if (std.mem.startsWith(u8, self.proposition, "not-"))
            self.proposition[4..]
        else
            try std.fmt.allocPrint(allocator, "not-{s}", .{self.proposition});
        return .{ .proposition = negated, .entrenchment = self.entrenchment };
    }
};

/// A belief set (possible world) with GF(3) trit classification
pub const BeliefSet = struct {
    beliefs: std.StringHashMap(Belief),
    trit: Trit = .zero,
    allocator: Allocator,

    pub fn init(allocator: Allocator) BeliefSet {
        return .{
            .beliefs = std.StringHashMap(Belief).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BeliefSet) void {
        self.beliefs.deinit();
    }

    /// AGM Expansion: K + p (add belief without consistency check)
    pub fn expand(self: *BeliefSet, belief: Belief) !void {
        try self.beliefs.put(belief.proposition, belief);
    }

    /// AGM Contraction: K - p (remove belief)
    pub fn contract(self: *BeliefSet, proposition: []const u8) void {
        _ = self.beliefs.remove(proposition);
        // Also remove negation
        if (std.mem.startsWith(u8, proposition, "not-")) {
            _ = self.beliefs.remove(proposition[4..]);
        } else {
            var buf: [256]u8 = undefined;
            const negated = std.fmt.bufPrint(&buf, "not-{s}", .{proposition}) catch return;
            _ = self.beliefs.remove(negated);
        }
    }

    /// AGM Revision: K * p (Levi identity: (K - ¬p) + p)
    pub fn revise(self: *BeliefSet, belief: Belief) !void {
        const negated = try belief.negate(self.allocator);
        defer if (!std.mem.startsWith(u8, belief.proposition, "not-"))
            self.allocator.free(negated.proposition);
        self.contract(negated.proposition);
        try self.expand(belief);
    }

    /// Check if belief set entails proposition
    pub fn entails(self: BeliefSet, proposition: []const u8) bool {
        return self.beliefs.contains(proposition);
    }

    /// Check consistency (no p and ¬p both present)
    pub fn isConsistent(self: BeliefSet) bool {
        var iter = self.beliefs.keyIterator();
        while (iter.next()) |key| {
            if (std.mem.startsWith(u8, key.*, "not-")) {
                const base = key.*[4..];
                if (self.beliefs.contains(base)) return false;
            } else {
                var buf: [256]u8 = undefined;
                const negated = std.fmt.bufPrint(&buf, "not-{s}", .{key.*}) catch continue;
                if (self.beliefs.contains(negated)) return false;
            }
        }
        return true;
    }

    /// Convert to Syrup set
    pub fn toSyrup(self: BeliefSet, allocator: Allocator) !syrup.Value {
        var values = std.ArrayListUnmanaged(syrup.Value){};
        defer values.deinit(allocator);

        var iter = self.beliefs.valueIterator();
        while (iter.next()) |belief| {
            try values.append(allocator, belief.toSyrup());
        }

        return syrup.Value{ .set = try values.toOwnedSlice(allocator) };
    }
};

/// Grove sphere system - ordered collection of possible worlds
pub const GroveSpheres = struct {
    worlds: std.ArrayListUnmanaged(BeliefSet),
    allocator: Allocator,

    pub fn init(allocator: Allocator) GroveSpheres {
        return .{
            .worlds = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GroveSpheres) void {
        for (self.worlds.items) |*world| {
            world.deinit();
        }
        self.worlds.deinit(self.allocator);
    }

    /// Add a new possible world (branch)
    pub fn addWorld(self: *GroveSpheres, world: BeliefSet) !void {
        try self.worlds.append(self.allocator, world);
    }

    /// Get the actual world (innermost sphere)
    pub fn actualWorld(self: GroveSpheres) ?*BeliefSet {
        if (self.worlds.items.len == 0) return null;
        return &self.worlds.items[0];
    }

    /// Serialize to Syrup list of sets
    pub fn toSyrup(self: GroveSpheres, allocator: Allocator) !syrup.Value {
        var values = std.ArrayListUnmanaged(syrup.Value){};
        defer values.deinit(allocator);

        for (self.worlds.items) |world| {
            try values.append(allocator, try world.toSyrup(allocator));
        }

        return syrup.Value{ .list = try values.toOwnedSlice(allocator) };
    }
};

// ============================================================================
// CONTINUATION PIPELINE EXECUTOR
// ============================================================================

/// Step function type: takes state, returns result or error
pub const StepFn = *const fn (state: syrup.Value, allocator: Allocator) StepResult;

pub const StepResult = union(enum) {
    success: syrup.Value,
    failure: []const u8,
    yield: syrup.Value, // Pause and return intermediate state
};

/// Pipeline executor with resumable semantics
pub const Pipeline = struct {
    state: ContinuationState,
    step_fns: []const StepFn,
    allocator: Allocator,

    pub fn init(allocator: Allocator, steps: []const Step, step_fns: []const StepFn) !Pipeline {
        return .{
            .state = try ContinuationState.init(allocator, steps),
            .step_fns = step_fns,
            .allocator = allocator,
        };
    }

    /// Execute one step, returning updated state
    pub fn step(self: *Pipeline, input: syrup.Value) StepResult {
        if (self.state.isComplete()) {
            return .{ .success = input };
        }

        const step_fn = self.step_fns[self.state.current_step];
        const result = step_fn(input, self.allocator);

        switch (result) {
            .success => {
                self.state.current_step += 1;
                self.state.updated_at = std.time.timestamp();
                if (self.state.isComplete()) {
                    self.state.status = .completed;
                }
            },
            .failure => {
                self.state.status = .failed;
            },
            .yield => {
                self.state.status = .paused;
            },
        }

        return result;
    }

    /// Run all steps to completion or first yield/failure
    pub fn run(self: *Pipeline, initial: syrup.Value) StepResult {
        self.state.status = .running;
        var current = initial;

        while (!self.state.isComplete()) {
            const result = self.step(current);
            switch (result) {
                .success => |v| current = v,
                .failure, .yield => return result,
            }
        }

        return .{ .success = current };
    }

    /// Resume from paused state
    pub fn @"resume"(self: *Pipeline, input: syrup.Value) StepResult {
        if (!self.state.isResumable()) {
            return .{ .failure = "continuation not resumable" };
        }
        return self.run(input);
    }
};

// ============================================================================
// TESTS
// ============================================================================

test "trit arithmetic" {
    const t = std.testing;

    // GF(3) addition table
    try t.expectEqual(Trit.zero, Trit.add(.zero, .zero));
    try t.expectEqual(Trit.plus, Trit.add(.zero, .plus));
    try t.expectEqual(Trit.minus, Trit.add(.zero, .minus));
    try t.expectEqual(Trit.minus, Trit.add(.plus, .plus)); // 1+1 = 2 ≡ -1 (mod 3)
    try t.expectEqual(Trit.zero, Trit.add(.plus, .minus)); // 1+(-1) = 0
    try t.expectEqual(Trit.plus, Trit.add(.minus, .minus)); // -1+(-1) = -2 ≡ 1 (mod 3)

    // Negation
    try t.expectEqual(Trit.minus, Trit.neg(.plus));
    try t.expectEqual(Trit.plus, Trit.neg(.minus));
    try t.expectEqual(Trit.zero, Trit.neg(.zero));
}

test "belief set operations" {
    const allocator = std.testing.allocator;

    var bs = BeliefSet.init(allocator);
    defer bs.deinit();

    // Expansion
    try bs.expand(.{ .proposition = "vm-running" });
    try bs.expand(.{ .proposition = "network-connected" });
    try std.testing.expect(bs.entails("vm-running"));
    try std.testing.expect(bs.isConsistent());

    // Contraction
    bs.contract("vm-running");
    try std.testing.expect(!bs.entails("vm-running"));

    // Revision (adds belief, removes negation)
    try bs.revise(.{ .proposition = "not-vm-running" });
    try std.testing.expect(bs.entails("not-vm-running"));
    try std.testing.expect(bs.isConsistent());
}

test "continuation state serialization" {
    const allocator = std.testing.allocator;

    const steps = [_]Step{
        .{ .name = "init", .trit = .plus },
        .{ .name = "process", .trit = .zero },
        .{ .name = "verify", .trit = .minus },
    };

    var state = try ContinuationState.init(allocator, &steps);
    const syrup_val = try state.toSyrup(allocator);
    defer {
        // Free the allocPrint'd id string in fields[0]
        allocator.free(syrup_val.record.fields[0].string);
        syrup_val.deinitContainers(allocator);
    }

    // Should be a record with label "continuation"
    try std.testing.expectEqual(syrup.Value.record, std.meta.activeTag(syrup_val));
    const label = syrup_val.record.label.*;
    try std.testing.expectEqualStrings("continuation", label.symbol);
}

test "full GF(3) addition table" {
    const t = std.testing;

    // All 9 combinations
    try t.expectEqual(Trit.zero, Trit.add(.zero, .zero));
    try t.expectEqual(Trit.plus, Trit.add(.zero, .plus));
    try t.expectEqual(Trit.minus, Trit.add(.zero, .minus));
    try t.expectEqual(Trit.plus, Trit.add(.plus, .zero));
    try t.expectEqual(Trit.minus, Trit.add(.plus, .plus));
    try t.expectEqual(Trit.zero, Trit.add(.plus, .minus));
    try t.expectEqual(Trit.minus, Trit.add(.minus, .zero));
    try t.expectEqual(Trit.zero, Trit.add(.minus, .plus));
    try t.expectEqual(Trit.plus, Trit.add(.minus, .minus));
}

test "trit double negation" {
    try std.testing.expectEqual(Trit.plus, Trit.neg(Trit.neg(.plus)));
    try std.testing.expectEqual(Trit.minus, Trit.neg(Trit.neg(.minus)));
    try std.testing.expectEqual(Trit.zero, Trit.neg(Trit.neg(.zero)));
}

test "belief revision entails revised proposition" {
    const allocator = std.testing.allocator;
    var bs = BeliefSet.init(allocator);
    defer bs.deinit();

    try bs.revise(.{ .proposition = "raining" });
    try std.testing.expect(bs.entails("raining"));
}

test "belief contraction removes proposition" {
    const allocator = std.testing.allocator;
    var bs = BeliefSet.init(allocator);
    defer bs.deinit();

    try bs.expand(.{ .proposition = "sunny" });
    try std.testing.expect(bs.entails("sunny"));

    bs.contract("sunny");
    try std.testing.expect(!bs.entails("sunny"));
}

test "belief consistency after revision" {
    const allocator = std.testing.allocator;
    var bs = BeliefSet.init(allocator);
    defer bs.deinit();

    // Add p
    try bs.revise(.{ .proposition = "alive" });
    try std.testing.expect(bs.isConsistent());

    // Revise with not-p (should remove p, add not-p)
    try bs.revise(.{ .proposition = "not-alive" });
    try std.testing.expect(bs.isConsistent());
    try std.testing.expect(bs.entails("not-alive"));
    try std.testing.expect(!bs.entails("alive"));
}

test "pipeline step execution with yield" {
    const allocator = std.testing.allocator;

    const step_fn = struct {
        fn execute(_: syrup.Value, _: Allocator) StepResult {
            return .{ .yield = syrup.Value{ .symbol = "paused-state" } };
        }
    }.execute;

    const steps = [_]Step{
        .{ .name = "step1", .trit = .plus },
    };
    var pipeline = try Pipeline.init(allocator, &steps, &[_]StepFn{step_fn});

    const result = pipeline.run(syrup.Value{ .symbol = "start" });
    switch (result) {
        .yield => |v| try std.testing.expectEqualStrings("paused-state", v.symbol),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(ContinuationStatus.paused, pipeline.state.status);
}

test "continuation state syrup has correct fields" {
    const allocator = std.testing.allocator;

    const steps = [_]Step{
        .{ .name = "alpha", .trit = .plus },
        .{ .name = "beta", .trit = .zero },
    };
    var state = try ContinuationState.init(allocator, &steps);
    const val = try state.toSyrup(allocator);
    defer {
        allocator.free(val.record.fields[0].string);
        val.deinitContainers(allocator);
    }

    try std.testing.expectEqual(syrup.Value.record, std.meta.activeTag(val));
    // Should have 6 fields
    try std.testing.expectEqual(@as(usize, 6), val.record.fields.len);
}
