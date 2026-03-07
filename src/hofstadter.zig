//! Hofstadter Butterfly via Harper equation
//! H = δ_{n,m+1} + δ_{n,m-1} + 2λ·cos(2παn + φ)·δ_{nm}
//! For α = p/q, q×q matrix → q energy bands
//! Flapping parameter λ: Aubry-André metal-insulator transition at λ=1

const std = @import("std");
const math = std.math;
const Allocator = std.mem.Allocator;
const spectral = @import("spectral_tensor.zig");
const DenseMatrix = spectral.DenseMatrix;

pub const ButterflyPoint = struct {
    alpha: f32,
    energy: f32,
    band: u16,
    q: u16,
};

fn gcd(a: u32, b: u32) u32 {
    var x = a;
    var y = b;
    while (y != 0) {
        const t = y;
        y = x % y;
        x = t;
    }
    return x;
}

/// Build Harper matrix for α = p/q with anisotropy λ
fn buildHarper(allocator: Allocator, p: u32, q: u32, lambda: f64) !DenseMatrix {
    var H = try DenseMatrix.init(allocator, q, q);
    for (0..q) |n| {
        // Diagonal: 2λ cos(2π·p·n/q)
        const phase = 2.0 * math.pi * @as(f64, @floatFromInt(p * n)) / @as(f64, @floatFromInt(q));
        H.set(n, n, 2.0 * lambda * @cos(phase));
        // Off-diagonal hopping
        const next = (n + 1) % q;
        H.addTo(n, next, 1.0);
        H.addTo(next, n, 1.0);
    }
    return H;
}

/// Compute full Hofstadter butterfly spectrum for all α = p/q, q ≤ q_max
pub fn computeButterfly(
    allocator: Allocator,
    q_max: u32,
    lambda: f64,
    out_buf: []ButterflyPoint,
) !usize {
    var count: usize = 0;
    var q: u32 = 1;
    while (q <= q_max) : (q += 1) {
        var p: u32 = 0;
        while (p <= q) : (p += 1) {
            if (p != 0 and gcd(p, q) != 1) continue;

            var H = try buildHarper(allocator, p, q, lambda);
            defer H.deinit(allocator);

            var eigen = try spectral.eigendecompose(H, q, allocator);
            defer eigen.deinit(allocator);

            const alpha: f32 = @floatCast(@as(f64, @floatFromInt(p)) / @as(f64, @floatFromInt(q)));
            for (eigen.eigenvalues, 0..) |e, band| {
                if (count >= out_buf.len) return count;
                out_buf[count] = .{
                    .alpha = alpha,
                    .energy = @floatCast(e),
                    .band = @intCast(band),
                    .q = @intCast(q),
                };
                count += 1;
            }
        }
    }
    return count;
}

// C ABI exports for Swift FFI
const MAX_POINTS = 64 * 1024;
var g_buf: [MAX_POINTS]ButterflyPoint = undefined;

export fn hofstadter_compute(q_max: u32, lambda: f64) u32 {
    const count = computeButterfly(
        std.heap.page_allocator,
        q_max,
        lambda,
        &g_buf,
    ) catch return 0;
    return @intCast(count);
}

export fn hofstadter_get_alpha(idx: u32) f32 {
    return g_buf[idx].alpha;
}

export fn hofstadter_get_energy(idx: u32) f32 {
    return g_buf[idx].energy;
}

export fn hofstadter_get_band(idx: u32) u16 {
    return g_buf[idx].band;
}

export fn hofstadter_get_q(idx: u32) u16 {
    return g_buf[idx].q;
}

test "basic butterfly" {
    const allocator = std.testing.allocator;
    var buf: [4096]ButterflyPoint = undefined;

    // q_max=5, λ=1.0 → standard Hofstadter
    const n = try computeButterfly(allocator, 5, 1.0, &buf);
    try std.testing.expect(n > 0);

    // Check energy bounds: |E| ≤ 2 + 2|λ|
    for (buf[0..n]) |pt| {
        try std.testing.expect(@abs(pt.energy) <= 4.1);
    }
}

test "aubry-andre transition" {
    const allocator = std.testing.allocator;
    var buf: [4096]ButterflyPoint = undefined;

    // λ < 1: extended (metallic) — narrower bands
    const n_metal = try computeButterfly(allocator, 10, 0.5, &buf);
    var max_e_metal: f32 = 0;
    for (buf[0..n_metal]) |pt| {
        if (@abs(pt.energy) > max_e_metal) max_e_metal = @abs(pt.energy);
    }

    // λ > 1: localized (insulating) — wider bands
    const n_ins = try computeButterfly(allocator, 10, 2.0, &buf);
    var max_e_ins: f32 = 0;
    for (buf[0..n_ins]) |pt| {
        if (@abs(pt.energy) > max_e_ins) max_e_ins = @abs(pt.energy);
    }

    // Insulating phase has wider energy range
    try std.testing.expect(max_e_ins > max_e_metal);
}
