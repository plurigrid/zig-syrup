//! edn_bridge — DotFox/edn.c (C11 SIMD EDN reader) ⇄ syrup.Value
//!
//! Direction 1 (read):  EDN text --edn.c--> edn_value_t --deep copy--> syrup.Value
//! Direction 2 (write): syrup.Value --native Zig emitter--> EDN text
//!   (edn.c's tree writer only accepts values its own parser produced, so
//!    emission is ours; its *streaming* emitter's validate-before-emit contract
//!    is the model for the symbol/keyword validation below.)
//!
//! Both directions are involutions on their domains, and both are measured:
//!   law 1:  parse ∘ emit ∘ parse = parse      (EDN side; tools/edn_roundtrip.zig
//!           over edn.c's own corpus, equality on canonical syrup wire bytes)
//!   law 2:  convert ∘ emit = id               (syrup side; tests below, equality
//!           on canonical syrup wire bytes)
//!
//! Type mapping (EDN-native where possible):
//!   EDN nil        ⇄ .null
//!   EDN bool       ⇄ .bool
//!   EDN int        ⇄ .integer (i64)
//!   EDN float      ⇄ .float (f64)            (##Inf ##-Inf ##NaN ⇄ IEEE specials)
//!   EDN string     ⇄ .string
//!   EDN symbol     ⇄ .symbol "ns/name"
//!   EDN keyword    ⇄ .symbol ":ns/name"      (leading ':' marks keyword; the
//!                                             keyword/symbol distinction is
//!                                             deliberately quotiented at the
//!                                             syrup layer by this sigil)
//!   EDN vector     ⇄ .list                   (vector is the canonical seq)
//!   EDN list       ⇄ .tagged{"edn:list", .list}
//!   EDN map        ⇄ .dictionary
//!   EDN set        ⇄ .set
//!   EDN #tag v     ⇄ .tagged{tag, v}
//!   EDN character  ⇄ .tagged{"edn:char", .integer codepoint}
//!   EDN bigint     ⇄ .tagged{"edn:bigint", .string decimal}
//!   EDN bigdec     ⇄ .tagged{"edn:bigdec", .string decimal}
//!   EDN ratio      ⇄ .tagged{"edn:ratio", .list{num, den}}
//!
//! Escape conventions for syrup values EDN lacks (the EDN twin of cli.zig's
//! $dict/$bytes/$label JSON escapes; single-tag wrappers after edn-data-js's
//! lossless-by-default convention, #base64 precedent from go-edn):
//!   .bytes         → #syrup/bytes "<base64>"
//!   .float32       → #syrup/f32 <float>       (f64-only in every surveyed impl)
//!   .undefined     → #syrup/undefined nil     (distinct from .null ⇄ nil)
//!   .record        → #syrup/record [label field...]
//!   .error         → #syrup/error [message identifier data]
//!   .symbol (text not valid EDN identifier, or "nil"/"true"/"false")
//!                  → #syrup/symbol "<text>"
//!   .dictionary with duplicate keys
//!                  → #syrup/dict [[k v] ...]  (surveyed readers split 3 ways on
//!                    dup map keys — error/last-wins/preserve — and edn.c errors,
//!                    so a plain map here would be rejected by our own reader)
//!   .tagged whose tag is not a valid EDN symbol
//!                  → #syrup/tagged ["<tag>" payload]
//! All #syrup/* tags are reabsorbed to native syrup Values on read (law 2).
//!
//! Lifetime: parse() returns a Parsed owning an arena; all syrup.Value slices
//! point into that arena. edn.c's own arena is freed before parse() returns.

const std = @import("std");
const syrup = @import("syrup");

// translate-c module wired in build.zig (0.17-dev removed @cImport)
pub const c = @import("edn_c");

pub const BridgeError = error{
    ParseError,
    UnsupportedType,
    OutOfMemory,
};

pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    value: syrup.Value,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

/// Parse EDN text into a syrup.Value (deep-copied; edn.c memory released).
pub fn parse(base_allocator: std.mem.Allocator, input: []const u8) BridgeError!Parsed {
    const res = c.edn_read(input.ptr, input.len);
    if (res.value == null) return BridgeError.ParseError;
    defer c.edn_free(res.value);

    var arena = std.heap.ArenaAllocator.init(base_allocator);
    errdefer arena.deinit();
    const value = try convert(arena.allocator(), input, res.value);
    return .{ .arena = arena, .value = value };
}

fn dupe(a: std.mem.Allocator, ptr: [*c]const u8, len: usize) ![]const u8 {
    return a.dupe(u8, ptr[0..len]);
}

/// Join optional namespace + name, with optional keyword sigil.
fn ident(a: std.mem.Allocator, sigil: []const u8, ns: [*c]const u8, ns_len: usize, name: [*c]const u8, name_len: usize) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    try buf.appendSlice(a, sigil);
    if (ns_len > 0) {
        try buf.appendSlice(a, ns[0..ns_len]);
        try buf.append(a, '/');
    }
    try buf.appendSlice(a, name[0..name_len]);
    return buf.items;
}

fn signedDigits(a: std.mem.Allocator, neg: bool, digits: [*c]const u8, len: usize) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    if (neg) try buf.append(a, '-');
    try buf.appendSlice(a, digits[0..len]);
    return buf.items;
}

fn taggedVal(a: std.mem.Allocator, tag: []const u8, payload: syrup.Value) !syrup.Value {
    const p = try a.create(syrup.Value);
    p.* = payload;
    return .{ .tagged = .{ .tag = tag, .payload = p } };
}

fn heapValue(a: std.mem.Allocator, v: syrup.Value) !*syrup.Value {
    const p = try a.create(syrup.Value);
    p.* = v;
    return p;
}

// ---------------------------------------------------------------------------
// Read direction: edn.c value tree -> syrup.Value
// ---------------------------------------------------------------------------

/// Reabsorb a #syrup/* escape tag into its native syrup Value.
/// Returns null when `tag` is not a syrup/* escape (caller falls through to
/// the generic tagged representation). Malformed escape payloads are
/// ParseError: they cannot have been produced by `emit`.
fn reabsorbSyrupTag(a: std.mem.Allocator, tag: []const u8, payload: syrup.Value) BridgeError!?syrup.Value {
    if (!std.mem.startsWith(u8, tag, "syrup/")) return null;
    const kind = tag["syrup/".len..];

    if (std.mem.eql(u8, kind, "bytes")) {
        const b64 = switch (payload) {
            .string => |s| s,
            else => return BridgeError.ParseError,
        };
        const decoder = std.base64.standard.Decoder;
        const out_len = decoder.calcSizeForSlice(b64) catch return BridgeError.ParseError;
        const out = try a.alloc(u8, out_len);
        decoder.decode(out, b64) catch return BridgeError.ParseError;
        return .{ .bytes = out };
    }
    if (std.mem.eql(u8, kind, "symbol")) {
        return switch (payload) {
            .string => |s| .{ .symbol = s },
            else => BridgeError.ParseError,
        };
    }
    if (std.mem.eql(u8, kind, "f64-bits")) {
        const hex = switch (payload) {
            .string => |s| s,
            else => return BridgeError.ParseError,
        };
        const bits = std.fmt.parseInt(u64, hex, 16) catch return BridgeError.ParseError;
        return .{ .float = @bitCast(bits) };
    }
    if (std.mem.eql(u8, kind, "f32-bits")) {
        const hex = switch (payload) {
            .string => |s| s,
            else => return BridgeError.ParseError,
        };
        const bits = std.fmt.parseInt(u32, hex, 16) catch return BridgeError.ParseError;
        return .{ .float32 = @bitCast(bits) };
    }
    if (std.mem.eql(u8, kind, "f32")) {
        return switch (payload) {
            .float => |f| .{ .float32 = @floatCast(f) },
            .integer => |i| .{ .float32 = @floatFromInt(i) },
            else => BridgeError.ParseError,
        };
    }
    if (std.mem.eql(u8, kind, "undefined")) {
        return switch (payload) {
            .null => .undefined,
            else => BridgeError.ParseError,
        };
    }
    if (std.mem.eql(u8, kind, "dict")) {
        const pairs = switch (payload) {
            .list => |l| l,
            else => return BridgeError.ParseError,
        };
        const entries = try a.alloc(syrup.Value.DictEntry, pairs.len);
        for (pairs, 0..) |pair, i| {
            const kv = switch (pair) {
                .list => |l| l,
                else => return BridgeError.ParseError,
            };
            if (kv.len != 2) return BridgeError.ParseError;
            entries[i] = .{ .key = kv[0], .value = kv[1] };
        }
        return .{ .dictionary = entries };
    }
    if (std.mem.eql(u8, kind, "record")) {
        const items = switch (payload) {
            .list => |l| l,
            else => return BridgeError.ParseError,
        };
        if (items.len < 1) return BridgeError.ParseError;
        return .{ .record = .{
            .label = try heapValue(a, items[0]),
            .fields = items[1..],
        } };
    }
    if (std.mem.eql(u8, kind, "error")) {
        const items = switch (payload) {
            .list => |l| l,
            else => return BridgeError.ParseError,
        };
        if (items.len != 3) return BridgeError.ParseError;
        const message = switch (items[0]) {
            .string => |s| s,
            else => return BridgeError.ParseError,
        };
        const identifier = switch (items[1]) {
            .string => |s| s,
            else => return BridgeError.ParseError,
        };
        return .{ .@"error" = .{
            .message = message,
            .identifier = identifier,
            .data = try heapValue(a, items[2]),
        } };
    }
    if (std.mem.eql(u8, kind, "bigint")) {
        const items = switch (payload) {
            .list => |l| l,
            else => return BridgeError.ParseError,
        };
        if (items.len != 2) return BridgeError.ParseError;
        const negative = switch (items[0]) {
            .bool => |b| b,
            else => return BridgeError.ParseError,
        };
        const magnitude = switch (items[1]) {
            .bytes => |b| b,
            else => return BridgeError.ParseError,
        };
        return .{ .bigint = .{ .negative = negative, .magnitude = magnitude } };
    }
    if (std.mem.eql(u8, kind, "tagged")) {
        const items = switch (payload) {
            .list => |l| l,
            else => return BridgeError.ParseError,
        };
        if (items.len != 2) return BridgeError.ParseError;
        const tag_text = switch (items[0]) {
            .string => |s| s,
            else => return BridgeError.ParseError,
        };
        return try taggedVal(a, tag_text, items[1]);
    }
    // Unknown syrup/* tag: forward-compat passthrough as generic tagged
    // (go-edn's unknown-tag model), not an error.
    return null;
}

fn convert(a: std.mem.Allocator, input: []const u8, v: ?*c.edn_value_t) BridgeError!syrup.Value {
    const t = c.edn_type(v);
    switch (t) {
        c.EDN_TYPE_NIL => return .null,
        c.EDN_TYPE_BOOL => {
            var out: bool = undefined;
            _ = c.edn_bool_get(v, &out);
            return .{ .bool = out };
        },
        c.EDN_TYPE_INT => {
            var out: i64 = undefined;
            _ = c.edn_int64_get(v, &out);
            return .{ .integer = out };
        },
        c.EDN_TYPE_FLOAT => {
            var out: f64 = undefined;
            _ = c.edn_double_get(v, &out);
            // edn.c's decimal->double conversion mis-rounds by 1 ulp on some
            // inputs ("8.2" -> ...667, "17.24" -> ...a3e; nearest are ...666 /
            // ...a3d — found by cross-checking vivicat/zig-syrup's zoo.bin as
            // a ground-truth oracle; parse∘emit∘parse is blind to this since
            // the wrong double is *stable*). Re-parse the source text with
            // Zig's correctly-rounded parseFloat when the span is available
            // and numeric (##Inf/##-Inf/##NaN also arrive as FLOAT — their
            // spans start with '#', keep edn.c's value for those).
            var start: usize = 0;
            var end: usize = 0;
            if (c.edn_source_position(v, &start, &end) and end <= input.len and start < end) {
                const text = input[start..end];
                if (text[0] != '#') {
                    if (std.fmt.parseFloat(f64, text)) |exact| {
                        out = exact;
                    } else |_| {}
                }
            }
            return .{ .float = out };
        },
        c.EDN_TYPE_STRING => {
            var len: usize = 0;
            const s = c.edn_string_get(v, &len);
            return .{ .string = try dupe(a, s, len) };
        },
        c.EDN_TYPE_SYMBOL, c.EDN_TYPE_KEYWORD => {
            var ns: [*c]const u8 = null;
            var ns_len: usize = 0;
            var name: [*c]const u8 = null;
            var name_len: usize = 0;
            if (t == c.EDN_TYPE_SYMBOL) {
                _ = c.edn_symbol_get(v, &ns, &ns_len, &name, &name_len);
                return .{ .symbol = try ident(a, "", ns, ns_len, name, name_len) };
            } else {
                _ = c.edn_keyword_get(v, &ns, &ns_len, &name, &name_len);
                return .{ .symbol = try ident(a, ":", ns, ns_len, name, name_len) };
            }
        },
        c.EDN_TYPE_VECTOR => {
            const n = c.edn_vector_count(v);
            const items = try a.alloc(syrup.Value, n);
            for (items, 0..) |*slot, i| slot.* = try convert(a, input, c.edn_vector_get(v, i));
            return .{ .list = items };
        },
        c.EDN_TYPE_LIST => {
            const n = c.edn_list_count(v);
            const items = try a.alloc(syrup.Value, n);
            for (items, 0..) |*slot, i| slot.* = try convert(a, input, c.edn_list_get(v, i));
            return taggedVal(a, "edn:list", .{ .list = items });
        },
        c.EDN_TYPE_SET => {
            const n = c.edn_set_count(v);
            const items = try a.alloc(syrup.Value, n);
            for (items, 0..) |*slot, i| slot.* = try convert(a, input, c.edn_set_get(v, i));
            return .{ .set = items };
        },
        c.EDN_TYPE_MAP => {
            const n = c.edn_map_count(v);
            const entries = try a.alloc(syrup.Value.DictEntry, n);
            for (entries, 0..) |*e, i| {
                e.* = .{
                    .key = try convert(a, input, c.edn_map_get_key(v, i)),
                    .value = try convert(a, input, c.edn_map_get_value(v, i)),
                };
            }
            return .{ .dictionary = entries };
        },
        c.EDN_TYPE_TAGGED => {
            var tag: [*c]const u8 = null;
            var tag_len: usize = 0;
            var inner: ?*c.edn_value_t = null;
            _ = c.edn_tagged_get(v, &tag, &tag_len, &inner);
            const tag_text = try dupe(a, tag, tag_len);
            const payload = try convert(a, input, inner);
            if (try reabsorbSyrupTag(a, tag_text, payload)) |native| return native;
            return taggedVal(a, tag_text, payload);
        },
        c.EDN_TYPE_CHARACTER => {
            var cp: u32 = undefined;
            _ = c.edn_character_get(v, &cp);
            return taggedVal(a, "edn:char", .{ .integer = @intCast(cp) });
        },
        c.EDN_TYPE_BIGINT => {
            var len: usize = 0;
            var neg: bool = false;
            const digits = c.edn_bigint_get(v, &len, &neg, null);
            return taggedVal(a, "edn:bigint", .{ .string = try signedDigits(a, neg, digits, len) });
        },
        c.EDN_TYPE_BIGDEC => {
            var len: usize = 0;
            var neg: bool = false;
            const digits = c.edn_bigdec_get(v, &len, &neg);
            return taggedVal(a, "edn:bigdec", .{ .string = try signedDigits(a, neg, digits, len) });
        },
        c.EDN_TYPE_RATIO => {
            var num: i64 = undefined;
            var den: i64 = undefined;
            _ = c.edn_ratio_get(v, &num, &den);
            const items = try a.alloc(syrup.Value, 2);
            items[0] = .{ .integer = num };
            items[1] = .{ .integer = den };
            return taggedVal(a, "edn:ratio", .{ .list = items });
        },
        else => return BridgeError.UnsupportedType,
    }
}

// ---------------------------------------------------------------------------
// Identifier validation (emit side)
//
// Conservative subset of the EDN symbol grammar. The surveyed readers disagree
// about the edges (edn.c accepts control bytes; fast-edn treats them as token
// boundaries; edn-java rejects; zeal lex-errors), so anything outside the
// uncontested core is escaped to #syrup/symbol rather than emitted bare —
// escaping is always safe, permissive emit is not (GIGO in 4 of 9 impls).
// ---------------------------------------------------------------------------

fn isSymHeadChar(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or switch (ch) {
        '*', '!', '_', '?', '$', '%', '&', '=', '<', '>', '+', '-', '.' => true,
        else => false,
    };
}

fn isSymTailChar(ch: u8) bool {
    return isSymHeadChar(ch) or std.ascii.isDigit(ch);
}

/// One /-free segment of a symbol.
fn isValidSymbolSegment(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!isSymHeadChar(s[0])) return false;
    // "+1", "-1", ".5" would re-read as numbers
    if ((s[0] == '+' or s[0] == '-' or s[0] == '.') and s.len > 1 and std.ascii.isDigit(s[1])) return false;
    for (s[1..]) |ch| if (!isSymTailChar(ch)) return false;
    return true;
}

/// Full symbol text (optionally "ns/name"). Rejects the boolean/nil literals:
/// a syrup symbol "nil" emitted bare would re-read as EDN nil (type collapse).
fn isValidEdnSymbol(s: []const u8) bool {
    if (s.len == 0) return false;
    if (std.mem.eql(u8, s, "nil") or std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false")) return false;
    if (std.mem.eql(u8, s, "/")) return true; // division symbol is legal EDN
    if (std.mem.indexOfScalar(u8, s, '/')) |slash| {
        if (std.mem.indexOfScalarPos(u8, s, slash + 1, '/') != null) return false;
        return isValidSymbolSegment(s[0..slash]) and isValidSymbolSegment(s[slash + 1 ..]);
    }
    return isValidSymbolSegment(s);
}

/// Keyword text after the ':' sigil (may be "ns/name").
fn isValidEdnKeywordBody(s: []const u8) bool {
    // ":/", "::x" and empty are the uncontested-invalid forms
    if (s.len == 0 or s[0] == ':' or s[0] == '/') return false;
    return isValidEdnSymbol(s);
}

// ---------------------------------------------------------------------------
// Emission: syrup.Value -> EDN text (inverse of the mapping above)
// ---------------------------------------------------------------------------

/// The one NaN bit pattern that `##NaN` reads back as. Any other NaN payload
/// (signaling NaNs, sign-bit-set NaNs, diagnostic payloads) must take the
/// bit-exact escape or the wire is silently rewritten — syrup compares and
/// orders floats *by bits*, and the decoder accepts arbitrary payloads from
/// untrusted input, so payload loss is reachable and signature-relevant.
/// Found by cross-implementation probing, not by laws 1/2.
const canonical_quiet_nan_bits: u64 = @bitCast(@as(f64, std.math.nan(f64)));

/// Floats must re-read as floats: force a '.'/'e' marker, and map the IEEE
/// specials to EDN symbolic values (##Inf / ##-Inf / ##NaN).
fn emitFloat(f: f64, writer: anytype) !void {
    if (std.math.isNan(f)) {
        const bits: u64 = @bitCast(f);
        if (bits != canonical_quiet_nan_bits) {
            try writer.writeAll("#syrup/f64-bits \"");
            try writer.print("{x:0>16}", .{bits});
            try writer.writeByte('"');
            return;
        }
        return writer.writeAll("##NaN");
    }
    if (std.math.isInf(f)) return writer.writeAll(if (f > 0) "##Inf" else "##-Inf");
    var buf: [400]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
    try writer.writeAll(s);
    // "{d}" prints 1.5e10 as "15000000000" — without a marker it would
    // re-parse as an integer (type collapse caught by the edn.c corpus).
    if (std.mem.indexOfAny(u8, s, ".eE") == null) try writer.writeAll(".0");
}

/// EDN named characters for the whitespace family; raw for printable ASCII;
/// \uXXXX for other BMP codepoints; raw UTF-8 fallback beyond the BMP.
fn emitChar(cp: u32, writer: anytype) !void {
    switch (cp) {
        ' ' => try writer.writeAll("\\space"),
        '\n' => try writer.writeAll("\\newline"),
        '\t' => try writer.writeAll("\\tab"),
        '\r' => try writer.writeAll("\\return"),
        else => {
            if (cp > 0x20 and cp < 0x7f) {
                try writer.writeByte('\\');
                try writer.writeByte(@intCast(cp));
            } else if (cp <= 0xFFFF) {
                try writer.print("\\u{x:0>4}", .{cp});
            } else {
                var utf8: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(cp), &utf8) catch return error.UnsupportedType;
                try writer.writeByte('\\');
                try writer.writeAll(utf8[0..n]);
            }
        },
    }
}

fn emitString(s: []const u8, writer: anytype) !void {
    try writer.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\t' => try writer.writeAll("\\t"),
        '\r' => try writer.writeAll("\\r"),
        else => try writer.writeByte(ch),
    };
    try writer.writeByte('"');
}

/// Streaming base64: 48-byte input chunks -> 64 output chars, so arbitrary
/// byte-string sizes emit without an allocator (the previous fixed 4096-byte
/// buffer overflowed on inputs > 3 KiB).
fn emitBytesBase64(data: []const u8, writer: anytype) !void {
    try writer.writeAll("#syrup/bytes \"");
    const enc = std.base64.standard.Encoder;
    var i: usize = 0;
    var out: [64]u8 = undefined;
    while (i < data.len) : (i += 48) {
        const chunk = data[i..@min(i + 48, data.len)];
        try writer.writeAll(enc.encode(out[0..enc.calcSize(chunk.len)], chunk));
    }
    try writer.writeByte('"');
}

fn dictionaryHasDuplicateKeys(entries: []const syrup.Value.DictEntry) bool {
    for (entries, 0..) |a_entry, i| {
        for (entries[i + 1 ..]) |b_entry| {
            if (a_entry.key.compare(b_entry.key) == .eq) return true;
        }
    }
    return false;
}

fn emitDictAsPairs(entries: []const syrup.Value.DictEntry, writer: anytype) anyerror!void {
    try writer.writeAll("#syrup/dict [");
    for (entries, 0..) |e, i| {
        if (i > 0) try writer.writeByte(' ');
        try writer.writeByte('[');
        try emit(e.key, writer);
        try writer.writeByte(' ');
        try emit(e.value, writer);
        try writer.writeByte(']');
    }
    try writer.writeByte(']');
}

pub fn emit(value: syrup.Value, writer: anytype) anyerror!void {
    switch (value) {
        .null => try writer.writeAll("nil"),
        .undefined => try writer.writeAll("#syrup/undefined nil"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |i| try writer.print("{d}", .{i}),
        .float => |f| try emitFloat(f, writer),
        .float32 => |f| {
            const bits: u32 = @bitCast(f);
            if (std.math.isNan(f) and bits != @as(u32, @bitCast(@as(f32, std.math.nan(f32))))) {
                try writer.writeAll("#syrup/f32-bits \"");
                try writer.print("{x:0>8}", .{bits});
                try writer.writeByte('"');
            } else {
                try writer.writeAll("#syrup/f32 ");
                try emitFloat(f, writer);
            }
        },
        .string => |s| try emitString(s, writer),
        .symbol => |s| {
            // ':'-prefixed symbols were EDN keywords (see mapping table)
            if (s.len > 0 and s[0] == ':') {
                if (isValidEdnKeywordBody(s[1..])) {
                    try writer.writeAll(s);
                } else {
                    try writer.writeAll("#syrup/symbol ");
                    try emitString(s, writer);
                }
            } else if (isValidEdnSymbol(s)) {
                try writer.writeAll(s);
            } else {
                try writer.writeAll("#syrup/symbol ");
                try emitString(s, writer);
            }
        },
        .bytes => |b| try emitBytesBase64(b, writer),
        .bigint => |bi| {
            // syrup bigint magnitude is big-endian bytes; render decimal via
            // repeated division is overkill here — emit the exact bytes
            // instead, tagged, so nothing is invented. (i128-fitting bigints
            // could render as `<n>N`; kept simple and lossless for now.)
            try writer.writeAll("#syrup/bigint [");
            try writer.writeAll(if (bi.negative) "true" else "false");
            try writer.writeByte(' ');
            try emitBytesBase64(bi.magnitude, writer);
            try writer.writeByte(']');
        },
        .list => |items| {
            try writer.writeByte('[');
            for (items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(' ');
                try emit(item, writer);
            }
            try writer.writeByte(']');
        },
        .set => |items| {
            try writer.writeAll("#{");
            for (items, 0..) |item, i| {
                if (i > 0) try writer.writeByte(' ');
                try emit(item, writer);
            }
            try writer.writeByte('}');
        },
        .dictionary => |entries| {
            if (dictionaryHasDuplicateKeys(entries)) {
                try emitDictAsPairs(entries, writer);
            } else {
                try writer.writeByte('{');
                for (entries, 0..) |e, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try emit(e.key, writer);
                    try writer.writeByte(' ');
                    try emit(e.value, writer);
                }
                try writer.writeByte('}');
            }
        },
        .tagged => |tg| {
            if (std.mem.eql(u8, tg.tag, "edn:list")) {
                // restore a true EDN list
                try writer.writeByte('(');
                for (tg.payload.list, 0..) |item, i| {
                    if (i > 0) try writer.writeByte(' ');
                    try emit(item, writer);
                }
                try writer.writeByte(')');
            } else if (std.mem.eql(u8, tg.tag, "edn:char")) {
                try emitChar(@intCast(tg.payload.integer), writer);
            } else if (std.mem.eql(u8, tg.tag, "edn:bigint")) {
                try writer.writeAll(tg.payload.string);
                try writer.writeByte('N');
            } else if (std.mem.eql(u8, tg.tag, "edn:bigdec")) {
                try writer.writeAll(tg.payload.string);
                try writer.writeByte('M');
            } else if (std.mem.eql(u8, tg.tag, "edn:ratio")) {
                try writer.print("{d}", .{tg.payload.list[0].integer});
                try writer.writeByte('/');
                try writer.print("{d}", .{tg.payload.list[1].integer});
            } else if (isValidEdnSymbol(tg.tag)) {
                try writer.writeByte('#');
                try writer.writeAll(tg.tag);
                try writer.writeByte(' ');
                try emit(tg.payload.*, writer);
            } else {
                // tag text is not a legal EDN tag symbol: escape it
                try writer.writeAll("#syrup/tagged [");
                try emitString(tg.tag, writer);
                try writer.writeByte(' ');
                try emit(tg.payload.*, writer);
                try writer.writeByte(']');
            }
        },
        .record => |r| {
            try writer.writeAll("#syrup/record [");
            try emit(r.label.*, writer);
            for (r.fields) |f| {
                try writer.writeByte(' ');
                try emit(f, writer);
            }
            try writer.writeByte(']');
        },
        .@"error" => |e| {
            try writer.writeAll("#syrup/error [");
            try emitString(e.message, writer);
            try writer.writeByte(' ');
            try emitString(e.identifier, writer);
            try writer.writeByte(' ');
            try emit(e.data.*, writer);
            try writer.writeByte(']');
        },
    }
}

/// Minimal writer over ArrayListUnmanaged(u8) — same shape as syrup.zig's
/// private compat adapter; works across 0.15–0.17-dev.
const ListWriter = struct {
    list: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    pub const Error = std.mem.Allocator.Error;
    pub fn writeByte(self: *ListWriter, byte: u8) Error!void {
        try self.list.append(self.alloc, byte);
    }
    pub fn writeAll(self: *ListWriter, data: []const u8) Error!void {
        try self.list.appendSlice(self.alloc, data);
    }
    pub fn print(self: *ListWriter, comptime fmt: []const u8, args: anytype) Error!void {
        var buf: [64]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, fmt, args) catch unreachable;
        try self.list.appendSlice(self.alloc, slice);
    }
};

pub fn emitAlloc(allocator: std.mem.Allocator, value: syrup.Value) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(allocator);
    var w = ListWriter{ .list = &buf, .alloc = allocator };
    try emit(value, &w);
    return buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// law 1 (EDN side) is measured over the edn.c corpus by tools/edn_roundtrip.zig;
// the tests here pin law 2 (syrup side) and the individual mapping arms.
// ---------------------------------------------------------------------------

test "edn -> syrup: atoms and collections" {
    const src = "{:a [1 2.5 \"hi\"] :b #{x/y} :c (1 2) :d #inst \"2026-07-30\"}";
    var parsed = try parse(std.testing.allocator, src);
    defer parsed.deinit();

    const dict = parsed.value.dictionary;
    try std.testing.expectEqual(@as(usize, 4), dict.len);
    try std.testing.expectEqualStrings(":a", dict[0].key.symbol);
    try std.testing.expectEqual(@as(i64, 1), dict[0].value.list[0].integer);
    try std.testing.expectEqualStrings("x/y", dict[1].value.set[0].symbol);
    try std.testing.expectEqualStrings("edn:list", dict[2].value.tagged.tag);
    try std.testing.expectEqualStrings("inst", dict[3].value.tagged.tag);
}

test "round-trip: edn -> syrup -> canonical bytes -> decode -> edn" {
    const src = "[nil true 42 \\a 1/3 {:k \"v\"} #{:s} (7)]";
    var parsed = try parse(std.testing.allocator, src);
    defer parsed.deinit();

    const wire = try parsed.value.encodeAlloc(std.testing.allocator);
    defer std.testing.allocator.free(wire);
    var decode_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer decode_arena.deinit();
    const back = try syrup.decode(wire, decode_arena.allocator());
    _ = back;

    const out = try emitAlloc(std.testing.allocator, parsed.value);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        "[nil true 42 \\a 1/3 {:k \"v\"} #{:s} (7)]",
        out,
    );
}

test "i64 extremes survive edn -> syrup wire -> decode (minInt regression)" {
    const src = "[-9223372036854775808 9223372036854775807]";
    var parsed = try parse(std.testing.allocator, src);
    defer parsed.deinit();
    const wire = try parsed.value.encodeAlloc(std.testing.allocator);
    defer std.testing.allocator.free(wire);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const back = try syrup.decode(wire, arena.allocator());
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), back.list[0].integer);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), back.list[1].integer);
}

test "parse error surfaces" {
    try std.testing.expectError(BridgeError.ParseError, parse(std.testing.allocator, "{:unclosed"));
}

/// law 2: convert(emit(v)) = v on the syrup side, judged on canonical wire
/// bytes. Exercises every escape convention at once.
fn expectSyrupRoundTrip(v: syrup.Value) !void {
    const gpa = std.testing.allocator;
    const text = try emitAlloc(gpa, v);
    defer gpa.free(text);

    var back = try parse(gpa, text);
    defer back.deinit();

    const wire_a = try v.encodeAlloc(gpa);
    defer gpa.free(wire_a);
    const wire_b = try back.value.encodeAlloc(gpa);
    defer gpa.free(wire_b);
    try std.testing.expectEqualSlices(u8, wire_a, wire_b);
}

test "law 2: syrup escapes reabsorb — bytes (incl. >4KiB), f32, undefined" {
    var big: [5000]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate(i *% 31);
    try expectSyrupRoundTrip(.{ .bytes = &big });
    try expectSyrupRoundTrip(.{ .bytes = "" });
    try expectSyrupRoundTrip(.{ .bytes = "\xff\x00\xfe" });
    try expectSyrupRoundTrip(.{ .float32 = 1.5 });
    try expectSyrupRoundTrip(.undefined);
}

test "law 2: non-identifier symbols escape; identifier symbols stay bare" {
    try expectSyrupRoundTrip(.{ .symbol = "has space" });
    try expectSyrupRoundTrip(.{ .symbol = "nil" }); // would collapse to EDN nil if bare
    try expectSyrupRoundTrip(.{ .symbol = "true" });
    try expectSyrupRoundTrip(.{ .symbol = "1abc" });
    try expectSyrupRoundTrip(.{ .symbol = "a//b" });
    try expectSyrupRoundTrip(.{ .symbol = ":" }); // empty keyword body
    try expectSyrupRoundTrip(.{ .symbol = ":ns/ok" }); // valid keyword, bare
    try expectSyrupRoundTrip(.{ .symbol = "plain-sym" }); // valid symbol, bare

    const bare = try emitAlloc(std.testing.allocator, .{ .symbol = "plain-sym" });
    defer std.testing.allocator.free(bare);
    try std.testing.expectEqualStrings("plain-sym", bare);
}

test "law 2: duplicate-key dictionaries take the pair-list escape" {
    const entries = [_]syrup.Value.DictEntry{
        .{ .key = .{ .string = "k" }, .value = .{ .integer = 1 } },
        .{ .key = .{ .string = "k" }, .value = .{ .integer = 2 } },
    };
    try expectSyrupRoundTrip(.{ .dictionary = &entries });

    const text = try emitAlloc(std.testing.allocator, .{ .dictionary = &entries });
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "#syrup/dict"));

    // no duplicates -> plain EDN map
    const clean = [_]syrup.Value.DictEntry{
        .{ .key = .{ .string = "a" }, .value = .{ .integer = 1 } },
        .{ .key = .{ .string = "b" }, .value = .{ .integer = 2 } },
    };
    const clean_text = try emitAlloc(std.testing.allocator, .{ .dictionary = &clean });
    defer std.testing.allocator.free(clean_text);
    try std.testing.expect(clean_text[0] == '{');
    try expectSyrupRoundTrip(.{ .dictionary = &clean });
}

test "law 2: records, errors, and invalid-tag tagged values" {
    const label: syrup.Value = .{ .symbol = "point" };
    const fields = [_]syrup.Value{ .{ .integer = 3 }, .{ .integer = 4 } };
    try expectSyrupRoundTrip(.{ .record = .{ .label = &label, .fields = &fields } });

    const err_data: syrup.Value = .{ .integer = 99 };
    try expectSyrupRoundTrip(.{ .@"error" = .{
        .message = "boom",
        .identifier = "desc:error",
        .data = &err_data,
    } });

    const payload: syrup.Value = .{ .integer = 7 };
    try expectSyrupRoundTrip(.{ .tagged = .{ .tag = "not a symbol!", .payload = &payload } });
    try expectSyrupRoundTrip(.{ .tagged = .{ .tag = "my/tag", .payload = &payload } });
}

test "law 2: float bit patterns survive exactly (NaN payloads, randomized)" {
    // Hand-picked adversarial patterns first — the three that the
    // cross-implementation matrix showed collapsing to ##NaN.
    const f64_bits = [_]u64{
        0x7ff8000000000001, // NaN with payload
        0x7ff0000000000001, // signaling NaN
        0xfff8000000000000, // negative NaN
        0x7ff8000000000000, // canonical quiet NaN -> ##NaN
        0x7ff0000000000000, // +Inf
        0xfff0000000000000, // -Inf
        0x8000000000000000, // -0.0
        0x0000000000000000, // +0.0
        0x0000000000000001, // smallest subnormal
        0x4020666666666666, // 8.2
    };
    for (f64_bits) |bits| {
        try expectSyrupRoundTrip(.{ .float = @bitCast(bits) });
    }

    const f32_bits = [_]u32{ 0x7fc00001, 0x7f800001, 0xffc00000, 0x7fc00000, 0x80000000, 0x00000001 };
    for (f32_bits) |bits| {
        try expectSyrupRoundTrip(.{ .float32 = @bitCast(bits) });
    }

    // Randomized sweep: every f64/f32 bit pattern must survive the text form.
    var prng = std.Random.DefaultPrng.init(0x5171_09ac_8762_a354);
    const rand = prng.random();
    for (0..2000) |_| {
        try expectSyrupRoundTrip(.{ .float = @bitCast(rand.int(u64)) });
        try expectSyrupRoundTrip(.{ .float32 = @bitCast(rand.int(u32)) });
    }
}

test "law 2: bigint magnitude travels exactly" {
    try expectSyrupRoundTrip(.{ .bigint = .{
        .negative = true,
        .magnitude = "\x05\x6b\xc7\x5e\x2d\x63\x10\x00\x00", // 99999999999999999999+
    } });
}
