//! OCapN Tor onion netlayer — wire primitives.
//!
//! Per guile-goblins `goblins/ocapn/netlayer/onion.scm` + OCapN draft
//! `Netlayers.md`:
//!
//!   - Transport symbol: `onion`. `hints` is `false` / empty.
//!   - Wire framing: raw TCP stream of back-to-back Syrup values — NO length
//!     prefix (reuses our `ocapn_transport.OcapnConnection`). Tor provides
//!     encryption; no additional TLS.
//!   - Hidden service MUST bind port **9045**, key type **ED25519-V3**.
//!   - Designator: the 56-char base32 v3 onion Service ID (no `.onion`
//!     suffix). URI composition appends `.onion`.
//!   - Publication: Tor control-port `ADD_ONION NEW:ED25519-V3 PORT=9045,...`
//!     over `~/.cache/goblins/tor/tor-control-sock`. Control auth via
//!     `AUTHENTICATE`; ServiceID read from `250-ServiceID=` response.
//!   - Client SOCKS: default unix socket
//!     `~/.cache/goblins/tor/tor-socks-sock`; fall back to TCP
//!     `127.0.0.1:9050`.
//!
//! This module is byte-oriented. The caller owns the actual I/O and feeds
//! response bytes back in. That keeps us compatible across Zig 0.15/0.16
//! Reader/Writer churn and lets the same code drive unix sockets, TCP, or
//! test fixtures.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const HIDDEN_SERVICE_PORT: u16 = 9045;
pub const DEFAULT_SOCKS_TCP_PORT: u16 = 9050;
pub const DEFAULT_CONTROL_SOCK: []const u8 = ".cache/goblins/tor/tor-control-sock";
pub const DEFAULT_SOCKS_SOCK: []const u8 = ".cache/goblins/tor/tor-socks-sock";

// ---- SOCKS5 (client side) ---------------------------------------------------

/// SOCKS5 greeting bytes: one method = NO_AUTH.
pub const SOCKS5_GREETING: [3]u8 = .{ 0x05, 0x01, 0x00 };

/// Build a SOCKS5 CONNECT request for `<host>:<port>` (ATYP=DOMAINNAME).
pub fn socks5ConnectRequestAlloc(
    allocator: Allocator,
    host: []const u8,
    port: u16,
) ![]u8 {
    if (host.len > 255) return error.HostnameTooLong;
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.appendSlice(&[_]u8{ 0x05, 0x01, 0x00, 0x03, @as(u8, @intCast(host.len)) });
    try out.appendSlice(host);
    var port_be: [2]u8 = undefined;
    std.mem.writeInt(u16, &port_be, port, .big);
    try out.appendSlice(&port_be);
    return out.toOwnedSlice();
}

pub const Socks5Ack = struct {
    rep: u8,
    /// byte length of the full reply (so caller can slice remaining stream).
    consumed: usize,
};

/// Parse a SOCKS5 greeting reply. `buf` must be at least 2 bytes.
pub fn parseSocks5Greeting(buf: []const u8) !void {
    if (buf.len < 2) return error.ShortReply;
    if (buf[0] != 0x05) return error.BadSocksVersion;
    if (buf[1] != 0x00) return error.SocksAuthRequired;
}

/// Parse a SOCKS5 CONNECT reply. Returns {rep, consumed}. `rep==0` means
/// tunnel open. `consumed` tells the caller how many bytes to discard
/// before reading application data.
pub fn parseSocks5ConnectReply(buf: []const u8) !Socks5Ack {
    if (buf.len < 4) return error.ShortReply;
    if (buf[0] != 0x05) return error.BadSocksVersion;
    const rep = buf[1];
    const atyp = buf[3];
    const addr_len: usize = switch (atyp) {
        0x01 => 4,
        0x03 => blk: {
            if (buf.len < 5) return error.ShortReply;
            break :blk @as(usize, buf[4]) + 1;
        },
        0x04 => 16,
        else => return error.BadSocksAtyp,
    };
    const total = 4 + addr_len + 2;
    if (buf.len < total) return error.ShortReply;
    return .{ .rep = rep, .consumed = total };
}

/// Build the host string used in a SOCKS CONNECT to an onion service.
/// Goblins appends a single `.onion` to the 56-char base32 designator.
pub fn onionHostAlloc(allocator: Allocator, designator_b32: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.onion", .{designator_b32});
}

// ---- Tor control protocol ---------------------------------------------------

pub const AddOnionResult = struct {
    service_id: []u8, // caller-owned; 56-char v3 service ID (no .onion suffix)
    private_key: []u8, // caller-owned; e.g. "ED25519-V3:base64..." or "" if discarded

    pub fn deinit(self: AddOnionResult, allocator: Allocator) void {
        allocator.free(self.service_id);
        allocator.free(self.private_key);
    }
};

/// Build the bytes of an `AUTHENTICATE` control command. Pass the hex-encoded
/// cookie for cookie auth, or null/empty for NULL auth.
pub fn authenticateLineAlloc(allocator: Allocator, cookie_hex: ?[]const u8) ![]u8 {
    if (cookie_hex) |h| {
        return std.fmt.allocPrint(allocator, "AUTHENTICATE {s}\r\n", .{h});
    }
    return std.fmt.allocPrint(allocator, "AUTHENTICATE\r\n", .{});
}

/// Build the bytes of an `ADD_ONION NEW:ED25519-V3 PORT=9045,...` command.
/// `target` is typically `unix:/path/to/sock` or `127.0.0.1:PORT`.
pub fn addOnionLineAlloc(allocator: Allocator, target: []const u8, keep_key: bool) ![]u8 {
    const flags = if (keep_key) "" else "Flags=DiscardPK ";
    return std.fmt.allocPrint(
        allocator,
        "ADD_ONION NEW:ED25519-V3 {s}Port={d},{s}\r\n",
        .{ flags, HIDDEN_SERVICE_PORT, target },
    );
}

/// Parse a complete `ADD_ONION` response block (terminated by a `250 OK`
/// line). Scans for `250-ServiceID=` and `250-PrivateKey=` prefixes. Caller
/// owns returned strings.
pub fn parseAddOnionResponse(allocator: Allocator, response: []const u8) !AddOnionResult {
    var service_id: ?[]u8 = null;
    var private_key: ?[]u8 = null;
    errdefer if (service_id) |s| allocator.free(s);
    errdefer if (private_key) |pk| allocator.free(pk);

    var it = std.mem.splitScalar(u8, response, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r\n ");
        if (std.mem.startsWith(u8, line, "250-ServiceID=")) {
            service_id = try allocator.dupe(u8, line["250-ServiceID=".len..]);
        } else if (std.mem.startsWith(u8, line, "250-PrivateKey=")) {
            private_key = try allocator.dupe(u8, line["250-PrivateKey=".len..]);
        } else if (std.mem.eql(u8, line, "250 OK")) {
            break;
        } else if (line.len > 0 and (line[0] == '4' or line[0] == '5')) {
            return error.ControlError;
        }
    }

    const sid = service_id orelse return error.MissingServiceId;
    return .{
        .service_id = sid,
        .private_key = private_key orelse try allocator.dupe(u8, ""),
    };
}

// ---- I/O orchestration (Posix) ---------------------------------------------
//
// Helpers that compose the byte-oriented primitives above into an end-to-end
// "give me a connected Stream to this onion" call. Posix-only: rely on
// `std.net.connectUnixSocket`. On other platforms the caller can still use
// the byte-oriented primitives directly.

/// Connect to the Tor SOCKS proxy. Tries the unix socket at `unix_path`
/// first if non-null; falls back to TCP `127.0.0.1:DEFAULT_SOCKS_TCP_PORT`.
/// `unix_path` may be absolute or `~`-relative — caller is responsible for
/// home-expansion (we don't drag in env lookups here).
pub fn connectSocksProxy(unix_path: ?[]const u8) !std.net.Stream {
    if (unix_path) |p| {
        if (std.net.connectUnixSocket(p)) |s| return s else |_| {}
    }
    const addr = try std.net.Address.parseIp4("127.0.0.1", DEFAULT_SOCKS_TCP_PORT);
    return std.net.tcpConnectToAddress(addr);
}

/// Connect to the Tor control port unix socket. No TCP fallback — control
/// auth is sensitive enough that the unix-socket path is the only sane
/// default.
pub fn connectControlSocket(path: []const u8) !std.net.Stream {
    return std.net.connectUnixSocket(path);
}

/// Run the full SOCKS5 handshake against an already-connected proxy stream
/// to reach `<onion-designator>.onion:9045`. On success the stream is left
/// positioned past the SOCKS reply, ready for application bytes (Syrup).
/// On any SOCKS error returns `error.SocksConnectFailed` after closing the
/// stream — caller does not need to clean up.
pub fn negotiateSocks5(
    allocator: Allocator,
    stream: std.net.Stream,
    designator_b32: []const u8,
) !void {
    errdefer stream.close();

    // Greeting.
    _ = try stream.write(&SOCKS5_GREETING);
    var greeting_reply: [2]u8 = undefined;
    var read: usize = 0;
    while (read < greeting_reply.len) {
        const n = try stream.read(greeting_reply[read..]);
        if (n == 0) return error.SocksConnectFailed;
        read += n;
    }
    try parseSocks5Greeting(&greeting_reply);

    // CONNECT.
    const host = try onionHostAlloc(allocator, designator_b32);
    defer allocator.free(host);
    const req = try socks5ConnectRequestAlloc(allocator, host, HIDDEN_SERVICE_PORT);
    defer allocator.free(req);
    _ = try stream.write(req);

    // Reply: read the fixed 4-byte head, then dispatch on ATYP.
    var head: [4]u8 = undefined;
    read = 0;
    while (read < head.len) {
        const n = try stream.read(head[read..]);
        if (n == 0) return error.SocksConnectFailed;
        read += n;
    }
    if (head[0] != 0x05) return error.SocksConnectFailed;
    if (head[1] != 0x00) return error.SocksConnectFailed;
    const tail_len: usize = switch (head[3]) {
        0x01 => 4 + 2, // IPv4 + port
        0x03 => blk: {
            var l: [1]u8 = undefined;
            _ = try stream.read(&l);
            // Domain length is included in tail; consume domain + port.
            break :blk @as(usize, l[0]) + 2;
        },
        0x04 => 16 + 2, // IPv6 + port
        else => return error.SocksConnectFailed,
    };
    var tail_buf: [262]u8 = undefined; // max: 256 (domain) + 2 (port) + 4 slack
    if (tail_len > tail_buf.len) return error.SocksConnectFailed;
    read = 0;
    while (read < tail_len) {
        const n = try stream.read(tail_buf[read..tail_len]);
        if (n == 0) return error.SocksConnectFailed;
        read += n;
    }
}

/// One-shot: connect to local Tor SOCKS, run handshake, return a Stream
/// pointed at the onion service. `socks_unix_path` may be null to force TCP.
pub fn connectThroughTor(
    allocator: Allocator,
    socks_unix_path: ?[]const u8,
    designator_b32: []const u8,
) !std.net.Stream {
    const proxy = try connectSocksProxy(socks_unix_path);
    try negotiateSocks5(allocator, proxy, designator_b32);
    return proxy;
}

// ---- Tests ------------------------------------------------------------------

test "onionHostAlloc appends .onion" {
    const allocator = std.testing.allocator;
    const got = try onionHostAlloc(allocator, "kjvy4q57mcjqowfjxskvjhwh5by6qmxwf6io4ebnbajdg23vxwpq");
    defer allocator.free(got);
    try std.testing.expectEqualStrings(
        "kjvy4q57mcjqowfjxskvjhwh5by6qmxwf6io4ebnbajdg23vxwpq.onion",
        got,
    );
}

test "SOCKS5 CONNECT request: domain atyp + port 9045" {
    const allocator = std.testing.allocator;
    const req = try socks5ConnectRequestAlloc(allocator, "example.onion", HIDDEN_SERVICE_PORT);
    defer allocator.free(req);
    try std.testing.expectEqual(@as(u8, 0x05), req[0]); // VER
    try std.testing.expectEqual(@as(u8, 0x01), req[1]); // CMD=CONNECT
    try std.testing.expectEqual(@as(u8, 0x03), req[3]); // ATYP=DOMAIN
    try std.testing.expectEqual(@as(u8, @intCast("example.onion".len)), req[4]);
    const port_hi = req[req.len - 2];
    const port_lo = req[req.len - 1];
    try std.testing.expectEqual(@as(u16, HIDDEN_SERVICE_PORT), (@as(u16, port_hi) << 8) | port_lo);
}

test "SOCKS5 CONNECT reply parse: IPv4 success" {
    const reply = [_]u8{ 0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0x01, 0x02 };
    const ack = try parseSocks5ConnectReply(&reply);
    try std.testing.expectEqual(@as(u8, 0x00), ack.rep);
    try std.testing.expectEqual(@as(usize, 10), ack.consumed);
}

test "ADD_ONION response parse: scrapes ServiceID" {
    const allocator = std.testing.allocator;
    const resp =
        "250-ServiceID=kjvy4q57mcjqowfjxskvjhwh5by6qmxwf6io4ebnbajdg23vxwpq\r\n" ++
        "250-PrivateKey=ED25519-V3:abc\r\n" ++
        "250 OK\r\n";
    const r = try parseAddOnionResponse(allocator, resp);
    defer r.deinit(allocator);
    try std.testing.expectEqualStrings(
        "kjvy4q57mcjqowfjxskvjhwh5by6qmxwf6io4ebnbajdg23vxwpq",
        r.service_id,
    );
    try std.testing.expectEqualStrings("ED25519-V3:abc", r.private_key);
}
