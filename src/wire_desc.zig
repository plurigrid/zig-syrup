//! OCapN wire descriptors — typed union replacing stringly-typed parsing.
//!
//! Every CapTP message uses descriptors to identify targets, resolvers,
//! and transferred references. The spec defines:
//!
//!   desc:import-object  position   — imported object (target or resolver)
//!   desc:import-promise position   — imported promise (pipelining target)
//!   desc:export         position   — exported reference
//!   desc:answer         answer-pos — promise pipelining handle
//!
//! This module provides `WireDesc`, the tagged union that replaces the
//! old `readImportObjectPos` function. Every descriptor parse site in
//! ocapn_vat.zig should go through `WireDesc.fromValue`.

const std = @import("std");
const syrup = @import("syrup");

/// A parsed CapTP descriptor. This is the typed replacement for ad-hoc
/// string matching against `"desc:import-object"` etc.
pub const WireDesc = union(enum) {
    import_object: u32,
    import_promise: u32,
    @"export": u32,
    answer: u32,

    /// Parse any spec-defined descriptor from a Syrup record value.
    /// Returns `error.InvalidDescriptor` if the value is not a recognized
    /// descriptor record with a single integer field.
    pub fn fromValue(v: syrup.Value) !WireDesc {
        if (v != .record) return error.InvalidDescriptor;
        const r = v.record;
        if (r.label.* != .symbol) return error.InvalidDescriptor;
        if (r.fields.len < 1) return error.InvalidDescriptor;
        const pos = try readPos(r.fields[0]);
        const label = r.label.symbol;

        if (std.mem.eql(u8, label, "desc:import-object")) return .{ .import_object = pos };
        if (std.mem.eql(u8, label, "desc:import-promise")) return .{ .import_promise = pos };
        if (std.mem.eql(u8, label, "desc:export")) return .{ .@"export" = pos };
        if (std.mem.eql(u8, label, "desc:answer")) return .{ .answer = pos };

        return error.InvalidDescriptor;
    }

    /// Convenience: extract position regardless of descriptor kind.
    pub fn position(self: WireDesc) u32 {
        return switch (self) {
            .import_object => |p| p,
            .import_promise => |p| p,
            .@"export" => |p| p,
            .answer => |p| p,
        };
    }

    /// True when this descriptor refers to a promise (pipelining target).
    pub fn isPromise(self: WireDesc) bool {
        return switch (self) {
            .import_promise, .answer => true,
            .import_object, .@"export" => false,
        };
    }

    /// Encode to caller-owned Syrup bytes.
    pub fn encodeAlloc(self: WireDesc, allocator: std.mem.Allocator) ![]u8 {
        const label = switch (self) {
            .import_object => "desc:import-object",
            .import_promise => "desc:import-promise",
            .@"export" => "desc:export",
            .answer => "desc:answer",
        };
        var buf: [80]u8 = undefined;
        const inner = std.fmt.bufPrint(&buf, "<{d}'{s}{d}+>", .{
            label.len, label, self.position(),
        }) catch return error.EncodingOverflow;
        const out = try allocator.alloc(u8, inner.len);
        @memcpy(out, inner);
        return out;
    }
};

/// The spec's `to-desc` for op:deliver / op:deliver-only / op:listen.
/// Restricts which descriptor kinds are valid as message targets.
pub const TargetDesc = union(enum) {
    import_object: u32,
    import_promise: u32,
    answer: u32,

    pub fn fromWireDesc(wd: WireDesc) !TargetDesc {
        return switch (wd) {
            .import_object => |p| .{ .import_object = p },
            .import_promise => |p| .{ .import_promise = p },
            .answer => |p| .{ .answer = p },
            .@"export" => error.InvalidDescriptor,
        };
    }

    pub fn position(self: TargetDesc) u32 {
        return switch (self) {
            .import_object => |p| p,
            .import_promise => |p| p,
            .answer => |p| p,
        };
    }
};

/// The spec's `resolve-me-desc` for op:deliver field 4.
/// Either desc:import-object or desc:import-promise. Not desc:answer.
pub const ResolverDesc = union(enum) {
    import_object: u32,
    import_promise: u32,

    pub fn fromWireDesc(wd: WireDesc) !ResolverDesc {
        return switch (wd) {
            .import_object => |p| .{ .import_object = p },
            .import_promise => |p| .{ .import_promise = p },
            .answer, .@"export" => error.InvalidDescriptor,
        };
    }

    pub fn position(self: ResolverDesc) u32 {
        return switch (self) {
            .import_object => |p| p,
            .import_promise => |p| p,
        };
    }

    pub fn isPromise(self: ResolverDesc) bool {
        return self == .import_promise;
    }

    /// Convert back to a generic WireDesc for encoding.
    pub fn toWireDesc(self: ResolverDesc) WireDesc {
        return switch (self) {
            .import_object => |p| .{ .import_object = p },
            .import_promise => |p| .{ .import_promise = p },
        };
    }
};

/// The spec's `to-desc` for op:listen — only promise-shaped targets.
pub const ListenTargetDesc = union(enum) {
    answer: u32,
    import_promise: u32,

    pub fn fromWireDesc(wd: WireDesc) !ListenTargetDesc {
        return switch (wd) {
            .answer => |p| .{ .answer = p },
            .import_promise => |p| .{ .import_promise = p },
            .import_object, .@"export" => error.InvalidDescriptor,
        };
    }

    pub fn position(self: ListenTargetDesc) u32 {
        return switch (self) {
            .answer => |p| p,
            .import_promise => |p| p,
        };
    }
};

fn readPos(v: syrup.Value) !u32 {
    return switch (v) {
        .integer => |i| std.math.cast(u32, i) orelse error.IntOutOfRange,
        else => error.InvalidDescriptor,
    };
}

/// Zero-allocation descriptor parse: reads directly from Syrup wire bytes
/// without constructing any `Value` intermediates. For the hot path.
///
/// Handles the common shape: `<N'label M+>` where label is one of the
/// four descriptor types and M is a non-negative integer position.
pub fn parseDescriptorFast(input: []const u8) !WireDesc {
    if (input.len < 5 or input[0] != '<') return error.InvalidDescriptor;

    // Parse label length prefix: digits before the quote marker.
    var i: usize = 1;
    while (i < input.len and input[i] >= '0' and input[i] <= '9') : (i += 1) {}
    if (i == 1 or i >= input.len or input[i] != '\'') return error.InvalidDescriptor;
    const label_len = std.fmt.parseInt(usize, input[1..i], 10) catch return error.InvalidDescriptor;
    const label_start = i + 1;
    if (label_start + label_len >= input.len) return error.InvalidDescriptor;
    const label = input[label_start .. label_start + label_len];

    // Parse position integer after the label.
    var j: usize = label_start + label_len;
    const pos_start = j;
    while (j < input.len and input[j] >= '0' and input[j] <= '9') : (j += 1) {}
    if (j == pos_start or j >= input.len or input[j] != '+') return error.InvalidDescriptor;
    const pos = std.fmt.parseInt(u32, input[pos_start..j], 10) catch return error.InvalidDescriptor;

    // Length-based label dispatch (zero string comparison for distinct lengths).
    return switch (label.len) {
        18 => if (label[5] == 'i') WireDesc{ .import_object = pos } else error.InvalidDescriptor,
        19 => if (label[5] == 'i') WireDesc{ .import_promise = pos } else error.InvalidDescriptor,
        11 => switch (label[5]) {
            'e' => WireDesc{ .@"export" = pos },
            'a' => WireDesc{ .answer = pos },
            else => error.InvalidDescriptor,
        },
        else => error.InvalidDescriptor,
    };
}

// ---- Tests ------------------------------------------------------------------

test "WireDesc: parse desc:import-object" {
    const allocator = std.testing.allocator;
    const bytes = "<18'desc:import-object42+>";
    var parser = syrup.Parser.init(bytes, allocator);
    var v = try parser.parse();
    defer v.deinitContainers(allocator);
    const desc = try WireDesc.fromValue(v);
    try std.testing.expectEqual(WireDesc{ .import_object = 42 }, desc);
    try std.testing.expect(!desc.isPromise());
}

test "WireDesc: parse desc:import-promise" {
    const allocator = std.testing.allocator;
    const bytes = "<19'desc:import-promise7+>";
    var parser = syrup.Parser.init(bytes, allocator);
    var v = try parser.parse();
    defer v.deinitContainers(allocator);
    const desc = try WireDesc.fromValue(v);
    try std.testing.expectEqual(WireDesc{ .import_promise = 7 }, desc);
    try std.testing.expect(desc.isPromise());
}

test "WireDesc: parse desc:answer" {
    const allocator = std.testing.allocator;
    const bytes = "<11'desc:answer3+>";
    var parser = syrup.Parser.init(bytes, allocator);
    var v = try parser.parse();
    defer v.deinitContainers(allocator);
    const desc = try WireDesc.fromValue(v);
    try std.testing.expectEqual(WireDesc{ .answer = 3 }, desc);
    try std.testing.expect(desc.isPromise());
}

test "WireDesc: parse desc:export" {
    const allocator = std.testing.allocator;
    const bytes = "<11'desc:export5+>";
    var parser = syrup.Parser.init(bytes, allocator);
    var v = try parser.parse();
    defer v.deinitContainers(allocator);
    const desc = try WireDesc.fromValue(v);
    try std.testing.expectEqual(WireDesc{ .@"export" = 5 }, desc);
    try std.testing.expect(!desc.isPromise());
}

test "WireDesc: reject non-record" {
    try std.testing.expectError(error.InvalidDescriptor, WireDesc.fromValue(.{ .integer = 42 }));
}

test "TargetDesc: import-object accepted, export rejected" {
    try std.testing.expect((try TargetDesc.fromWireDesc(.{ .import_object = 1 })) == .import_object);
    try std.testing.expect((try TargetDesc.fromWireDesc(.{ .answer = 2 })) == .answer);
    try std.testing.expectError(error.InvalidDescriptor, TargetDesc.fromWireDesc(.{ .@"export" = 3 }));
}

test "ResolverDesc: import-promise accepted" {
    const rd = try ResolverDesc.fromWireDesc(.{ .import_promise = 10 });
    try std.testing.expectEqual(@as(u32, 10), rd.position());
    try std.testing.expect(rd.isPromise());
}

test "ListenTargetDesc: only answer and import-promise" {
    try std.testing.expect((try ListenTargetDesc.fromWireDesc(.{ .answer = 1 })) == .answer);
    try std.testing.expect((try ListenTargetDesc.fromWireDesc(.{ .import_promise = 2 })) == .import_promise);
    try std.testing.expectError(error.InvalidDescriptor, ListenTargetDesc.fromWireDesc(.{ .import_object = 3 }));
}

test "WireDesc: encodeAlloc round-trips" {
    const allocator = std.testing.allocator;
    const original = WireDesc{ .import_promise = 99 };
    const bytes = try original.encodeAlloc(allocator);
    defer allocator.free(bytes);
    var parser = syrup.Parser.init(bytes, allocator);
    var v = try parser.parse();
    defer v.deinitContainers(allocator);
    const parsed = try WireDesc.fromValue(v);
    try std.testing.expectEqual(original, parsed);
}
