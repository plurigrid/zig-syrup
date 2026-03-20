//! Standalone `.world` chronoscope for Hylomorph in `world://ies`.

const std = @import("std");
const syrup = @import("syrup");

const testing = std.testing;

const WORLD_SOURCE = @embedFile("hylomorph_chronoscope.world");

const ArtifactError = error{
    InvalidArtifact,
    MissingField,
    WrongType,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const decoded = try syrup.decode(WORLD_SOURCE, allocator);
    defer decoded.deinitContainers(allocator);

    try renderArtifact(decoded, std.io.getStdOut().writer());
}

fn renderArtifact(value: syrup.Value, writer: anytype) !void {
    const body = try recordBody(value);
    const name = try expectString(try dictValue(body, "name"));
    const kind = try expectString(try dictValue(body, "kind"));
    const world_uri = try expectString(try dictValue(body, "world_uri"));
    const ownership = try expectDict(try dictValue(body, "ownership"));
    const ologs = try expectList(try dictValue(body, "ologs"));
    const tables = try expectList(try dictValue(body, "tables"));
    const sequence = try expectList(try dictValue(body, "chronoscope_sequence"));
    const split = try expectList(try dictValue(body, "implementation_split"));
    const delayed_action = try expectDict(try dictValue(body, "delayed_action"));
    const runner = try expectString(try dictValue(ownership, "runner"));
    const proposer = try expectString(try dictValue(ownership, "proposer"));
    const committer = try expectString(try dictValue(ownership, "committer"));
    const memory = try expectString(try dictValue(ownership, "memory"));
    const mechanism = try expectString(try dictValue(delayed_action, "mechanism"));

    try writer.print("Hylomorph Chronoscope\n", .{});
    try writer.print("  name: {s}\n", .{name});
    try writer.print("  kind: {s}\n", .{kind});
    try writer.print("  world_uri: {s}\n", .{world_uri});
    try writer.print("  owner.runner: {s}\n", .{runner});
    try writer.print("  owner.proposer: {s}\n", .{proposer});
    try writer.print("  owner.committer: {s}\n", .{committer});
    try writer.print("  owner.memory: {s}\n", .{memory});
    try writer.print("  delayed_action: {s}\n", .{mechanism});

    try writer.print("\nOlogs\n", .{});
    for (ologs, 0..) |olog_value, i| {
        const olog = try expectDict(olog_value);
        const title = try expectString(try dictValue(olog, "title"));
        const objects = try expectList(try dictValue(olog, "objects"));
        const arrows = try expectList(try dictValue(olog, "arrows"));
        try writer.print("  {d}. {s} objects={d} arrows={d}\n", .{ i + 1, title, objects.len, arrows.len });
    }

    try writer.print("\nChronoscope Sequence\n", .{});
    for (sequence) |item| {
        try writer.print("  - {s}\n", .{try expectString(item)});
    }

    try writer.print("\nTables\n", .{});
    for (tables) |table_value| {
        const table = try expectDict(table_value);
        const table_name = try expectString(try dictValue(table, "name"));
        const columns = try expectList(try dictValue(table, "columns"));
        try writer.print("  - {s} columns={d}\n", .{ table_name, columns.len });
    }

    try writer.print("\nImplementation Split\n", .{});
    for (split) |runtime_value| {
        const runtime_dict = try expectDict(runtime_value);
        const runtime_name = try expectString(try dictValue(runtime_dict, "runtime"));
        const uses = try expectList(try dictValue(runtime_dict, "uses"));
        try writer.print("  - {s} uses={d}\n", .{ runtime_name, uses.len });
    }
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

test "embedded hylomorph chronoscope decodes" {
    const decoded = try syrup.decode(WORLD_SOURCE, testing.allocator);
    defer decoded.deinitContainers(testing.allocator);

    const body = try recordBody(decoded);
    try testing.expectEqualStrings("hylomorph.chronoscope", try expectString(try dictValue(body, "name")));
    try testing.expectEqualStrings("world://ies", try expectString(try dictValue(body, "world_uri")));
}

test "embedded hylomorph chronoscope carries three ologs and four tables" {
    const decoded = try syrup.decode(WORLD_SOURCE, testing.allocator);
    defer decoded.deinitContainers(testing.allocator);

    const body = try recordBody(decoded);
    const ologs = try expectList(try dictValue(body, "ologs"));
    const tables = try expectList(try dictValue(body, "tables"));
    try testing.expectEqual(@as(usize, 3), ologs.len);
    try testing.expectEqual(@as(usize, 4), tables.len);
}
