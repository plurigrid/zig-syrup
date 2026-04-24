//! Gay Propagator: Chromatic Radul-Sussman propagator network
//! Wraps src/propagator.zig with Gay.jl SplitMix64 chromatic identity.
//! Every cell, premise, and propagator gets a deterministic color from its name.
//!
//! SDF Chapter 7 structures with support sets (§6.4, §7.4).

const std = @import("std");
const splitmix = @import("splitmix.zig");

// =============================================================================
// Chromatic hash: name -> u32 color via SplitMix64
// =============================================================================

pub fn chromaticHash(name: []const u8) u32 {
    var seed: u64 = splitmix.GAY_SEED;
    for (name) |c| {
        seed = splitmix.splitmix64(seed +% @as(u64, c));
    }
    return @truncate(seed);
}

// =============================================================================
// Partial Information Lattice (SDF §7.2)
// =============================================================================

pub const Nothing = struct {};
pub const Contradiction = struct { info: ?[]const u8 = null };

pub const Value = union(enum) {
    nothing: Nothing,
    contradiction: Contradiction,
    integer: i64,
    float: f64,
    boolean: bool,
    interval: Interval,

    pub const Interval = struct { lo: f64, hi: f64 };

    pub fn isNothing(self: Value) bool {
        return self == .nothing;
    }

    pub fn isContradiction(self: Value) bool {
        return self == .contradiction;
    }

    pub fn eql(a: Value, b: Value) bool {
        const tag_a: u8 = @intFromEnum(a);
        const tag_b: u8 = @intFromEnum(b);
        if (tag_a != tag_b) return false;
        return switch (a) {
            .nothing => true,
            .contradiction => true,
            .integer => |va| va == b.integer,
            .float => |va| va == b.float,
            .boolean => |va| va == b.boolean,
            .interval => |va| va.lo == b.interval.lo and va.hi == b.interval.hi,
        };
    }

    /// Extract f64 from float or integer (for arithmetic propagators)
    pub fn asFloat(self: Value) ?f64 {
        return switch (self) {
            .float => |v| v,
            .integer => |v| @as(f64, @floatFromInt(v)),
            else => null,
        };
    }
};

// =============================================================================
// Merge (SDF §7.4)
// =============================================================================

pub fn mergeValues(content: Value, increment: Value) Value {
    if (increment.isNothing()) return content;
    if (content.isNothing()) return increment;
    if (content.isContradiction()) return content;
    if (increment.isContradiction()) return increment;

    if (Value.eql(content, increment)) return content;

    // Interval narrowing
    if (content == .interval and increment == .interval) {
        const lo = @max(content.interval.lo, increment.interval.lo);
        const hi = @min(content.interval.hi, increment.interval.hi);
        if (lo <= hi) {
            return Value{ .interval = .{ .lo = lo, .hi = hi } };
        }
        return Value{ .contradiction = .{ .info = "interval empty" } };
    }

    return Value{ .contradiction = .{ .info = "inconsistent" } };
}

// =============================================================================
// Premise (SDF §6.4)
// =============================================================================

pub const Premise = struct {
    name: []const u8,
    is_in: bool,
    is_hypothetical: bool,
    color: u32,

    pub fn init(name: []const u8, hypothetical: bool) Premise {
        return .{
            .name = name,
            .is_in = true,
            .is_hypothetical = hypothetical,
            .color = chromaticHash(name),
        };
    }

    pub fn markIn(self: *Premise) void {
        self.is_in = true;
    }

    pub fn markOut(self: *Premise) void {
        self.is_in = false;
    }
};

// =============================================================================
// Support Set
// =============================================================================

pub const SupportSet = struct {
    premises: std.ArrayList(*Premise),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SupportSet {
        return .{ .premises = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *SupportSet) void {
        self.premises.deinit(self.allocator);
    }

    pub fn add(self: *SupportSet, p: *Premise) void {
        self.premises.append(self.allocator, p) catch {};
    }

    pub fn allIn(self: *const SupportSet) bool {
        for (self.premises.items) |p| {
            if (!p.is_in) return false;
        }
        return true;
    }

    /// XOR of premise colors
    pub fn color(self: *const SupportSet) u32 {
        var c: u32 = 0;
        for (self.premises.items) |p| {
            c ^= p.color;
        }
        return c;
    }
};

// =============================================================================
// Supported value (§7.4.2)
// =============================================================================

pub const Supported = struct {
    value: Value,
    support: SupportSet,
};

// =============================================================================
// Forward declaration
// =============================================================================

pub const ActivateFn = *const fn (inputs: []const *Cell, outputs: []const *Cell) void;

// =============================================================================
// Propagator (§7.2.2)
// =============================================================================

pub const PropagatorDef = struct {
    name: []const u8,
    inputs: std.ArrayList(*Cell),
    outputs: std.ArrayList(*Cell),
    activate: ActivateFn,
    color: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, activate: ActivateFn) PropagatorDef {
        return .{
            .name = name,
            .inputs = .{},
            .outputs = .{},
            .activate = activate,
            .color = chromaticHash(name),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PropagatorDef) void {
        self.inputs.deinit(self.allocator);
        self.outputs.deinit(self.allocator);
    }

    pub fn fire(self: *const PropagatorDef) void {
        self.activate(self.inputs.items, self.outputs.items);
    }
};

// =============================================================================
// Cell (§7.2.1)
// =============================================================================

pub const Cell = struct {
    name: []const u8,
    content: Value,
    strongest: Value,
    neighbors: std.ArrayList(*PropagatorDef),
    color: u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) Cell {
        return .{
            .name = name,
            .content = Value{ .nothing = .{} },
            .strongest = Value{ .nothing = .{} },
            .neighbors = .{},
            .color = chromaticHash(name),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Cell) void {
        self.neighbors.deinit(self.allocator);
    }

    pub fn addContent(self: *Cell, increment: Value, scheduler: *Scheduler) void {
        const merged = mergeValues(self.content, increment);
        if (!Value.eql(self.content, merged)) {
            self.content = merged;
            self.strongest = merged;
            // Alert all neighbor propagators
            for (self.neighbors.items) |prop| {
                scheduler.alert(prop);
            }
        }
    }
};

// =============================================================================
// Scheduler (§7.2)
// =============================================================================

pub const Scheduler = struct {
    queue: std.ArrayList(*PropagatorDef),
    running: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Scheduler {
        return .{
            .queue = .{},
            .running = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Scheduler) void {
        self.queue.deinit(self.allocator);
    }

    pub fn alert(self: *Scheduler, p: *PropagatorDef) void {
        self.queue.append(self.allocator, p) catch {};
    }

    pub fn run(self: *Scheduler) void {
        self.running = true;
        while (self.queue.items.len > 0) {
            const prop = self.queue.orderedRemove(0);
            prop.fire();
        }
        self.running = false;
    }
};

// =============================================================================
// Arithmetic propagator constructors
// =============================================================================

fn addActivate(inputs: []const *Cell, outputs: []const *Cell) void {
    const a_val = inputs[0].content.asFloat() orelse return;
    const b_val = inputs[1].content.asFloat() orelse return;
    // We need a scheduler ref — smuggle via outputs[0]'s neighbor list context
    // Actually: we set content directly via mergeValues to avoid needing scheduler in activate
    const result = Value{ .float = a_val + b_val };
    const merged = mergeValues(outputs[0].content, result);
    if (!Value.eql(outputs[0].content, merged)) {
        outputs[0].content = merged;
        outputs[0].strongest = merged;
    }
}

fn subActivate(inputs: []const *Cell, outputs: []const *Cell) void {
    const a_val = inputs[0].content.asFloat() orelse return;
    const b_val = inputs[1].content.asFloat() orelse return;
    const result = Value{ .float = a_val - b_val };
    const merged = mergeValues(outputs[0].content, result);
    if (!Value.eql(outputs[0].content, merged)) {
        outputs[0].content = merged;
        outputs[0].strongest = merged;
    }
}

fn mulActivate(inputs: []const *Cell, outputs: []const *Cell) void {
    const a_val = inputs[0].content.asFloat() orelse return;
    const b_val = inputs[1].content.asFloat() orelse return;
    const result = Value{ .float = a_val * b_val };
    const merged = mergeValues(outputs[0].content, result);
    if (!Value.eql(outputs[0].content, merged)) {
        outputs[0].content = merged;
        outputs[0].strongest = merged;
    }
}

fn divActivate(inputs: []const *Cell, outputs: []const *Cell) void {
    const a_val = inputs[0].content.asFloat() orelse return;
    const b_val = inputs[1].content.asFloat() orelse return;
    if (b_val == 0.0) return;
    const result = Value{ .float = a_val / b_val };
    const merged = mergeValues(outputs[0].content, result);
    if (!Value.eql(outputs[0].content, merged)) {
        outputs[0].content = merged;
        outputs[0].strongest = merged;
    }
}

/// Install a one-directional propagator: a + b -> sum
pub fn pAdd(a: *Cell, b: *Cell, sum: *Cell, scheduler: *Scheduler) *PropagatorDef {
    return installProp("p:add", &.{ a, b }, &.{sum}, addActivate, scheduler);
}

/// Install a one-directional propagator: a * b -> product
pub fn pMul(a: *Cell, b: *Cell, product: *Cell, scheduler: *Scheduler) *PropagatorDef {
    return installProp("p:mul", &.{ a, b }, &.{product}, mulActivate, scheduler);
}

/// Install a one-directional propagator: a - b -> diff
pub fn pSub(a: *Cell, b: *Cell, diff: *Cell, scheduler: *Scheduler) *PropagatorDef {
    return installProp("p:sub", &.{ a, b }, &.{diff}, subActivate, scheduler);
}

/// Constraint: a + b = sum (bidirectional, installs 3 propagators)
pub fn cAdd(a: *Cell, b: *Cell, sum: *Cell, scheduler: *Scheduler) void {
    _ = installProp("c:add:ab->s", &.{ a, b }, &.{sum}, addActivate, scheduler);
    _ = installProp("c:add:sb->a", &.{ sum, b }, &.{a}, subActivate, scheduler);
    _ = installProp("c:add:sa->b", &.{ sum, a }, &.{b}, subActivate, scheduler);
}

/// Constraint: a * b = product (bidirectional, installs 3 propagators)
pub fn cMul(a: *Cell, b: *Cell, product: *Cell, scheduler: *Scheduler) void {
    _ = installProp("c:mul:ab->p", &.{ a, b }, &.{product}, mulActivate, scheduler);
    _ = installProp("c:mul:pa->b", &.{ product, a }, &.{b}, divActivate, scheduler);
    _ = installProp("c:mul:pb->a", &.{ product, b }, &.{a}, divActivate, scheduler);
}

fn installProp(
    name: []const u8,
    inputs: []const *Cell,
    outputs: []const *Cell,
    activate: ActivateFn,
    scheduler: *Scheduler,
) *PropagatorDef {
    const alloc = scheduler.allocator;
    const prop = alloc.create(PropagatorDef) catch @panic("OOM");
    prop.* = PropagatorDef.init(alloc, name, activate);
    for (inputs) |cell| {
        prop.inputs.append(alloc, cell) catch {};
        cell.neighbors.append(cell.allocator, prop) catch {};
    }
    for (outputs) |cell| {
        prop.outputs.append(alloc, cell) catch {};
    }
    return prop;
}

// =============================================================================
// Tests
// =============================================================================

test "chromatic hash deterministic" {
    const c1 = chromaticHash("alpha");
    const c2 = chromaticHash("alpha");
    const c3 = chromaticHash("beta");
    try std.testing.expectEqual(c1, c2);
    try std.testing.expect(c1 != c3);
}

test "cell creation with color" {
    const alloc = std.testing.allocator;
    var cell = Cell.init(alloc, "temperature");
    defer cell.deinit();
    try std.testing.expect(cell.content.isNothing());
    try std.testing.expect(cell.color != 0); // overwhelmingly likely
    try std.testing.expectEqual(chromaticHash("temperature"), cell.color);
}

test "value merge nothing is identity" {
    const nothing = Value{ .nothing = .{} };
    const v = Value{ .float = 3.14 };
    try std.testing.expect(Value.eql(mergeValues(nothing, v), v));
    try std.testing.expect(Value.eql(mergeValues(v, nothing), v));
}

test "value merge same is idempotent" {
    const v = Value{ .integer = 42 };
    try std.testing.expect(Value.eql(mergeValues(v, v), v));
}

test "value merge contradiction" {
    const a = Value{ .float = 1.0 };
    const b = Value{ .float = 2.0 };
    const result = mergeValues(a, b);
    try std.testing.expect(result.isContradiction());
}

test "value merge contradiction absorbs" {
    const c = Value{ .contradiction = .{ .info = "bad" } };
    const v = Value{ .float = 1.0 };
    try std.testing.expect(mergeValues(c, v).isContradiction());
}

test "interval narrowing" {
    const a = Value{ .interval = .{ .lo = 0.0, .hi = 10.0 } };
    const b = Value{ .interval = .{ .lo = 3.0, .hi = 7.0 } };
    const result = mergeValues(a, b);
    try std.testing.expectEqual(Value.Interval{ .lo = 3.0, .hi = 7.0 }, result.interval);
}

test "interval contradiction on empty" {
    const a = Value{ .interval = .{ .lo = 5.0, .hi = 10.0 } };
    const b = Value{ .interval = .{ .lo = 0.0, .hi = 3.0 } };
    try std.testing.expect(mergeValues(a, b).isContradiction());
}

test "propagator activation" {
    const alloc = std.testing.allocator;
    var sched = Scheduler.init(alloc);
    defer sched.deinit();

    var a = Cell.init(alloc, "a");
    defer a.deinit();
    var b = Cell.init(alloc, "b");
    defer b.deinit();
    var sum = Cell.init(alloc, "sum");
    defer sum.deinit();

    const prop = pAdd(&a, &b, &sum, &sched);
    defer {
        prop.inputs.deinit(alloc);
        prop.outputs.deinit(alloc);
        alloc.destroy(prop);
    }

    a.addContent(Value{ .float = 3.0 }, &sched);
    b.addContent(Value{ .float = 4.0 }, &sched);
    sched.run();

    try std.testing.expectEqual(@as(f64, 7.0), sum.content.float);
}

test "constraint propagation cAdd bidirectional" {
    const alloc = std.testing.allocator;
    var sched = Scheduler.init(alloc);
    defer sched.deinit();

    var a = Cell.init(alloc, "a");
    defer a.deinit();
    var b = Cell.init(alloc, "b");
    defer b.deinit();
    var sum = Cell.init(alloc, "sum");
    defer sum.deinit();

    cAdd(&a, &b, &sum, &sched);

    // Forward: a=3, b=4 -> sum=7
    a.addContent(Value{ .float = 3.0 }, &sched);
    b.addContent(Value{ .float = 4.0 }, &sched);
    sched.run();
    try std.testing.expectEqual(@as(f64, 7.0), sum.content.float);

    // Now test backward: set sum and one input, derive the other
    var x = Cell.init(alloc, "x");
    defer x.deinit();
    var y = Cell.init(alloc, "y");
    defer y.deinit();
    var s = Cell.init(alloc, "s");
    defer s.deinit();

    cAdd(&x, &y, &s, &sched);

    s.addContent(Value{ .float = 10.0 }, &sched);
    x.addContent(Value{ .float = 3.0 }, &sched);
    sched.run();
    try std.testing.expectEqual(@as(f64, 7.0), y.content.float);

    // Clean up heap-allocated propagators
    for (a.neighbors.items) |p| {
        p.inputs.deinit(alloc);
        p.outputs.deinit(alloc);
        alloc.destroy(p);
    }
    for (x.neighbors.items) |p| {
        p.inputs.deinit(alloc);
        p.outputs.deinit(alloc);
        alloc.destroy(p);
    }
    // s and y share propagators already freed via x's neighbors;
    // we only need to free the ones unique to s and y
    // Since cAdd creates 3 props and registers them on multiple cells,
    // we already freed all 3 via x.neighbors (they all have x as input/output)
}

test "scheduler queue ordering" {
    const alloc = std.testing.allocator;
    var sched = Scheduler.init(alloc);
    defer sched.deinit();

    var p1 = PropagatorDef.init(alloc, "first", &struct {
        fn f(_: []const *Cell, _: []const *Cell) void {}
    }.f);
    defer p1.deinit();
    var p2 = PropagatorDef.init(alloc, "second", &struct {
        fn f(_: []const *Cell, _: []const *Cell) void {}
    }.f);
    defer p2.deinit();

    sched.alert(&p1);
    sched.alert(&p2);
    try std.testing.expectEqual(@as(usize, 2), sched.queue.items.len);

    sched.run();
    try std.testing.expectEqual(@as(usize, 0), sched.queue.items.len);
    try std.testing.expect(!sched.running);
}

test "premise chromatic identity" {
    var p = Premise.init("voltage", false);
    try std.testing.expectEqual(chromaticHash("voltage"), p.color);
    try std.testing.expect(p.is_in);
    p.markOut();
    try std.testing.expect(!p.is_in);
    p.markIn();
    try std.testing.expect(p.is_in);
}

test "support set color is XOR" {
    const alloc = std.testing.allocator;
    var p1 = Premise.init("alpha", false);
    var p2 = Premise.init("beta", false);
    var ss = SupportSet.init(alloc);
    defer ss.deinit();
    ss.add(&p1);
    ss.add(&p2);
    try std.testing.expectEqual(p1.color ^ p2.color, ss.color());
    try std.testing.expect(ss.allIn());
    p2.markOut();
    try std.testing.expect(!ss.allIn());
}
