//! OCapN bootstrap object + swiss-number registry.
//!
//! Every OCapN vat exposes an implicit bootstrap object at export position 0.
//! Remote peers invoke `fetch(swiss-number)` on it to resolve a sturdy-ref
//! into a concrete import position for future op:deliver calls.
//!
//! The registry is a map: swiss [32]u8 → local export position (u32).
//! `register` adds an entry (and allocates a fresh export position in the
//! caller's session). `fetch` looks up a swiss and returns the position or
//! `null` if unknown.

const std = @import("std");
const syrup = @import("syrup");
const Allocator = std.mem.Allocator;
const ByteList = std.array_list.Managed(u8);

pub const SWISS_LEN: usize = 32;
pub const BOOTSTRAP_POS: u32 = 0;

/// Swiss-number → export-position map. Ownership of the key bytes is by-value
/// (stored inline in the struct), so callers can free their source buffers
/// after registering.
pub const SwissRegistry = struct {
    const Entry = struct {
        swiss: [SWISS_LEN]u8,
        position: u32,
    };

    entries: std.ArrayListUnmanaged(Entry),
    next_position: u32 = 1, // 0 reserved for bootstrap itself

    pub fn init() SwissRegistry {
        return .{ .entries = .empty };
    }

    pub fn deinit(self: *SwissRegistry, allocator: Allocator) void {
        self.entries.deinit(allocator);
    }

    /// Register a fresh sturdy: returns the allocated export position.
    pub fn register(
        self: *SwissRegistry,
        allocator: Allocator,
        swiss: [SWISS_LEN]u8,
    ) !u32 {
        if (self.lookup(swiss)) |pos| return pos;
        const pos = self.next_position;
        self.next_position += 1;
        try self.entries.append(allocator, .{ .swiss = swiss, .position = pos });
        return pos;
    }

    /// Look up an existing swiss. Returns null if not registered.
    pub fn lookup(self: *const SwissRegistry, swiss: [SWISS_LEN]u8) ?u32 {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, &e.swiss, &swiss)) return e.position;
        }
        return null;
    }

    /// Serve a fetch request. Returns the export position for this swiss,
    /// or null if unknown (caller should reply with a desc:error).
    pub fn fetch(self: *const SwissRegistry, swiss: [SWISS_LEN]u8) ?u32 {
        return self.lookup(swiss);
    }

    /// Current count of registered sturdies (excluding bootstrap itself).
    pub fn size(self: *const SwissRegistry) usize {
        return self.entries.items.len;
    }
};

/// Generate a fresh 32-byte swiss using a cryptographic RNG.
pub fn freshSwiss() [SWISS_LEN]u8 {
    var out: [SWISS_LEN]u8 = undefined;
    std.crypto.random.bytes(&out);
    return out;
}

/// Build a caller-owned `<desc:import-object N>` Syrup record. Common
/// payload for `Vat.sendFulfill` when replying to a bootstrap `fetch`.
pub fn encodeImportObjectAlloc(allocator: Allocator, position: u32) ![]u8 {
    var out = ByteList.init(allocator);
    errdefer out.deinit();
    try out.appendSlice("<18'desc:import-object");
    try std.fmt.format(out.writer(), "{d}+", .{position});
    try out.append('>');
    return out.toOwnedSlice();
}

/// Extract a 32-byte swiss from the first argument of a `fetch` call.
/// Racket/Guile Goblins emit swiss as a bytestring.
pub fn readFetchSwiss(arg: syrup.Value) ![SWISS_LEN]u8 {
    switch (arg) {
        .bytes => |b| {
            if (b.len != SWISS_LEN) return error.InvalidSwiss;
            var out: [SWISS_LEN]u8 = undefined;
            @memcpy(&out, b);
            return out;
        },
        else => return error.InvalidSwiss,
    }
}

// ---- Tests ------------------------------------------------------------------

test "register → lookup → fetch" {
    const allocator = std.testing.allocator;
    var reg = SwissRegistry.init();
    defer reg.deinit(allocator);

    var s1: [SWISS_LEN]u8 = undefined;
    var s2: [SWISS_LEN]u8 = undefined;
    for (&s1, 0..) |*b, i| b.* = @intCast(i);
    for (&s2, 0..) |*b, i| b.* = @intCast(0xFF - i);

    const p1 = try reg.register(allocator, s1);
    const p2 = try reg.register(allocator, s2);
    try std.testing.expect(p1 != BOOTSTRAP_POS);
    try std.testing.expect(p2 != BOOTSTRAP_POS);
    try std.testing.expect(p1 != p2);

    try std.testing.expectEqual(@as(?u32, p1), reg.fetch(s1));
    try std.testing.expectEqual(@as(?u32, p2), reg.fetch(s2));

    // Unknown swiss returns null.
    const s3: [SWISS_LEN]u8 = [_]u8{0} ** SWISS_LEN;
    try std.testing.expectEqual(@as(?u32, null), reg.fetch(s3));

    // Re-registering the same swiss returns the same position.
    const p1_again = try reg.register(allocator, s1);
    try std.testing.expectEqual(p1, p1_again);
    try std.testing.expectEqual(@as(usize, 2), reg.size());
}

test "freshSwiss yields nonzero bytes with overwhelming probability" {
    const s = freshSwiss();
    var zero_count: usize = 0;
    for (s) |b| if (b == 0) {
        zero_count += 1;
    };
    try std.testing.expect(zero_count < SWISS_LEN);
}

test "encodeImportObjectAlloc produces parseable desc:import-object" {
    const allocator = std.testing.allocator;
    const bytes = try encodeImportObjectAlloc(allocator, 42);
    defer allocator.free(bytes);

    var parser = syrup.Parser.init(bytes, allocator);
    var v = try parser.parse();
    defer v.deinitAll(allocator);
    try std.testing.expect(v == .record);
    try std.testing.expectEqualStrings("desc:import-object", v.record.label.symbol);
    try std.testing.expectEqual(@as(usize, 1), v.record.fields.len);
    try std.testing.expectEqual(@as(i64, 42), v.record.fields[0].integer);
}

test "readFetchSwiss: 32-byte bytes OK, wrong length rejected" {
    var full: [SWISS_LEN]u8 = undefined;
    for (&full, 0..) |*b, i| b.* = @intCast(i);
    const ok = try readFetchSwiss(.{ .bytes = &full });
    try std.testing.expectEqualSlices(u8, &full, &ok);

    const short = &[_]u8{ 1, 2, 3 };
    try std.testing.expectError(error.InvalidSwiss, readFetchSwiss(.{ .bytes = short }));
    try std.testing.expectError(error.InvalidSwiss, readFetchSwiss(.{ .integer = 5 }));
}
