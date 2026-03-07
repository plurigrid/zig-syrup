//! Benchmarks for Clifford algebra operations.

const std = @import("std");
const clifford = @import("clifford.zig");

const ITERATIONS: u64 = 1_000_000;
const WARMUP: u64 = 10_000;

fn nanoPerOp(elapsed_ns: u64, iters: u64) u64 {
    return elapsed_ns / iters;
}

// --- Algebra types ---
const Dual = clifford.Algebra(0, 0, 1);
const Complex = clifford.Algebra(0, 1, 0);
const Quat = clifford.Algebra(0, 2, 0);
const VGA = clifford.Algebra(3, 0, 0);
const PGA = clifford.Algebra(3, 0, 1);
const CGA = clifford.Algebra(4, 1, 0);

// --- Pre-built test values (module-level constants) ---
const dual_a: Dual = blk: {
    var d = Dual.scalar(3.0);
    d.coeffs[1] = 2.0;
    break :blk d;
};
const dual_b: Dual = blk: {
    var d = Dual.scalar(5.0);
    d.coeffs[1] = 7.0;
    break :blk d;
};

const complex_a: Complex = blk: {
    var z = Complex.scalar(3.0);
    z.coeffs[1] = 4.0;
    break :blk z;
};
const complex_b: Complex = blk: {
    var z = Complex.scalar(1.0);
    z.coeffs[1] = -2.0;
    break :blk z;
};

const quat_a: Quat = blk: {
    var q = Quat.scalar(1.0);
    q.coeffs[1] = 2.0;
    q.coeffs[2] = 3.0;
    q.coeffs[3] = 4.0;
    break :blk q;
};
const quat_b: Quat = blk: {
    var q = Quat.scalar(0.5);
    q.coeffs[1] = -1.0;
    q.coeffs[2] = 0.3;
    q.coeffs[3] = 2.0;
    break :blk q;
};

const vga_v1: VGA = blk: {
    var v = VGA.zero();
    v.coeffs[1] = 1.0;
    v.coeffs[2] = 2.0;
    v.coeffs[4] = 3.0;
    break :blk v;
};
const vga_v2: VGA = blk: {
    var v = VGA.zero();
    v.coeffs[1] = 4.0;
    v.coeffs[2] = -1.0;
    v.coeffs[4] = 2.0;
    break :blk v;
};
const vga_rotor: VGA = blk: {
    const angle = std.math.pi / 4.0;
    var r = VGA.scalar(@cos(angle / 2.0));
    r.coeffs[3] = @sin(angle / 2.0);
    break :blk r;
};

const pga_p1: PGA = blk: {
    var p = PGA.zero();
    p.coeffs[1] = 1.0;
    p.coeffs[2] = 2.0;
    p.coeffs[4] = 3.0;
    p.coeffs[8] = 1.0;
    break :blk p;
};
const pga_p2: PGA = blk: {
    var p = PGA.zero();
    p.coeffs[1] = 4.0;
    p.coeffs[2] = -1.0;
    p.coeffs[4] = 2.0;
    p.coeffs[8] = 1.0;
    break :blk p;
};

const cga_v1: CGA = blk: {
    var v = CGA.zero();
    v.coeffs[1] = 1.0;
    v.coeffs[2] = 2.0;
    v.coeffs[4] = 3.0;
    break :blk v;
};
const cga_v2: CGA = blk: {
    var v = CGA.zero();
    v.coeffs[1] = 4.0;
    v.coeffs[2] = -1.0;
    v.coeffs[4] = 2.0;
    break :blk v;
};

fn runBench(comptime name: []const u8, comptime T: type, comptime f: fn () T) void {
    var w: u64 = 0;
    while (w < WARMUP) : (w += 1) {
        std.mem.doNotOptimizeAway(f());
    }
    var timer = std.time.Timer.start() catch unreachable;
    var i: u64 = 0;
    while (i < ITERATIONS) : (i += 1) {
        std.mem.doNotOptimizeAway(f());
    }
    const elapsed = timer.read();
    const ns_op = nanoPerOp(elapsed, ITERATIONS);
    const mops = if (ns_op > 0) 1000 / ns_op else 9999;
    std.debug.print("{s:<48} {d:>6} ns/op   {d:>6} Mop/s\n", .{ name, ns_op, mops });
}

// --- Benchmark functions (all comptime-known, no closures) ---

fn bench_dual_mul() Dual { return dual_a.mul(dual_b); }
fn bench_dual_rev() Dual { return dual_a.reverse(); }

fn bench_complex_mul() Complex { return complex_a.mul(complex_b); }
fn bench_complex_inv() ?Complex { return complex_a.inverse(); }

fn bench_quat_mul() Quat { return quat_a.mul(quat_b); }
fn bench_quat_rev() Quat { return quat_a.reverse(); }
fn bench_quat_conj() Quat { return quat_a.conjugate(); }
fn bench_quat_norm() f64 { return quat_a.norm(); }
fn bench_quat_inv() ?Quat { return quat_a.inverse(); }

fn bench_vga_mul() VGA { return vga_v1.mul(vga_v2); }
fn bench_vga_wedge() VGA { return vga_v1.wedge(vga_v2); }
fn bench_vga_lc() VGA { return vga_v1.leftContract(vga_v2); }
fn bench_vga_rev() VGA { return vga_v1.reverse(); }
fn bench_vga_sandwich() VGA { return vga_rotor.sandwich(vga_v1); }
fn bench_vga_inv() ?VGA { return vga_v1.inverse(); }
fn bench_vga_grade() VGA { return vga_v1.mul(vga_v2).grade(1); }

fn bench_pga_mul() PGA { return pga_p1.mul(pga_p2); }
fn bench_pga_wedge() PGA { return pga_p1.wedge(pga_p2); }
fn bench_pga_sandwich() PGA { return pga_p1.sandwich(pga_p2); }
fn bench_pga_rev() PGA { return pga_p1.reverse(); }

fn bench_cga_mul() CGA { return cga_v1.mul(cga_v2); }
fn bench_cga_wedge() CGA { return cga_v1.wedge(cga_v2); }
fn bench_cga_rev() CGA { return cga_v1.reverse(); }
fn bench_cga_sandwich() CGA { return cga_v1.sandwich(cga_v2); }

pub fn main() !void {
    std.debug.print("\n============================================================\n", .{});
    std.debug.print("  Clifford Algebra Benchmarks (comptime Cayley tables)\n", .{});
    std.debug.print("  {d} iterations, {d} warmup\n", .{ ITERATIONS, WARMUP });
    std.debug.print("============================================================\n\n", .{});

    std.debug.print("--- Algebra(0,0,1) Dual Numbers (dim=2) ---\n", .{});
    runBench("  dual: geometric product", Dual, bench_dual_mul);
    runBench("  dual: reverse", Dual, bench_dual_rev);

    std.debug.print("\n--- Algebra(0,1,0) Complex Numbers (dim=2) ---\n", .{});
    runBench("  complex: geometric product", Complex, bench_complex_mul);
    runBench("  complex: inverse", ?Complex, bench_complex_inv);

    std.debug.print("\n--- Algebra(0,2,0) Quaternions (dim=4) ---\n", .{});
    runBench("  quat: geometric product", Quat, bench_quat_mul);
    runBench("  quat: reverse", Quat, bench_quat_rev);
    runBench("  quat: conjugate", Quat, bench_quat_conj);
    runBench("  quat: norm", f64, bench_quat_norm);
    runBench("  quat: inverse", ?Quat, bench_quat_inv);

    std.debug.print("\n--- Algebra(3,0,0) VGA 3D Euclidean (dim=8) ---\n", .{});
    runBench("  VGA: geometric product (vec*vec)", VGA, bench_vga_mul);
    runBench("  VGA: wedge product", VGA, bench_vga_wedge);
    runBench("  VGA: left contraction", VGA, bench_vga_lc);
    runBench("  VGA: reverse", VGA, bench_vga_rev);
    runBench("  VGA: sandwich (rotor*vec*rev)", VGA, bench_vga_sandwich);
    runBench("  VGA: inverse", ?VGA, bench_vga_inv);
    runBench("  VGA: mul + grade extract", VGA, bench_vga_grade);

    std.debug.print("\n--- Algebra(3,0,1) PGA 3D Projective (dim=16) ---\n", .{});
    runBench("  PGA: geometric product", PGA, bench_pga_mul);
    runBench("  PGA: wedge product", PGA, bench_pga_wedge);
    runBench("  PGA: sandwich", PGA, bench_pga_sandwich);
    runBench("  PGA: reverse", PGA, bench_pga_rev);

    std.debug.print("\n--- Algebra(4,1,0) CGA 3D Conformal (dim=32) ---\n", .{});
    runBench("  CGA: geometric product", CGA, bench_cga_mul);
    runBench("  CGA: wedge product", CGA, bench_cga_wedge);
    runBench("  CGA: reverse", CGA, bench_cga_rev);
    runBench("  CGA: sandwich", CGA, bench_cga_sandwich);

    std.debug.print("\n--- Comptime Table Sizes ---\n", .{});
    std.debug.print("  Algebra(0,0,1):  2x2   =      4 entries (baked at comptime)\n", .{});
    std.debug.print("  Algebra(0,2,0):  4x4   =     16 entries\n", .{});
    std.debug.print("  Algebra(3,0,0):  8x8   =     64 entries\n", .{});
    std.debug.print("  Algebra(3,0,1): 16x16  =    256 entries\n", .{});
    std.debug.print("  Algebra(4,1,0): 32x32  =  1,024 entries\n", .{});
    std.debug.print("\n", .{});
}
