//! openclaw.zig — Extitutional credential manifold
//!
//! The extitute is the space between institutions where capabilities compose.
//! No single institution is root. Credentials are validated by triangulation
//! across independent witness types, not by hierarchical descent from a root.
//!
//! Witness types (all equal, no hierarchy):
//!   InstitutionWitness — .edu email attestation (stanford, harvard, yale...)
//!   PeerWitness        — signed by co-participants (Minecraft scrutiny, etc.)
//!   WorkWitness        — content-addressed artifacts (capstone, code, audio)
//!   AIWitness          — synthesis attestation (convocation AI, LLM eval)
//!
//! A credential is valid when enough independent witnesses attest from
//! different positions on the manifold. Like triangulation, not hierarchy.
//!
//! Content-addressed via SHA3-256 (Keccak, NIST FIPS 202 — matches Move/Aptos hash::sha3_256).
//!
//! Transport: Syrup records via QRTP (fountain.zig) or OCapN CapTP (goblins_ffi.zig).
//!
//! $GAY <> $REGRET tokenomics:
//!   $REGRET accumulates when institutional credentials fail to capture real learning.
//!   $GAY is the deterministic color of what was actually learned — content-addressed,
//!   seed-reproducible, verifiable. The exchange rate is the extitute's price signal:
//!   how much institutional legibility do you need to convert tacit knowledge into
//!   recognized capability?
//!
//! GF(3) trit: -1 (MINUS) — verification/gatekeeping role

const std = @import("std");
const Sha3_256 = std.crypto.hash.sha3.Sha3_256;

// ============================================================================
// WITNESS TYPES (extitutional — no hierarchy, all equal)
// ============================================================================

pub const WitnessKind = enum(u8) {
    /// .edu email domain attestation — institution says "this person is enrolled"
    institution = 0,
    /// Peer co-participant — signed attestation from someone who was there
    peer = 1,
    /// Content-addressed work artifact — capstone, code, recording, essay
    work = 2,
    /// AI synthesis — convocation AI, LLM evaluation, automated assessment
    ai = 3,

    pub fn name(self: WitnessKind) []const u8 {
        return switch (self) {
            .institution => "institution",
            .peer => "peer",
            .work => "work",
            .ai => "ai",
        };
    }

    pub fn trit(self: WitnessKind) Trit {
        return switch (self) {
            .institution => .minus, // verification/gatekeeping
            .peer => .plus, // generation/attestation
            .work => .zero, // ergodic/artifact
            .ai => .minus, // verification/synthesis
        };
    }
};

// ============================================================================
// INSTITUTION REGISTRY (witnesses, not authorities)
// ============================================================================

pub const Institution = enum(u8) {
    // Universities
    harvard = 0,
    stanford = 1,
    yale = 2,
    ucsb = 3, // Geometric Intelligence Lab, Geomstats
    berkeley = 4, // Simons Institute, unstable ontology
    // National labs
    pnnl = 10, // VOLTTRON, HELICS, GridAPPS-D
    // Research orgs
    simons = 20, // Simons Institute (Project CETI, TCS)
    ceti = 21, // Cetacean Translation Initiative (interspecies)
    // Energy / DeSci
    plurigrid = 30, // mastodon.energy, CoFi, e-gen
    /// The extitute itself — the space between institutions
    extitute = 255,

    pub fn domain(self: Institution) []const u8 {
        return switch (self) {
            .harvard => "harvard.edu",
            .stanford => "stanford.edu",
            .yale => "yale.edu",
            .ucsb => "ucsb.edu",
            .berkeley => "berkeley.edu",
            .pnnl => "pnnl.gov",
            .simons => "simons.berkeley.edu",
            .ceti => "projectceti.org",
            .plurigrid => "plurigrid.xyz",
            .extitute => "openclaw.net",
        };
    }

    pub fn displayName(self: Institution) []const u8 {
        return switch (self) {
            .harvard => "Harvard University",
            .stanford => "Stanford University",
            .yale => "Yale University",
            .ucsb => "UC Santa Barbara",
            .berkeley => "UC Berkeley",
            .pnnl => "Pacific Northwest National Laboratory",
            .simons => "Simons Institute for TCS",
            .ceti => "Project CETI",
            .plurigrid => "Plurigrid",
            .extitute => "Extitute (credential manifold)",
        };
    }

    pub fn seed(self: Institution) u64 {
        return switch (self) {
            .harvard => 0xA51C30_00000001,
            .stanford => 0x8C1515_00000002,
            .yale => 0x00356B_00000003,
            .ucsb => 0x003660_00000004,
            .berkeley => 0x003262_00000005,
            .pnnl => 0x4B8BBE_0000000A,
            .simons => 0x1A5276_00000014,
            .ceti => 0x0077B6_00000015,
            .plurigrid => 0x7CFC00_0000001E,
            .extitute => 0x696969_00000000,
        };
    }

    pub fn fromDomain(domain_str: []const u8) ?Institution {
        if (endsWith(domain_str, "harvard.edu")) return .harvard;
        if (endsWith(domain_str, "stanford.edu")) return .stanford;
        if (endsWith(domain_str, "yale.edu")) return .yale;
        if (endsWith(domain_str, "ucsb.edu")) return .ucsb;
        if (endsWith(domain_str, "berkeley.edu")) return .berkeley;
        if (endsWith(domain_str, "pnnl.gov")) return .pnnl;
        if (endsWith(domain_str, "simons.berkeley.edu")) return .simons;
        if (endsWith(domain_str, "projectceti.org")) return .ceti;
        if (endsWith(domain_str, "plurigrid.xyz")) return .plurigrid;
        return null;
    }
};

// ============================================================================
// GF(3) TRIT
// ============================================================================

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

// ============================================================================
// CREDENTIAL ID — SHA3-256 content address
// ============================================================================

pub const CredId = [32]u8;

// ============================================================================
// WITNESS — a single attestation on the credential manifold
// ============================================================================

pub const Witness = struct {
    witness_id: CredId,
    kind: WitnessKind,
    /// For institution witnesses: which institution attested
    institution: Institution = .extitute,
    /// Scope of what is being witnessed (e.g. "music/composition", "cs/systems")
    scope: [64]u8 = [_]u8{0} ** 64,
    scope_len: u8 = 0,
    /// SHA3-256 hash of the witness's signing key or identity
    witness_key_hash: CredId = [_]u8{0} ** 32,
    /// SHA3-256 hash of the evidence (email challenge response, artifact CID, etc.)
    evidence_hash: CredId = [_]u8{0} ** 32,
    issued_at: u64,
    expires_at: u64 = 0,
    revoked: bool = false,

    pub fn scopeSlice(self: *const Witness) []const u8 {
        return self.scope[0..self.scope_len];
    }

    pub fn isExpired(self: *const Witness, now_ms: u64) bool {
        return self.expires_at > 0 and now_ms > self.expires_at;
    }

    pub fn isValid(self: *const Witness, now_ms: u64) bool {
        return !self.revoked and !self.isExpired(now_ms);
    }
};

// ============================================================================
// CREDENTIAL — a point on the manifold, validated by witness triangulation
// ============================================================================

/// Minimum distinct witness kinds required to validate a credential.
/// 2 = at least two independent witness types must agree.
pub const MIN_WITNESS_KINDS: u8 = 2;

/// Maximum witnesses per credential
pub const MAX_WITNESSES_PER_CRED: usize = 16;

pub const Credential = struct {
    cred_id: CredId,
    /// What this credential attests (e.g. "music_minor", "cs_capstone", "peer_review")
    label: [64]u8 = [_]u8{0} ** 64,
    label_len: u8 = 0,
    /// Holder identity — SHA3-256 of their public key or email
    holder_hash: CredId,
    /// GF(3) trit of holder's role in generating this credential
    holder_trit: Trit = .zero,
    /// Witnesses that attest this credential
    witness_ids: [MAX_WITNESSES_PER_CRED]CredId = undefined,
    witness_kinds: [MAX_WITNESSES_PER_CRED]WitnessKind = undefined,
    witness_count: u8 = 0,
    issued_at: u64,
    /// $REGRET accumulated — how much institutional legibility was lost
    regret_accumulated: u64 = 0,
    /// $GAY color seed — deterministic color of what was learned
    gay_color_seed: u64 = 0,

    pub fn labelSlice(self: *const Credential) []const u8 {
        return self.label[0..self.label_len];
    }

    /// Count distinct witness kinds attesting this credential
    pub fn distinctWitnessKinds(self: *const Credential) u8 {
        var seen = [_]bool{false} ** 4; // 4 WitnessKind values
        for (self.witness_kinds[0..self.witness_count]) |k| {
            seen[@intFromEnum(k)] = true;
        }
        var count: u8 = 0;
        for (seen) |s| {
            if (s) count += 1;
        }
        return count;
    }

    /// A credential is valid on the manifold when enough independent
    /// witness types attest it. This is triangulation, not hierarchy.
    pub fn isTriangulated(self: *const Credential) bool {
        return self.distinctWitnessKinds() >= MIN_WITNESS_KINDS;
    }

    /// GF(3) balance of all witness trits
    pub fn witnessBalance(self: *const Credential) Trit {
        var acc: Trit = .zero;
        for (self.witness_kinds[0..self.witness_count]) |k| {
            acc = Trit.add(acc, k.trit());
        }
        return acc;
    }
};

// ============================================================================
// MANIFOLD STORE
// ============================================================================

pub const MAX_WITNESSES: usize = 512;
pub const MAX_CREDENTIALS: usize = 256;

pub const ManifoldStore = struct {
    witnesses: [MAX_WITNESSES]Witness = undefined,
    witness_count: usize = 0,
    credentials: [MAX_CREDENTIALS]Credential = undefined,
    cred_count: usize = 0,
    revoked_ids: [MAX_WITNESSES]CredId = undefined,
    revoked_count: usize = 0,

    // -- Witness operations --

    pub fn addWitness(
        self: *ManifoldStore,
        kind: WitnessKind,
        institution: Institution,
        scope: []const u8,
        witness_key_hash: *const CredId,
        evidence_hash: *const CredId,
        now_ms: u64,
        expires_at: u64,
    ) ?*const Witness {
        if (self.witness_count >= MAX_WITNESSES) return null;

        var w = Witness{
            .witness_id = undefined,
            .kind = kind,
            .institution = institution,
            .issued_at = now_ms,
            .expires_at = expires_at,
        };

        const len = @min(scope.len, 64);
        @memcpy(w.scope[0..len], scope[0..len]);
        w.scope_len = @intCast(len);
        w.witness_key_hash = witness_key_hash.*;
        w.evidence_hash = evidence_hash.*;
        w.witness_id = computeWitnessId(&w);

        self.witnesses[self.witness_count] = w;
        self.witness_count += 1;
        return &self.witnesses[self.witness_count - 1];
    }

    // -- Credential operations --

    pub fn createCredential(
        self: *ManifoldStore,
        label: []const u8,
        holder_hash: *const CredId,
        holder_trit: Trit,
        now_ms: u64,
        gay_color_seed: u64,
    ) ?*Credential {
        if (self.cred_count >= MAX_CREDENTIALS) return null;

        var cred = Credential{
            .cred_id = undefined,
            .holder_hash = holder_hash.*,
            .holder_trit = holder_trit,
            .issued_at = now_ms,
            .gay_color_seed = gay_color_seed,
        };

        const len = @min(label.len, 64);
        @memcpy(cred.label[0..len], label[0..len]);
        cred.label_len = @intCast(len);
        cred.cred_id = computeCredId(&cred);

        self.credentials[self.cred_count] = cred;
        self.cred_count += 1;
        return &self.credentials[self.cred_count - 1];
    }

    /// Attach a witness to a credential. The witness must exist and be valid.
    pub fn attachWitness(
        self: *ManifoldStore,
        cred: *Credential,
        witness_id: *const CredId,
        now_ms: u64,
    ) bool {
        if (cred.witness_count >= MAX_WITNESSES_PER_CRED) return false;

        const w = self.lookupWitness(witness_id) orelse return false;
        if (!w.isValid(now_ms)) return false;
        if (self.isRevoked(witness_id)) return false;

        cred.witness_ids[cred.witness_count] = witness_id.*;
        cred.witness_kinds[cred.witness_count] = w.kind;
        cred.witness_count += 1;
        return true;
    }

    /// Verify a credential: check triangulation and all witness validity
    pub fn verifyCredential(
        self: *const ManifoldStore,
        cred_id: *const CredId,
        now_ms: u64,
    ) ManifoldVerifyResult {
        const cred = self.lookupCredential(cred_id) orelse return .not_found;

        if (cred.witness_count == 0) return .no_witnesses;

        // Check each witness is still valid
        var valid_kinds = [_]bool{false} ** 4;
        for (0..cred.witness_count) |i| {
            const w = self.lookupWitness(&cred.witness_ids[i]) orelse continue;
            if (self.isRevoked(&w.witness_id)) return .witness_revoked;
            if (!w.isValid(now_ms)) continue;
            valid_kinds[@intFromEnum(w.kind)] = true;
        }

        var distinct: u8 = 0;
        for (valid_kinds) |v| {
            if (v) distinct += 1;
        }

        if (distinct < MIN_WITNESS_KINDS) return .insufficient_triangulation;
        return .valid;
    }

    // -- Revocation --

    pub fn revoke(self: *ManifoldStore, id: *const CredId) bool {
        if (self.revoked_count >= MAX_WITNESSES) return false;
        self.revoked_ids[self.revoked_count] = id.*;
        self.revoked_count += 1;

        for (self.witnesses[0..self.witness_count]) |*w| {
            if (std.mem.eql(u8, &w.witness_id, id)) w.revoked = true;
        }
        return true;
    }

    pub fn isRevoked(self: *const ManifoldStore, id: *const CredId) bool {
        for (self.revoked_ids[0..self.revoked_count]) |*rid| {
            if (std.mem.eql(u8, rid, id)) return true;
        }
        return false;
    }

    // -- Lookup --

    pub fn lookupWitness(self: *const ManifoldStore, id: *const CredId) ?*const Witness {
        for (self.witnesses[0..self.witness_count]) |*w| {
            if (std.mem.eql(u8, &w.witness_id, id)) return w;
        }
        return null;
    }

    pub fn lookupCredential(self: *const ManifoldStore, id: *const CredId) ?*const Credential {
        for (self.credentials[0..self.cred_count]) |*c| {
            if (std.mem.eql(u8, &c.cred_id, id)) return c;
        }
        return null;
    }

    pub fn lookupCredentialMut(self: *ManifoldStore, id: *const CredId) ?*Credential {
        for (self.credentials[0..self.cred_count]) |*c| {
            if (std.mem.eql(u8, &c.cred_id, id)) return c;
        }
        return null;
    }

    // -- $REGRET accounting --

    /// Accumulate regret on a credential. Called when institutional
    /// legibility fails to capture what was learned.
    pub fn accumulateRegret(self: *ManifoldStore, cred_id: *const CredId, amount: u64) bool {
        const cred = self.lookupCredentialMut(cred_id) orelse return false;
        cred.regret_accumulated += amount;
        return true;
    }
};

pub const ManifoldVerifyResult = enum(u8) {
    valid = 0,
    not_found = 1,
    no_witnesses = 2,
    witness_revoked = 3,
    insufficient_triangulation = 4,

    pub fn isOk(self: ManifoldVerifyResult) bool {
        return self == .valid;
    }

    pub fn name(self: ManifoldVerifyResult) []const u8 {
        return switch (self) {
            .valid => "valid",
            .not_found => "not_found",
            .no_witnesses => "no_witnesses",
            .witness_revoked => "witness_revoked",
            .insufficient_triangulation => "insufficient_triangulation",
        };
    }
};

// ============================================================================
// EMAIL DOMAIN VERIFICATION (institution witness factory)
// ============================================================================

pub const EmailChallenge = struct {
    institution: Institution,
    nonce: [16]u8,
    email_hash: [32]u8,
    issued_at: u64,
    expires_at: u64,

    pub fn create(institution: Institution, email: []const u8, now_ms: u64) EmailChallenge {
        var nonce: [16]u8 = undefined;
        var full_hash: [32]u8 = undefined;
        var h = Sha3_256.init(.{});
        h.update(email);
        h.update(std.mem.asBytes(&now_ms));
        h.update(&[_]u8{SIGIL_EMAIL});
        h.final(&full_hash);
        @memcpy(&nonce, full_hash[0..16]);

        var email_hash: [32]u8 = undefined;
        Sha3_256.hash(email, &email_hash, .{});

        return .{
            .institution = institution,
            .nonce = nonce,
            .email_hash = email_hash,
            .issued_at = now_ms,
            .expires_at = now_ms + 600_000,
        };
    }

    pub fn verify(self: *const EmailChallenge, response_nonce: *const [16]u8, now_ms: u64) bool {
        if (now_ms > self.expires_at) return false;
        return std.mem.eql(u8, &self.nonce, response_nonce);
    }
};

// ============================================================================
// SYRUP SERIALIZATION
// ============================================================================

pub fn serializeWitness(w: *const Witness, buf: []u8) usize {
    var pos: usize = 0;
    const tag = "openclaw-witness";
    buf[pos] = @intCast(tag.len);
    pos += 1;
    @memcpy(buf[pos..][0..tag.len], tag);
    pos += tag.len;

    @memcpy(buf[pos..][0..32], &w.witness_id);
    pos += 32;
    buf[pos] = @intFromEnum(w.kind);
    pos += 1;
    buf[pos] = @intFromEnum(w.institution);
    pos += 1;
    buf[pos] = w.scope_len;
    pos += 1;
    @memcpy(buf[pos..][0..w.scope_len], w.scope[0..w.scope_len]);
    pos += w.scope_len;
    @memcpy(buf[pos..][0..32], &w.witness_key_hash);
    pos += 32;
    @memcpy(buf[pos..][0..32], &w.evidence_hash);
    pos += 32;
    @memcpy(buf[pos..][0..8], std.mem.asBytes(&w.issued_at));
    pos += 8;
    @memcpy(buf[pos..][0..8], std.mem.asBytes(&w.expires_at));
    pos += 8;
    return pos;
}

pub fn serializeCredential(c: *const Credential, buf: []u8) usize {
    var pos: usize = 0;
    const tag = "openclaw-cred";
    buf[pos] = @intCast(tag.len);
    pos += 1;
    @memcpy(buf[pos..][0..tag.len], tag);
    pos += tag.len;

    @memcpy(buf[pos..][0..32], &c.cred_id);
    pos += 32;
    buf[pos] = c.label_len;
    pos += 1;
    @memcpy(buf[pos..][0..c.label_len], c.label[0..c.label_len]);
    pos += c.label_len;
    @memcpy(buf[pos..][0..32], &c.holder_hash);
    pos += 32;
    buf[pos] = @bitCast(@intFromEnum(c.holder_trit));
    pos += 1;
    buf[pos] = c.witness_count;
    pos += 1;
    for (0..c.witness_count) |i| {
        @memcpy(buf[pos..][0..32], &c.witness_ids[i]);
        pos += 32;
        buf[pos] = @intFromEnum(c.witness_kinds[i]);
        pos += 1;
    }
    @memcpy(buf[pos..][0..8], std.mem.asBytes(&c.issued_at));
    pos += 8;
    @memcpy(buf[pos..][0..8], std.mem.asBytes(&c.regret_accumulated));
    pos += 8;
    @memcpy(buf[pos..][0..8], std.mem.asBytes(&c.gay_color_seed));
    pos += 8;
    return pos;
}

// ============================================================================
// OPENPRIORS INTEGRATION (extitutional query)
// ============================================================================

pub const PriorQuery = struct {
    cred_id: CredId,
    topic: [128]u8 = [_]u8{0} ** 128,
    topic_len: u8 = 0,
    limit: u16 = 10,

    pub fn topicSlice(self: *const PriorQuery) []const u8 {
        return self.topic[0..self.topic_len];
    }
};

pub const PriorResult = struct {
    status: ManifoldVerifyResult,
    triangulation_depth: u8 = 0,
    topic: [128]u8 = [_]u8{0} ** 128,
    topic_len: u8 = 0,
    count: u16 = 0,
    regret_cost: u64 = 0,

    pub fn topicSlice(self: *const PriorResult) []const u8 {
        return self.topic[0..self.topic_len];
    }
};

/// Query priors gated by extitutional credential manifold.
/// Access requires a triangulated credential, not just a .edu email.
pub fn queryPriors(
    store: *const ManifoldStore,
    query: *const PriorQuery,
    now_ms: u64,
) PriorResult {
    var result = PriorResult{ .status = .not_found };

    const cred = store.lookupCredential(&query.cred_id) orelse {
        result.status = .not_found;
        return result;
    };

    result.status = store.verifyCredential(&query.cred_id, now_ms);
    result.triangulation_depth = cred.distinctWitnessKinds();

    if (result.status.isOk()) {
        const tlen = @min(query.topic_len, 128);
        @memcpy(result.topic[0..tlen], query.topic[0..tlen]);
        result.topic_len = @intCast(tlen);
        result.count = query.limit;
        result.regret_cost = cred.regret_accumulated;
    }

    return result;
}

// ============================================================================
// C ABI EXPORTS
// ============================================================================

export fn openclaw_add_witness(
    kind: u8,
    institution: u8,
    scope_ptr: [*]const u8,
    scope_len: usize,
    witness_key_hash: *const [32]u8,
    evidence_hash: *const [32]u8,
    now_ms: u64,
    expires_at: u64,
    out_witness_id: *[32]u8,
) bool {
    var store = getGlobalStore();
    const w = store.addWitness(
        @enumFromInt(kind),
        @enumFromInt(institution),
        scope_ptr[0..scope_len],
        witness_key_hash,
        evidence_hash,
        now_ms,
        expires_at,
    ) orelse return false;
    out_witness_id.* = w.witness_id;
    return true;
}

export fn openclaw_create_credential(
    label_ptr: [*]const u8,
    label_len: usize,
    holder_hash: *const [32]u8,
    holder_trit: i8,
    now_ms: u64,
    gay_color_seed: u64,
    out_cred_id: *[32]u8,
) bool {
    var store = getGlobalStore();
    const c = store.createCredential(
        label_ptr[0..label_len],
        holder_hash,
        @enumFromInt(holder_trit),
        now_ms,
        gay_color_seed,
    ) orelse return false;
    out_cred_id.* = c.cred_id;
    return true;
}

export fn openclaw_attach_witness(
    cred_id: *const [32]u8,
    witness_id: *const [32]u8,
    now_ms: u64,
) bool {
    var store = getGlobalStore();
    const cred = store.lookupCredentialMut(cred_id) orelse return false;
    return store.attachWitness(cred, witness_id, now_ms);
}

export fn openclaw_verify(
    cred_id: *const [32]u8,
    now_ms: u64,
) u8 {
    const store = getGlobalStore();
    return @intFromEnum(store.verifyCredential(cred_id, now_ms));
}

export fn openclaw_revoke(id: *const [32]u8) bool {
    var store = getGlobalStore();
    return store.revoke(id);
}

export fn openclaw_accumulate_regret(
    cred_id: *const [32]u8,
    amount: u64,
) bool {
    var store = getGlobalStore();
    return store.accumulateRegret(cred_id, amount);
}

// ============================================================================
// GLOBAL STATE
// ============================================================================

var global_store: ManifoldStore = .{};

fn getGlobalStore() *ManifoldStore {
    return &global_store;
}

pub fn resetGlobalStore() void {
    global_store = .{};
}

// ============================================================================
// SHA3-256 HELPERS (Keccak — matches Move/Aptos hash::sha3_256)
// ============================================================================

// Sigil bytes — domain separators matching Aptos object address derivation:
//   0xFE = named object (source | seed | 0xFE)
//   0xFD = unnamed object (guid | 0xFD)
//   0xFC = derived object (source | child | 0xFC)
//   0xFB = unique/auid object (tx | counter | 0xFB)
//
// OpenClaw sigil extension:
//   0xFA = witness attestation
//   0xF9 = credential on manifold
//   0xF8 = email challenge nonce
const SIGIL_WITNESS: u8 = 0xFA;
const SIGIL_CREDENTIAL: u8 = 0xF9;
const SIGIL_EMAIL: u8 = 0xF8;

fn computeWitnessId(w: *const Witness) CredId {
    var hasher = Sha3_256.init(.{});
    hasher.update(std.mem.asBytes(&@intFromEnum(w.kind)));
    hasher.update(std.mem.asBytes(&@intFromEnum(w.institution)));
    hasher.update(w.scope[0..w.scope_len]);
    hasher.update(&w.witness_key_hash);
    hasher.update(&w.evidence_hash);
    hasher.update(std.mem.asBytes(&w.issued_at));
    hasher.update(std.mem.asBytes(&w.expires_at));
    hasher.update(&[_]u8{SIGIL_WITNESS});
    return hasher.finalResult();
}

fn computeCredId(c: *const Credential) CredId {
    var hasher = Sha3_256.init(.{});
    hasher.update(c.label[0..c.label_len]);
    hasher.update(&c.holder_hash);
    hasher.update(std.mem.asBytes(&@intFromEnum(c.holder_trit)));
    hasher.update(std.mem.asBytes(&c.issued_at));
    hasher.update(std.mem.asBytes(&c.gay_color_seed));
    hasher.update(&[_]u8{SIGIL_CREDENTIAL});
    return hasher.finalResult();
}

fn endsWith(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return std.mem.eql(u8, haystack[haystack.len - needle.len ..], needle);
}

fn startsWith(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return std.mem.eql(u8, haystack[0..needle.len], needle);
}

// ============================================================================
// MCP TOOL SCHEMA (Palantir Ontology MCP pattern: search / action / query)
// ============================================================================
//
// Exposes openclaw credential operations as MCP tools.
// Tool names follow Palantir convention: {domain}_{verb}_{object}
//
// Search tools (read-only):
//   openclaw_search_credentials  — find credentials by holder/scope/institution
//   openclaw_search_witnesses    — find witnesses by kind/scope
//   openclaw_lookup_credential   — get credential by ID with verification status
//
// Action tools (mutating):
//   openclaw_create_credential   — mint new credential on manifold
//   openclaw_add_witness         — add witness attestation
//   openclaw_attach_witness      — attach witness to credential
//   openclaw_revoke              — revoke witness or credential
//   openclaw_accumulate_regret   — record institutional legibility loss
//
// Query tools (computed):
//   openclaw_verify              — check triangulation status
//   openclaw_witness_balance     — GF(3) trit balance of witnesses
//   openclaw_query_priors        — gated OpenPriors query
//
// Scopes (domain taxonomy — what credentials can attest):
//   music/*           — Stanford music minor/major
//   cs/*              — computer science
//   energy/*          — PNNL VOLTTRON/HELICS, Plurigrid, grid interop
//   geometry/*        — UCSB Geomstats, Riemannian statistics
//   topology/*        — topological deep learning (TopoX, HOPSE)
//   interspecies/*    — Project CETI, whale communication
//   cognitive_economy — OpenPriors, cognitive infrastructure

pub const MCP_TOOL_COUNT: usize = 10;

pub const McpToolKind = enum(u8) {
    search = 0,
    action = 1,
    query = 2,
};

pub const McpTool = struct {
    name: []const u8,
    kind: McpToolKind,
    description: []const u8,
};

pub const mcp_tools = [MCP_TOOL_COUNT]McpTool{
    .{ .name = "openclaw_search_credentials", .kind = .search, .description = "Find credentials by holder, scope, or institution" },
    .{ .name = "openclaw_search_witnesses", .kind = .search, .description = "Find witnesses by kind or scope" },
    .{ .name = "openclaw_lookup_credential", .kind = .search, .description = "Get credential by ID with verification status" },
    .{ .name = "openclaw_create_credential", .kind = .action, .description = "Mint new credential on the extitutional manifold" },
    .{ .name = "openclaw_add_witness", .kind = .action, .description = "Add witness attestation (institution/peer/work/AI)" },
    .{ .name = "openclaw_attach_witness", .kind = .action, .description = "Attach existing witness to a credential" },
    .{ .name = "openclaw_revoke", .kind = .action, .description = "Revoke a witness or credential" },
    .{ .name = "openclaw_accumulate_regret", .kind = .action, .description = "Record institutional legibility loss ($REGRET)" },
    .{ .name = "openclaw_verify", .kind = .query, .description = "Check triangulation status of a credential" },
    .{ .name = "openclaw_query_priors", .kind = .query, .description = "Query OpenPriors gated by triangulated credential" },
};

// ============================================================================
// TESTS
// ============================================================================

test "credential requires triangulation from 2+ witness kinds" {
    resetGlobalStore();
    var store = getGlobalStore();
    const now: u64 = 1_700_000_000_000;

    const holder_hash = [_]u8{0xAA} ** 32;
    const key_hash = [_]u8{0xBB} ** 32;
    const evidence1 = [_]u8{0xCC} ** 32;
    const evidence2 = [_]u8{0xDD} ** 32;

    // Create credential for a music minor
    const cred = store.createCredential("music_minor", &holder_hash, .zero, now, 1069) orelse
        return error.CreateFailed;

    // With zero witnesses: not valid
    try std.testing.expectEqual(ManifoldVerifyResult.no_witnesses, store.verifyCredential(&cred.cred_id, now));

    // Add institution witness (stanford .edu email)
    const w1 = store.addWitness(.institution, .stanford, "music", &key_hash, &evidence1, now, 0) orelse
        return error.WitnessFailed;

    var cred_mut = store.lookupCredentialMut(&cred.cred_id) orelse return error.LookupFailed;
    try std.testing.expect(store.attachWitness(cred_mut, &w1.witness_id, now));

    // With 1 witness kind: insufficient
    try std.testing.expectEqual(ManifoldVerifyResult.insufficient_triangulation, store.verifyCredential(&cred.cred_id, now));

    // Add peer witness (Minecraft scrutiny attestation)
    const w2 = store.addWitness(.peer, .extitute, "music/ear_training", &key_hash, &evidence2, now, 0) orelse
        return error.WitnessFailed;

    cred_mut = store.lookupCredentialMut(&cred.cred_id) orelse return error.LookupFailed;
    try std.testing.expect(store.attachWitness(cred_mut, &w2.witness_id, now));

    // With 2 distinct witness kinds: VALID (triangulated)
    try std.testing.expectEqual(ManifoldVerifyResult.valid, store.verifyCredential(&cred.cred_id, now));
}

test "institution witness alone is insufficient" {
    resetGlobalStore();
    var store = getGlobalStore();
    const now: u64 = 1_700_000_000_000;

    const holder_hash = [_]u8{0xAA} ** 32;
    const key_hash = [_]u8{0xBB} ** 32;
    const ev1 = [_]u8{0x01} ** 32;
    const ev2 = [_]u8{0x02} ** 32;

    const cred = store.createCredential("cs_capstone", &holder_hash, .plus, now, 42) orelse
        return error.CreateFailed;

    // Two institution witnesses from different schools — still only 1 kind
    const w1 = store.addWitness(.institution, .stanford, "cs", &key_hash, &ev1, now, 0) orelse
        return error.WitnessFailed;
    const w2 = store.addWitness(.institution, .harvard, "cs", &key_hash, &ev2, now, 0) orelse
        return error.WitnessFailed;

    var cred_mut = store.lookupCredentialMut(&cred.cred_id) orelse return error.LookupFailed;
    try std.testing.expect(store.attachWitness(cred_mut, &w1.witness_id, now));
    cred_mut = store.lookupCredentialMut(&cred.cred_id) orelse return error.LookupFailed;
    try std.testing.expect(store.attachWitness(cred_mut, &w2.witness_id, now));

    // Still insufficient — two institutions is still only 1 witness KIND
    try std.testing.expectEqual(ManifoldVerifyResult.insufficient_triangulation, store.verifyCredential(&cred.cred_id, now));
}

test "revoke witness invalidates credential" {
    resetGlobalStore();
    var store = getGlobalStore();
    const now: u64 = 1_700_000_000_000;

    const holder = [_]u8{0xAA} ** 32;
    const key = [_]u8{0xBB} ** 32;
    const ev1 = [_]u8{0x01} ** 32;
    const ev2 = [_]u8{0x02} ** 32;

    const cred = store.createCredential("self_designed_music", &holder, .zero, now, 1069) orelse
        return error.CreateFailed;

    const w1 = store.addWitness(.institution, .stanford, "music", &key, &ev1, now, 0) orelse return error.Fail;
    const w2 = store.addWitness(.work, .extitute, "music/capstone", &key, &ev2, now, 0) orelse return error.Fail;

    var cm = store.lookupCredentialMut(&cred.cred_id) orelse return error.Fail;
    try std.testing.expect(store.attachWitness(cm, &w1.witness_id, now));
    cm = store.lookupCredentialMut(&cred.cred_id) orelse return error.Fail;
    try std.testing.expect(store.attachWitness(cm, &w2.witness_id, now));

    try std.testing.expectEqual(ManifoldVerifyResult.valid, store.verifyCredential(&cred.cred_id, now));

    // Revoke the work witness
    _ = store.revoke(&w2.witness_id);

    try std.testing.expectEqual(ManifoldVerifyResult.witness_revoked, store.verifyCredential(&cred.cred_id, now));
}

test "regret accumulation" {
    resetGlobalStore();
    var store = getGlobalStore();
    const now: u64 = 1_700_000_000_000;

    const holder = [_]u8{0xAA} ** 32;
    const cred = store.createCredential("narya_bridge", &holder, .minus, now, 7) orelse
        return error.CreateFailed;

    try std.testing.expect(store.accumulateRegret(&cred.cred_id, 551));
    try std.testing.expect(store.accumulateRegret(&cred.cred_id, 100));

    const c = store.lookupCredential(&cred.cred_id) orelse return error.Fail;
    try std.testing.expectEqual(@as(u64, 651), c.regret_accumulated);
}

test "GF(3) witness balance" {
    resetGlobalStore();
    var store = getGlobalStore();
    const now: u64 = 1_700_000_000_000;

    const holder = [_]u8{0xAA} ** 32;
    const key = [_]u8{0xBB} ** 32;
    const ev1 = [_]u8{0x01} ** 32;
    const ev2 = [_]u8{0x02} ** 32;
    const ev3 = [_]u8{0x03} ** 32;

    const cred = store.createCredential("balanced_credential", &holder, .zero, now, 69) orelse
        return error.CreateFailed;

    // institution: trit=-1, peer: trit=+1, work: trit=0
    const w1 = store.addWitness(.institution, .stanford, "", &key, &ev1, now, 0) orelse return error.Fail;
    const w2 = store.addWitness(.peer, .extitute, "", &key, &ev2, now, 0) orelse return error.Fail;
    const w3 = store.addWitness(.work, .extitute, "", &key, &ev3, now, 0) orelse return error.Fail;

    var cm = store.lookupCredentialMut(&cred.cred_id) orelse return error.Fail;
    try std.testing.expect(store.attachWitness(cm, &w1.witness_id, now));
    cm = store.lookupCredentialMut(&cred.cred_id) orelse return error.Fail;
    try std.testing.expect(store.attachWitness(cm, &w2.witness_id, now));
    cm = store.lookupCredentialMut(&cred.cred_id) orelse return error.Fail;
    try std.testing.expect(store.attachWitness(cm, &w3.witness_id, now));

    const c = store.lookupCredential(&cred.cred_id) orelse return error.Fail;
    // -1 + 1 + 0 = 0 (balanced)
    try std.testing.expectEqual(Trit.zero, c.witnessBalance());
    try std.testing.expectEqual(@as(u8, 3), c.distinctWitnessKinds());
}

test "email domain verification" {
    const inst = Institution.fromDomain("student@stanford.edu");
    try std.testing.expectEqual(Institution.stanford, inst.?);

    const none = Institution.fromDomain("student@mit.edu");
    try std.testing.expectEqual(@as(?Institution, null), none);

    // Energy / research institutions
    const pnnl = Institution.fromDomain("researcher@pnnl.gov");
    try std.testing.expectEqual(Institution.pnnl, pnnl.?);

    const ucsb = Institution.fromDomain("miolane@ucsb.edu");
    try std.testing.expectEqual(Institution.ucsb, ucsb.?);

    const pluri = Institution.fromDomain("node@plurigrid.xyz");
    try std.testing.expectEqual(Institution.plurigrid, pluri.?);
}

test "MCP tools registry" {
    // Verify tool count and kinds
    try std.testing.expectEqual(@as(usize, 10), mcp_tools.len);

    var search_count: usize = 0;
    var action_count: usize = 0;
    var query_count: usize = 0;
    for (mcp_tools) |tool| {
        switch (tool.kind) {
            .search => search_count += 1,
            .action => action_count += 1,
            .query => query_count += 1,
        }
    }
    try std.testing.expectEqual(@as(usize, 3), search_count);
    try std.testing.expectEqual(@as(usize, 5), action_count);
    try std.testing.expectEqual(@as(usize, 2), query_count);
}

test "cross-institutional credential (energy + geometry)" {
    resetGlobalStore();
    var store = getGlobalStore();
    const now: u64 = 1_700_000_000_000;

    const holder = [_]u8{0xAA} ** 32;
    const key = [_]u8{0xBB} ** 32;
    const ev1 = [_]u8{0x01} ** 32;
    const ev2 = [_]u8{0x02} ** 32;
    const ev3 = [_]u8{0x03} ** 32;

    // Credential: "grid geometry" — spans PNNL energy + UCSB geometric ML
    const cred = store.createCredential("grid_geometry", &holder, .zero, now, 420) orelse
        return error.CreateFailed;

    // PNNL institution witness (VOLTTRON/HELICS contributor)
    const w1 = store.addWitness(.institution, .pnnl, "energy/grid_interop", &key, &ev1, now, 0) orelse return error.Fail;
    // UCSB peer witness (Geomstats contributor)
    const w2 = store.addWitness(.peer, .ucsb, "geometry/riemannian", &key, &ev2, now, 0) orelse return error.Fail;
    // Plurigrid work artifact (CoFi protocol implementation)
    const w3 = store.addWitness(.work, .plurigrid, "energy/cofi", &key, &ev3, now, 0) orelse return error.Fail;

    var cm = store.lookupCredentialMut(&cred.cred_id) orelse return error.Fail;
    try std.testing.expect(store.attachWitness(cm, &w1.witness_id, now));
    cm = store.lookupCredentialMut(&cred.cred_id) orelse return error.Fail;
    try std.testing.expect(store.attachWitness(cm, &w2.witness_id, now));
    cm = store.lookupCredentialMut(&cred.cred_id) orelse return error.Fail;
    try std.testing.expect(store.attachWitness(cm, &w3.witness_id, now));

    // 3 distinct witness kinds (institution, peer, work) = strongly triangulated
    const c = store.lookupCredential(&cred.cred_id) orelse return error.Fail;
    try std.testing.expectEqual(@as(u8, 3), c.distinctWitnessKinds());
    try std.testing.expect(c.isTriangulated());
    try std.testing.expectEqual(ManifoldVerifyResult.valid, store.verifyCredential(&cred.cred_id, now));
}

test "openpriors query requires triangulated credential" {
    resetGlobalStore();
    var store = getGlobalStore();
    const now: u64 = 1_700_000_000_000;

    const holder = [_]u8{0xAA} ** 32;
    const key = [_]u8{0xBB} ** 32;
    const ev1 = [_]u8{0x01} ** 32;
    const ev2 = [_]u8{0x02} ** 32;

    const cred = store.createCredential("cognitive_economy", &holder, .plus, now, 1069) orelse
        return error.CreateFailed;

    // Not triangulated yet — query should fail
    var query = PriorQuery{ .cred_id = cred.cred_id, .limit = 5 };
    const topic = "openpriors";
    @memcpy(query.topic[0..topic.len], topic);
    query.topic_len = @intCast(topic.len);

    var result = queryPriors(store, &query, now);
    try std.testing.expect(!result.status.isOk());

    // Add two witness kinds
    const w1 = store.addWitness(.ai, .extitute, "synthesis", &key, &ev1, now, 0) orelse return error.Fail;
    const w2 = store.addWitness(.work, .extitute, "artifact", &key, &ev2, now, 0) orelse return error.Fail;

    var cm = store.lookupCredentialMut(&cred.cred_id) orelse return error.Fail;
    try std.testing.expect(store.attachWitness(cm, &w1.witness_id, now));
    cm = store.lookupCredentialMut(&cred.cred_id) orelse return error.Fail;
    try std.testing.expect(store.attachWitness(cm, &w2.witness_id, now));

    // Now triangulated — query succeeds
    result = queryPriors(store, &query, now);
    try std.testing.expectEqual(ManifoldVerifyResult.valid, result.status);
    try std.testing.expectEqual(@as(u8, 2), result.triangulation_depth);
    try std.testing.expectEqual(@as(u16, 5), result.count);
}
