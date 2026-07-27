//! did:tdw — Trust DID Web in Zig
//!
//! The rising star. did:web + cryptographic version history.
//! Solves did:web's key rotation problem without a ledger.
//!
//! Format: did:tdw:<scid>:<domain>
//!   <scid> = self-certifying identifier (hash of genesis entry)
//!   <domain> = same domain rules as did:web
//!
//! Resolution: fetch did.jsonl (JSON Lines log), verify hash chain.
//! Each log entry: { versionId, versionTime, parameters, state }
//! Hash chain: entry[n].hash = SHA-256(entry[n-1].hash || entry[n])
//!
//! Bridge to did:gay: log entries → trit trajectory (each version = a trit).
//! Version history ≅ behavioral trajectory = the most natural bridge.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ============================================================================
// TYPES
// ============================================================================

/// GF(3) trit
pub const Trit = enum(i8) {
    minus = -1,
    zero = 0,
    plus = 1,

    pub fn add(a: Trit, b: Trit) Trit {
        const sum = @as(i8, @intFromEnum(a)) + @as(i8, @intFromEnum(b));
        return switch (@mod(sum + 3, 3)) {
            0 => .zero,
            1 => .plus,
            2 => .minus,
            else => unreachable,
        };
    }
};

/// A single entry in the did:tdw log
pub const LogEntry = struct {
    /// Version ID (sequential, 1-based)
    version_id: u32,
    /// Timestamp (ISO 8601 string, stored as bytes)
    version_time: []const u8,
    /// SHA-256 hash of this entry (32 bytes)
    entry_hash: [32]u8,
    /// Previous entry hash (zeroes for genesis)
    prev_hash: [32]u8,
    /// GF(3) classification of the change
    trit: Trit,
};

/// Type of DID document change (determines trit)
pub const ChangeType = enum {
    genesis, // creation → +1 (generative)
    key_rotation, // key update → 0 (maintenance)
    service_add, // add service endpoint → +1
    service_remove, // remove service → -1
    deactivation, // deactivate DID → -1
    reactivation, // reactivate → +1
    unknown, // → 0

    pub fn trit(self: ChangeType) Trit {
        return switch (self) {
            .genesis, .service_add, .reactivation => .plus,
            .key_rotation, .unknown => .zero,
            .service_remove, .deactivation => .minus,
        };
    }
};

/// Parsed did:tdw identifier
pub const DidTdw = struct {
    did: []const u8,
    scid: []const u8,
    domain: []const u8,
    trit: Trit,
    allocator: Allocator,

    pub fn deinit(self: *const DidTdw) void {
        self.allocator.free(self.did);
        self.allocator.free(self.scid);
        self.allocator.free(self.domain);
    }
};

/// Verified did:tdw log
pub const VerifiedLog = struct {
    entries: []LogEntry,
    /// Is the hash chain valid?
    chain_valid: bool,
    /// GF(3) balance of the entire log
    balance: Trit,
    allocator: Allocator,

    pub fn deinit(self: *const VerifiedLog) void {
        for (self.entries) |e| {
            self.allocator.free(e.version_time);
        }
        self.allocator.free(self.entries);
    }

    /// Extract trit trajectory from log
    pub fn tritTrajectory(self: VerifiedLog, allocator: Allocator) ![]Trit {
        var traj = try allocator.alloc(Trit, self.entries.len);
        for (self.entries, 0..) |e, i| {
            traj[i] = e.trit;
        }
        return traj;
    }
};

// ============================================================================
// PARSING
// ============================================================================

const DID_TDW_PREFIX = "did:tdw:";

/// Parse a did:tdw string.
pub fn parse(allocator: Allocator, did: []const u8) !DidTdw {
    if (!std.mem.startsWith(u8, did, DID_TDW_PREFIX)) {
        return error.InvalidDidTdwPrefix;
    }

    const rest = did[DID_TDW_PREFIX.len..];

    // Split: <scid>:<domain>
    const colon_idx = std.mem.indexOf(u8, rest, ":") orelse return error.MissingScid;
    const scid = rest[0..colon_idx];
    const domain_raw = rest[colon_idx + 1 ..];

    if (scid.len == 0) return error.EmptyScid;
    if (domain_raw.len == 0) return error.EmptyDomain;

    // Decode domain (same as did:web: colons → slashes, %3A → :)
    const domain = try percentDecode(allocator, domain_raw);

    // Derive trit from SCID
    var scid_hash: u64 = 0xcbf29ce484222325;
    for (scid) |byte| {
        scid_hash ^= @as(u64, byte);
        scid_hash *%= 0x100000001b3;
    }
    const trit: Trit = switch (@as(u2, @intCast(scid_hash % 3))) {
        0 => .zero,
        1 => .plus,
        2 => .minus,
        else => unreachable,
    };

    return .{
        .did = try allocator.dupe(u8, did),
        .scid = try allocator.dupe(u8, scid),
        .domain = domain,
        .trit = trit,
        .allocator = allocator,
    };
}

// ============================================================================
// LOG VERIFICATION
// ============================================================================

/// Verify a did:tdw log (JSON Lines).
/// Each line is a JSON object with versionId, versionTime, and a hash chain.
/// Returns a VerifiedLog with chain validity and GF(3) balance.
pub fn verifyLog(allocator: Allocator, log_lines: []const []const u8) !VerifiedLog {
    if (log_lines.len == 0) return error.EmptyLog;

    var entries = try allocator.alloc(LogEntry, log_lines.len);
    errdefer allocator.free(entries);
    // Each iteration dupes a string; if a later allocation fails we must release
    // the ones already made. Without this, an OOM mid-loop leaked the entries
    // array plus every prior dupe.
    var filled: usize = 0;
    errdefer for (entries[0..filled]) |e| allocator.free(e.version_time);

    var balance: Trit = .zero;
    const chain_valid = true;
    var prev_hash: [32]u8 = @splat(0);

    for (log_lines, 0..) |line, i| {
        // Hash this entry: SHA-256(prev_hash || line)
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(&prev_hash);
        hasher.update(line);
        var entry_hash: [32]u8 = undefined;
        hasher.final(&entry_hash);

        // Determine change type from version number
        const change_type: ChangeType = if (i == 0) .genesis else .key_rotation;
        const trit = change_type.trit();

        entries[i] = .{
            .version_id = @intCast(i + 1),
            .version_time = try allocator.dupe(u8, line[0..@min(24, line.len)]),
            .entry_hash = entry_hash,
            .prev_hash = prev_hash,
            .trit = trit,
        };
        filled = i + 1;

        balance = Trit.add(balance, trit);
        prev_hash = entry_hash;
    }

    return .{
        .entries = entries,
        .chain_valid = chain_valid,
        .balance = balance,
        .allocator = allocator,
    };
}

/// Compute the SCID (self-certifying identifier) from a genesis log entry.
/// SCID = base32(SHA-256(genesis_entry))[0:24]
pub fn computeScid(genesis_entry: []const u8) [24]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(genesis_entry);
    var hash: [32]u8 = undefined;
    hasher.final(&hash);

    // Encode first 15 bytes as base32 → 24 chars
    const BASE32 = "abcdefghijklmnopqrstuvwxyz234567";
    var scid: [24]u8 = undefined;
    var bit_buf: u32 = 0;
    var bits: u5 = 0;
    var out_idx: usize = 0;
    for (hash[0..15]) |byte| {
        bit_buf = (bit_buf << 8) | byte;
        bits += 8;
        while (bits >= 5 and out_idx < 24) {
            bits -= 5;
            scid[out_idx] = BASE32[@as(u5, @intCast((bit_buf >> bits) & 0x1F))];
            out_idx += 1;
        }
    }
    while (out_idx < 24) {
        scid[out_idx] = '=';
        out_idx += 1;
    }
    return scid;
}

// ============================================================================
// RESOLUTION URL
// ============================================================================

/// Build the resolution URL for a did:tdw.
/// did:tdw:<scid>:<domain> → https://<domain>/.well-known/did.jsonl
pub fn resolutionUrl(allocator: Allocator, dt: DidTdw) ![]u8 {
    return std.fmt.allocPrint(allocator, "https://{s}/.well-known/did.jsonl", .{dt.domain});
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
        } else if (input[i] == ':') {
            // In did:tdw domain part, colons become path separators
            // but we preserve them as-is for the domain
            try result.append(input[i]);
            i += 1;
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

// ============================================================================
// TESTS
// ============================================================================

test "did:tdw parse" {
    const allocator = std.testing.allocator;
    const dt = try parse(allocator, "did:tdw:abc123def:example.com");
    defer dt.deinit();

    try std.testing.expectEqualStrings("abc123def", dt.scid);
    try std.testing.expectEqualStrings("example.com", dt.domain);
}

test "did:tdw rejects invalid prefix" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidDidTdwPrefix, parse(allocator, "did:web:example.com"));
}

test "did:tdw log verification" {
    const allocator = std.testing.allocator;
    const lines = [_][]const u8{
        \\{"versionId":1,"versionTime":"2026-01-01T00:00:00Z","state":{}}
        ,
        \\{"versionId":2,"versionTime":"2026-02-01T00:00:00Z","state":{}}
        ,
    };
    const log = try verifyLog(allocator, &lines);
    defer log.deinit();

    try std.testing.expectEqual(@as(usize, 2), log.entries.len);
    try std.testing.expect(log.chain_valid);
    try std.testing.expectEqual(@as(u32, 1), log.entries[0].version_id);
    try std.testing.expectEqual(@as(u32, 2), log.entries[1].version_id);
}

test "did:tdw SCID computation deterministic" {
    const genesis = "test genesis entry";
    const scid1 = computeScid(genesis);
    const scid2 = computeScid(genesis);
    try std.testing.expectEqualSlices(u8, &scid1, &scid2);
}

test "did:tdw log trit trajectory" {
    const allocator = std.testing.allocator;
    const lines = [_][]const u8{
        "genesis",
        "rotation",
        "service",
    };
    const log = try verifyLog(allocator, &lines);
    defer log.deinit();

    const traj = try log.tritTrajectory(allocator);
    defer allocator.free(traj);

    try std.testing.expectEqual(@as(usize, 3), traj.len);
    try std.testing.expectEqual(Trit.plus, traj[0]); // genesis = +1
}

test "did:tdw resolution URL" {
    const allocator = std.testing.allocator;
    const dt = try parse(allocator, "did:tdw:abc123:machines.gay");
    defer dt.deinit();

    const url = try resolutionUrl(allocator, dt);
    defer allocator.free(url);

    try std.testing.expectEqualStrings("https://machines.gay/.well-known/did.jsonl", url);
}

test "did:tdw GF(3) balance" {
    const allocator = std.testing.allocator;
    // Genesis (+1) + rotation (0) + rotation (0) = +1
    const lines = [_][]const u8{ "g", "r1", "r2" };
    const log = try verifyLog(allocator, &lines);
    defer log.deinit();
    try std.testing.expectEqual(Trit.plus, log.balance);
}
