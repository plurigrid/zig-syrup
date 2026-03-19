//! Standalone `.world` artifact demo for geodesic triadic search.
//!
//! The artifact is embedded at compile time so the executable is self-contained:
//! one `.world` file, one renderer, one canonical Syrup payload.

const std = @import("std");
const syrup = @import("syrup");

const testing = std.testing;
const Allocator = std.mem.Allocator;

const WORLD_SOURCE = @embedFile("geodesic_parallel.world");

const ArtifactError = error{
    InvalidArtifact,
    MissingField,
    WrongType,
    InvalidColor,
};

const LaneSpec = struct {
    name: []const u8,
    index: i64,
    hex: []const u8,
    trit: i64,
};

const STATE_NAMES = [_][]const u8{
    "blueprinted",
    "compilable",
    "runnable",
    "renderable",
};

const INCLUDE_SYMBOLS = [_][]const u8{
    "artifact",
    "compiler",
    "renderer",
    "lanes",
    "states",
    "cid",
};

const LANE_SPECS = [_]LaneSpec{
    .{ .name = "workflow", .index = 1, .hex = "#E67F86", .trit = 0 },
    .{ .name = "lexical", .index = 5, .hex = "#49EE54", .trit = -1 },
    .{ .name = "mathematical", .index = 574, .hex = "#70D43D", .trit = 1 },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const decoded = try syrup.decode(WORLD_SOURCE, allocator);
    defer decoded.deinitContainers(allocator);

    try renderArtifact(decoded, allocator, std.io.getStdOut().writer());
}

fn buildArtifact(allocator: Allocator) !syrup.Value {
    const includes = try allocator.alloc(syrup.Value, INCLUDE_SYMBOLS.len);
    for (INCLUDE_SYMBOLS, 0..) |symbol_name, i| {
        includes[i] = syrup.Value.fromSymbol(symbol_name);
    }

    const states = try allocator.alloc(syrup.Value, STATE_NAMES.len);
    for (STATE_NAMES, 0..) |state_name, i| {
        states[i] = try buildStateValue(allocator, state_name);
    }

    const lanes = try allocator.alloc(syrup.Value, LANE_SPECS.len);
    for (LANE_SPECS, 0..) |lane_spec, i| {
        lanes[i] = try buildLaneValue(allocator, lane_spec);
    }

    const compression = try buildCompressionValue(allocator);

    const entries = try allocator.alloc(syrup.Value.DictEntry, 11);
    entries[0] = dictEntry("kind", syrup.Value.fromString("world://plurigrid/geodesic"));
    entries[1] = dictEntry("name", syrup.Value.fromString("geodesic.parallel.triad"));
    entries[2] = dictEntry("seed", syrup.Value.fromInteger(1069));
    entries[3] = dictEntry("frontier", syrup.Value.fromInteger(574));
    entries[4] = dictEntry("standalone", syrup.Value.fromBool(true));
    entries[5] = dictEntry("compiler", syrup.Value.fromString("zig-syrup"));
    entries[6] = dictEntry("renderer", syrup.Value.fromString("terminal/chromatic"));
    entries[7] = dictEntry("includes", syrup.Value.fromList(includes));
    entries[8] = dictEntry("states", syrup.Value.fromList(states));
    entries[9] = dictEntry("lanes", syrup.Value.fromList(lanes));
    entries[10] = dictEntry("compression", compression);

    const label = try allocator.alloc(syrup.Value, 1);
    label[0] = syrup.Value.fromSymbol("world");

    const fields = try allocator.alloc(syrup.Value, 1);
    fields[0] = try syrup.dictionaryCanonical(allocator, entries);

    return syrup.Value.fromRecord(&label[0], fields);
}

fn buildStateValue(allocator: Allocator, state_name: []const u8) !syrup.Value {
    const entries = try allocator.alloc(syrup.Value.DictEntry, 2);
    entries[0] = dictEntry("name", syrup.Value.fromString(state_name));
    entries[1] = dictEntry("parallel", syrup.Value.fromBool(true));
    return syrup.dictionaryCanonical(allocator, entries);
}

fn buildLaneValue(allocator: Allocator, spec: LaneSpec) !syrup.Value {
    const entries = try allocator.alloc(syrup.Value.DictEntry, 4);
    entries[0] = dictEntry("name", syrup.Value.fromString(spec.name));
    entries[1] = dictEntry("index", syrup.Value.fromInteger(spec.index));
    entries[2] = dictEntry("hex", syrup.Value.fromString(spec.hex));
    entries[3] = dictEntry("trit", syrup.Value.fromInteger(spec.trit));
    return syrup.dictionaryCanonical(allocator, entries);
}

fn buildCompressionValue(allocator: Allocator) !syrup.Value {
    const entries = try allocator.alloc(syrup.Value.DictEntry, 3);
    entries[0] = dictEntry("motif", syrup.Value.fromString("WLWLWLWLM"));
    entries[1] = dictEntry("frontier", syrup.Value.fromInteger(574));
    entries[2] = dictEntry("optimal", syrup.Value.fromInteger(3));
    return syrup.dictionaryCanonical(allocator, entries);
}

fn dictEntry(key: []const u8, value: syrup.Value) syrup.Value.DictEntry {
    return .{
        .key = syrup.Value.fromSymbol(key),
        .value = value,
    };
}

fn renderArtifact(value: syrup.Value, allocator: Allocator, writer: anytype) !void {
    const body = try recordBody(value);
    const kind = try expectString(try dictValue(body, "kind"));
    const name = try expectString(try dictValue(body, "name"));
    const seed = try expectInt(try dictValue(body, "seed"));
    const frontier = try expectInt(try dictValue(body, "frontier"));
    const standalone = try expectBool(try dictValue(body, "standalone"));
    const compiler = try expectString(try dictValue(body, "compiler"));
    const renderer = try expectString(try dictValue(body, "renderer"));
    const includes = try expectList(try dictValue(body, "includes"));
    const states = try expectList(try dictValue(body, "states"));
    const lanes = try expectList(try dictValue(body, "lanes"));
    const compression = try expectDict(try dictValue(body, "compression"));
    const motif = try expectString(try dictValue(compression, "motif"));
    const optimal = try expectInt(try dictValue(compression, "optimal"));

    const cid_hex = try syrup.computeCidHex(value, allocator);
    defer allocator.free(cid_hex);

    try writer.print("Geodesic World Artifact\n", .{});
    try writer.print("  name: {s}\n", .{name});
    try writer.print("  kind: {s}\n", .{kind});
    try writer.print("  seed: 0x{x}\n", .{@as(u64, @intCast(seed))});
    try writer.print("  frontier: {d}\n", .{frontier});
    try writer.print("  optimal: {d}\n", .{optimal});
    try writer.print("  compression_gain: {d:.1}x\n", .{@as(f64, @floatFromInt(frontier)) / @as(f64, @floatFromInt(optimal))});
    try writer.print("  standalone: {s}\n", .{if (standalone) "true" else "false"});
    try writer.print("  compiler: {s}\n", .{compiler});
    try writer.print("  renderer: {s}\n", .{renderer});
    try writer.print("  cid: {s}\n", .{cid_hex});
    try writer.print("\nIncludes\n", .{});
    for (includes) |include_value| {
        try writer.print("  - {s}\n", .{try expectSymbol(include_value)});
    }

    try writer.print("\nParallel States\n", .{});
    for (states) |state_value| {
        const state_dict = try expectDict(state_value);
        const state_name = try expectString(try dictValue(state_dict, "name"));
        try writer.print("  - {s}\n", .{state_name});
    }

    try writer.print("\nChromatic Lanes\n", .{});
    for (lanes) |lane_value| {
        const lane_dict = try expectDict(lane_value);
        const lane_name = try expectString(try dictValue(lane_dict, "name"));
        const lane_index = try expectInt(try dictValue(lane_dict, "index"));
        const lane_hex = try expectString(try dictValue(lane_dict, "hex"));
        const lane_trit = try expectInt(try dictValue(lane_dict, "trit"));
        try writer.writeAll("  - ");
        try writeColorChip(writer, lane_hex);
        try writer.print(" {s} index={d} trit={d}\n", .{ lane_name, lane_index, lane_trit });
    }

    try writer.print("\nMotif\n  ", .{});
    try writeMotif(writer, lanes, motif);
    try writer.print(" {s}\n", .{motif});
}

fn writeMotif(writer: anytype, lanes: []const syrup.Value, motif: []const u8) !void {
    for (motif) |symbol| {
        const hex = switch (symbol) {
            'W' => try laneHexByName(lanes, "workflow"),
            'L' => try laneHexByName(lanes, "lexical"),
            'M' => try laneHexByName(lanes, "mathematical"),
            else => return ArtifactError.InvalidArtifact,
        };
        try writeColorChip(writer, hex);
    }
    try writer.writeAll("\x1b[0m");
}

fn laneHexByName(lanes: []const syrup.Value, lane_name: []const u8) ![]const u8 {
    for (lanes) |lane_value| {
        const lane_dict = try expectDict(lane_value);
        const current_name = try expectString(try dictValue(lane_dict, "name"));
        if (std.mem.eql(u8, current_name, lane_name)) {
            return expectString(try dictValue(lane_dict, "hex"));
        }
    }
    return ArtifactError.MissingField;
}

fn writeColorChip(writer: anytype, hex: []const u8) !void {
    const rgb = try parseHexRgb(hex);
    try writer.print("\x1b[38;2;{d};{d};{d}m██\x1b[0m", .{ rgb.r, rgb.g, rgb.b });
}

fn parseHexRgb(hex: []const u8) !struct { r: u8, g: u8, b: u8 } {
    if (hex.len != 7 or hex[0] != '#') return ArtifactError.InvalidColor;
    return .{
        .r = try std.fmt.parseInt(u8, hex[1..3], 16),
        .g = try std.fmt.parseInt(u8, hex[3..5], 16),
        .b = try std.fmt.parseInt(u8, hex[5..7], 16),
    };
}

fn recordBody(value: syrup.Value) ![]const syrup.Value.DictEntry {
    return switch (value) {
        .record => |record_value| blk: {
            if (!matchesSymbol(record_value.label.*, "world")) return ArtifactError.InvalidArtifact;
            if (record_value.fields.len != 1) return ArtifactError.InvalidArtifact;
            break :blk try expectDict(record_value.fields[0]);
        },
        else => ArtifactError.WrongType,
    };
}

fn dictValue(entries: []const syrup.Value.DictEntry, key: []const u8) !syrup.Value {
    for (entries) |entry| {
        if (matchesSymbol(entry.key, key)) return entry.value;
    }
    return ArtifactError.MissingField;
}

fn matchesSymbol(value: syrup.Value, key: []const u8) bool {
    return switch (value) {
        .symbol => |symbol_name| std.mem.eql(u8, symbol_name, key),
        else => false,
    };
}

fn expectDict(value: syrup.Value) ![]const syrup.Value.DictEntry {
    return switch (value) {
        .dictionary => |entries| entries,
        else => ArtifactError.WrongType,
    };
}

fn expectList(value: syrup.Value) ![]const syrup.Value {
    return switch (value) {
        .list => |items| items,
        else => ArtifactError.WrongType,
    };
}

fn expectString(value: syrup.Value) ![]const u8 {
    return switch (value) {
        .string => |string_value| string_value,
        else => ArtifactError.WrongType,
    };
}

fn expectSymbol(value: syrup.Value) ![]const u8 {
    return switch (value) {
        .symbol => |symbol_value| symbol_value,
        else => ArtifactError.WrongType,
    };
}

fn expectInt(value: syrup.Value) !i64 {
    return switch (value) {
        .integer => |integer_value| integer_value,
        else => ArtifactError.WrongType,
    };
}

fn expectBool(value: syrup.Value) !bool {
    return switch (value) {
        .bool => |bool_value| bool_value,
        else => ArtifactError.WrongType,
    };
}

test "embedded world artifact matches generated canonical encoding" {
    const decoded = try syrup.decode(WORLD_SOURCE, testing.allocator);
    defer decoded.deinitContainers(testing.allocator);

    const generated = try buildArtifact(testing.allocator);
    defer generated.deinitContainers(testing.allocator);

    var decoded_buf: [2048]u8 = undefined;
    var generated_buf: [2048]u8 = undefined;

    const decoded_bytes = try decoded.encodeBuf(&decoded_buf);
    const generated_bytes = try generated.encodeBuf(&generated_buf);

    try testing.expectEqualStrings(generated_bytes, decoded_bytes);
}

test "embedded world artifact exposes triadic frontier metadata" {
    const decoded = try syrup.decode(WORLD_SOURCE, testing.allocator);
    defer decoded.deinitContainers(testing.allocator);

    const body = try recordBody(decoded);
    try testing.expectEqualStrings("geodesic.parallel.triad", try expectString(try dictValue(body, "name")));
    try testing.expectEqual(@as(i64, 1069), try expectInt(try dictValue(body, "seed")));
    try testing.expectEqual(@as(i64, 574), try expectInt(try dictValue(body, "frontier")));

    const lanes = try expectList(try dictValue(body, "lanes"));
    try testing.expectEqual(@as(usize, 3), lanes.len);

    const first_lane = try expectDict(lanes[0]);
    try testing.expectEqualStrings("workflow", try expectString(try dictValue(first_lane, "name")));
    try testing.expectEqualStrings("#E67F86", try expectString(try dictValue(first_lane, "hex")));
}
