//! did:web — Domain-linked DID method in Zig
//!
//! The boring winner. EU eIDAS 2.0, Gaia-X, enterprise standard.
//! Resolution: did:web:example.com → HTTPS GET https://example.com/.well-known/did.json
//! Subdomain: did:web:example.com:path:to:resource → https://example.com/path/to/resource/did.json
//!
//! Zero other Zig implementations exist (as of 2026-04).
//! Bridges to did:gay via bisimulation.zig (DID Document → LTS).
//!
//! Security model: relies on DNS + TLS (no blockchain, no DHT).
//! Key rotation: replace did.json. Revocation: delete or 404.
//! Weakness: domain seizure = identity theft (did:tdw fixes this).

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// TYPES
// ============================================================================

/// Parsed did:web identifier
pub const DidWeb = struct {
    /// The full DID string (e.g., "did:web:example.com")
    did: []const u8,
    /// The resolved HTTPS URL for the DID document
    url: []const u8,
    /// Domain extracted from the DID
    domain: []const u8,
    /// GF(3) trit derived from domain hash
    trit: Trit,

    allocator: Allocator,

    pub fn deinit(self: *const DidWeb) void {
        self.allocator.free(self.did);
        self.allocator.free(self.url);
        self.allocator.free(self.domain);
    }
};

/// GF(3) trit — matches bisimulation.zig / continuation.zig
pub const Trit = enum(i8) {
    minus = -1,
    zero = 0,
    plus = 1,

    pub fn fromHash(h: u64) Trit {
        return switch (@as(u2, @intCast(h % 3))) {
            0 => .zero,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }
};

// ============================================================================
// PARSING
// ============================================================================

const DID_WEB_PREFIX = "did:web:";

/// Parse a did:web string into its components.
///
/// did:web:example.com → domain="example.com", url="https://example.com/.well-known/did.json"
/// did:web:example.com:user:alice → domain="example.com", url="https://example.com/user/alice/did.json"
/// Percent-encoded colons in domain: did:web:example.com%3A3000 → example.com:3000
pub fn parse(allocator: Allocator, did: []const u8) !DidWeb {
    if (!std.mem.startsWith(u8, did, DID_WEB_PREFIX)) {
        return error.InvalidDidWebPrefix;
    }

    const method_specific = did[DID_WEB_PREFIX.len..];
    if (method_specific.len == 0) return error.EmptyDidWeb;

    // Split on ':' to get path segments
    var segments = std.array_list.AlignedManaged([]const u8, null).init(allocator);
    defer segments.deinit();

    var start: usize = 0;
    for (method_specific, 0..) |ch, i| {
        if (ch == ':') {
            try segments.append(method_specific[start..i]);
            start = i + 1;
        }
    }
    try segments.append(method_specific[start..]);

    // First segment is domain (percent-decode %3A → :)
    const raw_domain = segments.items[0];
    const domain = try percentDecode(allocator, raw_domain);

    // Build URL
    var url_buf = std.array_list.AlignedManaged(u8, null).init(allocator);
    try url_buf.appendSlice("https://");
    try url_buf.appendSlice(domain);

    if (segments.items.len == 1) {
        // No path → /.well-known/did.json
        try url_buf.appendSlice("/.well-known/did.json");
    } else {
        // Path segments → /seg1/seg2/.../did.json
        for (segments.items[1..]) |seg| {
            try url_buf.append('/');
            try url_buf.appendSlice(seg);
        }
        try url_buf.appendSlice("/did.json");
    }

    const url = try url_buf.toOwnedSlice();
    const did_copy = try allocator.dupe(u8, did);

    // Derive trit from domain hash
    const trit = Trit.fromHash(domainHash(domain));

    return .{
        .did = did_copy,
        .url = url,
        .domain = domain,
        .trit = trit,
        .allocator = allocator,
    };
}

/// Construct a did:web from a domain and optional path.
pub fn fromDomain(allocator: Allocator, domain: []const u8, path: ?[]const []const u8) !DidWeb {
    var did_buf = std.array_list.AlignedManaged(u8, null).init(allocator);
    try did_buf.appendSlice(DID_WEB_PREFIX);

    // Percent-encode ':' as %3A in domain
    for (domain) |ch| {
        if (ch == ':') {
            try did_buf.appendSlice("%3A");
        } else {
            try did_buf.append(ch);
        }
    }

    if (path) |p| {
        for (p) |segment| {
            try did_buf.append(':');
            try did_buf.appendSlice(segment);
        }
    }

    const did_str = try did_buf.toOwnedSlice();
    defer allocator.free(did_str);

    return parse(allocator, did_str);
}

// ============================================================================
// DID DOCUMENT GENERATION
// ============================================================================

/// Generate a minimal did:web DID Document.
/// Caller provides the Ed25519 public key for the verification method.
pub fn toDidDocument(allocator: Allocator, dw: DidWeb, public_key_multibase: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"@context":["https://www.w3.org/ns/did/v1","https://w3id.org/security/suites/ed25519-2020/v1"],"id":"{s}","verificationMethod":[{{"id":"{s}#key-1","type":"Ed25519VerificationKey2020","controller":"{s}","publicKeyMultibase":"{s}"}}],"authentication":["{s}#key-1"],"service":[]}}
    , .{ dw.did, dw.did, dw.did, public_key_multibase, dw.did });
}

// ============================================================================
// BRIDGE TO did:gay (via trit trajectory)
// ============================================================================

/// Convert a did:web's domain to a trit trajectory for bisimulation.
/// Maps each domain character to a trit (vowels=0, consonants=+1, symbols=-1).
pub fn domainToTritTrajectory(allocator: Allocator, domain: []const u8) ![]Trit {
    var trajectory = try allocator.alloc(Trit, domain.len);
    for (domain, 0..) |ch, i| {
        trajectory[i] = charToTrit(ch);
    }
    return trajectory;
}

fn charToTrit(ch: u8) Trit {
    return switch (ch) {
        'a', 'e', 'i', 'o', 'u', 'A', 'E', 'I', 'O', 'U' => .zero,
        'b',
        'c',
        'd',
        'f',
        'g',
        'h',
        'j',
        'k',
        'l',
        'm',
        'n',
        'p',
        'q',
        'r',
        's',
        't',
        'v',
        'w',
        'x',
        'y',
        'z',
        'B',
        'C',
        'D',
        'F',
        'G',
        'H',
        'J',
        'K',
        'L',
        'M',
        'N',
        'P',
        'Q',
        'R',
        'S',
        'T',
        'V',
        'W',
        'X',
        'Y',
        'Z',
        => .plus,
        else => .minus,
    };
}

// ============================================================================
// HELPERS
// ============================================================================

fn percentDecode(allocator: Allocator, input: []const u8) ![]u8 {
    var result = std.array_list.AlignedManaged(u8, null).init(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = hexVal(input[i + 1]) orelse {
                try result.append(input[i]);
                i += 1;
                continue;
            };
            const lo = hexVal(input[i + 2]) orelse {
                try result.append(input[i]);
                i += 1;
                continue;
            };
            try result.append(hi * 16 + lo);
            i += 3;
        } else {
            try result.append(input[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice();
}

fn hexVal(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

/// FNV-1a hash of domain for trit derivation
fn domainHash(domain: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (domain) |byte| {
        h ^= @as(u64, byte);
        h *%= 0x100000001b3;
    }
    return h;
}

// ============================================================================
// TESTS
// ============================================================================

test "did:web basic parse" {
    const allocator = std.testing.allocator;
    const dw = try parse(allocator, "did:web:example.com");
    defer dw.deinit();

    try std.testing.expectEqualStrings("example.com", dw.domain);
    try std.testing.expectEqualStrings("https://example.com/.well-known/did.json", dw.url);
}

test "did:web with path" {
    const allocator = std.testing.allocator;
    const dw = try parse(allocator, "did:web:example.com:user:alice");
    defer dw.deinit();

    try std.testing.expectEqualStrings("example.com", dw.domain);
    try std.testing.expectEqualStrings("https://example.com/user/alice/did.json", dw.url);
}

test "did:web percent-encoded port" {
    const allocator = std.testing.allocator;
    const dw = try parse(allocator, "did:web:localhost%3A3000");
    defer dw.deinit();

    try std.testing.expectEqualStrings("localhost:3000", dw.domain);
    try std.testing.expectEqualStrings("https://localhost:3000/.well-known/did.json", dw.url);
}

test "did:web rejects invalid prefix" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidDidWebPrefix, parse(allocator, "did:key:z6Mk"));
}

test "did:web fromDomain roundtrip" {
    const allocator = std.testing.allocator;
    const path = [_][]const u8{ "users", "bob" };
    const dw = try fromDomain(allocator, "machines.gay", &path);
    defer dw.deinit();

    try std.testing.expectEqualStrings("machines.gay", dw.domain);
    try std.testing.expect(std.mem.indexOf(u8, dw.url, "/users/bob/did.json") != null);
}

test "did:web domain trit trajectory" {
    const allocator = std.testing.allocator;
    const traj = try domainToTritTrajectory(allocator, "machines.gay");
    defer allocator.free(traj);

    // "machines.gay" = 12 chars → 12 trits
    try std.testing.expectEqual(@as(usize, 12), traj.len);
}

test "did:web DID document generation" {
    const allocator = std.testing.allocator;
    const dw = try parse(allocator, "did:web:machines.gay");
    defer dw.deinit();

    const doc = try toDidDocument(allocator, dw, "z6MkhaXgBZDvotDkL5257faiztiGiC2QtKLGpbnnEGta2doK");
    defer allocator.free(doc);

    try std.testing.expect(std.mem.indexOf(u8, doc, "did:web:machines.gay") != null);
    try std.testing.expectEqual(@as(u8, '{'), doc[0]);
}
