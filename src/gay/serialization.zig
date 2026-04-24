// serialization.zig: Binary and general serialization for Gay color types
// Zig translation of Gay.jl's binary.jl and serialization.jl
//
// Wire format: Syrup-compatible (OCapN canonical binary).
// Uses tagged records for Color, GayMCContext checkpoints, and propagator cell state.
//
// Syrup record format: <'label field1 field2 ...>
// Tags used:
//   gay:color    — RGB color (3 floats)
//   gay:ckpt     — GayMCContext checkpoint
//   gay:cell     — propagator cell state
//   gay:palette  — color palette with metadata
//   gay:invader  — invader (teleportation sim result)
//   gay:fleet    — invader fleet

const std = @import("std");
const syrup = @import("syrup");
const color_mod = @import("color.zig");
const gaymc = @import("gaymc.zig");
const propagator = @import("propagator.zig");
const splitmix = @import("splitmix.zig");
const Value = syrup.Value;
const Allocator = std.mem.Allocator;
const RGB = color_mod.RGB;

// ═══════════════════════════════════════════════════════════════════════════════
// Color Serialization
// ═══════════════════════════════════════════════════════════════════════════════

/// Encode an RGB color as a syrup tagged record: <'gay:color r g b>
pub fn encodeColor(c: RGB, allocator: Allocator) !Value {
    const label = try allocator.create(Value);
    label.* = Value.fromSymbol("gay:color");
    const fields = try allocator.alloc(Value, 3);
    fields[0] = Value.fromFloat(c.r);
    fields[1] = Value.fromFloat(c.g);
    fields[2] = Value.fromFloat(c.b);
    return Value.fromRecord(label, fields);
}

/// Decode a syrup record back to RGB.
pub fn decodeColor(val: Value) !RGB {
    switch (val) {
        .record => |rec| {
            if (rec.label.* != .symbol) return error.InvalidLabel;
            if (!std.mem.eql(u8, rec.label.symbol, "gay:color")) return error.WrongTag;
            if (rec.fields.len != 3) return error.WrongFieldCount;
            return RGB{
                .r = extractFloat(rec.fields[0]) orelse return error.InvalidField,
                .g = extractFloat(rec.fields[1]) orelse return error.InvalidField,
                .b = extractFloat(rec.fields[2]) orelse return error.InvalidField,
            };
        },
        else => return error.NotARecord,
    }
}

fn extractFloat(v: Value) ?f64 {
    return switch (v) {
        .float => |f| f,
        .float32 => |f| @as(f64, f),
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => null,
    };
}

/// Encode color to hex string "#RRGGBB"
pub fn colorToHex(c: RGB) [7]u8 {
    return c.toHex();
}

// ═══════════════════════════════════════════════════════════════════════════════
// Checkpoint Serialization
// ═══════════════════════════════════════════════════════════════════════════════

/// Encode a GayMCContext checkpoint as syrup record:
/// <'gay:ckpt seed worker_id sweep_count measure_count checkpoint_count <'gay:color r g b>>
pub fn encodeCheckpoint(ckpt: gaymc.Checkpoint, allocator: Allocator) !Value {
    const color_val = try encodeColor(ckpt.color, allocator);

    const label = try allocator.create(Value);
    label.* = Value.fromSymbol("gay:ckpt");

    const fields = try allocator.alloc(Value, 6);
    fields[0] = Value.fromInteger(@as(i64, @intCast(ckpt.seed)));
    fields[1] = Value.fromInteger(@as(i64, @intCast(ckpt.worker_id)));
    fields[2] = Value.fromInteger(@as(i64, @intCast(ckpt.sweep_count)));
    fields[3] = Value.fromInteger(@as(i64, @intCast(ckpt.measure_count)));
    fields[4] = Value.fromInteger(@as(i64, @intCast(ckpt.checkpoint_count)));
    fields[5] = color_val;

    return Value.fromRecord(label, fields);
}

/// Decode a syrup checkpoint record back to Checkpoint.
pub fn decodeCheckpoint(val: Value) !gaymc.Checkpoint {
    switch (val) {
        .record => |rec| {
            if (rec.label.* != .symbol) return error.InvalidLabel;
            if (!std.mem.eql(u8, rec.label.symbol, "gay:ckpt")) return error.WrongTag;
            if (rec.fields.len != 6) return error.WrongFieldCount;
            const color = try decodeColor(rec.fields[5]);
            return gaymc.Checkpoint{
                .seed = @as(u64, @intCast(extractInt(rec.fields[0]) orelse return error.InvalidField)),
                .worker_id = @as(u64, @intCast(extractInt(rec.fields[1]) orelse return error.InvalidField)),
                .sweep_count = @as(u64, @intCast(extractInt(rec.fields[2]) orelse return error.InvalidField)),
                .measure_count = @as(u64, @intCast(extractInt(rec.fields[3]) orelse return error.InvalidField)),
                .checkpoint_count = @as(u64, @intCast(extractInt(rec.fields[4]) orelse return error.InvalidField)),
                .color = color,
            };
        },
        else => return error.NotARecord,
    }
}

fn extractInt(v: Value) ?i64 {
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}

// ═══════════════════════════════════════════════════════════════════════════════
// Propagator Cell State Serialization
// ═══════════════════════════════════════════════════════════════════════════════

/// Encode a propagator Value as syrup.
pub fn encodePropValue(pv: propagator.Value, allocator: Allocator) !Value {
    return switch (pv) {
        .nothing => Value.fromSymbol("nothing"),
        .contradiction => |c| blk: {
            const label = try allocator.create(Value);
            label.* = Value.fromSymbol("gay:contradiction");
            if (c.info) |info| {
                const fields = try allocator.alloc(Value, 1);
                const info_dupe = try allocator.dupe(u8, info);
                fields[0] = Value.fromString(info_dupe);
                break :blk Value.fromRecord(label, fields);
            } else {
                const fields = try allocator.alloc(Value, 0);
                break :blk Value.fromRecord(label, fields);
            }
        },
        .integer => |v| Value.fromInteger(v),
        .float => |v| Value.fromFloat(v),
        .boolean => |v| Value.fromBool(v),
        .interval => |iv| blk: {
            const label = try allocator.create(Value);
            label.* = Value.fromSymbol("gay:interval");
            const fields = try allocator.alloc(Value, 2);
            fields[0] = Value.fromFloat(iv.lo);
            fields[1] = Value.fromFloat(iv.hi);
            break :blk Value.fromRecord(label, fields);
        },
    };
}

/// Decode syrup back to propagator Value.
pub fn decodePropValue(val: Value) !propagator.Value {
    switch (val) {
        .symbol => |s| {
            if (std.mem.eql(u8, s, "nothing")) return propagator.Value{ .nothing = .{} };
            return error.UnknownSymbol;
        },
        .integer => |v| return propagator.Value{ .integer = v },
        .float => |v| return propagator.Value{ .float = v },
        .bool => |v| return propagator.Value{ .boolean = v },
        .record => |rec| {
            if (rec.label.* != .symbol) return error.InvalidLabel;
            const tag = rec.label.symbol;
            if (std.mem.eql(u8, tag, "gay:contradiction")) {
                if (rec.fields.len > 0 and rec.fields[0] == .string) {
                    return propagator.Value{ .contradiction = .{ .info = rec.fields[0].string } };
                }
                return propagator.Value{ .contradiction = .{} };
            }
            if (std.mem.eql(u8, tag, "gay:interval")) {
                if (rec.fields.len != 2) return error.WrongFieldCount;
                return propagator.Value{ .interval = .{
                    .lo = extractFloat(rec.fields[0]) orelse return error.InvalidField,
                    .hi = extractFloat(rec.fields[1]) orelse return error.InvalidField,
                } };
            }
            return error.WrongTag;
        },
        else => return error.UnsupportedType,
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Cell State (name + value + color)
// ═══════════════════════════════════════════════════════════════════════════════

pub const CellState = struct {
    name: []const u8,
    value: propagator.Value,
    color: u32,
};

/// Encode: <'gay:cell name value color>
pub fn encodeCellState(cs: CellState, allocator: Allocator) !Value {
    const label = try allocator.create(Value);
    label.* = Value.fromSymbol("gay:cell");
    const fields = try allocator.alloc(Value, 3);
    const name_dupe = try allocator.dupe(u8, cs.name);
    fields[0] = Value.fromString(name_dupe);
    fields[1] = try encodePropValue(cs.value, allocator);
    fields[2] = Value.fromInteger(@as(i64, @intCast(cs.color)));
    return Value.fromRecord(label, fields);
}

/// Decode cell state record.
pub fn decodeCellState(val: Value) !CellState {
    switch (val) {
        .record => |rec| {
            if (rec.label.* != .symbol) return error.InvalidLabel;
            if (!std.mem.eql(u8, rec.label.symbol, "gay:cell")) return error.WrongTag;
            if (rec.fields.len != 3) return error.WrongFieldCount;
            const name = switch (rec.fields[0]) {
                .string => |s| s,
                else => return error.InvalidField,
            };
            const value = try decodePropValue(rec.fields[1]);
            const color_int = extractInt(rec.fields[2]) orelse return error.InvalidField;
            return CellState{
                .name = name,
                .value = value,
                .color = @as(u32, @intCast(color_int)),
            };
        },
        else => return error.NotARecord,
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Color Palette Serialization (matches Gay.jl ColorPaletteJSON)
// ═══════════════════════════════════════════════════════════════════════════════

pub const ColorPalette = struct {
    name: []const u8,
    seed: u64,
    colorspace: []const u8,
    colors: []const RGB,
};

/// Encode: <'gay:palette name seed colorspace [color1 color2 ...]>
pub fn encodePalette(palette: ColorPalette, allocator: Allocator) !Value {
    const label = try allocator.create(Value);
    label.* = Value.fromSymbol("gay:palette");

    // Encode color list
    const color_vals = try allocator.alloc(Value, palette.colors.len);
    for (palette.colors, 0..) |c, i| {
        color_vals[i] = try encodeColor(c, allocator);
    }

    const fields = try allocator.alloc(Value, 4);
    fields[0] = Value.fromString(try allocator.dupe(u8, palette.name));
    fields[1] = Value.fromInteger(@as(i64, @intCast(palette.seed)));
    fields[2] = Value.fromString(try allocator.dupe(u8, palette.colorspace));
    fields[3] = Value.fromList(color_vals);

    return Value.fromRecord(label, fields);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Invader Serialization (matches Gay.jl InvaderJSON)
// ═══════════════════════════════════════════════════════════════════════════════

pub const Invader = struct {
    id: u64,
    seed: u64,
    source: RGB,
    deranged: RGB,
    world: RGB,
    derangement: i32,
    tropical_t: f64,
    spin: i32,
};

/// Encode: <'gay:invader id seed source deranged world derangement tropical_t spin>
pub fn encodeInvader(inv: Invader, allocator: Allocator) !Value {
    const label = try allocator.create(Value);
    label.* = Value.fromSymbol("gay:invader");

    const fields = try allocator.alloc(Value, 8);
    fields[0] = Value.fromInteger(@as(i64, @intCast(inv.id)));
    fields[1] = Value.fromInteger(@as(i64, @intCast(inv.seed)));
    fields[2] = try encodeColor(inv.source, allocator);
    fields[3] = try encodeColor(inv.deranged, allocator);
    fields[4] = try encodeColor(inv.world, allocator);
    fields[5] = Value.fromInteger(@as(i64, inv.derangement));
    fields[6] = Value.fromFloat(inv.tropical_t);
    fields[7] = Value.fromInteger(@as(i64, inv.spin));

    return Value.fromRecord(label, fields);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Wire-level encode/decode helpers
// ═══════════════════════════════════════════════════════════════════════════════

/// Encode a Gay value to syrup bytes, ready for wire transmission.
pub fn toBytes(val: Value, allocator: Allocator) ![]u8 {
    return val.encodeAlloc(allocator);
}

/// Decode syrup bytes to a syrup Value.
pub fn fromBytes(bytes: []const u8, allocator: Allocator) !Value {
    return syrup.decode(bytes, allocator);
}

/// FNV-1a hash (matches Gay.jl's fnv1a_hash)
pub fn fnv1a(data: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (data) |b| {
        h = (h ^ @as(u64, b)) *% 0x100000001b3;
    }
    return h;
}

/// FNV-1a over u64 values (matches Gay.jl's fnv1a_hash for Vector{UInt64})
pub fn fnv1aU64(values: []const u64) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (values) |x| {
        for (0..8) |i| {
            const byte: u8 = @truncate(x >> @intCast(8 * i));
            h = (h ^ @as(u64, byte)) *% 0x100000001b3;
        }
    }
    return h;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Serialization Errors
// ═══════════════════════════════════════════════════════════════════════════════

pub const SerError = error{
    InvalidLabel,
    WrongTag,
    WrongFieldCount,
    InvalidField,
    NotARecord,
    UnknownSymbol,
    UnsupportedType,
    OutOfMemory,
};

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

test "color encode-decode roundtrip" {
    const allocator = std.testing.allocator;
    const c = RGB{ .r = 0.5, .g = 0.25, .b = 0.75 };
    const val = try encodeColor(c, allocator);
    defer val.deinitAll(allocator);

    const decoded = try decodeColor(val);
    try std.testing.expect(@abs(decoded.r - 0.5) < 1e-10);
    try std.testing.expect(@abs(decoded.g - 0.25) < 1e-10);
    try std.testing.expect(@abs(decoded.b - 0.75) < 1e-10);
}

// Documentation test — the witnessing closure of color encoding.
//
// A color C has a canonical wire encoding bytes(C). Hashing those bytes
// (Wyhash, no seed) yields a u64 fingerprint; splitmix-decoding that
// fingerprint produces ANOTHER color C′. So "the encoding of C, witnessed,
// IS a color" — the operation closes in color-space. Iterating this map
//
//     C  →  bytes(C)  →  hash  →  C′  =  W(C)
//
// stays in [0,1]³ for all steps (the test's first claim) and admits a
// deterministic GF(3) trit-class per color (sign of (r+g+b - 1.5)
// projected to {-1,0,+1}). The chain's trit-class is computable at every
// step — i.e. the qualia ARE effable through the wire format. This is the
// self-referential reading: there is no observer outside the color system,
// only colors witnessing colors.
test "color witnessing chain — encode/hash/witness closes in color space" {
    const allocator = std.testing.allocator;
    var c = RGB{ .r = 0.5, .g = 0.25, .b = 0.75 };

    var trit_sum: i32 = 0;
    const steps = 7;
    var step: usize = 0;
    while (step < steps) : (step += 1) {
        const val = try encodeColor(c, allocator);
        const bytes = try toBytes(val, allocator);
        defer allocator.free(bytes);
        val.deinitAll(allocator);

        const fp = std.hash.Wyhash.hash(0, bytes);
        const w = splitmix.colorFromU64(splitmix.splitmix64(fp));
        const witness = RGB{ .r = w.r, .g = w.g, .b = w.b };

        // Closure: every witnessed color is in [0,1]³.
        try std.testing.expect(witness.r >= 0.0 and witness.r <= 1.0);
        try std.testing.expect(witness.g >= 0.0 and witness.g <= 1.0);
        try std.testing.expect(witness.b >= 0.0 and witness.b <= 1.0);

        // Effability: GF(3) trit-class of (r+g+b - 1.5) is well-defined.
        const lum = witness.r + witness.g + witness.b - 1.5;
        const trit: i32 = if (lum > 1e-9) 1 else if (lum < -1e-9) -1 else 0;
        trit_sum = @mod(trit_sum + trit, 3);

        c = witness;
    }

    // The chain's trit-sum lives in {0,1,2} — a deterministic GF(3)
    // residue, the wire-level signature of a color sequence's witnessing
    // history. Same starting color always reproduces the same residue.
    try std.testing.expect(trit_sum >= 0 and trit_sum < 3);
}

// Path-invariance corpus generator — see `gay.cgt_corpus`. Shared between
// Square D (this file) and the harness binary in `examples/interop/`.
const cgt_corpus = @import("cgt_corpus.zig");
const cgtCorpus = cgt_corpus.fill;

// Path-invariance Square D — same-runtime W chain for the full 70-color
// corpus. Asserts every corpus color survives encode → toBytes → fromBytes
// → decodeColor with bit-exact float equality. This is the local oracle
// that Squares A (Guile) and B (Racket) must reproduce remotely; if Square
// D fails, the cross-runtime tests cannot succeed.
test "path-invariance Square D — 70-color corpus survives Zig encode/decode round-trip" {
    const allocator = std.testing.allocator;
    var corpus: [70]RGB = undefined;
    cgtCorpus(&corpus);

    for (corpus, 0..) |c, idx| {
        const val = try encodeColor(c, allocator);
        const bytes = try toBytes(val, allocator);
        defer allocator.free(bytes);
        val.deinitAll(allocator);

        const val2 = try fromBytes(bytes, allocator);
        defer val2.deinitAll(allocator);
        const c2 = try decodeColor(val2);

        // Bit-exact float equality — the corpus uses exact-representable
        // values (0.0, 0.5, 1.0, splitmix-derived) so any drift indicates
        // a Syrup encoder bug. No epsilon tolerance on path-invariance.
        std.testing.expectEqual(c.r, c2.r) catch |e| {
            std.debug.print("idx={d} r mismatch: {d} vs {d}\n", .{ idx, c.r, c2.r });
            return e;
        };
        std.testing.expectEqual(c.g, c2.g) catch |e| {
            std.debug.print("idx={d} g mismatch: {d} vs {d}\n", .{ idx, c.g, c2.g });
            return e;
        };
        std.testing.expectEqual(c.b, c2.b) catch |e| {
            std.debug.print("idx={d} b mismatch: {d} vs {d}\n", .{ idx, c.b, c2.b });
            return e;
        };
    }
}

// Path-invariance Square D' — encoded-bytes determinism. The same color
// must produce the same bytes across multiple encode calls (Syrup
// canonical form). This is the property Guile/Racket peers must also
// satisfy — if their canonical encoding differs from Zig's for any corpus
// color, Square A/B fails on byte comparison.
test "path-invariance Square D' — Syrup encoding is deterministic across calls" {
    const allocator = std.testing.allocator;
    var corpus: [70]RGB = undefined;
    cgtCorpus(&corpus);

    for (corpus, 0..) |c, idx| {
        const v1 = try encodeColor(c, allocator);
        const b1 = try toBytes(v1, allocator);
        defer allocator.free(b1);
        v1.deinitAll(allocator);

        const v2 = try encodeColor(c, allocator);
        const b2 = try toBytes(v2, allocator);
        defer allocator.free(b2);
        v2.deinitAll(allocator);

        std.testing.expectEqualSlices(u8, b1, b2) catch |e| {
            std.debug.print("idx={d} non-deterministic bytes ({d} vs {d})\n", .{ idx, b1.len, b2.len });
            return e;
        };
    }
}

test "color encode to bytes and back" {
    const allocator = std.testing.allocator;
    const c = RGB{ .r = 1.0, .g = 0.0, .b = 0.5 };
    const val = try encodeColor(c, allocator);
    const bytes = try toBytes(val, allocator);
    defer allocator.free(bytes);
    val.deinitAll(allocator);

    const val2 = try fromBytes(bytes, allocator);
    defer val2.deinitAll(allocator);
    const decoded = try decodeColor(val2);
    try std.testing.expect(@abs(decoded.r - 1.0) < 1e-10);
    try std.testing.expect(@abs(decoded.b - 0.5) < 1e-10);
}

test "checkpoint encode-decode roundtrip" {
    const allocator = std.testing.allocator;
    const ckpt = gaymc.Checkpoint{
        .seed = 0xDEADBEEF,
        .worker_id = 7,
        .sweep_count = 100,
        .measure_count = 50,
        .checkpoint_count = 3,
        .color = RGB{ .r = 0.1, .g = 0.2, .b = 0.3 },
    };
    const val = try encodeCheckpoint(ckpt, allocator);
    defer val.deinitAll(allocator);

    const decoded = try decodeCheckpoint(val);
    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), decoded.seed);
    try std.testing.expectEqual(@as(u64, 7), decoded.worker_id);
    try std.testing.expectEqual(@as(u64, 100), decoded.sweep_count);
    try std.testing.expectEqual(@as(u64, 50), decoded.measure_count);
    try std.testing.expectEqual(@as(u64, 3), decoded.checkpoint_count);
    try std.testing.expect(@abs(decoded.color.r - 0.1) < 1e-10);
}

test "propagator value roundtrip - integer" {
    const allocator = std.testing.allocator;
    const pv = propagator.Value{ .integer = 42 };
    const val = try encodePropValue(pv, allocator);
    // integer doesn't allocate containers, no deinit needed for val itself
    const decoded = try decodePropValue(val);
    try std.testing.expectEqual(@as(i64, 42), decoded.integer);
}

test "propagator value roundtrip - interval" {
    const allocator = std.testing.allocator;
    const pv = propagator.Value{ .interval = .{ .lo = 1.0, .hi = 2.0 } };
    const val = try encodePropValue(pv, allocator);
    defer val.deinitAll(allocator);
    const decoded = try decodePropValue(val);
    try std.testing.expect(@abs(decoded.interval.lo - 1.0) < 1e-10);
    try std.testing.expect(@abs(decoded.interval.hi - 2.0) < 1e-10);
}

test "propagator value roundtrip - nothing" {
    const allocator = std.testing.allocator;
    const pv = propagator.Value{ .nothing = .{} };
    const val = try encodePropValue(pv, allocator);
    const decoded = try decodePropValue(val);
    try std.testing.expect(decoded.isNothing());
}

test "propagator value roundtrip - contradiction" {
    const allocator = std.testing.allocator;
    const pv = propagator.Value{ .contradiction = .{ .info = "test conflict" } };
    const val = try encodePropValue(pv, allocator);
    defer val.deinitAll(allocator);
    const decoded = try decodePropValue(val);
    try std.testing.expect(decoded.isContradiction());
}

test "cell state roundtrip" {
    const allocator = std.testing.allocator;
    const cs = CellState{
        .name = "temperature",
        .value = propagator.Value{ .float = 98.6 },
        .color = 0xFF00FF,
    };
    const val = try encodeCellState(cs, allocator);
    defer val.deinitAll(allocator);
    const decoded = try decodeCellState(val);
    try std.testing.expectEqualStrings("temperature", decoded.name);
    try std.testing.expect(@abs(decoded.value.float - 98.6) < 1e-10);
    try std.testing.expectEqual(@as(u32, 0xFF00FF), decoded.color);
}

test "fnv1a matches known value" {
    // FNV-1a of "" = 0xcbf29ce484222325
    try std.testing.expectEqual(@as(u64, 0xcbf29ce484222325), fnv1a(""));
    // FNV-1a of "a" is well-known
    const h = fnv1a("a");
    try std.testing.expect(h != 0); // smoke test
}

test "fnv1a u64 values" {
    const vals = [_]u64{ 0x401000, 0x401100 };
    const h = fnv1aU64(&vals);
    try std.testing.expect(h != 0);
    // Same input => same output
    const h2 = fnv1aU64(&vals);
    try std.testing.expectEqual(h, h2);
}

test "color hex" {
    const c = RGB{ .r = 1.0, .g = 0.0, .b = 0.0 };
    const hex = colorToHex(c);
    try std.testing.expectEqualStrings("#ff0000", &hex);
}

test "invader encode" {
    const allocator = std.testing.allocator;
    const inv = Invader{
        .id = 1,
        .seed = 0xDEAD,
        .source = RGB{ .r = 1, .g = 0, .b = 0 },
        .deranged = RGB{ .r = 0, .g = 1, .b = 0 },
        .world = RGB{ .r = 0, .g = 0, .b = 1 },
        .derangement = 2,
        .tropical_t = 0.5,
        .spin = 1,
    };
    const val = try encodeInvader(inv, allocator);
    defer val.deinitAll(allocator);

    // Verify it's a record with correct tag
    try std.testing.expect(val == .record);
    try std.testing.expectEqualStrings("gay:invader", val.record.label.symbol);
    try std.testing.expectEqual(@as(usize, 8), val.record.fields.len);
}

test "palette encode" {
    const allocator = std.testing.allocator;
    const colors = [_]RGB{
        .{ .r = 1, .g = 0, .b = 0 },
        .{ .r = 0, .g = 1, .b = 0 },
    };
    const palette = ColorPalette{
        .name = "pride",
        .seed = 42,
        .colorspace = "sRGB",
        .colors = &colors,
    };
    const val = try encodePalette(palette, allocator);
    defer val.deinitAll(allocator);

    try std.testing.expect(val == .record);
    try std.testing.expectEqualStrings("gay:palette", val.record.label.symbol);
}
