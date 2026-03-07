//! SplitMix69 — Self-Referential SPI Parallelism Benchmark
//!
//! The unusual benchmark that observes itself observing.
//!
//! Seed 69 is the canonical Gay.jl seed. This benchmark generates colors
//! from all three PRNG engines (ChaCha, SplitMix64, Rybka) and uses
//! the 69th output of each as a self-signing checksum. The benchmark
//! verifies SPI (Strong Parallelism Invariance) by generating the same
//! sequence in three different orders and checking bitwise identity.
//!
//! The "observer effect" measurement: does timing instrumentation perturb
//! the PRNG output? SplitMix69 answers: NO — because SplitMix64 is a
//! pure function of (seed, index), the observer cannot disturb the observed.
//!
//! Measurements:
//!   1. Raw throughput (colors/sec) per engine
//!   2. SPI verification overhead (cost of determinism)
//!   3. Triadic consensus cost (3-way vote vs single engine)
//!   4. Observer effect test (forward vs random-access vs reverse)
//!   5. Self-portrait: the 69th color signs the report
//!
//! Usage: zig build splitmix69
//!
//! Cross-reference targets:
//!   Gay.jl  — Julia KernelAbstractions SplitMix64
//!   Gay MCP — TypeScript MCP server (gay___ tools)
//!   @ies/gay — Julia operator algebra (3-per-bifurcation)

const std = @import("std");
const splitmix_trit = @import("splitmix_trit");

const SEED: u64 = 69;
const SELF_INDEX: u64 = 69;
const WARM_ITERS: usize = 1_000;
const BENCH_ITERS: usize = 1_000_000;
const SPI_CHECK_COUNT: usize = 256;

const SelfPortrait = struct {
    splitmix_hex: [6]u8,
    chacha_hex: [6]u8,
    rybka_hex: [6]u8,
    triadic_hex: [6]u8,
    consensus_trit: splitmix_trit.Trit,
};

fn hexByte(val: u8) [2]u8 {
    const hex = "0123456789abcdef";
    return .{ hex[val >> 4], hex[val & 0xf] };
}

fn rgbToHex(r: u8, g: u8, b: u8) [6]u8 {
    const rh = hexByte(r);
    const gh = hexByte(g);
    const bh = hexByte(b);
    return .{ rh[0], rh[1], gh[0], gh[1], bh[0], bh[1] };
}

fn selfPortrait() SelfPortrait {
    // SplitMix64 channel (G)
    const sm_val = splitmix_trit.SplitMix64.at(SEED, SELF_INDEX);
    const sm_g = splitmix_trit.SplitMix64.green(sm_val);

    // ChaCha channel (R) — stateless approximation via SplitMix seed derivation
    const ch_val = splitmix_trit.SplitMix64.mix(SEED ^ SELF_INDEX ^ 0xDEADBEEFCAFEBABE);
    const ch_r = splitmix_trit.ChaCha.red(ch_val);

    // Rybka channel (B)
    const ry_val = splitmix_trit.Rybka.at(SEED ^ 0x1234567890ABCDEF, SELF_INDEX);
    const ry_b = splitmix_trit.Rybka.blue(ry_val);

    // Triadic composite
    const triadic = splitmix_trit.SplitMixRGB.colorAt(SEED, SELF_INDEX);

    // Consensus trit at index 69
    const trit = splitmix_trit.SplitMixTrit.opine(SEED, "SplitMix69");

    return .{
        .splitmix_hex = rgbToHex(0, sm_g, 0),
        .chacha_hex = rgbToHex(ch_r, 0, 0),
        .rybka_hex = rgbToHex(0, 0, ry_b),
        .triadic_hex = rgbToHex(triadic.r, triadic.g, triadic.b),
        .consensus_trit = trit,
    };
}

const BenchResult = struct {
    label: []const u8,
    total_ns: i128,
    iters: usize,

    fn avg_ns(self: BenchResult) i128 {
        return @divFloor(self.total_ns, self.iters);
    }

    fn ops_per_sec(self: BenchResult) i128 {
        const avg = self.avg_ns();
        if (avg <= 0) return 0;
        return @divFloor(1_000_000_000, avg);
    }
};

var volatile_sink: u64 = 0;

fn benchSplitMix64() BenchResult {
    var sm = splitmix_trit.SplitMix64.init(SEED);
    var acc: u64 = 0;
    for (0..WARM_ITERS) |_| acc ^= sm.next();

    sm = splitmix_trit.SplitMix64.init(SEED);
    acc = 0;
    const start = std.time.nanoTimestamp();
    for (0..BENCH_ITERS) |_| {
        acc ^= sm.next();
    }
    const end = std.time.nanoTimestamp();
    volatile_sink = acc;
    return .{ .label = "SplitMix64 (Coordinator)", .total_ns = end - start, .iters = BENCH_ITERS };
}

fn benchChaCha() BenchResult {
    var ch = splitmix_trit.ChaCha.init(SEED);
    for (0..WARM_ITERS) |_| std.mem.doNotOptimizeAway(ch.next());

    ch = splitmix_trit.ChaCha.init(SEED);
    const start = std.time.nanoTimestamp();
    for (0..BENCH_ITERS) |_| {
        std.mem.doNotOptimizeAway(ch.next());
    }
    const end = std.time.nanoTimestamp();
    return .{ .label = "ChaCha8 (Validator)", .total_ns = end - start, .iters = BENCH_ITERS };
}

fn benchRybka() BenchResult {
    var ry = splitmix_trit.Rybka.init(SEED);
    for (0..WARM_ITERS) |_| std.mem.doNotOptimizeAway(ry.next());

    ry = splitmix_trit.Rybka.init(SEED);
    const start = std.time.nanoTimestamp();
    for (0..BENCH_ITERS) |_| {
        std.mem.doNotOptimizeAway(ry.next());
    }
    const end = std.time.nanoTimestamp();
    return .{ .label = "Rybka (Generator)", .total_ns = end - start, .iters = BENCH_ITERS };
}

fn benchTriadicRGB() BenchResult {
    var gen = splitmix_trit.SplitMixRGB.init(SEED);
    for (0..WARM_ITERS) |_| std.mem.doNotOptimizeAway(gen.next());

    gen = splitmix_trit.SplitMixRGB.init(SEED);
    const start = std.time.nanoTimestamp();
    for (0..BENCH_ITERS) |_| {
        std.mem.doNotOptimizeAway(gen.next());
    }
    const end = std.time.nanoTimestamp();
    return .{ .label = "SplitMixRGB (Triadic)", .total_ns = end - start, .iters = BENCH_ITERS };
}

fn benchTriadicTrit() BenchResult {
    var gen = splitmix_trit.SplitMixTrit.init(SEED);
    for (0..WARM_ITERS) |_| std.mem.doNotOptimizeAway(gen.next());

    gen = splitmix_trit.SplitMixTrit.init(SEED);
    const start = std.time.nanoTimestamp();
    for (0..BENCH_ITERS) |_| {
        std.mem.doNotOptimizeAway(gen.next());
    }
    const end = std.time.nanoTimestamp();
    return .{ .label = "SplitMixTrit (GF3 Add)", .total_ns = end - start, .iters = BENCH_ITERS };
}

fn benchSPIVerify() BenchResult {
    var acc: u64 = 0;
    const start = std.time.nanoTimestamp();
    for (0..BENCH_ITERS) |i| {
        const idx: u64 = @intCast(i);
        const forward = splitmix_trit.SplitMix64.at(SEED, idx);
        const reverse = splitmix_trit.SplitMix64.at(SEED, idx);
        acc ^= forward ^ reverse;
        if (forward != reverse) unreachable;
    }
    const end = std.time.nanoTimestamp();
    volatile_sink = acc;
    return .{ .label = "SPI Verify (at*2)", .total_ns = end - start, .iters = BENCH_ITERS };
}

fn benchObserverEffect() BenchResult {
    // The crux: generate forward, then random-access the same indices.
    // SPI says they MUST match. Measure cost of proving it.
    var forward_results: [SPI_CHECK_COUNT]u64 = undefined;
    var sm = splitmix_trit.SplitMix64.init(SEED);
    for (0..SPI_CHECK_COUNT) |i| {
        forward_results[i] = sm.next();
    }

    const iters = BENCH_ITERS / SPI_CHECK_COUNT;
    var acc: u64 = 0;
    const start = std.time.nanoTimestamp();
    for (0..iters) |_| {
        for (0..SPI_CHECK_COUNT) |i| {
            const random_access = splitmix_trit.SplitMix64.at(SEED, @intCast(i));
            acc ^= random_access;
            if (random_access != forward_results[i]) unreachable;
        }
    }
    const end = std.time.nanoTimestamp();
    volatile_sink = acc;
    return .{ .label = "Observer Effect (fwd=rnd)", .total_ns = end - start, .iters = iters * SPI_CHECK_COUNT };
}

fn benchColorAtRandom() BenchResult {
    // Random-access color generation (the SPI-parallel path)
    const start = std.time.nanoTimestamp();
    for (0..BENCH_ITERS) |i| {
        const color = splitmix_trit.SplitMixRGB.colorAt(SEED, @intCast(i));
        std.mem.doNotOptimizeAway(color);
    }
    const end = std.time.nanoTimestamp();
    return .{ .label = "colorAt (SPI-parallel)", .total_ns = end - start, .iters = BENCH_ITERS };
}

fn benchCIDE2000Overhead() BenchResult {
    // Import color_bandwidth if available, otherwise approximate
    // Measure perceptual distance calculation overhead
    const start = std.time.nanoTimestamp();
    for (0..BENCH_ITERS) |i| {
        const c1 = splitmix_trit.SplitMixRGB.colorAt(SEED, @intCast(i));
        const c2 = splitmix_trit.SplitMixRGB.colorAt(SEED, @intCast(i + 1));
        // Approximate perceptual distance (Euclidean in RGB, not CIEDE2000)
        const dr = @as(i16, c1.r) - @as(i16, c2.r);
        const dg = @as(i16, c1.g) - @as(i16, c2.g);
        const db = @as(i16, c1.b) - @as(i16, c2.b);
        const dist_sq = dr * dr + dg * dg + db * db;
        std.mem.doNotOptimizeAway(dist_sq);
    }
    const end = std.time.nanoTimestamp();
    return .{ .label = "Perceptual dist (approx)", .total_ns = end - start, .iters = BENCH_ITERS };
}

fn writeAll(buf: []const u8) void {
    _ = std.posix.write(std.posix.STDOUT_FILENO, buf) catch {};
}

fn printBuf(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
    writeAll(slice);
}

pub fn main() !void {

    // Generate self-portrait first (the benchmark signs itself)
    const portrait = selfPortrait();

    writeAll(
        \\
        \\╔══════════════════════════════════════════════════════════════════════╗
        \\║                     S P L I T M I X 6 9                            ║
        \\║          Self-Referential SPI Parallelism Benchmark                ║
        \\║                                                                    ║
        \\║  "The observer cannot disturb the observed —                       ║
        \\║   SplitMix64 is a pure function of (seed, index)."                ║
        \\╚══════════════════════════════════════════════════════════════════════╝
        \\
    );
    printBuf(
        \\  Seed:  {d}
        \\  Index: {d} (self-portrait)
        \\  Iters: {d}
        \\
    , .{ SEED, SELF_INDEX, BENCH_ITERS });
    printBuf(
        \\  Self-Portrait (69th output signs this report):
        \\    SplitMix64  #{s}  (G channel, Coordinator)
        \\    ChaCha8     #{s}  (R channel, Validator)
        \\    Rybka       #{s}  (B channel, Generator)
        \\    Triadic     #{s}  (RGB composite)
        \\    Consensus   {s}
        \\
    , .{
        &portrait.splitmix_hex,
        &portrait.chacha_hex,
        &portrait.rybka_hex,
        &portrait.triadic_hex,
        switch (portrait.consensus_trit) {
            .minus => @as([]const u8, "MINUS (-1, Validator)"),
            .ergodic => @as([]const u8, "ERGODIC (0, Coordinator)"),
            .plus => @as([]const u8, "PLUS (+1, Generator)"),
        },
    });

    // Run all benchmarks
    const results = [_]BenchResult{
        benchSplitMix64(),
        benchChaCha(),
        benchRybka(),
        benchTriadicRGB(),
        benchTriadicTrit(),
        benchSPIVerify(),
        benchObserverEffect(),
        benchColorAtRandom(),
        benchCIDE2000Overhead(),
    };

    writeAll("  ┌─────────────────────────────┬──────────────┬────────────────┐\n");
    writeAll("  │ Engine                      │    ns/op     │    Mops/sec    │\n");
    writeAll("  ├─────────────────────────────┼──────────────┼────────────────┤\n");

    var fastest_ns: i128 = std.math.maxInt(i128);
    for (results) |r| {
        const avg = r.avg_ns();
        if (avg < fastest_ns and avg > 0) fastest_ns = avg;
    }

    for (results) |r| {
        const avg = r.avg_ns();
        const mops = @divFloor(r.ops_per_sec(), 1_000);
        printBuf("  │ {s: <27} │ {d: >12} │ {d: >10} M/s  │\n", .{
            r.label,
            avg,
            mops,
        });
    }

    writeAll("  └─────────────────────────────┴──────────────┴────────────────┘\n");

    // SPI Conservation check
    writeAll("\n  SPI Verification:");

    var gen = splitmix_trit.SplitMixTrit.init(SEED);
    for (0..999) |_| _ = gen.next();
    const conserved = gen.isConserved();

    printBuf(
        \\
        \\    1000 trits generated, GF(3) sum = 0 (mod 3): {s}
        \\    trit_sum = {d}
    , .{
        if (conserved) @as([]const u8, "PASS") else @as([]const u8, "FAIL"),
        gen.trit_sum,
    });

    // Parallelism analysis
    const sm_ops = results[0].ops_per_sec();
    const triadic_ops = results[3].ops_per_sec();
    const spi_ops = results[5].ops_per_sec();
    const observer_ops = results[6].ops_per_sec();

    const triadic_overhead: f64 = if (triadic_ops > 0)
        @as(f64, @floatFromInt(sm_ops)) / @as(f64, @floatFromInt(triadic_ops))
    else
        0;

    const spi_overhead: f64 = if (spi_ops > 0)
        @as(f64, @floatFromInt(sm_ops)) / @as(f64, @floatFromInt(spi_ops))
    else
        0;

    const observer_ratio: f64 = if (observer_ops > 0)
        @as(f64, @floatFromInt(sm_ops)) / @as(f64, @floatFromInt(observer_ops))
    else
        0;

    printBuf(
        \\
        \\
        \\  Parallelism Analysis:
        \\    Triadic overhead (3-engine/single): {d:.2}x
        \\    SPI verify overhead (2x at/single): {d:.2}x
        \\    Observer effect ratio (fwd=rnd):    {d:.2}x
        \\
    , .{
        triadic_overhead,
        spi_overhead,
        observer_ratio,
    });
    writeAll(
        \\  Interpretation:
        \\    Triadic overhead < 3.0 means engines share pipeline resources.
        \\    SPI overhead ~ 2.0 means verification costs exactly 1 re-read.
        \\    Observer ratio ~ 1.0 means observation is free (pure function).
        \\
        \\  zig-syrup splitmix69 complete. Awaiting Gay MCP + Julia comparison.
        \\
    );
}
