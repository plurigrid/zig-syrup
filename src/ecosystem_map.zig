//! Ecosystem → Virion Domain Mapping
//!
//! Maps 6 autonomous agent ecosystems to virion capability domains and
//! world_enum.zig configurations. Each ecosystem is an instance of:
//!   "autonomous agents discovering capability chains in adversarial state spaces"
//!
//! Deep variables that differ:
//!   State space:     Linux hosts | EVM | K8s | program paths | control trajectories | PDDL states
//!   Capability unit: shell cmd   | tx call | fault injection | harness fn | action | PDDL action
//!   Chain type:      kill chain  | tx seq  | fault cascade   | crash path | trajectory | plan
//!   Guarantees:      none        | invariants | TNR          | completeness | safety | termination

const std = @import("std");

pub const Ecosystem = enum(u4) {
    aixcc_crs = 0, // DARPA AIxCC / CRS (Team Atlanta ATLANTIS)
    smart_contract = 1, // Anthropic SCONE-bench, smart contract exploits
    chaos_engineering = 2, // ChaosEater, IBM STRATUS
    fuzz_harness = 3, // HarnessAgent, OSS-Fuzz
    adversarial_rl = 4, // Phantom Menace VLA attacks, Robust-Gymnasium
    attack_graph = 5, // ChainReactor PDDL-based privilege escalation
};

pub const CapDomain = enum(u5) {
    serialize = 0,
    transport = 1,
    color = 2,
    propagate = 3,
    identity = 4,
    bci = 5,
    topology = 6,
    terminal = 7,
    world = 8,
    agent = 9,
    verify = 10,
    generate = 11,
    coordinate = 12,
    measure = 13,
    transform = 14,
    bridge = 15,
};

pub const EcosystemMapping = struct {
    ecosystem: Ecosystem,
    name: []const u8,
    primary_domains: []const CapDomain,
    state_space: []const u8,
    capability_unit: []const u8,
    chain_type: []const u8,
    formal_guarantee: []const u8,
    repos: []const []const u8,
    czernowitz_landing: []const u8, // Which czernowitz speculator(s) this maps to
};

pub const mappings = [_]EcosystemMapping{
    .{
        .ecosystem = .aixcc_crs,
        .name = "AIxCC CRS (Vulnerability Discovery + Patching)",
        .primary_domains = &.{ .verify, .generate, .bridge },
        .state_space = "Linux host + binary + source",
        .capability_unit = "shell command / patch",
        .chain_type = "kill chain → patch chain",
        .formal_guarantee = "CWE coverage, patch correctness",
        .repos = &.{
            "team-atlanta/atlantis",
            "bmorphism/syrup-verify",
            "bmorphism/duck-rs",
        },
        .czernowitz_landing = "Quality Inspector (syrup-verify) + Reseller (duck-rs)",
    },
    .{
        .ecosystem = .smart_contract,
        .name = "Smart Contract Exploits (SCONE-bench, DeFi)",
        .primary_domains = &.{ .verify, .serialize, .agent },
        .state_space = "EVM / Solana / Move state",
        .capability_unit = "transaction call",
        .chain_type = "exploit tx sequence",
        .formal_guarantee = "invariant violation proof",
        .repos = &.{
            "anthropics/scone-bench",
            "bmorphism/manifold-mcp-server",
        },
        .czernowitz_landing = "Trend Scout (manifold-mcp-server)",
    },
    .{
        .ecosystem = .chaos_engineering,
        .name = "Chaos Engineering / SRE (ChaosEater, STRATUS)",
        .primary_domains = &.{ .propagate, .measure, .coordinate },
        .state_space = "Kubernetes cluster / service mesh",
        .capability_unit = "fault injection",
        .chain_type = "fault cascade",
        .formal_guarantee = "TNR (Time, Number, Range) safety",
        .repos = &.{
            "daisuke-kikuta/ChaosEater",
            "bmorphism/babashka-mcp-server",
            "bmorphism/nats-mcp-server",
        },
        .czernowitz_landing = "Stall Holder (babashka) + Porter (nats)",
    },
    .{
        .ecosystem = .fuzz_harness,
        .name = "Fuzzing Harness Synthesis (HarnessAgent, OSS-Fuzz)",
        .primary_domains = &.{ .generate, .transform, .verify },
        .state_space = "program input space / CFG paths",
        .capability_unit = "harness function / fuzz input",
        .chain_type = "crash path / coverage path",
        .formal_guarantee = "coverage completeness",
        .repos = &.{
            "HarnessAgent",
            "bmorphism/anti-bullshit-mcp-server",
            "bmorphism/say-mcp-server",
        },
        .czernowitz_landing = "Customs Broker (anti-bullshit) + Wholesale Buyer (say)",
    },
    .{
        .ecosystem = .adversarial_rl,
        .name = "Adversarial Robot Policies (Phantom Menace, Robust-Gymnasium)",
        .primary_domains = &.{ .agent, .topology, .measure },
        .state_space = "control trajectory / observation space",
        .capability_unit = "adversarial perturbation",
        .chain_type = "attack trajectory",
        .formal_guarantee = "safety envelope, Lipschitz bound",
        .repos = &.{
            "phantom-menace/vla-attacks",
            "bmorphism/multiverse-color-game",
            "bmorphism/trittty",
        },
        .czernowitz_landing = "Container Speculator (multiverse) + Display Board (trittty)",
    },
    .{
        .ecosystem = .attack_graph,
        .name = "Attack Graph / AI Planning (ChainReactor PDDL)",
        .primary_domains = &.{ .propagate, .identity, .bridge },
        .state_space = "PDDL state / privilege graph",
        .capability_unit = "PDDL action / privilege escalation step",
        .chain_type = "privilege escalation plan",
        .formal_guarantee = "plan termination, goal reachability",
        .repos = &.{
            "chainreactor/pddl-exploit",
            "bmorphism/penrose-mcp",
            "bmorphism/ocaml-mcp-sdk",
        },
        .czernowitz_landing = "Route Pioneer (penrose) + Shuttle Trader (ocaml-mcp-sdk)",
    },
};

/// Find ecosystems that use a given capability domain
pub fn findByDomain(domain: CapDomain) [6]bool {
    var result: [6]bool = @splat(false);
    for (mappings) |m| {
        for (m.primary_domains) |d| {
            if (d == domain) {
                result[@backingInt(m.ecosystem)] = true;
                break;
            }
        }
    }
    return result;
}

/// Count how many ecosystems share a pair of domains (co-occurrence)
pub fn domainCoOccurrence(a: CapDomain, b: CapDomain) u4 {
    var count: u4 = 0;
    for (mappings) |m| {
        var has_a = false;
        var has_b = false;
        for (m.primary_domains) |d| {
            if (d == a) has_a = true;
            if (d == b) has_b = true;
        }
        if (has_a and has_b) count += 1;
    }
    return count;
}

// ============================================================================
// Tests
// ============================================================================

test "all ecosystems have 3 primary domains" {
    for (mappings) |m| {
        try std.testing.expectEqual(@as(usize, 3), m.primary_domains.len);
    }
}

test "verify domain appears in multiple ecosystems" {
    const hits = findByDomain(.verify);
    var count: u4 = 0;
    for (hits) |h| if (h) {
        count += 1;
    };
    try std.testing.expect(count >= 2);
}

test "generate domain appears in CRS and fuzz" {
    const hits = findByDomain(.generate);
    try std.testing.expect(hits[@backingInt(Ecosystem.aixcc_crs)]);
    try std.testing.expect(hits[@backingInt(Ecosystem.fuzz_harness)]);
}

test "co-occurrence of verify and generate" {
    const co = domainCoOccurrence(.verify, .generate);
    try std.testing.expect(co >= 2); // CRS and fuzz both have both
}

test "all repos non-empty" {
    for (mappings) |m| {
        try std.testing.expect(m.repos.len > 0);
    }
}
