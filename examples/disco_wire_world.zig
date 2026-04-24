//! Render the Disco wire world artifact embedded as Syrup.

const std = @import("std");
const syrup = @import("syrup");

const testing = std.testing;

const WORLD_SOURCE = @embedFile("disco_wire.world");

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
    const standalone = try expectDict(try dictValue(body, "standalone"));
    const rendering_paths = try expectList(try dictValue(body, "rendering_paths"));
    const goblins_hoot = try expectDict(try dictValue(body, "goblins_hoot"));
    const catcolab = try expectDict(try dictValue(body, "catcolab"));
    const dataflow = try expectDict(try dictValue(body, "dataflow"));
    const zen_today = try expectList(try dictValue(body, "zen_today"));
    const status = try expectDict(try dictValue(body, "status"));

    try writer.print("Disco wire world\n", .{});
    try writer.print("  name: {s}\n", .{name});
    try writer.print("  kind: {s}\n", .{kind});
    try writer.print("  world_uri: {s}\n", .{world_uri});
    try writer.print("  standalone.target: {s}\n", .{
        try expectString(try dictValue(standalone, "target")),
    });
    try writer.print("  standalone.artifact: {s}\n", .{
        try expectString(try dictValue(standalone, "artifact")),
    });
    try writer.print("  status.validation: {s}\n", .{
        try expectString(try dictValue(status, "validation")),
    });

    try writer.print("\nRendering paths\n", .{});
    for (rendering_paths) |path_value| {
        const path = try expectDict(path_value);
        try writer.print("  - {s}: {s}\n", .{
            try expectString(try dictValue(path, "name")),
            try expectString(try dictValue(path, "role")),
        });
    }

    try writer.print("\nGoblins and Hoot\n", .{});
    try writer.print("  hoot: {s}\n", .{
        try expectString(try dictValue(goblins_hoot, "hoot")),
    });
    try writer.print("  goblins: {s}\n", .{
        try expectString(try dictValue(goblins_hoot, "goblins")),
    });
    try writer.print("  state_of_the_art:\n", .{});
    for (try expectList(try dictValue(goblins_hoot, "state_of_the_art"))) |item| {
        try writer.print("    - {s}\n", .{try expectString(item)});
    }

    try writer.print("\nCatColab\n", .{});
    try writer.print("  delayed_action: {s}\n", .{
        try expectString(try dictValue(catcolab, "delayed_action")),
    });
    for (try expectList(try dictValue(catcolab, "regulatory_mechanisms"))) |item| {
        try writer.print("  - {s}\n", .{try expectString(item)});
    }

    try writer.print("\nDataflow\n", .{});
    try writer.print("  nuworlds: {s}\n", .{
        try expectString(try dictValue(dataflow, "nuworlds")),
    });
    try writer.print("  lazyframe: {s}\n", .{
        try expectString(try dictValue(dataflow, "lazyframe")),
    });
    try writer.print("  interleaving: {s}\n", .{
        try expectString(try dictValue(dataflow, "interleaving")),
    });
    try writer.print("  jlcolor: {s}\n", .{
        try expectString(try dictValue(dataflow, "jlcolor")),
    });

    try writer.print("\nZen today\n", .{});
    for (zen_today) |item| {
        try writer.print("  - {s}\n", .{try expectString(item)});
    }
}

fn recordBody(value: syrup.Value) ![]const syrup.Value.DictEntry {
    return switch (value) {
        .record => |record_value| blk: {
            if (!matchesSymbol(record_value.label.*, "world")) {
                return ArtifactError.InvalidArtifact;
            }
            if (record_value.fields.len != 1) return ArtifactError.InvalidArtifact;
            break :blk try expectDict(record_value.fields[0]);
        },
        // Handle dict-encoded records: {$label: "world", $fields: [...]}
        .dictionary => |entries| blk: {
            var label_ok = false;
            var fields_val: ?syrup.Value = null;
            for (entries) |entry| {
                if (matchesString(entry.key, "$label")) {
                    if (matchesString(entry.value, "world")) label_ok = true;
                } else if (matchesString(entry.key, "$fields")) {
                    fields_val = entry.value;
                }
            }
            if (!label_ok) return ArtifactError.InvalidArtifact;
            const fields = fields_val orelse return ArtifactError.MissingField;
            const items = switch (fields) {
                .list => |list| list,
                else => return ArtifactError.WrongType,
            };
            if (items.len != 1) return ArtifactError.InvalidArtifact;
            break :blk try expectDict(items[0]);
        },
        else => ArtifactError.WrongType,
    };
}

fn dictValue(entries: []const syrup.Value.DictEntry, key: []const u8) !syrup.Value {
    for (entries) |entry| {
        if (matchesSymbol(entry.key, key) or matchesString(entry.key, key)) return entry.value;
    }
    return ArtifactError.MissingField;
}

fn matchesSymbol(value: syrup.Value, key: []const u8) bool {
    return switch (value) {
        .symbol => |symbol_name| std.mem.eql(u8, symbol_name, key),
        else => false,
    };
}

fn matchesString(value: syrup.Value, key: []const u8) bool {
    return switch (value) {
        .string => |s| std.mem.eql(u8, s, key),
        .symbol => |s| std.mem.eql(u8, s, key),
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

test "embedded disco world decodes" {
    const decoded = try syrup.decode(WORLD_SOURCE, testing.allocator);
    defer decoded.deinitContainers(testing.allocator);

    const body = try recordBody(decoded);
    try testing.expectEqualStrings(
        "disco.wire.world",
        try expectString(try dictValue(body, "name")),
    );
    try testing.expectEqualStrings(
        "world://ies/disco/wire",
        try expectString(try dictValue(body, "world_uri")),
    );
}

test "embedded disco world contains four rendering paths" {
    const decoded = try syrup.decode(WORLD_SOURCE, testing.allocator);
    defer decoded.deinitContainers(testing.allocator);

    const body = try recordBody(decoded);
    const rendering_paths = try expectList(try dictValue(body, "rendering_paths"));
    try testing.expectEqual(@as(usize, 4), rendering_paths.len);
}
