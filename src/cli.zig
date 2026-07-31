const std = @import("std");
const syrup = @import("syrup.zig");
const Value = syrup.Value;

/// Largest accepted stdin payload. Inputs of exactly this size are accepted;
/// anything larger yields `error.StreamTooLong`.
const max_input_bytes = 1024 * 1024 * 10;

/// Buffer sizes for the `std.Io` stdio writers/readers. `std.Io.File.Writer`
/// and `std.Io.File.Reader` require the caller to supply the buffer.
const stdio_buffer_size = 4096;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // `Args.toSlice` may reference several allocations and may point into the
    // args vector itself, so it requires an arena — `init.arena` is exactly
    // that, and is released by the runtime on exit.
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        fatal(io, "Usage: {s} [encode|decode]\n", .{if (args.len > 0) args[0] else "syrup"});
    }

    const mode = args[1];

    // stdout is a pipe or a tty in practice; `writerStreaming` skips the
    // failed positional-write syscall that `writer` would attempt first.
    var stdout_buffer: [stdio_buffer_size]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    if (std.mem.eql(u8, mode, "encode")) {
        const input = try readAllStdin(io, gpa);
        defer gpa.free(input);

        // Parse JSON and convert to a Syrup Value inside one arena, mirroring
        // the decode path: `jsonToSyrup` allocates list/dict slices that would
        // otherwise leak (the converted value shares string memory with the
        // parsed JSON, so per-node ownership is impractical to free piecemeal).
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena_alloc, input, .{});

        // Convert to Syrup Value
        const syrup_val = try jsonToSyrup(arena_alloc, parsed);

        // Encode to stdout
        try syrup_val.encode(stdout);
    } else if (std.mem.eql(u8, mode, "decode")) {
        // Read all stdin (Syrup bytes)
        const input = try readAllStdin(io, gpa);
        defer gpa.free(input);

        // Decode Syrup
        // Use the arena allocator for the decoded value to simplify cleanup
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const val = try syrup.decode(input, arena_alloc);

        // Convert to JSON and print
        const jval = try syrupToJson(arena_alloc, val);
        try stdout.print("{f}", .{std.json.fmt(jval, .{})});
    } else {
        fatal(io, "Unknown mode: {s}\n", .{mode});
    }

    try stdout.flush();
}

/// Write a message to stderr and exit(1). Flushes before exiting: `exit` does
/// not run deferred code, so the buffered writer must be drained by hand.
fn fatal(io: std.Io, comptime format: []const u8, args: anytype) noreturn {
    var buffer: [512]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(io, &buffer);
    stderr_writer.interface.print(format, args) catch {};
    stderr_writer.interface.flush() catch {};
    std.process.exit(1);
}

/// Read all of stdin into an allocated buffer owned by the caller.
fn readAllStdin(io: std.Io, gpa: std.mem.Allocator) ![]u8 {
    var stdin_buffer: [stdio_buffer_size]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buffer);
    // `allocRemaining` fails once the limit is *reached*, so ask for one byte
    // more than the maximum in order to accept an input of exactly the max.
    return stdin_reader.interface.allocRemaining(gpa, .limited(max_input_bytes + 1));
}

// Explicit `anyerror` return type (rather than inferred): `jsonToSyrup` and
// `dictFromJsonPairs` are mutually recursive, and Zig cannot resolve a cycle
// of two inferred error sets referencing each other — one side must be
// concrete to break the loop.
fn jsonToSyrup(allocator: std.mem.Allocator, json_val: std.json.Value) anyerror!Value {
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
            // `{"$dict": [[k, v], ...]}` is the explicit pair-list form that
            // `syrupToJson` emits for every syrup dictionary: syrup dict keys
            // need not be unique strings (unlike JSON object keys), so they
            // cannot in general be folded into a JSON object without lossy
            // synthetic key-rendering. Recognize the pair-list form here so
            // syrup -> JSON -> syrup round-trips even for dicts with
            // non-string or duplicate keys.
            if (obj.count() == 1) {
                if (obj.get("$dict")) |pairs| {
                    return try dictFromJsonPairs(allocator, pairs);
                }
                if (obj.get("$bytes")) |hex_val| {
                    return try bytesFromJsonHex(allocator, hex_val);
                }
            }

            // Backward-compatible shorthand: a plain JSON object is a dict
            // with string keys. JSON objects have no defined member order,
            // so (unlike the `$dict` form, which preserves order exactly)
            // this shorthand sorts into canonical order.
            var entries = try allocator.alloc(Value.DictEntry, obj.count());
            var i: usize = 0;
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key_val = Value{ .string = entry.key_ptr.* };
                const val_val = try jsonToSyrup(allocator, entry.value_ptr.*);
                entries[i] = .{ .key = key_val, .value = val_val };
                i += 1;
            }
            std.sort.block(Value.DictEntry, entries, {}, compareDictEntries);
            return Value{ .dictionary = entries };
        },
    }
}

/// Decode the `{"$dict": [[k, v], ...]}` pair-list form into a syrup
/// dictionary. Each pair's key/value are themselves recursively decoded by
/// `jsonToSyrup`, so a key can be anything JSON can express (string, number,
/// nested `$dict`/array, ...) — there is no restriction to string keys here.
/// Pair order is preserved exactly (no sort): this form exists precisely so
/// non-canonical order and duplicate keys survive a round-trip.
fn dictFromJsonPairs(allocator: std.mem.Allocator, pairs_val: std.json.Value) !Value {
    const pairs = switch (pairs_val) {
        .array => |a| a.items,
        else => return error.InvalidDictFormat,
    };
    var entries = try allocator.alloc(Value.DictEntry, pairs.len);
    for (pairs, 0..) |pair, idx| {
        const pair_items = switch (pair) {
            .array => |pa| pa.items,
            else => return error.InvalidDictFormat,
        };
        if (pair_items.len != 2) return error.InvalidDictFormat;
        entries[idx] = .{
            .key = try jsonToSyrup(allocator, pair_items[0]),
            .value = try jsonToSyrup(allocator, pair_items[1]),
        };
    }
    return Value{ .dictionary = entries };
}

/// Decode the `{"$bytes": "<lowercase-hex>"}` tagged form into a syrup byte
/// string. This is the inverse of `syrupToJson`'s `.bytes` arm for the case
/// where the bytes are not valid UTF-8 (see there for why a plain JSON
/// string cannot always carry a `.bytes` value losslessly). `hexToBytes`
/// already reports odd-length input (`error.InvalidLength`) and non-hex
/// characters (`error.InvalidCharacter`) as ordinary errors rather than
/// panicking; they propagate unchanged here.
fn bytesFromJsonHex(allocator: std.mem.Allocator, hex_val: std.json.Value) !Value {
    const hex_str = switch (hex_val) {
        .string => |s| s,
        else => return error.InvalidBytesFormat,
    };
    const out = try allocator.alloc(u8, hex_str.len / 2);
    return Value{ .bytes = try std.fmt.hexToBytes(out, hex_str) };
}

fn compareDictEntries(context: void, a: Value.DictEntry, b: Value.DictEntry) bool {
    _ = context;
    // Use Value.compare which implements the correct canonical ordering (length-first for strings)
    return a.key.compare(b.key) == .lt;
}

/// Lowercase-hex encode `data` into an allocator-owned buffer, for the
/// `{"$bytes": "<hex>"}` tagged form. `std.fmt.bytesToHex` returns a
/// comptime-sized `[input.len * 2]u8` array, which doesn't fit a
/// runtime-length `.bytes` slice -- hence this hand-rolled variant.
fn bytesToHexAlloc(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const charset = "0123456789abcdef";
    const out = try allocator.alloc(u8, data.len * 2);
    for (data, 0..) |b, i| {
        out[i * 2 + 0] = charset[b >> 4];
        out[i * 2 + 1] = charset[b & 15];
    }
    return out;
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
            // Bigint doesn't fit in i64 — encode as string with "$bigint" prefix
            return std.json.Value{ .string = "$bigint" };
        },
        .float32 => |f| return std.json.Value{ .float = @floatCast(f) },
        .float => |f| return std.json.Value{ .float = f },
        .string => |s| return std.json.Value{ .string = s },
        .symbol => |s| return std.json.Value{ .string = s }, // Map symbols to strings
        .bytes => |b| {
            // Valid UTF-8 renders as a plain JSON string (cheapest common
            // case, and what most byte-strings in practice are: identifiers,
            // ASCII tokens, ...). Invalid UTF-8 cannot go through
            // `std.json.Value{.string = b}` safely: Zig's json writer
            // (`std.json.Stringify.write`, std/json/Stringify.zig) validates
            // with `std.unicode.utf8ValidateSlice` and, on invalid input,
            // silently reshapes the value into a JSON array of byte
            // integers instead of a string -- measured directly, not
            // assumed. That's syntactically valid JSON, but the output
            // shape now depends on byte content in a way callers can't
            // predict, and it does not round-trip: `jsonToSyrup` would
            // decode `[255]` back as a syrup *list* of one integer, not a
            // one-byte string, silently changing the value's type. Make the
            // fallback explicit and structural instead of accidental: an
            // object tag distinguishable from both a string and a list,
            // consistent with the `$dict`/`$label`/`$fields` convention
            // used elsewhere in this function (a string-prefix convention
            // was rejected for the analogous dict-key problem because it
            // can collide with genuine string data -- an object shape
            // can't).
            if (std.unicode.utf8ValidateSlice(b)) {
                return std.json.Value{ .string = b };
            }
            var obj: std.json.ObjectMap = .empty;
            try obj.put(allocator, "$bytes", std.json.Value{ .string = try bytesToHexAlloc(allocator, b) });
            return std.json.Value{ .object = obj };
        },
        .list => |l| {
            var arr = std.json.Array.init(allocator);
            for (l) |item| {
                try arr.append(try syrupToJson(allocator, item));
            }
            return std.json.Value{ .array = arr };
        },
        .dictionary => |d| {
            // Syrup dictionaries have no constraint that JSON objects do
            // (unique string keys) — a syrup key can be bytes, an integer, a
            // list, another dict, anything, and keys may repeat. Forcing that
            // into a JSON object requires either lossy key-to-string
            // rendering (which can collide with genuine data, or with each
            // other) or dropping duplicates outright. Instead, represent the
            // dictionary as an ordered list of `[key, value]` pairs, mirroring
            // the `$label`/`$fields` convention used for records below.
            // Order is preserved as decoded (already canonical from the
            // decoder); the key is recursively converted by `syrupToJson`
            // just like any value, so e.g. a `.bytes` key renders exactly the
            // way a `.bytes` value would (see the `.bytes` arm above) — no
            // second, key-specific rendering scheme.
            var pairs = std.json.Array.init(allocator);
            for (d) |entry| {
                var pair = std.json.Array.init(allocator);
                try pair.append(try syrupToJson(allocator, entry.key));
                try pair.append(try syrupToJson(allocator, entry.value));
                try pairs.append(std.json.Value{ .array = pair });
            }
            var obj: std.json.ObjectMap = .empty;
            try obj.put(allocator, "$dict", std.json.Value{ .array = pairs });
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
            var obj: std.json.ObjectMap = .empty;
            // Label is a Value
            const label_json = try syrupToJson(allocator, r.label.*);
            try obj.put(allocator, "$label", label_json);

            var fields_arr = std.json.Array.init(allocator);
            for (r.fields) |arg| {
                try fields_arr.append(try syrupToJson(allocator, arg));
            }
            try obj.put(allocator, "$fields", std.json.Value{ .array = fields_arr });
            return std.json.Value{ .object = obj };
        },
        .tagged => |t| {
            // Tagged value: { "$tag": tag_string, "$value": payload }
            var obj: std.json.ObjectMap = .empty;
            try obj.put(allocator, "$tag", std.json.Value{ .string = t.tag });
            try obj.put(allocator, "$value", try syrupToJson(allocator, t.payload.*));
            return std.json.Value{ .object = obj };
        },
        .@"error" => |e| {
            // Error value: { "$error": message, "$id": identifier, "$data": data }
            var obj: std.json.ObjectMap = .empty;
            try obj.put(allocator, "$error", std.json.Value{ .string = e.message });
            try obj.put(allocator, "$id", std.json.Value{ .string = e.identifier });
            try obj.put(allocator, "$data", try syrupToJson(allocator, e.data.*));
            return std.json.Value{ .object = obj };
        },
    }
}
