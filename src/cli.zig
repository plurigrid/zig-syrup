const std = @import("std");
const syrup = @import("syrup.zig");
const Value = syrup.Value;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} [encode|decode]\n", .{args[0]});
        std.process.exit(1);
    }

    const mode = args[1];
    
    const stdin_file = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    const stdout_file = std.fs.File{ .handle = std.posix.STDOUT_FILENO };

    const stdin = std.io.GenericReader(std.fs.File, std.fs.File.ReadError, std.fs.File.read){ .context = stdin_file };
    const stdout = std.io.GenericWriter(std.fs.File, std.fs.File.WriteError, std.fs.File.write){ .context = stdout_file };

    if (std.mem.eql(u8, mode, "encode")) {
        const input = try stdin.readAllAlloc(allocator, 1024 * 1024 * 10); // 10MB limit
        defer allocator.free(input);

        // Parse JSON
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
        defer parsed.deinit();

        // Convert to Syrup Value
        var syrup_val = try jsonToSyrup(allocator, parsed.value);
        // Note: syrup_val might share memory with parsed.value or allocate new

        // Encode to stdout
        // We need a writer that implements the Writer interface
        // syrup.Value.encode takes a writer
        try syrup_val.encode(stdout);

    } else if (std.mem.eql(u8, mode, "decode")) {
        // Read all stdin (Syrup bytes)
        const input = try stdin.readAllAlloc(allocator, 1024 * 1024 * 10);
        defer allocator.free(input);

        // Decode Syrup
        // Use the arena allocator for the decoded value to simplify cleanup
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const val = try syrup.decode(input, arena_alloc);

        // Convert to JSON and print
        // std.json.stringify handles writing to a stream
        const jval = try syrupToJson(arena_alloc, val);
        try stdout.print("{f}", .{std.json.fmt(jval, .{})});

    } else {
        std.debug.print("Unknown mode: {s}\n", .{mode});
        std.process.exit(1);
    }
}

fn jsonToSyrup(allocator: std.mem.Allocator, json_val: std.json.Value) !Value {
    switch (json_val) {
        .null => return .null,
        .bool => |b| return Value{ .bool = b },
        .integer => |i| return Value{ .integer = i },
        .float => |f| return Value{ .float = f },
        .number_string => |s| {
            // Try to parse as integer, then float
            if (std.fmt.parseInt(i64, s, 10)) |i| {
                return Value{ .integer = i };
            } else |_| {
                const f = try std.fmt.parseFloat(f64, s);
                return Value{ .float = f };
            }
        },
        .string => |s| return Value{ .string = s }, // Shares memory if possible
        .array => |arr| {
            var list = try allocator.alloc(Value, arr.items.len);
            for (arr.items, 0..) |item, i| {
                list[i] = try jsonToSyrup(allocator, item);
            }
            return Value{ .list = list };
        },
        .object => |obj| {
            var entries = try allocator.alloc(Value.DictEntry, obj.count());
            var i: usize = 0;
            var it = obj.iterator();
            while (it.next()) |entry| {
                // Syrup dictionary keys are values (usually strings or symbols)
                // JSON object keys are strings.
                // We convert JSON key (string) to Syrup string.
                const key_val = Value{ .string = entry.key_ptr.* };
                const val_val = try jsonToSyrup(allocator, entry.value_ptr.*);
                entries[i] = .{ .key = key_val, .value = val_val };
                i += 1;
            }
            // Syrup requires sorted keys? Value.dictionary will sort them if we use the constructor?
            // Actually Value.dictionary is just a slice. The encoder expects them sorted?
            // Let's assume the library handles it or we need to sort.
            // syrup.zig says "Canonical encoding (auto-sorted dicts/sets)" 
            // but checking the encode implementation would be safe.
            // For now, let's sort them.
            std.sort.block(Value.DictEntry, entries, {}, compareDictEntries);
            return Value{ .dictionary = entries };
        },
    }
}

fn compareDictEntries(context: void, a: Value.DictEntry, b: Value.DictEntry) bool {
    _ = context;
    // Use Value.compare which implements the correct canonical ordering (length-first for strings)
    return a.key.compare(b.key) == .lt;
}

fn syrupToJson(allocator: std.mem.Allocator, syrup_val: Value) !std.json.Value {
    switch (syrup_val) {
        .null, .undefined => return .null,
        .bool => |b| return std.json.Value{ .bool = b },
        .integer => |i| return std.json.Value{ .integer = i },
        .bigint => |bi| {
            // Convert to string or float? JSON doesn't support bigint well.
            // Converting to float (precision loss) or string.
            // Let's use float for now as it's common JSON practice, or maybe string?
            // syrup-transport.ts uses JSON.parse which produces numbers.
            // Let's try to convert to i64 if it fits, else float.
            if (bi.toI128()) |i| {
                 if (i >= std.math.minInt(i64) and i <= std.math.maxInt(i64)) {
                     return std.json.Value{ .integer = @intCast(i) };
                 }
            }
            // Fallback to null/error? Or float.
            return .null; // TODO: Better bigint handling
        },
        .float32 => |f| return std.json.Value{ .float = @floatCast(f) },
        .float => |f| return std.json.Value{ .float = f },
        .string => |s| return std.json.Value{ .string = s },
        .symbol => |s| return std.json.Value{ .string = s }, // Map symbols to strings
        .bytes => |b| {
             // JSON doesn't support bytes. Base64?
             // Or maybe just string if it's UTF8?
             // For now, let's assume it's string-compatible or error.
             return std.json.Value{ .string = b }; 
        },
        .list => |l| {
            var arr = std.json.Array.init(allocator);
            for (l) |item| {
                try arr.append(try syrupToJson(allocator, item));
            }
            return std.json.Value{ .array = arr };
        },
        .dictionary => |d| {
            var obj = std.json.ObjectMap.init(allocator);
            for (d) |entry| {
                // Keys must be strings in JSON
                switch (entry.key) {
                    .string, .symbol => |k| {
                         try obj.put(k, try syrupToJson(allocator, entry.value));
                    },
                    else => {
                        // Skip non-string keys or convert to string repr
                        // TODO: Handle complex keys
                    }
                }
            }
            return std.json.Value{ .object = obj };
        },
        .set => |s| {
            // Map set to array
            var arr = std.json.Array.init(allocator);
            for (s) |item| {
                try arr.append(try syrupToJson(allocator, item));
            }
            return std.json.Value{ .array = arr };
        },
        .record => |r| {
             // Map record to object with special field?
             // Or just an array [label, fields...]
             // syrup-transport.ts expects JSON objects.
             // Let's map to object: { "$label": label, "$fields": [...] }
             var obj = std.json.ObjectMap.init(allocator);
             // Label is a Value
             const label_json = try syrupToJson(allocator, r.label.*);
             try obj.put("$label", label_json);
             
             var fields_arr = std.json.Array.init(allocator);
             for (r.fields) |arg| {
                 try fields_arr.append(try syrupToJson(allocator, arg));
             }
             try obj.put("$fields", std.json.Value{ .array = fields_arr });
             return std.json.Value{ .object = obj };
        },
        .tagged => |_| return .null, // TODO
        .@"error" => |_| return .null, // TODO
    }
}
