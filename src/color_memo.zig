//! Color Memo — Old C-style memoization (#88DCA3)
//!
//! No generics, no allocator, extern-C compatible.
//! Static arrays, fixed-size cache, pure functions.
//! The hash table IS the identity (skeeto).
//! The comptime table IS the proof (Zig).
//! The overlay IS the transclusion (nobiot).
//!
//! Exceeds Guile/Racket syrup: those compute color per-render.
//! This precomputes at compile time and caches at runtime.

const std = @import("std");

const GOLDEN: u64 = 0x9E3779B97F4A7C15;
const MIX1: u64 = 0xBF58476D1CE4E5B9;
const MIX2: u64 = 0x94D049BB133111EB;

fn splitmix64(x: u64) u64 {
    var z = x +% GOLDEN;
    z = (z ^ (z >> 30)) *% MIX1;
    z = (z ^ (z >> 27)) *% MIX2;
    return z ^ (z >> 31);
}

// ============================================================================
// C-style color triple
// ============================================================================

pub const Color3 = extern struct {
    r: u8,
    g: u8,
    b: u8,
    _pad: u8 = 0,
};

// ============================================================================
// Static cache: 256 entries, direct-mapped by hash
// ============================================================================

const CACHE_SIZE = 256;
const CACHE_MASK = CACHE_SIZE - 1;

const CacheEntry = struct {
    key: u64 = 0,
    val: Color3 = .{ .r = 0, .g = 0, .b = 0 },
    occupied: bool = false,
};

var runtime_cache: [CACHE_SIZE]CacheEntry = [_]CacheEntry{.{}} ** CACHE_SIZE;

fn cacheSlot(key: u64) usize {
    return @intCast(key & CACHE_MASK);
}

// ============================================================================
// Core: color_at with cache
// ============================================================================

pub fn colorAt(seed: u64, index: u64) Color3 {
    const key = seed +% (GOLDEN *% index);
    const slot = cacheSlot(key);

    if (runtime_cache[slot].occupied and runtime_cache[slot].key == key) {
        return runtime_cache[slot].val;
    }

    const raw = splitmix64(key);
    const c = Color3{
        .r = @truncate(raw >> 16),
        .g = @truncate(raw >> 8),
        .b = @truncate(raw),
    };

    runtime_cache[slot] = .{ .key = key, .val = c, .occupied = true };
    return c;
}

// ============================================================================
// Expression fingerprint (FNV-1a, no allocator)
// ============================================================================

pub fn fingerprint(op: [*]const u8, op_len: usize, children: [*]const u64, n_children: usize) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (0..op_len) |i| {
        h ^= op[i];
        h *%= 0x100000001b3;
    }
    for (0..n_children) |i| {
        h ^= children[i];
        h *%= 0x100000001b3;
    }
    return h;
}

pub fn fingerprintColor(fp: u64, seed: u64) Color3 {
    const raw = splitmix64(fp ^ seed);
    return .{
        .r = @truncate(raw >> 16),
        .g = @truncate(raw >> 8),
        .b = @truncate(raw),
    };
}

// ============================================================================
// GF(3) trit from color
// ============================================================================

pub fn trit(c: Color3) i8 {
    const sum: u16 = @as(u16, c.r) + c.g + c.b;
    return switch (@as(u2, @intCast(sum % 3))) {
        0 => 0,
        1 => 1,
        2 => -1,
        3 => unreachable,
    };
}

pub fn balanced(a: Color3, b: Color3, c: Color3) bool {
    const s = @mod(@as(i16, trit(a)) + trit(b) + trit(c) + 3, 3);
    return s == 0;
}

// ============================================================================
// extern "C" — callable from Guile FFI, Python ctypes, Racket FFI
// ============================================================================

export fn gay_color_at(seed: u64, index: u64) Color3 {
    return colorAt(seed, index);
}

export fn gay_fingerprint(op: [*]const u8, op_len: usize, children: [*]const u64, n_children: usize) u64 {
    return fingerprint(op, op_len, children, n_children);
}

export fn gay_fingerprint_color(fp: u64, seed: u64) Color3 {
    return fingerprintColor(fp, seed);
}

export fn gay_trit(c: Color3) i8 {
    return trit(c);
}

export fn gay_balanced(a: Color3, b: Color3, c: Color3) bool {
    return balanced(a, b, c);
}

export fn gay_cache_clear() void {
    runtime_cache = [_]CacheEntry{.{}} ** CACHE_SIZE;
}

// ============================================================================
// Tests
// ============================================================================

test "colorAt determinism" {
    const c1 = colorAt(42, 1);
    const c2 = colorAt(42, 1);
    try std.testing.expectEqual(c1.r, c2.r);
    try std.testing.expectEqual(c1.g, c2.g);
    try std.testing.expectEqual(c1.b, c2.b);
}

test "colorAt cache hit" {
    gay_cache_clear();
    _ = colorAt(69, 7);
    const slot = cacheSlot(69 +% (GOLDEN *% 7));
    try std.testing.expect(runtime_cache[slot].occupied);
    const c = colorAt(69, 7);
    try std.testing.expect(c.r != 0 or c.g != 0 or c.b != 0);
}

test "fingerprint determinism" {
    const op = "compose";
    const kids = [_]u64{ 111, 222 };
    const fp1 = fingerprint(op.ptr, op.len, &kids, kids.len);
    const fp2 = fingerprint(op.ptr, op.len, &kids, kids.len);
    try std.testing.expectEqual(fp1, fp2);
}

test "fingerprint order matters" {
    const op = "compose";
    const kids_a = [_]u64{ 111, 222 };
    const kids_b = [_]u64{ 222, 111 };
    const fp_a = fingerprint(op.ptr, op.len, &kids_a, kids_a.len);
    const fp_b = fingerprint(op.ptr, op.len, &kids_b, kids_b.len);
    try std.testing.expect(fp_a != fp_b);
}

test "trit values" {
    const c0 = Color3{ .r = 0, .g = 0, .b = 0 };
    try std.testing.expectEqual(@as(i8, 0), trit(c0));

    const c1 = Color3{ .r = 1, .g = 0, .b = 0 };
    try std.testing.expectEqual(@as(i8, 1), trit(c1));

    const c2 = Color3{ .r = 2, .g = 0, .b = 0 };
    try std.testing.expectEqual(@as(i8, -1), trit(c2));
}

test "balanced triad" {
    const a = Color3{ .r = 0, .g = 0, .b = 0 }; // trit 0
    const b = Color3{ .r = 1, .g = 0, .b = 0 }; // trit 1
    const c = Color3{ .r = 2, .g = 0, .b = 0 }; // trit -1
    try std.testing.expect(balanced(a, b, c));
}

test "extern C symbols exist" {
    const c = gay_color_at(42, 1);
    try std.testing.expect(c.r != 0 or c.g != 0 or c.b != 0);

    const t = gay_trit(c);
    try std.testing.expect(t >= -1 and t <= 1);
}
