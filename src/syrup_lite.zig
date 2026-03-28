//! Syrup: OCapN canonical serialization format
//! https://github.com/ocapn/syrup
//!
//! Tileable (comptime generic over any Zig type)
//! Colorable (tagged wire format: atom/collection/reference)
//! Sendable (sometimes) (capability-secure message passing)

const std = @import("std");
const mem = std.mem;
const math = std.math;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;

// ============================================================
// Value: the Syrup sum type
// ============================================================

pub const Value = union(enum) {
    boolean: bool,
    positive_int: u64,
    negative_int: u64, // stores absolute value
    float_single: f32,
    float_double: f64,
    bytestring: []const u8,
    string: []const u8,
    symbol: []const u8,
    list: []const Value,
    dict: []const DictEntry,
    record: Record,
    set: []const Value,

    pub const DictEntry = struct {
        key: Value,
        value: Value,
    };

    pub const Record = struct {
        label: *const Value,
        fields: []const Value,
    };

    pub fn deinit(self: Value, allocator: Allocator) void {
        switch (self) {
            .list => |items| {
                for (items) |item| item.deinit(allocator);
                allocator.free(items);
            },
            .dict => |entries| {
                for (entries) |entry| {
                    entry.key.deinit(allocator);
                    entry.value.deinit(allocator);
                }
                allocator.free(entries);
            },
            .record => |rec| {
                rec.label.deinit(allocator);
                allocator.destroy(rec.label);
                for (rec.fields) |field| field.deinit(allocator);
                allocator.free(rec.fields);
            },
            .set => |items| {
                for (items) |item| item.deinit(allocator);
                allocator.free(items);
            },
            .bytestring, .string, .symbol => |bytes| {
                allocator.free(bytes);
            },
            else => {},
        }
    }

    pub fn eql(a: Value, b: Value) bool {
        const tag_a = std.meta.activeTag(a);
        const tag_b = std.meta.activeTag(b);
        if (tag_a != tag_b) return false;
        return switch (a) {
            .boolean => |v| v == b.boolean,
            .positive_int => |v| v == b.positive_int,
            .negative_int => |v| v == b.negative_int,
            .float_single => |v| v == b.float_single,
            .float_double => |v| v == b.float_double,
            .bytestring => |v| mem.eql(u8, v, b.bytestring),
            .string => |v| mem.eql(u8, v, b.string),
            .symbol => |v| mem.eql(u8, v, b.symbol),
            .list => |items| {
                const other = b.list;
                if (items.len != other.len) return false;
                for (items, other) |x, y| {
                    if (!x.eql(y)) return false;
                }
                return true;
            },
            .dict => |entries| {
                const other = b.dict;
                if (entries.len != other.len) return false;
                for (entries, other) |x, y| {
                    if (!x.key.eql(y.key) or !x.value.eql(y.value)) return false;
                }
                return true;
            },
            .set => |items| {
                const other = b.set;
                if (items.len != other.len) return false;
                for (items, other) |x, y| {
                    if (!x.eql(y)) return false;
                }
                return true;
            },
            .record => |rec| {
                const other = b.record;
                if (!rec.label.eql(other.label.*)) return false;
                if (rec.fields.len != other.fields.len) return false;
                for (rec.fields, other.fields) |x, y| {
                    if (!x.eql(y)) return false;
                }
                return true;
            },
        };
    }
};

// ============================================================
// Encoder
// ============================================================

pub const Encoder = struct {
    output: ArrayList(u8),

    pub fn init(allocator: Allocator) Encoder {
        return .{ .output = ArrayList(u8).init(allocator) };
    }

    pub fn deinit(self: *Encoder) void {
        self.output.deinit();
    }

    pub fn result(self: *const Encoder) []const u8 {
        return self.output.items;
    }

    pub fn encode(self: *Encoder, value: Value) !void {
        switch (value) {
            .boolean => |v| try self.output.append(if (v) 't' else 'f'),
            .positive_int => |v| {
                try self.writeDecimal(v);
                try self.output.append('+');
            },
            .negative_int => |v| {
                try self.writeDecimal(v);
                try self.output.append('-');
            },
            .float_single => |v| {
                try self.output.append('F');
                var bytes = @as([4]u8, @bitCast(v));
                if (comptime @import("builtin").target.cpu.arch.endian() == .little) {
                    mem.reverse(u8, &bytes);
                }
                try self.output.appendSlice(&bytes);
            },
            .float_double => |v| {
                try self.output.append('D');
                var bytes = @as([8]u8, @bitCast(v));
                if (comptime @import("builtin").target.cpu.arch.endian() == .little) {
                    mem.reverse(u8, &bytes);
                }
                try self.output.appendSlice(&bytes);
            },
            .bytestring => |v| {
                try self.writeDecimal(v.len);
                try self.output.append(':');
                try self.output.appendSlice(v);
            },
            .string => |v| {
                try self.writeDecimal(v.len);
                try self.output.append('"');
                try self.output.appendSlice(v);
            },
            .symbol => |v| {
                try self.writeDecimal(v.len);
                try self.output.append('\'');
                try self.output.appendSlice(v);
            },
            .list => |items| {
                try self.output.append('[');
                for (items) |item| try self.encode(item);
                try self.output.append(']');
            },
            .dict => |entries| {
                try self.output.append('{');
                // entries assumed pre-sorted by canonical key encoding
                for (entries) |entry| {
                    try self.encode(entry.key);
                    try self.encode(entry.value);
                }
                try self.output.append('}');
            },
            .record => |rec| {
                try self.output.append('<');
                try self.encode(rec.label.*);
                for (rec.fields) |field| try self.encode(field);
                try self.output.append('>');
            },
            .set => |items| {
                try self.output.append('#');
                // items assumed pre-sorted by canonical encoding
                for (items) |item| try self.encode(item);
                try self.output.append('$');
            },
        }
    }

    fn writeDecimal(self: *Encoder, value: anytype) !void {
        var buf: [20]u8 = undefined;
        const n: u64 = @intCast(value);
        var len: usize = 0;
        if (n == 0) {
            try self.output.append('0');
            return;
        }
        var v = n;
        while (v > 0) : (v /= 10) {
            buf[len] = @intCast('0' + (v % 10));
            len += 1;
        }
        // reverse
        var i: usize = 0;
        while (i < len) : (i += 1) {
            try self.output.append(buf[len - 1 - i]);
        }
    }
};

// ============================================================
// Decoder
// ============================================================

pub const DecodeError = error{
    UnexpectedByte,
    UnexpectedEnd,
    InvalidInteger,
    InvalidFloat,
    InvalidUtf8,
    OutOfMemory,
};

pub const Decoder = struct {
    input: []const u8,
    pos: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator, input: []const u8) Decoder {
        return .{ .input = input, .pos = 0, .allocator = allocator };
    }

    pub fn decode(self: *Decoder) DecodeError!Value {
        if (self.pos >= self.input.len) return error.UnexpectedEnd;
        const byte = self.input[self.pos];

        return switch (byte) {
            't' => {
                self.pos += 1;
                return Value{ .boolean = true };
            },
            'f' => {
                self.pos += 1;
                return Value{ .boolean = false };
            },
            'F' => self.decodeFloat32(),
            'D' => self.decodeFloat64(),
            '[' => self.decodeList(),
            '{' => self.decodeDict(),
            '<' => self.decodeRecord(),
            '#' => self.decodeSet(),
            '0'...'9' => self.decodeNumberOrLengthPrefixed(),
            else => error.UnexpectedByte,
        };
    }

    fn decodeFloat32(self: *Decoder) DecodeError!Value {
        self.pos += 1; // skip 'F'
        if (self.pos + 4 > self.input.len) return error.UnexpectedEnd;
        var bytes: [4]u8 = self.input[self.pos..][0..4].*;
        self.pos += 4;
        if (comptime @import("builtin").target.cpu.arch.endian() == .little) {
            mem.reverse(u8, &bytes);
        }
        return Value{ .float_single = @bitCast(bytes) };
    }

    fn decodeFloat64(self: *Decoder) DecodeError!Value {
        self.pos += 1; // skip 'D'
        if (self.pos + 8 > self.input.len) return error.UnexpectedEnd;
        var bytes: [8]u8 = self.input[self.pos..][0..8].*;
        self.pos += 8;
        if (comptime @import("builtin").target.cpu.arch.endian() == .little) {
            mem.reverse(u8, &bytes);
        }
        return Value{ .float_double = @bitCast(bytes) };
    }

    fn readDecimal(self: *Decoder) DecodeError!u64 {
        var result: u64 = 0;
        var count: usize = 0;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c >= '0' and c <= '9') {
                result = result * 10 + (c - '0');
                self.pos += 1;
                count += 1;
            } else break;
        }
        if (count == 0) return error.InvalidInteger;
        return result;
    }

    fn decodeNumberOrLengthPrefixed(self: *Decoder) DecodeError!Value {
        const num = try self.readDecimal();
        if (self.pos >= self.input.len) return error.UnexpectedEnd;
        const tag = self.input[self.pos];
        self.pos += 1;

        return switch (tag) {
            '+' => Value{ .positive_int = num },
            '-' => Value{ .negative_int = num },
            ':' => self.readBytes(num, .bytestring),
            '"' => self.readBytes(num, .string),
            '\'' => self.readBytes(num, .symbol),
            else => error.UnexpectedByte,
        };
    }

    const ByteTag = enum { bytestring, string, symbol };

    fn readBytes(self: *Decoder, len: u64, tag: ByteTag) DecodeError!Value {
        const n: usize = @intCast(len);
        if (self.pos + n > self.input.len) return error.UnexpectedEnd;
        const data = try self.allocator.dupe(u8, self.input[self.pos .. self.pos + n]);
        self.pos += n;
        return switch (tag) {
            .bytestring => Value{ .bytestring = data },
            .string => Value{ .string = data },
            .symbol => Value{ .symbol = data },
        };
    }

    fn decodeList(self: *Decoder) DecodeError!Value {
        self.pos += 1; // skip '['
        var items = ArrayList(Value).init(self.allocator);
        errdefer {
            for (items.items) |item| item.deinit(self.allocator);
            items.deinit();
        }
        while (self.pos < self.input.len and self.input[self.pos] != ']') {
            const item = try self.decode();
            try items.append(item);
        }
        if (self.pos >= self.input.len) return error.UnexpectedEnd;
        self.pos += 1; // skip ']'
        return Value{ .list = try items.toOwnedSlice() };
    }

    fn decodeDict(self: *Decoder) DecodeError!Value {
        self.pos += 1; // skip '{'
        var entries = ArrayList(Value.DictEntry).init(self.allocator);
        errdefer {
            for (entries.items) |entry| {
                entry.key.deinit(self.allocator);
                entry.value.deinit(self.allocator);
            }
            entries.deinit();
        }
        while (self.pos < self.input.len and self.input[self.pos] != '}') {
            const key = try self.decode();
            errdefer key.deinit(self.allocator);
            const val = try self.decode();
            try entries.append(.{ .key = key, .value = val });
        }
        if (self.pos >= self.input.len) return error.UnexpectedEnd;
        self.pos += 1; // skip '}'
        return Value{ .dict = try entries.toOwnedSlice() };
    }

    fn decodeRecord(self: *Decoder) DecodeError!Value {
        self.pos += 1; // skip '<'
        const label = try self.decode();
        const label_ptr = try self.allocator.create(Value);
        label_ptr.* = label;
        errdefer {
            label_ptr.deinit(self.allocator);
            self.allocator.destroy(label_ptr);
        }

        var fields = ArrayList(Value).init(self.allocator);
        errdefer {
            for (fields.items) |field| field.deinit(self.allocator);
            fields.deinit();
        }
        while (self.pos < self.input.len and self.input[self.pos] != '>') {
            const field = try self.decode();
            try fields.append(field);
        }
        if (self.pos >= self.input.len) return error.UnexpectedEnd;
        self.pos += 1; // skip '>'
        return Value{ .record = .{
            .label = label_ptr,
            .fields = try fields.toOwnedSlice(),
        } };
    }

    fn decodeSet(self: *Decoder) DecodeError!Value {
        self.pos += 1; // skip '#'
        var items = ArrayList(Value).init(self.allocator);
        errdefer {
            for (items.items) |item| item.deinit(self.allocator);
            items.deinit();
        }
        while (self.pos < self.input.len and self.input[self.pos] != '$') {
            const item = try self.decode();
            try items.append(item);
        }
        if (self.pos >= self.input.len) return error.UnexpectedEnd;
        self.pos += 1; // skip '$'
        return Value{ .set = try items.toOwnedSlice() };
    }
};

// ============================================================
// Comptime struct encoding: tile Syrup over any Zig type
// ============================================================

pub fn encodeStruct(encoder: *Encoder, value: anytype) !void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    switch (info) {
        .Bool => try encoder.encode(Value{ .boolean = value }),
        .Int => |int_info| {
            if (int_info.signedness == .signed) {
                if (value < 0) {
                    try encoder.encode(Value{ .negative_int = @intCast(-@as(i64, value)) });
                } else {
                    try encoder.encode(Value{ .positive_int = @intCast(value) });
                }
            } else {
                try encoder.encode(Value{ .positive_int = @intCast(value) });
            }
        },
        .Float => |float_info| {
            if (float_info.bits <= 32) {
                try encoder.encode(Value{ .float_single = @floatCast(value) });
            } else {
                try encoder.encode(Value{ .float_double = @floatCast(value) });
            }
        },
        .Pointer => |ptr_info| {
            if (ptr_info.size == .Slice and ptr_info.child == u8) {
                try encoder.encode(Value{ .string = value });
            } else if (ptr_info.size == .Slice) {
                try encoder.encode(Value{ .list = &.{} }); // TODO: proper slice encoding
            } else {
                try encodeStruct(encoder, value.*);
            }
        },
        .Struct => |struct_info| {
            // Encode struct as a Syrup record with symbol label
            const name = @typeName(T);
            try encoder.output.append('<');
            // label
            try encoder.writeDecimal(name.len);
            try encoder.output.append('\'');
            try encoder.output.appendSlice(name);
            // fields
            inline for (struct_info.fields) |field| {
                try encodeStruct(encoder, @field(value, field.name));
            }
            try encoder.output.append('>');
        },
        .Optional => {
            if (value) |v| {
                try encodeStruct(encoder, v);
            } else {
                try encoder.encode(Value{ .boolean = false }); // None as false
            }
        },
        else => @compileError("unsupported type for Syrup encoding: " ++ @typeName(T)),
    }
}

// ============================================================
// Canonical comparison for sorting dicts/sets
// ============================================================

pub fn canonicalCompare(allocator: Allocator, a: Value, b: Value) !std.math.Order {
    var enc_a = Encoder.init(allocator);
    defer enc_a.deinit();
    var enc_b = Encoder.init(allocator);
    defer enc_b.deinit();

    try enc_a.encode(a);
    try enc_b.encode(b);

    return mem.order(u8, enc_a.result(), enc_b.result());
}

// ============================================================
// Tests
// ============================================================

test "encode boolean true" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.encode(Value{ .boolean = true });
    try std.testing.expectEqualSlices(u8, "t", enc.result());
}

test "encode boolean false" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.encode(Value{ .boolean = false });
    try std.testing.expectEqualSlices(u8, "f", enc.result());
}

test "encode positive integer" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.encode(Value{ .positive_int = 42 });
    try std.testing.expectEqualSlices(u8, "42+", enc.result());
}

test "encode zero" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.encode(Value{ .positive_int = 0 });
    try std.testing.expectEqualSlices(u8, "0+", enc.result());
}

test "encode negative integer" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.encode(Value{ .negative_int = 5 });
    try std.testing.expectEqualSlices(u8, "5-", enc.result());
}

test "encode bytestring" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.encode(Value{ .bytestring = "cat" });
    try std.testing.expectEqualSlices(u8, "3:cat", enc.result());
}

test "encode string" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.encode(Value{ .string = "bear" });
    try std.testing.expectEqualSlices(u8, "4\"bear", enc.result());
}

test "encode symbol" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.encode(Value{ .symbol = "fetch" });
    try std.testing.expectEqualSlices(u8, "5'fetch", enc.result());
}

test "encode list" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    const items = [_]Value{
        Value{ .positive_int = 1 },
        Value{ .positive_int = 2 },
        Value{ .boolean = true },
    };
    try enc.encode(Value{ .list = &items });
    try std.testing.expectEqualSlices(u8, "[1+2+t]", enc.result());
}

test "encode dict" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    const entries = [_]Value.DictEntry{
        .{ .key = Value{ .string = "a" }, .value = Value{ .positive_int = 1 } },
        .{ .key = Value{ .string = "b" }, .value = Value{ .positive_int = 2 } },
    };
    try enc.encode(Value{ .dict = &entries });
    try std.testing.expectEqualSlices(u8, "{1\"a1+1\"b2+}", enc.result());
}

test "encode record" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    const label = Value{ .symbol = "person" };
    const fields = [_]Value{
        Value{ .string = "Alice" },
        Value{ .positive_int = 30 },
    };
    try enc.encode(Value{ .record = .{
        .label = &label,
        .fields = &fields,
    } });
    try std.testing.expectEqualSlices(u8, "<6'person5\"Alice30+>", enc.result());
}

test "encode set" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    const items = [_]Value{
        Value{ .positive_int = 1 },
        Value{ .positive_int = 2 },
        Value{ .positive_int = 3 },
    };
    try enc.encode(Value{ .set = &items });
    try std.testing.expectEqualSlices(u8, "#1+2+3+$", enc.result());
}

test "encode empty list" {
    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try enc.encode(Value{ .list = &.{} });
    try std.testing.expectEqualSlices(u8, "[]", enc.result());
}

test "decode boolean" {
    var dec = Decoder.init(std.testing.allocator, "t");
    const val = try dec.decode();
    try std.testing.expect(val.boolean == true);
}

test "decode positive integer" {
    var dec = Decoder.init(std.testing.allocator, "42+");
    const val = try dec.decode();
    try std.testing.expect(val.positive_int == 42);
}

test "decode negative integer" {
    var dec = Decoder.init(std.testing.allocator, "5-");
    const val = try dec.decode();
    try std.testing.expect(val.negative_int == 5);
}

test "decode string" {
    var dec = Decoder.init(std.testing.allocator, "4\"bear");
    const val = try dec.decode();
    defer val.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "bear", val.string);
}

test "decode symbol" {
    var dec = Decoder.init(std.testing.allocator, "5'fetch");
    const val = try dec.decode();
    defer val.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "fetch", val.symbol);
}

test "decode bytestring" {
    var dec = Decoder.init(std.testing.allocator, "3:cat");
    const val = try dec.decode();
    defer val.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "cat", val.bytestring);
}

test "decode list" {
    var dec = Decoder.init(std.testing.allocator, "[1+2+t]");
    const val = try dec.decode();
    defer val.deinit(std.testing.allocator);
    try std.testing.expect(val.list.len == 3);
    try std.testing.expect(val.list[0].positive_int == 1);
    try std.testing.expect(val.list[1].positive_int == 2);
    try std.testing.expect(val.list[2].boolean == true);
}

test "decode dict" {
    var dec = Decoder.init(std.testing.allocator, "{1\"a1+1\"b2+}");
    const val = try dec.decode();
    defer val.deinit(std.testing.allocator);
    try std.testing.expect(val.dict.len == 2);
    try std.testing.expectEqualSlices(u8, "a", val.dict[0].key.string);
    try std.testing.expect(val.dict[0].value.positive_int == 1);
}

test "decode record" {
    var dec = Decoder.init(std.testing.allocator, "<6'person5\"Alice30+>");
    const val = try dec.decode();
    defer val.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, "person", val.record.label.symbol);
    try std.testing.expect(val.record.fields.len == 2);
    try std.testing.expectEqualSlices(u8, "Alice", val.record.fields[0].string);
    try std.testing.expect(val.record.fields[1].positive_int == 30);
}

test "decode set" {
    var dec = Decoder.init(std.testing.allocator, "#1+2+3+$");
    const val = try dec.decode();
    defer val.deinit(std.testing.allocator);
    try std.testing.expect(val.set.len == 3);
}

test "roundtrip nested structure" {
    const allocator = std.testing.allocator;

    // Encode
    var enc = Encoder.init(allocator);
    defer enc.deinit();

    const inner_list = [_]Value{
        Value{ .positive_int = 1 },
        Value{ .string = "hello" },
    };
    const label = Value{ .symbol = "msg" };
    const fields = [_]Value{
        Value{ .list = &inner_list },
        Value{ .boolean = true },
    };
    const original = Value{ .record = .{
        .label = &label,
        .fields = &fields,
    } };
    try enc.encode(original);

    // Decode
    var dec = Decoder.init(allocator, enc.result());
    const decoded = try dec.decode();
    defer decoded.deinit(allocator);

    // Verify
    try std.testing.expectEqualSlices(u8, "msg", decoded.record.label.symbol);
    try std.testing.expect(decoded.record.fields.len == 2);
    try std.testing.expect(decoded.record.fields[0].list.len == 2);
    try std.testing.expect(decoded.record.fields[1].boolean == true);
}

test "comptime struct encoding" {
    const Point = struct {
        x: i32,
        y: i32,
    };

    var enc = Encoder.init(std.testing.allocator);
    defer enc.deinit();
    try encodeStruct(&enc, Point{ .x = 10, .y = -3 });

    // Should produce a record with the struct name as label
    const result = enc.result();
    try std.testing.expect(result[0] == '<'); // record open
    try std.testing.expect(result[result.len - 1] == '>'); // record close
}
