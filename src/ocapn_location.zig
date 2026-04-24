//! OCapN location records and sturdy ref URIs.
//!
//! Location record on the wire:
//!   <ocapn-node netlayer-sym designator-bytes hints-list>
//!
//! Sturdy ref URI:
//!   ocapn://<designator-base32>.<netlayer>/<swiss-hex>
//!
//! Netlayer is one of: tcp, onion, websocket. Designator is an opaque
//! bytestring (typically 32-byte Ed25519 pubkey). Swiss number is 32 bytes.
//! The WS transport symbol is `websocket` per OCapN draft (NOT `ws`).
//!
//! Encodes/decodes as syrup.Value trees so the same primitives feed both
//! op:start-session (location + signature) and handoff descriptors.
//!
//! Wire-format alignment (Racket Goblins is the live reference):
//!   - Label: `ocapn-node` (matches Racket; draft spec Locators.md says
//!     `ocapn-peer` — track if spec graduates).
//!   - Designator: emitted as Syrup string (Racket contract `string?`).
//!     `fromValue` still accepts `.bytes` for back-compat with older Zig
//!     traffic — read tolerant, write strict.
//!   - Hints: emitted as Syrup `f` when empty (Racket contract `(or/c #f
//!     string?)`); otherwise a list of strings. `fromValue` accepts list,
//!     bool, or string forms.
//!
//! Designator semantics (Racket-aligned 2026-04-18):
//!   `Location.designator` holds the **printable string form** — for tcp
//!   netlayer this is base32(pubkey); for onion it's the base32 onion
//!   address (without `.onion`); for websocket it's a `host:port` or URL.
//!   Both `encodeAlloc` (wire) and `SturdyRef.toUri` emit `designator`
//!   literally; `SturdyRef.fromUri` extracts the base32 substring without
//!   decoding. This keeps the byte-sequence identical across `fromUri →
//!   encodeAlloc` so captp-location-sig signatures verify against a Racket
//!   peer. Callers holding raw key bytes must `base32LowerEncode` before
//!   constructing a Location.

const std = @import("std");
const syrup = @import("syrup");
const Allocator = std.mem.Allocator;
const ByteList = std.array_list.Managed(u8);

pub const Netlayer = enum {
    tcp,
    onion,
    websocket,

    pub fn symbolName(self: Netlayer) []const u8 {
        return switch (self) {
            .tcp => "tcp",
            .onion => "onion",
            .websocket => "websocket",
        };
    }

    pub fn fromSymbol(s: []const u8) ?Netlayer {
        if (std.mem.eql(u8, s, "tcp")) return .tcp;
        if (std.mem.eql(u8, s, "onion")) return .onion;
        if (std.mem.eql(u8, s, "websocket")) return .websocket;
        return null;
    }
};

/// A remote vat's address.
pub const Location = struct {
    netlayer: Netlayer,
    designator: []const u8, // bytestring — typically 32 bytes for Ed25519 node key
    hints: []const []const u8 = &.{}, // optional transport hints ("1.2.3.4:1234", etc.)

    /// Encode as `<ocapn-node netlayer-sym designator-string hints>`.
    /// Designator is emitted as a Syrup string (Racket contract `string?`).
    /// Hints is emitted as `f` when empty (Racket idiom), otherwise a list
    /// of strings. Returns a caller-owned byte buffer.
    pub fn encodeAlloc(self: Location, allocator: Allocator) ![]u8 {
        var out = ByteList.init(allocator);
        defer out.deinit();
        try out.appendSlice("<10'ocapn-node");

        const sym = self.netlayer.symbolName();
        try std.fmt.format(out.writer(), "{d}'", .{sym.len});
        try out.appendSlice(sym);

        try std.fmt.format(out.writer(), "{d}\"", .{self.designator.len});
        try out.appendSlice(self.designator);

        if (self.hints.len == 0) {
            try out.append('f');
        } else {
            try out.append('[');
            for (self.hints) |h| {
                try std.fmt.format(out.writer(), "{d}\"", .{h.len});
                try out.appendSlice(h);
            }
            try out.append(']');
        }

        try out.append('>');
        return out.toOwnedSlice();
    }

    /// Parse a syrup.Value record into a Location.
    /// The value's backing memory must outlive the returned Location.
    pub fn fromValue(v: syrup.Value) !Location {
        if (v != .record) return error.InvalidFormat;
        const r = v.record;
        if (r.label.* != .symbol) return error.InvalidFormat;
        if (!std.mem.eql(u8, r.label.symbol, "ocapn-node")) return error.InvalidFormat;
        if (r.fields.len < 3) return error.InvalidFormat;

        if (r.fields[0] != .symbol) return error.InvalidFormat;
        const nl = Netlayer.fromSymbol(r.fields[0].symbol) orelse return error.UnknownNetlayer;

        // Zig self-emit is .bytes; live Racket Goblins emits .string
        // (base32-encoded). Accept either; caller decides how to interpret.
        const des = switch (r.fields[1]) {
            .bytes => |b| b,
            .string => |s| s,
            else => return error.InvalidFormat,
        };

        // Accept any of: list (zig-self), bool=false (racket empty),
        // string (racket single-hint). Hints content isn't used yet; caller
        // can re-destructure from r.fields[2] if needed.
        switch (r.fields[2]) {
            .list, .bool, .string => {},
            else => return error.InvalidFormat,
        }
        return Location{
            .netlayer = nl,
            .designator = des,
            .hints = &.{},
        };
    }
};

pub const SWISS_LEN: usize = 32;

/// Sturdy ref = location + swiss number (opaque 32-byte secret).
pub const SturdyRef = struct {
    location: Location,
    swiss: [SWISS_LEN]u8,

    /// Emit canonical URI: `ocapn://<designator>.<netlayer>/<swiss-hex>`.
    /// `designator` is emitted literally — caller is responsible for it
    /// being base32 (or whatever printable form the netlayer expects).
    pub fn toUri(self: SturdyRef, allocator: Allocator) ![]u8 {
        var out = ByteList.init(allocator);
        errdefer out.deinit();
        try out.appendSlice("ocapn://");
        try out.appendSlice(self.location.designator);
        try out.append('.');
        try out.appendSlice(self.location.netlayer.symbolName());
        try out.append('/');
        try hexLowerEncode(&out, &self.swiss);
        return out.toOwnedSlice();
    }

    /// Parse `ocapn://<designator>.<netlayer>/<swiss-hex>` into a SturdyRef.
    /// `designator` is preserved as the original (base32) string from the
    /// URI; allocator-owned dupe so the SturdyRef outlives the input slice.
    pub fn fromUri(uri: []const u8, allocator: Allocator) !SturdyRef {
        const prefix = "ocapn://";
        if (!std.mem.startsWith(u8, uri, prefix)) return error.InvalidUri;
        const rest = uri[prefix.len..];

        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidUri;
        const authority = rest[0..slash];
        const swiss_hex = rest[slash + 1 ..];

        const dot = std.mem.lastIndexOfScalar(u8, authority, '.') orelse return error.InvalidUri;
        const designator_str = authority[0..dot];
        const netlayer_sym = authority[dot + 1 ..];

        const nl = Netlayer.fromSymbol(netlayer_sym) orelse return error.UnknownNetlayer;
        const designator = try allocator.dupe(u8, designator_str);

        if (swiss_hex.len != SWISS_LEN * 2) return error.InvalidUri;
        var swiss: [SWISS_LEN]u8 = undefined;
        try hexLowerDecode(&swiss, swiss_hex);

        return SturdyRef{
            .location = .{ .netlayer = nl, .designator = designator, .hints = &.{} },
            .swiss = swiss,
        };
    }

    pub fn deinit(self: SturdyRef, allocator: Allocator) void {
        allocator.free(self.location.designator);
    }
};

// ---- hex / base32 helpers ---------------------------------------------------

fn hexLowerEncode(out: *ByteList, bytes: []const u8) !void {
    const tbl = "0123456789abcdef";
    for (bytes) |b| {
        try out.append(tbl[b >> 4]);
        try out.append(tbl[b & 0xF]);
    }
}

fn hexLowerDecode(dst: []u8, hex: []const u8) !void {
    if (hex.len != dst.len * 2) return error.InvalidHex;
    for (dst, 0..) |*d, i| {
        d.* = (try hexDigit(hex[i * 2]) << 4) | try hexDigit(hex[i * 2 + 1]);
    }
}

fn hexDigit(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
}

// RFC 4648 base32 (lowercase, no padding) — matches Goblins' `bytevector->base32`.
const B32_ALPHABET = "abcdefghijklmnopqrstuvwxyz234567";

pub fn base32LowerEncode(out: *ByteList, bytes: []const u8) !void {
    var i: usize = 0;
    var buf: u64 = 0;
    var bits: u6 = 0;
    while (i < bytes.len) : (i += 1) {
        buf = (buf << 8) | bytes[i];
        bits += 8;
        while (bits >= 5) {
            bits -= 5;
            const idx: u6 = @intCast((buf >> bits) & 0x1F);
            try out.append(B32_ALPHABET[idx]);
        }
    }
    if (bits > 0) {
        const idx: u6 = @intCast((buf << (5 - bits)) & 0x1F);
        try out.append(B32_ALPHABET[idx]);
    }
}

pub fn base32LowerDecodeAlloc(allocator: Allocator, text: []const u8) ![]u8 {
    var out = ByteList.init(allocator);
    errdefer out.deinit();
    var buf: u64 = 0;
    var bits: u6 = 0;
    for (text) |c| {
        const v = base32Digit(c) orelse return error.InvalidBase32;
        buf = (buf << 5) | v;
        bits += 5;
        if (bits >= 8) {
            bits -= 8;
            try out.append(@intCast((buf >> bits) & 0xFF));
        }
    }
    return out.toOwnedSlice();
}

fn base32Digit(c: u8) ?u8 {
    return switch (c) {
        'a'...'z' => c - 'a',
        'A'...'Z' => c - 'A',
        '2'...'7' => c - '2' + 26,
        else => null,
    };
}

// ---- Tests ------------------------------------------------------------------

test "location encode round-trip via Parser (Racket shape: string designator, false hints)" {
    const allocator = std.testing.allocator;
    const loc = Location{
        .netlayer = .tcp,
        .designator = "127.0.0.1:9000",
    };
    const bytes = try loc.encodeAlloc(allocator);
    defer allocator.free(bytes);

    var parser = syrup.Parser.init(bytes, allocator);
    var v = try parser.parse();
    defer v.deinitAll(allocator);

    try std.testing.expect(v == .record);
    try std.testing.expectEqualStrings("ocapn-node", v.record.label.symbol);
    try std.testing.expectEqual(@as(usize, 3), v.record.fields.len);
    try std.testing.expect(v.record.fields[1] == .string);
    try std.testing.expect(v.record.fields[2] == .bool);
    try std.testing.expectEqual(false, v.record.fields[2].bool);

    const round = try Location.fromValue(v);
    try std.testing.expectEqual(Netlayer.tcp, round.netlayer);
    try std.testing.expectEqualSlices(u8, loc.designator, round.designator);
}

test "location encode with non-empty hints emits list" {
    const allocator = std.testing.allocator;
    const loc = Location{
        .netlayer = .websocket,
        .designator = "example.com",
        .hints = &.{ "wss://example.com:8443/ocapn", "ipv4:1.2.3.4" },
    };
    const bytes = try loc.encodeAlloc(allocator);
    defer allocator.free(bytes);

    var parser = syrup.Parser.init(bytes, allocator);
    var v = try parser.parse();
    defer v.deinitAll(allocator);

    try std.testing.expect(v.record.fields[2] == .list);
    try std.testing.expectEqual(@as(usize, 2), v.record.fields[2].list.len);
}

test "location fromValue accepts Racket-shaped (string designator, false hints)" {
    const allocator = std.testing.allocator;
    // Hand-rolled Racket-style location:
    //   <ocapn-node onion "abc..." #f>
    // Designator as Syrup string, hints as Syrup false (`f`).
    const designator_str = "wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd";
    var buf = ByteList.init(allocator);
    defer buf.deinit();
    try buf.appendSlice("<10'ocapn-node");
    try buf.appendSlice("5'onion");
    try std.fmt.format(buf.writer(), "{d}\"", .{designator_str.len});
    try buf.appendSlice(designator_str);
    try buf.append('f');
    try buf.append('>');

    var parser = syrup.Parser.init(buf.items, allocator);
    var v = try parser.parse();
    defer v.deinitAll(allocator);

    const round = try Location.fromValue(v);
    try std.testing.expectEqual(Netlayer.onion, round.netlayer);
    try std.testing.expectEqualSlices(u8, designator_str, round.designator);
}

test "sturdy uri round-trip preserves base32 designator string" {
    const allocator = std.testing.allocator;
    // designator is the printable form (Racket convention): for tcp this
    // would be base32(pubkey). Use a fixed base32 string to verify
    // toUri/fromUri are byte-identity on it.
    const designator_str = "wy46gxdweyqn5m7ntzwlxinhdia2jjanlsh37gxklwhfec7yxqr4k3qd";
    var swiss: [SWISS_LEN]u8 = undefined;
    for (&swiss, 0..) |*s, i| s.* = @intCast((i * 7 + 3) & 0xFF);

    const ref = SturdyRef{
        .location = .{ .netlayer = .tcp, .designator = designator_str },
        .swiss = swiss,
    };
    const uri = try ref.toUri(allocator);
    defer allocator.free(uri);

    try std.testing.expect(std.mem.startsWith(u8, uri, "ocapn://"));
    try std.testing.expect(std.mem.indexOf(u8, uri, ".tcp/") != null);
    // designator literal is in URI (no double-encoding).
    try std.testing.expect(std.mem.indexOf(u8, uri, designator_str) != null);

    const parsed = try SturdyRef.fromUri(uri, allocator);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(Netlayer.tcp, parsed.location.netlayer);
    try std.testing.expectEqualSlices(u8, designator_str, parsed.location.designator);
    try std.testing.expectEqualSlices(u8, &swiss, &parsed.swiss);
}
