//! SDF Chapter 7: Propagator Networks
//! Implements bidirectional constraint propagation for BCI neurofeedback.
//!
//! Enriched with partial information lattice (Nothing < Value < Contradiction)
//! per Radul & Sussman "The Art of the Propagator".

const std = @import("std");

// =============================================================================
// Partial Information Lattice
// =============================================================================

/// Three-valued lattice: Nothing < Value(T) < Contradiction
pub fn CellValue(comptime T: type) type {
    return union(enum) {
        nothing: void,
        value: T,
        contradiction: struct { a: T, b: T },

        const Self = @This();

        pub fn isNothing(self: Self) bool {
            return self == .nothing;
        }

        pub fn hasValue(self: Self) ?T {
            return switch (self) {
                .value => |v| v,
                else => null,
            };
        }

        pub fn isContradiction(self: Self) bool {
            return self == .contradiction;
        }
    };
}

/// Merge function signature: combines two CellValues according to lattice rules.
pub fn MergeFn(comptime T: type) type {
    return *const fn (CellValue(T), CellValue(T)) CellValue(T);
}

/// Default merge: overwrite semantics (backward compatible with original behavior).
/// Incoming value always wins over existing, nothing is identity.
pub fn defaultMerge(comptime T: type) MergeFn(T) {
    return struct {
        fn merge(existing: CellValue(T), incoming: CellValue(T)) CellValue(T) {
            return switch (incoming) {
                .nothing => existing,
                .value => incoming,
                .contradiction => incoming,
            };
        }
    }.merge;
}

/// Lattice merge: monotonic partial information (SDF semantics).
/// Nothing < Value < Contradiction. Same values are idempotent,
/// different values produce a contradiction.
pub fn latticeMerge(comptime T: type) MergeFn(T) {
    return struct {
        fn merge(existing: CellValue(T), incoming: CellValue(T)) CellValue(T) {
            return switch (existing) {
                .nothing => incoming,
                .contradiction => existing, // Contradiction absorbs everything
                .value => |a| switch (incoming) {
                    .nothing => existing,
                    .value => |b| if (std.meta.eql(a, b))
                        existing
                    else
                        CellValue(T){ .contradiction = .{ .a = a, .b = b } },
                    .contradiction => incoming,
                },
            };
        }
    }.merge;
}

// =============================================================================
// Cell: holds partial information, alerts neighbors on change
// =============================================================================

pub fn Cell(comptime T: type, comptime merge_fn: MergeFn(T)) type {
    return struct {
        const Self = @This();

        name: []const u8,
        content: CellValue(T) = .{ .nothing = {} },
        neighbors: std.ArrayListUnmanaged(*Propagator(T, merge_fn)),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, name: []const u8) Self {
            return Self{
                .name = name,
                .allocator = allocator,
                .neighbors = std.ArrayListUnmanaged(*Propagator(T, merge_fn)){},
            };
        }

        pub fn deinit(self: *Self) void {
            self.neighbors.deinit(self.allocator);
        }

        pub fn add_neighbor(self: *Self, propagator: *Propagator(T, merge_fn)) anyerror!void {
            try self.neighbors.append(self.allocator, propagator);
        }

        pub fn set_content(self: *Self, value: T) anyerror!void {
            const incoming = CellValue(T){ .value = value };
            const merged = merge_fn(self.content, incoming);

            // Alert neighbors if state changed
            if (!std.meta.eql(self.content, merged)) {
                self.content = merged;
                try self.alert_neighbors();
            }
        }

        /// Set content directly from a CellValue (for advanced usage)
        pub fn set_cell_value(self: *Self, cv: CellValue(T)) anyerror!void {
            const merged = merge_fn(self.content, cv);
            if (!std.meta.eql(self.content, merged)) {
                self.content = merged;
                try self.alert_neighbors();
            }
        }

        /// Returns the value if present, null if nothing or contradiction.
        pub fn get_content(self: *const Self) ?T {
            return self.content.hasValue();
        }

        /// Returns the full CellValue (nothing/value/contradiction).
        pub fn get_cell_value(self: *const Self) CellValue(T) {
            return self.content;
        }

        fn alert_neighbors(self: *Self) anyerror!void {
            for (self.neighbors.items) |prop| {
                try prop.alert();
            }
        }
    };
}

/// Backward-compatible alias: Cell with overwrite semantics.
pub fn SimpleCell(comptime T: type) type {
    return Cell(T, defaultMerge(T));
}

// =============================================================================
// Propagator: computes output from inputs via function
// =============================================================================

pub fn Propagator(comptime T: type, comptime merge_fn: MergeFn(T)) type {
    return struct {
        const Self = @This();

        inputs: []const *Cell(T, merge_fn),
        outputs: []const *Cell(T, merge_fn),
        function: *const fn ([]const ?T) ?T,

        pub fn alert(self: *Self) anyerror!void {
            var args = std.ArrayListUnmanaged(?T){};
            const alloc = self.inputs[0].allocator;
            defer args.deinit(alloc);

            for (self.inputs) |cell| {
                try args.append(alloc, cell.get_content());
            }

            if (self.function(args.items)) |result| {
                for (self.outputs) |out_cell| {
                    try out_cell.set_content(result);
                }
            }
        }
    };
}

/// Backward-compatible alias: Propagator with overwrite semantics.
pub fn SimplePropagator(comptime T: type) type {
    return Propagator(T, defaultMerge(T));
}

// =============================================================================
// BCI Logic as Propagator Function
// =============================================================================

pub fn neurofeedback_gate(args: []const ?f32) ?f32 {
    const focus = args[0] orelse return null;
    const relax = args[1] orelse return null;
    const threshold = args[2] orelse return null;
    const social = if (args.len > 3) (args[3] orelse 0.0) else 0.0;

    // Social trit modulates threshold (positive social interaction lowers barrier to flow)
    const effective_threshold = threshold - (social * 0.1);

    if (focus > effective_threshold and relax < 0.3) {
        return 1.0; // Trigger Action
    } else {
        return 0.0; // No Action
    }
}

// =============================================================================
// Spatial Propagator Functions
// =============================================================================

/// Adjacency gate: propagates focus influence between adjacent nodes.
/// args[0] = self focus, args[1..] = neighbor focuses.
/// Returns blended focus (80% self + 20% neighbor average).
pub fn adjacency_gate(args: []const ?f32) ?f32 {
    const self_focus = args[0] orelse return null;
    var neighbor_sum: f32 = 0;
    var neighbor_count: u32 = 0;
    for (args[1..]) |arg| {
        if (arg) |v| {
            neighbor_sum += v;
            neighbor_count += 1;
        }
    }
    if (neighbor_count == 0) return self_focus;
    const neighbor_avg = neighbor_sum / @as(f32, @floatFromInt(neighbor_count));
    return self_focus * 0.8 + neighbor_avg * 0.2;
}

/// Focus propagator: maps focus level (0..1) to brightness multiplier.
/// Focused = 1.0, unfocused = 0.6.
pub fn focus_brightness(args: []const ?f32) ?f32 {
    const focus_level = args[0] orelse return null;
    return 0.6 + focus_level * 0.4;
}

// =============================================================================
// Tests
// =============================================================================

test "CellValue nothing" {
    const cv = CellValue(f32){ .nothing = {} };
    try std.testing.expect(cv.isNothing());
    try std.testing.expect(cv.hasValue() == null);
    try std.testing.expect(!cv.isContradiction());
}

test "CellValue value" {
    const cv = CellValue(f32){ .value = 42.0 };
    try std.testing.expect(!cv.isNothing());
    try std.testing.expectEqual(@as(?f32, 42.0), cv.hasValue());
    try std.testing.expect(!cv.isContradiction());
}

test "CellValue contradiction" {
    const cv = CellValue(f32){ .contradiction = .{ .a = 1.0, .b = 2.0 } };
    try std.testing.expect(!cv.isNothing());
    try std.testing.expect(cv.hasValue() == null);
    try std.testing.expect(cv.isContradiction());
}

test "defaultMerge overwrite semantics" {
    const merge = defaultMerge(f32);
    const nothing = CellValue(f32){ .nothing = {} };
    const val1 = CellValue(f32){ .value = 1.0 };
    const val2 = CellValue(f32){ .value = 2.0 };

    // nothing + value = value
    try std.testing.expectEqual(val1, merge(nothing, val1));
    // value + nothing = original value
    try std.testing.expectEqual(val1, merge(val1, nothing));
    // value + different value = incoming wins
    try std.testing.expectEqual(val2, merge(val1, val2));
}

test "latticeMerge monotonic" {
    const merge = latticeMerge(f32);
    const nothing = CellValue(f32){ .nothing = {} };
    const val1 = CellValue(f32){ .value = 1.0 };
    const val2 = CellValue(f32){ .value = 2.0 };

    // nothing + value = value
    try std.testing.expectEqual(val1, merge(nothing, val1));
    // value + nothing = original value
    try std.testing.expectEqual(val1, merge(val1, nothing));
    // value + same value = idempotent
    try std.testing.expectEqual(val1, merge(val1, val1));
    // value + different value = contradiction
    const result = merge(val1, val2);
    try std.testing.expect(result.isContradiction());
}

test "latticeMerge contradiction absorbs" {
    const merge = latticeMerge(f32);
    const contradiction = CellValue(f32){ .contradiction = .{ .a = 1.0, .b = 2.0 } };
    const val3 = CellValue(f32){ .value = 3.0 };
    const nothing = CellValue(f32){ .nothing = {} };

    // contradiction + anything = contradiction
    try std.testing.expect(merge(contradiction, val3).isContradiction());
    try std.testing.expect(merge(contradiction, nothing).isContradiction());
    // anything + contradiction = contradiction
    try std.testing.expect(merge(val3, contradiction).isContradiction());
    try std.testing.expect(merge(nothing, contradiction).isContradiction());
}

test "SimpleCell backward compat" {
    const allocator = std.testing.allocator;
    var cell = SimpleCell(f32).init(allocator, "test");
    defer cell.deinit();

    try std.testing.expect(cell.get_content() == null);
    try cell.set_content(42.0);
    try std.testing.expectEqual(@as(?f32, 42.0), cell.get_content());
    // Overwrite
    try cell.set_content(99.0);
    try std.testing.expectEqual(@as(?f32, 99.0), cell.get_content());
}

test "lattice Cell detects contradiction" {
    const allocator = std.testing.allocator;
    const LCell = Cell(f32, latticeMerge(f32));
    var cell = LCell.init(allocator, "lattice_test");
    defer cell.deinit();

    try cell.set_content(1.0);
    try std.testing.expectEqual(@as(?f32, 1.0), cell.get_content());

    // Setting same value is fine
    try cell.set_content(1.0);
    try std.testing.expectEqual(@as(?f32, 1.0), cell.get_content());

    // Setting different value creates contradiction
    try cell.set_content(2.0);
    try std.testing.expect(cell.get_cell_value().isContradiction());
    try std.testing.expect(cell.get_content() == null); // contradiction returns null
}

test "neurofeedback_gate still works" {
    // Focused with low relaxation above threshold -> trigger
    const result1 = neurofeedback_gate(&.{ 0.8, 0.1, 0.5 });
    try std.testing.expectEqual(@as(?f32, 1.0), result1);

    // Below threshold -> no trigger
    const result2 = neurofeedback_gate(&.{ 0.3, 0.1, 0.5 });
    try std.testing.expectEqual(@as(?f32, 0.0), result2);

    // Null input -> null output
    const result3 = neurofeedback_gate(&.{ null, 0.1, 0.5 });
    try std.testing.expect(result3 == null);
}

test "adjacency_gate blending" {
    // Self focus 1.0, two neighbors at 0.0
    const result = adjacency_gate(&.{ 1.0, 0.0, 0.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), result.?, 0.001);

    // Self focus 0.0, two neighbors at 1.0
    const result2 = adjacency_gate(&.{ 0.0, 1.0, 1.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), result2.?, 0.001);

    // No neighbors
    const result3 = adjacency_gate(&.{0.5});
    try std.testing.expectEqual(@as(?f32, 0.5), result3);
}

test "focus_brightness mapping" {
    try std.testing.expectEqual(@as(?f32, 1.0), focus_brightness(&.{1.0}));
    try std.testing.expectEqual(@as(?f32, 0.6), focus_brightness(&.{0.0}));
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), focus_brightness(&.{0.5}).?, 0.001);
}
