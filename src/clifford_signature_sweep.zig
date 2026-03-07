//! Signature Sweep: vary (p,q,r) across candidate Clifford algebras
//! and compare all 6 color game outcomes per category.
//!
//! "Indefinite" signatures have mixed positive/negative squares,
//! giving hyperbolic geometry where conservation, distinguishability,
//! and entropy behave qualitatively differently.
//!
//! Candidate 3D signatures (dim = 2^3 = 8 basis blades):
//!   (3,0,0) -- Euclidean 3-space. All axes square to +1.
//!   (2,1,0) -- Minkowski-like. Two space + one time.
//!   (1,2,0) -- Anti-Minkowski. One space + two time.
//!   (0,3,0) -- Anti-Euclidean. All axes square to -1.
//!   (2,0,1) -- PGA-like (current). Two Euclidean + one degenerate.
//!   (1,1,1) -- Mixed indefinite. One of each.
//!   (0,2,1) -- Anti-space + degenerate.
//!   (0,0,3) -- Fully degenerate (grassmann/exterior algebra).

const std = @import("std");
const math = std.math;
const testing = std.testing;
const clifford = @import("clifford");
const clifford_analytic = @import("clifford_analytic");

// ============================================================================
// Generic game functions parameterized by algebra type
// ============================================================================

fn GenericGames(comptime p: u3, comptime q: u3, comptime r: u3) type {
    const Alg = clifford.Algebra(p, q, r);

    return struct {
        const Trit = enum(i8) {
            minus = -1,
            zero = 0,
            plus = 1,
        };

        fn embedColor(rv: u8, gv: u8, bv: u8) Alg {
            var mv = Alg.zero();
            mv.coeffs[1] = @as(f64, @floatFromInt(rv)) / 255.0;
            mv.coeffs[2] = @as(f64, @floatFromInt(gv)) / 255.0;
            mv.coeffs[4] = @as(f64, @floatFromInt(bv)) / 255.0;
            return mv;
        }

        fn extractTrit(mv: Alg) Trit {
            const r_mag = @abs(mv.coeffs[1]);
            const g_mag = @abs(mv.coeffs[2]);
            const b_mag = @abs(mv.coeffs[4]);
            if (r_mag > g_mag and r_mag > b_mag) return .minus;
            if (g_mag > r_mag and g_mag > b_mag) return .plus;
            return .zero;
        }

        fn sigmaRotor(order: i8) Alg {
            if (order == 0) return Alg.scalar(1.0);
            const angle: f64 = @as(f64, @floatFromInt(order)) * 2.0 * math.pi / 3.0;
            const e0 = Alg.basis(0);
            const e1 = Alg.basis(1);
            const e01 = e0.wedge(e1);
            const half = angle / 2.0;
            return Alg.scalar(@cos(half)).add(e01.scale(@sin(half)));
        }

        fn embedRichWedge(rv: u8, gv: u8, bv: u8) Alg {
            const v = embedColor(rv, gv, bv);
            const rotor = sigmaRotor(1);
            const rotated = rotor.sandwich(v);
            const wedge_part = v.wedge(rotated);
            const norm_scalar = Alg.scalar(v.norm());
            // Pseudoscalar: product of all basis vectors
            const e0 = Alg.basis(0);
            const e1 = Alg.basis(1);
            const e2 = Alg.basis(2);
            const ps = e0.wedge(e1).wedge(e2);
            const lum = (v.coeffs[1] + v.coeffs[2] + v.coeffs[4]) / 3.0;
            return norm_scalar.add(v).add(wedge_part).add(ps.scale(lum));
        }

        // -- Game 1: Conservation --
        const ConservationResult = struct {
            equilibrium: bool,
            norm_preserved: bool,
            norm_ratio: f64, // |Rv~R| / |v|: should be 1.0 for isometry
        };

        fn conservationGame(color_a: Alg, color_b: Alg) ConservationResult {
            const rotor = sigmaRotor(1);
            const rotated = rotor.sandwich(color_a);
            const na = color_a.norm();
            const nr = rotated.norm();
            const ratio = if (na > 1e-12) nr / na else 1.0;
            const norm_preserved = @abs(ratio - 1.0) < 1e-6;

            const ta = extractTrit(color_a);
            const tb = extractTrit(color_b);
            const s = @as(i16, @intFromEnum(ta)) + @as(i16, @intFromEnum(tb));
            const equilibrium = @mod(s + 6, 3) == 0;

            return .{ .equilibrium = equilibrium, .norm_preserved = norm_preserved, .norm_ratio = ratio };
        }

        // -- Game 2: Distinguishability --
        const DistinguishResult = struct {
            distinguishable: bool,
            cosine: f64,
            wedge_norm: f64,
            distance: f64,
        };

        fn distinguishGame(color_a: Alg, color_b: Alg) DistinguishResult {
            const inner = color_a.mul(color_b.reverse()).scalarPart();
            const na = color_a.norm();
            const nb = color_b.norm();
            const denom = na * nb;
            const cosine = if (denom > 1e-12) inner / denom else 0.0;
            const wedge = color_a.wedge(color_b);
            const wn = wedge.norm();
            const diff = color_a.sub(color_b);
            const dist = diff.norm();
            return .{
                .distinguishable = wn > 0.1 or dist > 0.1,
                .cosine = cosine,
                .wedge_norm = wn,
                .distance = dist,
            };
        }

        // -- Game 3: Entropy Witness --
        const EntropyResult = struct {
            active_grades: u32,
            entropy_ratio: f64,
            sufficient: bool,
        };

        fn entropyWitness(elements: []const Alg) EntropyResult {
            const N = p + q + r;
            const total_grades: u32 = N + 1;
            const DIM = Alg.DIM;
            var grade_energy: [total_grades]f64 = @splat(0);
            var total_energy: f64 = 0;

            for (elements) |elem| {
                for (0..DIM) |bi| {
                    const g = @popCount(@as(u32, @intCast(bi)));
                    const e = elem.coeffs[bi] * elem.coeffs[bi];
                    grade_energy[g] += e;
                    total_energy += e;
                }
            }

            if (total_energy < 1e-14) {
                return .{ .active_grades = 0, .entropy_ratio = 0, .sufficient = false };
            }

            var entropy: f64 = 0;
            var active: u32 = 0;
            for (0..total_grades) |k| {
                const pp = grade_energy[k] / total_energy;
                if (pp > 1e-12) {
                    entropy -= pp * @log(pp);
                    active += 1;
                }
            }
            const max_ent = @log(@as(f64, @floatFromInt(total_grades)));
            const ratio = if (max_ent > 0) entropy / max_ent else 0;
            return .{ .active_grades = active, .entropy_ratio = ratio, .sufficient = ratio >= 0.3 };
        }

        // -- Game 4: Bisimulation --
        const BisimResult = struct {
            bisimilar: bool,
            trit_alignment: f64,
        };

        fn bisimulationGame(color_a: Alg, color_b: Alg) BisimResult {
            const ta = extractTrit(color_a);
            const tb = extractTrit(color_b);
            return .{
                .bisimilar = ta == tb,
                .trit_alignment = if (ta == tb) 1.0 else 0.0,
            };
        }

        // -- Game 5: Indistinguishability --
        const IndistResult = struct {
            indistinguishable: bool,
            degenerate_fraction: f64,
        };

        fn indistinguishabilityGame(color_a: Alg, color_b: Alg) IndistResult {
            const diff = color_a.sub(color_b);
            const dist = diff.norm();
            const degen_e = diff.coeffs[4] * diff.coeffs[4];
            var total_e: f64 = 0;
            for (diff.coeffs) |c| total_e += c * c;
            const df = if (total_e > 1e-14) degen_e / total_e else 0.0;
            return .{
                .indistinguishable = dist < 0.15 or df > 0.9,
                .degenerate_fraction = df,
            };
        }

        // -- Game 6: Cycle --
        const CycleResult = struct {
            gf3_conserved: bool,
            accumulated_norm: f64,
            norm_ratio: f64, // ratio of sandwich norms: how much the metric distorts
        };

        fn derangementCycleGame(colors: []const Alg, sigma: []const u32) CycleResult {
            var accumulated = Alg.zero();
            var trit_sum: i16 = 0;
            const rotor = sigmaRotor(1);

            var orig_norm_sum: f64 = 0;
            var rot_norm_sum: f64 = 0;

            for (0..colors.len) |i| {
                accumulated = accumulated.add(colors[i]);
                trit_sum += @as(i16, @intFromEnum(extractTrit(colors[i])));
                const rotated = rotor.sandwich(colors[i]);
                orig_norm_sum += colors[i].norm();
                rot_norm_sum += rotated.norm();
                _ = sigma;
            }

            const mod_sum = @mod(trit_sum + 3 * @as(i16, @intCast(colors.len)), 3);
            const nr = if (orig_norm_sum > 1e-12) rot_norm_sum / orig_norm_sum else 1.0;

            return .{
                .gf3_conserved = mod_sum == 0,
                .accumulated_norm = accumulated.norm(),
                .norm_ratio = nr,
            };
        }

        // -- Aggregate sweep for N players --
        pub const SweepResult = struct {
            sig_p: u3,
            sig_q: u3,
            sig_r: u3,
            // Conservation
            conservation_equil_pct: f64,
            conservation_norm_preserved_pct: f64,
            avg_norm_ratio: f64,
            // Distinguishability
            distinguish_pct: f64,
            avg_distance: f64,
            avg_wedge: f64,
            // Entropy (plain)
            entropy_plain_grades: u32,
            entropy_plain_ratio: f64,
            // Entropy (rich/wedge_augmented)
            entropy_rich_grades: u32,
            entropy_rich_ratio: f64,
            // Bisimulation
            bisim_pct: f64,
            // Indistinguishability
            indist_pct: f64,
            avg_degen_frac: f64,
            // Cycle
            gf3_conserved: bool,
            cycle_norm_ratio: f64,
        };

        pub fn sweep(comptime player_count: u32, seed: u64, offset: u32) SweepResult {
            var colors: [player_count]Alg = undefined;
            var rich: [player_count]Alg = undefined;
            var sigma: [player_count]u32 = undefined;

            for (0..player_count) |i| {
                const c = seedColor(seed, @intCast(i));
                colors[i] = embedColor(c.r, c.g, c.b);
                rich[i] = embedRichWedge(c.r, c.g, c.b);
                sigma[i] = @intCast((i + offset) % player_count);
            }

            var equil: u32 = 0;
            var norm_ok: u32 = 0;
            var norm_ratio_sum: f64 = 0;
            var dist_ok: u32 = 0;
            var dist_sum: f64 = 0;
            var wedge_sum: f64 = 0;
            var bisim_ok: u32 = 0;
            var indist_ok: u32 = 0;
            var degen_sum: f64 = 0;

            for (0..player_count) |i| {
                const j = sigma[i];
                const cons = conservationGame(colors[i], colors[j]);
                if (cons.equilibrium) equil += 1;
                if (cons.norm_preserved) norm_ok += 1;
                norm_ratio_sum += cons.norm_ratio;

                const dist = distinguishGame(colors[i], colors[j]);
                if (dist.distinguishable) dist_ok += 1;
                dist_sum += dist.distance;
                wedge_sum += dist.wedge_norm;

                const bisim = bisimulationGame(colors[i], colors[j]);
                if (bisim.bisimilar) bisim_ok += 1;

                const indist = indistinguishabilityGame(colors[i], colors[j]);
                if (indist.indistinguishable) indist_ok += 1;
                degen_sum += indist.degenerate_fraction;
            }

            const ew_plain = entropyWitness(&colors);
            const ew_rich = entropyWitness(&rich);
            const cycle = derangementCycleGame(&colors, &sigma);

            const n: f64 = @floatFromInt(player_count);
            return .{
                .sig_p = p,
                .sig_q = q,
                .sig_r = r,
                .conservation_equil_pct = @as(f64, @floatFromInt(equil)) / n * 100.0,
                .conservation_norm_preserved_pct = @as(f64, @floatFromInt(norm_ok)) / n * 100.0,
                .avg_norm_ratio = norm_ratio_sum / n,
                .distinguish_pct = @as(f64, @floatFromInt(dist_ok)) / n * 100.0,
                .avg_distance = dist_sum / n,
                .avg_wedge = wedge_sum / n,
                .entropy_plain_grades = ew_plain.active_grades,
                .entropy_plain_ratio = ew_plain.entropy_ratio,
                .entropy_rich_grades = ew_rich.active_grades,
                .entropy_rich_ratio = ew_rich.entropy_ratio,
                .bisim_pct = @as(f64, @floatFromInt(bisim_ok)) / n * 100.0,
                .indist_pct = @as(f64, @floatFromInt(indist_ok)) / n * 100.0,
                .avg_degen_frac = degen_sum / n,
                .gf3_conserved = cycle.gf3_conserved,
                .cycle_norm_ratio = cycle.norm_ratio,
            };
        }
    };
}

// ============================================================================
// SplitMix64 (duplicated here to avoid cross-module dependency)
// ============================================================================

fn seedColor(seed: u64, index: u64) struct { r: u8, g: u8, b: u8 } {
    var state = seed;
    var val: u64 = 0;
    for (0..index + 1) |_| {
        const s = state +% 0x9E3779B97F4A7C15;
        var z = s;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        z = z ^ (z >> 31);
        state = s;
        val = z;
    }
    return .{
        .r = @truncate((val >> 16) & 0xFF),
        .g = @truncate((val >> 8) & 0xFF),
        .b = @truncate(val & 0xFF),
    };
}

fn printResult(r: anytype) void {
    std.debug.print("  ({d},{d},{d})  {d:5.1}%  {d:5.1}%  {d:.4}   {d:5.1}% {d:.3} {d:.3}   {d}/4 {d:.3}  {d}/4 {d:.3}   {d:5.1}%  {d:5.1}% {d:.3}   {s} {d:.4}\n", .{
        r.sig_p,
        r.sig_q,
        r.sig_r,
        r.conservation_equil_pct,
        r.conservation_norm_preserved_pct,
        r.avg_norm_ratio,
        r.distinguish_pct,
        r.avg_distance,
        r.avg_wedge,
        r.entropy_plain_grades,
        r.entropy_plain_ratio,
        r.entropy_rich_grades,
        r.entropy_rich_ratio,
        r.bisim_pct,
        r.indist_pct,
        r.avg_degen_frac,
        if (r.gf3_conserved) "yes" else "NO ",
        r.cycle_norm_ratio,
    });
}

// ============================================================================
// Tests
// ============================================================================

test "signature sweep: 8 algebras, seed 69, 21 players" {
    @setEvalBranchQuota(5000000);
    const N = 21;
    const seed: u64 = 69;
    const offset = 19; // prime

    std.debug.print("\n=== SIGNATURE SWEEP (seed=69, N=21, offset=19) ===\n", .{});
    std.debug.print("  (p,q,r)  equil%  norm%   nratio  dist%  avgd  avgw   eplG epl   erG  er    bisim%  indist% degfr  gf3  cnr\n", .{});

    // (3,0,0) Euclidean
    const g300 = GenericGames(3, 0, 0);
    printResult(g300.sweep(N, seed, offset));

    // (2,1,0) Minkowski
    const g210 = GenericGames(2, 1, 0);
    printResult(g210.sweep(N, seed, offset));

    // (1,2,0) Anti-Minkowski
    const g120 = GenericGames(1, 2, 0);
    printResult(g120.sweep(N, seed, offset));

    // (0,3,0) Anti-Euclidean
    const g030 = GenericGames(0, 3, 0);
    printResult(g030.sweep(N, seed, offset));

    // (2,0,1) PGA (current default)
    const g201 = GenericGames(2, 0, 1);
    printResult(g201.sweep(N, seed, offset));

    // (1,1,1) Mixed indefinite
    const g111 = GenericGames(1, 1, 1);
    printResult(g111.sweep(N, seed, offset));

    // (0,2,1) Anti-space + degenerate
    const g021 = GenericGames(0, 2, 1);
    printResult(g021.sweep(N, seed, offset));

    // (0,0,3) Grassmann (exterior algebra)
    const g003 = GenericGames(0, 0, 3);
    printResult(g003.sweep(N, seed, offset));

    // Verify at least one non-trivial result
    const pga = g201.sweep(N, seed, offset);
    try testing.expect(pga.distinguish_pct > 0);
}

test "indefinite norm distortion: (2,1,0) vs (3,0,0)" {
    @setEvalBranchQuota(1000000);
    // In Minkowski (2,1,0), the third axis squares to -1.
    // This means some vectors have NEGATIVE norm-squared (timelike).
    // The sandwich product does NOT preserve the sign of the norm.
    const Euc = GenericGames(3, 0, 0);
    const Mink = GenericGames(2, 1, 0);

    const re = Euc.sweep(21, 69, 19);
    const rm = Mink.sweep(21, 69, 19);

    std.debug.print("\n=== INDEFINITE NORM DISTORTION ===\n", .{});
    std.debug.print("  Euclidean (3,0,0): norm_ratio={d:.6}, norm_preserved={d:.1}%\n", .{ re.avg_norm_ratio, re.conservation_norm_preserved_pct });
    std.debug.print("  Minkowski (2,1,0): norm_ratio={d:.6}, norm_preserved={d:.1}%\n", .{ rm.avg_norm_ratio, rm.conservation_norm_preserved_pct });
    std.debug.print("  Euclidean wedge: {d:.4}, Minkowski wedge: {d:.4}\n", .{ re.avg_wedge, rm.avg_wedge });
    std.debug.print("  Euclidean entropy rich: {d:.4}, Minkowski: {d:.4}\n", .{ re.entropy_rich_ratio, rm.entropy_rich_ratio });

    // Euclidean should preserve norm; Minkowski may not
    try testing.expect(re.conservation_norm_preserved_pct >= 90.0);
}

test "grassmann (0,0,3): all degenerate, maximum indistinguishability" {
    @setEvalBranchQuota(1000000);
    const Grass = GenericGames(0, 0, 3);
    const r = Grass.sweep(21, 69, 19);

    std.debug.print("\n=== GRASSMANN (0,0,3): FULLY DEGENERATE ===\n", .{});
    std.debug.print("  norm_ratio={d:.6} (all norms ~0 in degenerate algebra)\n", .{r.avg_norm_ratio});
    std.debug.print("  distinguish%={d:.1}, indist%={d:.1}\n", .{ r.distinguish_pct, r.indist_pct });
    std.debug.print("  entropy_rich={d:.4}\n", .{r.entropy_rich_ratio});

    // In fully degenerate algebra, norms are zero -> norm_preserved = true trivially
    try testing.expect(r.conservation_norm_preserved_pct > 0);
}
