//! yosh_bridge.zig — Bridge between zig-syrup outputs and pizlonator/yosh
//!
//! yosh (pizlonator) is an LLM-enabled bash fork (bash 5.2.32 + readline 8.2.13)
//! compiled with Fil-C memory-safe toolchain. Its `yo` command sends queries to
//! an LLM, and its PTY proxy captures terminal scrollback into an mmap'd buffer.
//!
//! The key insight: yosh's `yo` command can read terminal scrollback for context.
//! If zig-syrup outputs (denom verification, hash analysis, zombie detection)
//! appear in the terminal, yosh's LLM sees them in scrollback and can reason
//! about them when the user types `yo why did that denom fail?`
//!
//! This module formats zig-syrup outputs for yosh consumption:
//!   1. ANSI-stripped text (yosh strips ANSI from scrollback before sending to LLM)
//!   2. Structured markers that yosh's LLM can parse from scrollback
//!   3. JSON-RPC sidecar protocol for direct integration (bypasses PTY)
//!   4. Shell command generation (outputs that yosh can prefill as commands)
//!
//! Integration modes:
//!   A. PTY passthrough: zig-syrup writes to stdout, yosh pump captures in scrollback
//!   B. Named pipe: zig-syrup writes to FIFO, yosh reads via `cat /tmp/zig-syrup.fifo`
//!   C. JSON-RPC sidecar: zig-syrup listens on TCP, yosh `yo` queries via curl
//!   D. Environment injection: zig-syrup sets env vars that yosh's LLM prompt reads
//!
//! GF(3) role: ERGODIC (0) — coordinator between zig-syrup (+1 generator)
//!   and yosh (-1 verifier of shell command safety)

const std = @import("std");
const ibc = @import("ibc_denom_verifier");

// ============================================================================
// YOSH-COMPATIBLE OUTPUT FORMATTERS
// ============================================================================

/// Marker prefix that yosh's LLM can recognize in scrollback.
/// When `yo` sends scrollback to Claude, these markers let the LLM
/// identify zig-syrup verification results without parsing raw output.
const MARKER_PREFIX = "[zig-syrup]";
const MARKER_DENOM = "[zig-syrup:denom]";
const MARKER_ZOMBIE = "[zig-syrup:zombie]";
const MARKER_ATTACK = "[zig-syrup:attack]";
const MARKER_HASH = "[zig-syrup:hash]";

/// Format a denom verification result as yosh-scrollback-friendly text.
/// No ANSI escapes — yosh strips them anyway before sending to LLM.
/// Structured so LLM can parse: marker, key=value pairs, one per line.
pub fn formatVerificationForYosh(
    result: *const ibc.VerificationResult,
    trace_str: []const u8,
    buf: []u8,
) []const u8 {
    var pos: usize = 0;

    // Header marker
    pos += copyTo(buf[pos..], MARKER_DENOM);
    pos += copyTo(buf[pos..], " trace=");
    pos += copyTo(buf[pos..], trace_str);
    pos += copyTo(buf[pos..], "\n");

    // SHA-256 hash
    pos += copyTo(buf[pos..], MARKER_HASH);
    pos += copyTo(buf[pos..], " algo=sha256 hash=");
    var hex256: [64]u8 = undefined;
    ibc.hexEncode(&result.denom_hash.sha256, &hex256);
    pos += copyTo(buf[pos..], &hex256);
    pos += copyTo(buf[pos..], "\n");

    // SHA-3-256 hash (shadow)
    pos += copyTo(buf[pos..], MARKER_HASH);
    pos += copyTo(buf[pos..], " algo=sha3-256 hash=");
    var hex3: [64]u8 = undefined;
    ibc.hexEncode(&result.denom_hash.sha3_256, &hex3);
    pos += copyTo(buf[pos..], &hex3);
    pos += copyTo(buf[pos..], "\n");

    // Hash match status
    const match_status = if (std.mem.eql(u8, &result.denom_hash.sha256, &result.denom_hash.sha3_256))
        "IDENTICAL (base denom, no IBC path)"
    else
        "DIVERGENT (expected for IBC denoms)";
    pos += copyTo(buf[pos..], MARKER_DENOM);
    pos += copyTo(buf[pos..], " dual_hash=");
    pos += copyTo(buf[pos..], match_status);
    pos += copyTo(buf[pos..], "\n");

    // Zombie status
    const zombie_str = switch (result.zombie) {
        .alive => "alive",
        .maintenance_mode => "MAINTENANCE_MODE (Noble post-March 2026)",
        .dead_chain => "DEAD_CHAIN",
        .migrating => "MIGRATING",
        .zombie => "ZOMBIE",
    };
    pos += copyTo(buf[pos..], MARKER_ZOMBIE);
    pos += copyTo(buf[pos..], " status=");
    pos += copyTo(buf[pos..], zombie_str);
    pos += copyTo(buf[pos..], "\n");

    // Hop count
    pos += copyTo(buf[pos..], MARKER_DENOM);
    pos += copyTo(buf[pos..], " hops=");
    pos += writeU8(buf[pos..], result.hop_count);
    pos += copyTo(buf[pos..], "\n");

    // Length extension status
    const ext_str = switch (result.length_ext.status) {
        .valid => "valid",
        .invalid => "INVALID",
        .length_extension_suspected => "LENGTH_EXTENSION_SUSPECTED",
        .algo_confusion => "ALGO_CONFUSION",
    };
    pos += copyTo(buf[pos..], MARKER_ATTACK);
    pos += copyTo(buf[pos..], " length_extension=");
    pos += copyTo(buf[pos..], ext_str);
    pos += copyTo(buf[pos..], "\n");

    return buf[0..pos];
}

/// Format as a shell command that yosh can prefill via rl_yo_accept_line().
/// User types `yo check this denom`, yosh prefills the curl command.
pub fn formatAsYoshCommand(
    trace_str: []const u8,
    verifier_port: u16,
    buf: []u8,
) []const u8 {
    var pos: usize = 0;
    pos += copyTo(buf[pos..], "curl -s localhost:");
    pos += writeU16(buf[pos..], verifier_port);
    pos += copyTo(buf[pos..], "/verify?trace=");
    pos += copyTo(buf[pos..], trace_str);
    return buf[0..pos];
}

/// Format batch verification results as a compact table for scrollback.
pub fn formatBatchForYosh(
    traces: []const []const u8,
    results: []const ibc.VerificationResult,
    buf: []u8,
) []const u8 {
    var pos: usize = 0;

    pos += copyTo(buf[pos..], MARKER_PREFIX);
    pos += copyTo(buf[pos..], " batch_verify count=");
    pos += writeU8(buf[pos..], @intCast(traces.len));
    pos += copyTo(buf[pos..], "\n");

    // Header
    pos += copyTo(buf[pos..], "  TRACE");
    pos += padTo(buf[pos..], 50);
    pos += copyTo(buf[pos..], "HOPS  ZOMBIE          SHA256-PREFIX\n");
    pos += copyTo(buf[pos..], "  ");
    for (0..78) |_| {
        if (pos < buf.len) {
            buf[pos] = '-';
            pos += 1;
        }
    }
    pos += copyTo(buf[pos..], "\n");

    for (traces, 0..) |trace, i| {
        if (i >= results.len) break;
        const r = results[i];

        pos += copyTo(buf[pos..], "  ");
        const max_trace = @min(trace.len, 48);
        pos += copyTo(buf[pos..], trace[0..max_trace]);
        pos += padTo(buf[pos..], 50 - max_trace - 2);

        pos += writeU8(buf[pos..], r.hop_count);
        pos += copyTo(buf[pos..], "     ");

        const zs = switch (r.zombie) {
            .alive => "alive          ",
            .maintenance_mode => "MAINT_MODE     ",
            .dead_chain => "DEAD           ",
            .migrating => "MIGRATING      ",
            .zombie => "ZOMBIE         ",
        };
        pos += copyTo(buf[pos..], zs);

        var hex_short: [64]u8 = undefined;
        ibc.hexEncode(&r.denom_hash.sha256, &hex_short);
        pos += copyTo(buf[pos..], hex_short[0..16]);
        pos += copyTo(buf[pos..], "...\n");
    }

    return buf[0..pos];
}

// ============================================================================
// JSON-RPC SIDECAR PROTOCOL
// ============================================================================

/// JSON-RPC response format for yosh integration.
/// yosh can call `curl localhost:9256/verify?trace=...` and pipe output
/// through `yo` to get LLM analysis of the verification result.
pub fn formatJsonRpc(
    result: *const ibc.VerificationResult,
    trace_str: []const u8,
    buf: []u8,
) []const u8 {
    var pos: usize = 0;

    pos += copyTo(buf[pos..], "{\"jsonrpc\":\"2.0\",\"result\":{");

    // trace
    pos += copyTo(buf[pos..], "\"trace\":\"");
    pos += copyTo(buf[pos..], trace_str);
    pos += copyTo(buf[pos..], "\",");

    // hops
    pos += copyTo(buf[pos..], "\"hops\":");
    pos += writeU8(buf[pos..], result.hop_count);
    pos += copyTo(buf[pos..], ",");

    // zombie
    const zs = switch (result.zombie) {
        .alive => "\"alive\"",
        .maintenance_mode => "\"maintenance_mode\"",
        .dead_chain => "\"dead_chain\"",
        .migrating => "\"migrating\"",
        .zombie => "\"zombie\"",
    };
    pos += copyTo(buf[pos..], "\"zombie\":");
    pos += copyTo(buf[pos..], zs);
    pos += copyTo(buf[pos..], ",");

    // sha256
    pos += copyTo(buf[pos..], "\"sha256\":\"");
    var h256: [64]u8 = undefined;
    ibc.hexEncode(&result.denom_hash.sha256, &h256);
    pos += copyTo(buf[pos..], &h256);
    pos += copyTo(buf[pos..], "\",");

    // sha3_256
    pos += copyTo(buf[pos..], "\"sha3_256\":\"");
    var h3: [64]u8 = undefined;
    ibc.hexEncode(&result.denom_hash.sha3_256, &h3);
    pos += copyTo(buf[pos..], &h3);
    pos += copyTo(buf[pos..], "\",");

    // length_extension
    const le = switch (result.length_ext.status) {
        .valid => "\"valid\"",
        .invalid => "\"invalid\"",
        .length_extension_suspected => "\"suspected\"",
        .algo_confusion => "\"algo_confusion\"",
    };
    pos += copyTo(buf[pos..], "\"length_extension\":");
    pos += copyTo(buf[pos..], le);

    pos += copyTo(buf[pos..], "},\"id\":1}");
    return buf[0..pos];
}

// ============================================================================
// ENVIRONMENT VARIABLE INJECTION
// ============================================================================

/// Format verification result as environment variable assignments.
/// yosh reads env vars; the LLM system prompt can reference them.
/// Usage: `eval $(zig-syrup-verify transfer/channel-750/uusdc)`
pub fn formatAsEnvVars(
    result: *const ibc.VerificationResult,
    buf: []u8,
) []const u8 {
    var pos: usize = 0;

    pos += copyTo(buf[pos..], "export ZIG_DENOM_HOPS=");
    pos += writeU8(buf[pos..], result.hop_count);
    pos += copyTo(buf[pos..], "\n");

    const zs = switch (result.zombie) {
        .alive => "alive",
        .maintenance_mode => "maintenance_mode",
        .dead_chain => "dead_chain",
        .migrating => "migrating",
        .zombie => "zombie",
    };
    pos += copyTo(buf[pos..], "export ZIG_DENOM_ZOMBIE=");
    pos += copyTo(buf[pos..], zs);
    pos += copyTo(buf[pos..], "\n");

    const le = switch (result.length_ext.status) {
        .valid => "valid",
        .invalid => "invalid",
        .length_extension_suspected => "suspected",
        .algo_confusion => "algo_confusion",
    };
    pos += copyTo(buf[pos..], "export ZIG_DENOM_LENGTH_EXT=");
    pos += copyTo(buf[pos..], le);
    pos += copyTo(buf[pos..], "\n");

    pos += copyTo(buf[pos..], "export ZIG_DENOM_SHA256=");
    var h256: [64]u8 = undefined;
    ibc.hexEncode(&result.denom_hash.sha256, &h256);
    pos += copyTo(buf[pos..], &h256);
    pos += copyTo(buf[pos..], "\n");

    pos += copyTo(buf[pos..], "export ZIG_DENOM_SHA3=");
    var h3: [64]u8 = undefined;
    ibc.hexEncode(&result.denom_hash.sha3_256, &h3);
    pos += copyTo(buf[pos..], &h3);
    pos += copyTo(buf[pos..], "\n");

    return buf[0..pos];
}

// ============================================================================
// HELPERS (zero-allocation string building)
// ============================================================================

fn copyTo(dst: []u8, src: []const u8) usize {
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

fn padTo(dst: []u8, n: usize) usize {
    const actual = @min(dst.len, n);
    @memset(dst[0..actual], ' ');
    return actual;
}

fn writeU8(dst: []u8, val: u8) usize {
    if (val >= 100) {
        if (dst.len < 3) return 0;
        dst[0] = '0' + val / 100;
        dst[1] = '0' + (val / 10) % 10;
        dst[2] = '0' + val % 10;
        return 3;
    } else if (val >= 10) {
        if (dst.len < 2) return 0;
        dst[0] = '0' + val / 10;
        dst[1] = '0' + val % 10;
        return 2;
    } else {
        if (dst.len < 1) return 0;
        dst[0] = '0' + val;
        return 1;
    }
}

fn writeU16(dst: []u8, val: u16) usize {
    var v = val;
    var digits: [5]u8 = undefined;
    var n: usize = 0;
    if (v == 0) {
        if (dst.len < 1) return 0;
        dst[0] = '0';
        return 1;
    }
    while (v > 0) : (n += 1) {
        digits[n] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    const actual = @min(dst.len, n);
    for (0..actual) |i| {
        dst[i] = digits[n - 1 - i];
    }
    return actual;
}

// ============================================================================
// TESTS
// ============================================================================

test "format verification for yosh scrollback" {
    const trace = "transfer/channel-750/uusdc";
    const result = ibc.verifyDenom(trace);
    var buf: [4096]u8 = undefined;
    const output = formatVerificationForYosh(&result, trace, &buf);
    try std.testing.expect(output.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, output, "[zig-syrup:denom]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "MAINTENANCE_MODE") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "sha256") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "sha3-256") != null);
}

test "format as yosh command" {
    var buf: [256]u8 = undefined;
    const cmd = formatAsYoshCommand("transfer/channel-0/uatom", 9256, &buf);
    try std.testing.expect(std.mem.startsWith(u8, cmd, "curl -s localhost:9256/verify?trace="));
}

test "format as env vars" {
    const trace = "transfer/channel-750/uusdc";
    const result = ibc.verifyDenom(trace);
    var buf: [2048]u8 = undefined;
    const env = formatAsEnvVars(&result, &buf);
    try std.testing.expect(std.mem.indexOf(u8, env, "export ZIG_DENOM_ZOMBIE=maintenance_mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, env, "export ZIG_DENOM_SHA256=") != null);
}

test "format json-rpc" {
    const trace = "transfer/channel-0/uatom";
    const result = ibc.verifyDenom(trace);
    var buf: [4096]u8 = undefined;
    const rpc = formatJsonRpc(&result, trace, &buf);
    try std.testing.expect(std.mem.startsWith(u8, rpc, "{\"jsonrpc\":\"2.0\""));
    try std.testing.expect(std.mem.indexOf(u8, rpc, "\"zombie\":\"alive\"") != null);
}

test "format batch for yosh" {
    const traces = [_][]const u8{
        "transfer/channel-0/uatom",
        "transfer/channel-750/uusdc",
        "uosmo",
    };
    var results: [3]ibc.VerificationResult = undefined;
    ibc.batchVerify(&traces, &results);

    var buf: [4096]u8 = undefined;
    const table = formatBatchForYosh(&traces, &results, &buf);
    try std.testing.expect(std.mem.indexOf(u8, table, "batch_verify count=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, table, "MAINT_MODE") != null);
}
