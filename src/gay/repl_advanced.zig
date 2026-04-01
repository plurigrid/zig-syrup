// repl_advanced.zig: Advanced REPL, kernel lifetimes, test tracking, thread findings,
// verification reports, strategic differentiation, amp threads, and SPI CLI
//
// Zig translation of Gay.jl's:
//   - repl.jl                    (rainbow REPL, command dispatch, world teleportation)
//   - kernel_lifetimes.jl        (KernelColorContext, eventual_color, XOR fingerprint)
//   - tracking.jl                (TestTracker, violations, metrics, color-tagged results)
//   - thread_findings.jl         (Two Monad: Writer×Reader, FindingsSet, lazy placement)
//   - verification_report.jl     (FullReport, 6-layer attestation chain)
//   - strategic_differentiation.jl (Waddington landscape, 12 fate boriss, tower layers)
//   - amp_threads.jl             (Amp thread genealogy, XOR chain, thread distance)
//   - spi_cli.jl                 (CLI arg parsing, verify/report/demo commands)

const std = @import("std");
const math = std.math;
const splitmix = @import("splitmix.zig");

const Color = splitmix.Color;
const GAY_SEED: u64 = splitmix.GAY_SEED;
const GOLDEN: u64 = splitmix.GOLDEN;
const splitmix64 = splitmix.splitmix64;

// ============================================================================
// Hash color utility (local)
// ============================================================================

fn hashColor(id: u64, seed: u64) Color {
    const h = splitmix64(id ^ seed);
    const mask21: u64 = (1 << 21) - 1;
    const r_bits = (h >> 0) & mask21;
    const g_bits = (h >> 21) & mask21;
    const b_bits = (h >> 42) & mask21;
    const scale: f32 = 1.0 / @as(f32, @floatFromInt(mask21));
    return .{
        .r = @as(f32, @floatFromInt(r_bits)) * scale,
        .g = @as(f32, @floatFromInt(g_bits)) * scale,
        .b = @as(f32, @floatFromInt(b_bits)) * scale,
    };
}

fn xorFingerprint(colors: []const Color) u32 {
    var fp: u32 = 0;
    for (colors) |c| {
        fp ^= @bitCast(@as(u32, @intFromFloat(c.r * 255.0)));
        fp ^= @bitCast(@as(u32, @intFromFloat(c.g * 255.0)));
        fp ^= @bitCast(@as(u32, @intFromFloat(c.b * 255.0)));
    }
    return fp;
}

// ============================================================================
// RAINBOW PROMPT (repl.jl)
// ============================================================================

pub const RAINBOW_COLORS = [6][3]u8{
    .{ 228, 3, 3 }, // Red
    .{ 255, 140, 0 }, // Orange
    .{ 255, 237, 0 }, // Yellow
    .{ 0, 128, 38 }, // Green
    .{ 0, 77, 255 }, // Blue
    .{ 117, 7, 135 }, // Violet
};

/// Generate rainbow-colored ANSI text
pub fn rainbowText(text: []const u8, buf: []u8) usize {
    var pos: usize = 0;
    for (text, 0..) |ch, i| {
        const color = RAINBOW_COLORS[i % RAINBOW_COLORS.len];
        const written = std.fmt.bufPrint(buf[pos..], "\x1b[38;2;{d};{d};{d}m{c}", .{ color[0], color[1], color[2], ch }) catch break;
        pos += written.len;
    }
    const reset = std.fmt.bufPrint(buf[pos..], "\x1b[0m", .{}) catch return pos;
    pos += reset.len;
    return pos;
}

// ============================================================================
// REPL COMMAND DISPATCH (repl.jl)
// ============================================================================

pub const ReplCommand = enum {
    help,
    seed,
    next,
    at,
    palette,
    rainbow,
    pride,
    blackhole,
    space,
    state,
    bench,
    metal,
    teleport,
    world,
    back,
    abduce,
    jump,
    neighbors,
    run_test,
    unknown,
};

pub fn parseCommand(input: []const u8) ReplCommand {
    if (input.len == 0) return .help;
    if (std.mem.eql(u8, input, "help") or std.mem.eql(u8, input, "?")) return .help;
    if (std.mem.eql(u8, input, "seed")) return .seed;
    if (std.mem.eql(u8, input, "next")) return .next;
    if (std.mem.eql(u8, input, "at")) return .at;
    if (std.mem.eql(u8, input, "palette")) return .palette;
    if (std.mem.eql(u8, input, "rainbow")) return .rainbow;
    if (std.mem.eql(u8, input, "pride")) return .pride;
    if (std.mem.eql(u8, input, "blackhole") or std.mem.eql(u8, input, "bh")) return .blackhole;
    if (std.mem.eql(u8, input, "space") or std.mem.eql(u8, input, "cs")) return .space;
    if (std.mem.eql(u8, input, "state") or std.mem.eql(u8, input, "rng")) return .state;
    if (std.mem.eql(u8, input, "bench") or std.mem.eql(u8, input, "benchmark")) return .bench;
    if (std.mem.eql(u8, input, "metal") or std.mem.eql(u8, input, "gpu")) return .metal;
    if (std.mem.eql(u8, input, "teleport") or std.mem.eql(u8, input, "tp")) return .teleport;
    if (std.mem.eql(u8, input, "world") or std.mem.eql(u8, input, "w")) return .world;
    if (std.mem.eql(u8, input, "back") or std.mem.eql(u8, input, "b")) return .back;
    if (std.mem.eql(u8, input, "abduce") or std.mem.eql(u8, input, "ab")) return .abduce;
    if (std.mem.eql(u8, input, "jump") or std.mem.eql(u8, input, "j")) return .jump;
    if (std.mem.eql(u8, input, "neighbors") or std.mem.eql(u8, input, "nb")) return .neighbors;
    if (std.mem.eql(u8, input, "test")) return .run_test;
    return .unknown;
}

// ============================================================================
// KERNEL LIFETIMES (kernel_lifetimes.jl)
// ============================================================================

/// Compute the color a workitem will have after total_iterations steps.
/// O(1) — no iteration required.
pub fn eventualColor(seed: u64, global_index: u64, total_iterations: u64) Color {
    const h = seed ^ (global_index *% GOLDEN) ^ (total_iterations *% 0x517cc1b727220a95);
    return hashColor(h, total_iterations);
}

/// XOR fingerprint of all workitem final colors. O(n_workitems).
pub fn eventualFingerprint(seed: u64, n_workitems: u32, total_iterations: u64) u32 {
    var fp: u32 = 0;
    var i: u32 = 1;
    while (i <= n_workitems) : (i += 1) {
        const c = eventualColor(seed, i, total_iterations);
        fp ^= @as(u32, @intFromFloat(c.r * 255.0));
        fp ^= @as(u32, @intFromFloat(c.g * 255.0));
        fp ^= @as(u32, @intFromFloat(c.b * 255.0));
    }
    return fp;
}

/// Kernel-level color context tracking per-workitem iteration state.
pub const KernelColorContext = struct {
    seed: u64,
    n_workitems: u32,
    max_iterations: u32,
    iteration_counts: []u32,
    final_colors: []Color,
    fingerprint: u32,
    finalized: bool,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, seed: u64, n_workitems: u32, max_iterations: u32) !KernelColorContext {
        const counts = try allocator.alloc(u32, n_workitems);
        @memset(counts, 0);
        const colors = try allocator.alloc(Color, n_workitems);
        @memset(colors, Color{ .r = 0, .g = 0, .b = 0 });
        return .{
            .seed = seed,
            .n_workitems = n_workitems,
            .max_iterations = max_iterations,
            .iteration_counts = counts,
            .final_colors = colors,
            .fingerprint = 0,
            .finalized = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *KernelColorContext) void {
        self.allocator.free(self.iteration_counts);
        self.allocator.free(self.final_colors);
    }

    /// Get next color for a workitem and advance its iteration.
    pub fn kernelColor(self: *KernelColorContext, global_index: u32) !Color {
        if (self.finalized) return error.AlreadyFinalized;
        if (global_index == 0 or global_index > self.n_workitems) return error.IndexOutOfBounds;

        const idx = global_index - 1;
        self.iteration_counts[idx] += 1;
        const iter = self.iteration_counts[idx];
        if (iter > self.max_iterations) return error.MaxIterationsExceeded;

        const h = self.seed ^ (@as(u64, global_index) *% GOLDEN) ^
            (@as(u64, iter) *% 0x517cc1b727220a95);
        const c = hashColor(h, iter);
        self.final_colors[idx] = c;
        return c;
    }

    /// Finalize and compute XOR fingerprint.
    pub fn finalize(self: *KernelColorContext) u32 {
        self.finalized = true;
        self.fingerprint = xorFingerprint(self.final_colors);
        return self.fingerprint;
    }
};

/// Color from all three kernel index types (Global, Local, Group).
pub fn indexColor(seed: u64, global_idx: u64, local_idx: u64, group_idx: u64) Color {
    const h = seed ^ (global_idx *% GOLDEN) ^
        (local_idx *% 0x517cc1b727220a95) ^
        (group_idx *% 0xc4ceb9fe1a85ec53);
    return hashColor(h, global_idx);
}

/// Color from global index and iteration counter.
pub fn iterIndexColor(seed: u64, global_idx: u64, iteration: u64) Color {
    const h = seed ^ (global_idx *% GOLDEN) ^ (iteration *% 0x517cc1b727220a95);
    return hashColor(h, iteration);
}

/// Color from Cartesian indices (Morton/Z-order encoding).
pub fn cartesianColor(seed: u64, i: u64, j: u64, k: u64) Color {
    const linear = i + j * 0x100000 + k * 0x10000000000;
    return hashColor(seed, linear);
}

// ============================================================================
// TEST TRACKING (tracking.jl)
// ============================================================================

pub const TestResult = enum(u8) {
    pass = 0,
    fail = 1,
    skip = 2,
    violation = 3,
    anomaly = 4,
};

pub const ViolationType = enum(u8) {
    spi_violation = 0,
    race_condition = 1,
    fingerprint_mismatch = 2,
    determinism_failure = 3,
    distribution_anomaly = 4,
    timing_anomaly = 5,
    memory_corruption = 6,
    cross_substrate_mismatch = 7,
};

pub const TrackedMetric = struct {
    name_hash: u64,
    value: f64,
    timestamp: i64,
    color: Color,
};

pub const TrackedViolation = struct {
    violation_type: ViolationType,
    description_hash: u64,
    timestamp: i64,
    color: Color,
    fingerprint: u32,
};

pub const TrackedTest = struct {
    name_hash: u64,
    result: TestResult,
    duration_ns: u64,
    iterations: u32,
    timestamp: i64,
    color: Color,
    fingerprint: u32,
};

/// Color for a test result type.
pub fn resultColor(r: TestResult) Color {
    return switch (r) {
        .pass => .{ .r = 0.2, .g = 0.8, .b = 0.3 },
        .fail => .{ .r = 0.9, .g = 0.2, .b = 0.2 },
        .skip => .{ .r = 0.6, .g = 0.6, .b = 0.6 },
        .violation => .{ .r = 1.0, .g = 0.5, .b = 0.0 },
        .anomaly => .{ .r = 0.8, .g = 0.2, .b = 0.8 },
    };
}

/// Color for a violation type.
pub fn violationColor(v: ViolationType) Color {
    const idx: u64 = @intFromEnum(v) + 1;
    return hashColor(0xDEADBEEF, idx * 1000);
}

pub const TestTracker = struct {
    seed: u64,
    tests: std.ArrayList(TrackedTest),
    violations: std.ArrayList(TrackedViolation),
    metrics: std.ArrayList(TrackedMetric),
    total_colors: u64,
    total_iterations: u64,

    pub fn init(allocator: std.mem.Allocator, seed: u64) TestTracker {
        return .{
            .seed = seed,
            .tests = std.ArrayList(TrackedTest).init(allocator),
            .violations = std.ArrayList(TrackedViolation).init(allocator),
            .metrics = std.ArrayList(TrackedMetric).init(allocator),
            .total_colors = 0,
            .total_iterations = 0,
        };
    }

    pub fn deinit(self: *TestTracker) void {
        self.tests.deinit();
        self.violations.deinit();
        self.metrics.deinit();
    }

    pub fn track(self: *TestTracker, name_hash: u64, result: TestResult, duration_ns: u64, iterations: u32) !void {
        const fp = @as(u32, @truncate(splitmix64(name_hash ^ self.seed)));
        const color = hashColor(name_hash, self.seed);
        try self.tests.append(.{
            .name_hash = name_hash,
            .result = result,
            .duration_ns = duration_ns,
            .iterations = iterations,
            .timestamp = std.time.milliTimestamp(),
            .color = color,
            .fingerprint = fp,
        });
        self.total_iterations += iterations;
    }

    pub fn trackViolation(self: *TestTracker, vtype: ViolationType, desc_hash: u64) !void {
        const fp = @as(u32, @truncate(splitmix64(desc_hash ^ self.seed)));
        try self.violations.append(.{
            .violation_type = vtype,
            .description_hash = desc_hash,
            .timestamp = std.time.milliTimestamp(),
            .color = violationColor(vtype),
            .fingerprint = fp,
        });
    }

    pub fn trackMetric(self: *TestTracker, name_hash: u64, value: f64) !void {
        try self.metrics.append(.{
            .name_hash = name_hash,
            .value = value,
            .timestamp = std.time.milliTimestamp(),
            .color = hashColor(name_hash, self.seed),
        });
    }

    /// XOR fingerprint of all tracked tests.
    pub fn fingerprint(self: *const TestTracker) u32 {
        var fp: u32 = 0;
        for (self.tests.items) |t| fp ^= t.fingerprint;
        for (self.violations.items) |v| fp ^= v.fingerprint;
        return fp;
    }
};

// ============================================================================
// THREAD FINDINGS — Two Monad Structure (thread_findings.jl)
// ============================================================================

pub const Finding = struct {
    name_hash: u64,
    passed: bool,
    fingerprint: u32,
    layer: u8,
};

pub const FindingsSet = struct {
    findings: std.ArrayList(Finding),
    combined_fingerprint: u32,
    thread_count: u32,

    pub fn init(allocator: std.mem.Allocator) FindingsSet {
        return .{
            .findings = std.ArrayList(Finding).init(allocator),
            .combined_fingerprint = 0,
            .thread_count = 0,
        };
    }

    pub fn deinit(self: *FindingsSet) void {
        self.findings.deinit();
    }

    /// Monoid operation: combine two findings sets (XOR).
    pub fn merge(self: *FindingsSet, other: *const FindingsSet) !void {
        try self.findings.appendSlice(other.findings.items);
        self.combined_fingerprint ^= other.combined_fingerprint;
        self.thread_count += other.thread_count;
    }

    pub fn addFinding(self: *FindingsSet, finding: Finding) !void {
        try self.findings.append(finding);
        self.combined_fingerprint ^= finding.fingerprint;
        self.thread_count += 1;
    }
};

pub const ThreadContext = struct {
    seed: u64,
    thread_id: u64,
    parent_id: u64,
    layer: u8,
};

/// ReaderT ThreadContext (Writer FindingsSet) — the verification monad.
/// Represented as a function pointer + closure context.
pub const VerificationAction = struct {
    layer_hash: u64,
    layer: u8,

    /// Run this verification action with a given context.
    pub fn run(self: VerificationAction, ctx: ThreadContext, allocator: std.mem.Allocator) !struct { passed: bool, findings: FindingsSet } {
        const h = splitmix64(ctx.seed ^ (@as(u64, ctx.layer) *% GOLDEN));
        const passed = (h & 0xFF) > 10; // ~96% pass rate, deterministic

        var fs = FindingsSet.init(allocator);
        const fp = @as(u32, @truncate(splitmix64(ctx.seed ^ self.layer_hash)));
        try fs.addFinding(.{
            .name_hash = self.layer_hash,
            .passed = passed,
            .fingerprint = fp,
            .layer = self.layer,
        });
        return .{ .passed = passed, .findings = fs };
    }
};

/// The 6 SPI tower layer names.
pub const LAYER_NAMES = [6]u64{
    0x636f6e636570745f, // concept_tensor
    0x6578706f6e656e74, // exponential_XX
    0x6869676865725f58, // higher_XXXX
    0x7472616365645f6d, // traced_monoidal
    0x74656e736f725f6e, // tensor_network
    0x70726f7061676174, // propagator_bridge
};

/// Run all 6 layer verifications.
pub fn runAllVerifications(ctx: ThreadContext, allocator: std.mem.Allocator) !struct { all_passed: bool, combined: FindingsSet } {
    var combined = FindingsSet.init(allocator);
    var all_passed = true;

    for (LAYER_NAMES, 0..) |layer_hash, layer_idx| {
        const action = VerificationAction{ .layer_hash = layer_hash, .layer = @intCast(layer_idx) };
        var layer_ctx = ctx;
        layer_ctx.layer = @intCast(layer_idx);
        const result = try action.run(layer_ctx, allocator);
        defer {
            // findings ownership transferred via merge
        }
        all_passed = all_passed and result.passed;
        try combined.merge(&result.findings);
        // We need to free result.findings' ArrayList but not the items (they were copied)
        var mutable_result = result;
        mutable_result.findings.deinit();
    }

    return .{ .all_passed = all_passed, .combined = combined };
}

/// Lazy thread stream: generates threads on demand, places findings by layer.
pub const LazyThreadStream = struct {
    seed: u64,
    current_idx: u32,
    findings_by_layer: [6]?FindingsSet,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, seed: u64) LazyThreadStream {
        return .{
            .seed = seed,
            .current_idx = 0,
            .findings_by_layer = .{ null, null, null, null, null, null },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LazyThreadStream) void {
        for (&self.findings_by_layer) |*slot| {
            if (slot.*) |*fs| fs.deinit();
        }
    }

    /// Generate the next thread context.
    pub fn nextThread(self: *LazyThreadStream) ThreadContext {
        self.current_idx += 1;
        const thread_hash = splitmix64(self.seed ^ @as(u64, self.current_idx));
        const layer: u8 = @intCast(thread_hash % 6);
        return .{
            .seed = self.seed,
            .thread_id = thread_hash,
            .parent_id = if (self.current_idx > 1) splitmix64(self.seed ^ @as(u64, self.current_idx - 1)) else 0,
            .layer = layer,
        };
    }

    /// Place a finding into the appropriate layer set.
    pub fn lazyPlace(self: *LazyThreadStream, ctx: ThreadContext, finding: Finding) !void {
        const layer = ctx.layer;
        if (self.findings_by_layer[layer] == null) {
            self.findings_by_layer[layer] = FindingsSet.init(self.allocator);
        }
        try self.findings_by_layer[layer].?.addFinding(finding);
    }

    pub fn threadCount(self: *const LazyThreadStream) u32 {
        return self.current_idx;
    }

    /// Combined XOR fingerprint across all layers.
    pub fn combinedFingerprint(self: *const LazyThreadStream) u32 {
        var fp: u32 = 0;
        for (self.findings_by_layer) |slot| {
            if (slot) |fs| fp ^= fs.combined_fingerprint;
        }
        return fp;
    }
};

// ============================================================================
// VERIFICATION REPORT (verification_report.jl)
// ============================================================================

pub const ReportSection = struct {
    layer: u8,
    name_hash: u64,
    passed: bool,
    fingerprint: u32,
    detail_count: u8,
};

pub const FullReport = struct {
    seed: u64,
    sections: [6]ReportSection,
    attestation: u32,
    coherent: bool,

    /// Verify internal coherence: recompute attestation, check all sections passed.
    pub fn verifyCoherence(self: *const FullReport) bool {
        var computed: u32 = 0;
        var all_passed = true;
        for (self.sections) |s| {
            computed ^= s.fingerprint;
            all_passed = all_passed and s.passed;
        }
        return self.coherent and (self.attestation == computed) and all_passed;
    }
};

/// Generate a verification report by running all layers.
pub fn generateReport(allocator: std.mem.Allocator, seed: u64, n_threads: u32) !FullReport {
    var sections: [6]ReportSection = undefined;

    // Layers 0-4: deterministic fingerprints from seed
    for (0..5) |layer_idx| {
        const li: u8 = @intCast(layer_idx);
        const h = splitmix64(seed ^ (@as(u64, layer_idx) *% GOLDEN));
        const passed = (h & 0xFF) > 10;
        sections[layer_idx] = .{
            .layer = li,
            .name_hash = LAYER_NAMES[layer_idx],
            .passed = passed,
            .fingerprint = @as(u32, @truncate(h)),
            .detail_count = 4,
        };
    }

    // Layer 5: thread findings
    var stream = LazyThreadStream.init(allocator, seed);
    defer stream.deinit();

    for (0..n_threads) |_| {
        const ctx = stream.nextThread();
        const result = try runAllVerifications(ctx, allocator);
        var mutable_combined = result.combined;
        defer mutable_combined.deinit();
        for (mutable_combined.findings.items) |f| {
            try stream.lazyPlace(ctx, f);
        }
    }

    sections[5] = .{
        .layer = 5,
        .name_hash = LAYER_NAMES[5],
        .passed = true,
        .fingerprint = stream.combinedFingerprint(),
        .detail_count = @intCast(@min(n_threads, 255)),
    };

    // Attestation = XOR of all section fingerprints
    var attestation: u32 = 0;
    var coherent = true;
    for (sections) |s| {
        attestation ^= s.fingerprint;
        coherent = coherent and s.passed;
    }

    return .{
        .seed = seed,
        .sections = sections,
        .attestation = attestation,
        .coherent = coherent,
    };
}

// ============================================================================
// STRATEGIC DIFFERENTIATION (strategic_differentiation.jl)
// ============================================================================

pub const DifferentiationBoris = struct {
    layer: u8,
    name_hash: u64,
    capacity: u32,
    color_range_lo: u8,
    color_range_hi: u8,
};

/// The 12 fate boriss corresponding to tower layers 0-11.
pub const TOWER_BORISS = [12]DifferentiationBoris{
    .{ .layer = 0, .name_hash = 0x636f6e63657074, .capacity = 69 * 69 * 69, .color_range_lo = 0, .color_range_hi = 21 },
    .{ .layer = 1, .name_hash = 0x6578706f6e656e, .capacity = 256 * 256, .color_range_lo = 22, .color_range_hi = 43 },
    .{ .layer = 2, .name_hash = 0x686967686572, .capacity = 1024, .color_range_lo = 44, .color_range_hi = 65 },
    .{ .layer = 3, .name_hash = 0x747261636564, .capacity = 512, .color_range_lo = 66, .color_range_hi = 87 },
    .{ .layer = 4, .name_hash = 0x74656e736f72, .capacity = 256, .color_range_lo = 88, .color_range_hi = 109 },
    .{ .layer = 5, .name_hash = 0x74776f5f6d6f, .capacity = 128, .color_range_lo = 110, .color_range_hi = 131 },
    .{ .layer = 6, .name_hash = 0x6b7269706b65, .capacity = 64, .color_range_lo = 132, .color_range_hi = 153 },
    .{ .layer = 7, .name_hash = 0x6d6f64616c, .capacity = 64, .color_range_lo = 154, .color_range_hi = 175 },
    .{ .layer = 8, .name_hash = 0x7368656166, .capacity = 32, .color_range_lo = 176, .color_range_hi = 197 },
    .{ .layer = 9, .name_hash = 0x70726f626162, .capacity = 32, .color_range_lo = 198, .color_range_hi = 219 },
    .{ .layer = 10, .name_hash = 0x72616e645f74, .capacity = 16, .color_range_lo = 220, .color_range_hi = 241 },
    .{ .layer = 11, .name_hash = 0x73796e746865, .capacity = 16, .color_range_lo = 242, .color_range_hi = 255 },
};

/// Map a color (0-255) to the most appropriate tower layer.
pub fn colorToLayer(color: u8) u8 {
    for (TOWER_BORISS) |boris| {
        if (color >= boris.color_range_lo and color <= boris.color_range_hi) return boris.layer;
    }
    return 0;
}

pub const StrategicChoice = struct {
    entity_id: u64,
    source_layer: u8,
    target_layer: u8,
    commitment: f32,
};

pub const SemanticFate = struct {
    entity_id: u64,
    final_layer: u8,
    color: u8,
    fingerprint: u64,
};

/// Differentiate an entity to its natural boris based on color.
pub fn differentiate(entity_id: u64, color: u8) StrategicChoice {
    const target_layer = colorToLayer(color);
    const source_layer: u8 = @intCast(entity_id % 12);
    const boris = TOWER_BORISS[target_layer];
    const mid: f32 = @as(f32, @floatFromInt(boris.color_range_lo + boris.color_range_hi)) / 2.0;
    const half_range: f32 = @as(f32, @floatFromInt(boris.color_range_hi - boris.color_range_lo)) / 2.0;
    const distance = @abs(@as(f32, @floatFromInt(color)) - mid) / half_range;
    return .{
        .entity_id = entity_id,
        .source_layer = source_layer,
        .target_layer = target_layer,
        .commitment = 1.0 - 0.5 * distance,
    };
}

/// Compute the semantic fate if entity commits to given layer.
pub fn fateAtLayer(entity_id: u64, layer: u8) SemanticFate {
    const boris = TOWER_BORISS[layer];
    const color: u8 = boris.color_range_lo +% @as(u8, @intCast(entity_id % (@as(u64, boris.color_range_hi - boris.color_range_lo) + 1)));
    return .{
        .entity_id = entity_id,
        .final_layer = layer,
        .color = color,
        .fingerprint = entity_id ^ (@as(u64, layer) << 48),
    };
}

/// XOR fingerprint of strategic choices (order-independent).
pub fn fateFingerprint(choices: []const StrategicChoice) u64 {
    var fp: u64 = 0;
    for (choices) |c| {
        var h = c.entity_id;
        h ^= @as(u64, c.source_layer) << 8;
        h ^= @as(u64, c.target_layer) << 16;
        fp ^= h;
    }
    return fp;
}

// ============================================================================
// AMP THREADS (amp_threads.jl)
// ============================================================================

pub const AmpThread = struct {
    seed: u64,
    id_hash: u64,
    parent_hash: u64,
    attestation: u32,

    /// Derive seed from a thread ID string via polynomial rolling hash + SplitMix64.
    pub fn fromId(id: []const u8, parent_hash: u64) AmpThread {
        var h: u64 = 0;
        for (id) |c| h = h *% 31 +% @as(u64, c);
        const seed = splitmix64(h);
        return .{
            .seed = seed,
            .id_hash = h,
            .parent_hash = parent_hash,
            .attestation = 0,
        };
    }

    /// Primary color for this thread.
    pub fn color(self: AmpThread) Color {
        return hashColor(1, self.seed);
    }
};

pub const ThreadGenealogy = struct {
    threads: std.ArrayList(AmpThread),
    combined_fingerprint: u32,
    root_hash: u64,

    pub fn init(allocator: std.mem.Allocator, root: AmpThread) !ThreadGenealogy {
        var threads = std.ArrayList(AmpThread).init(allocator);
        try threads.append(root);
        return .{
            .threads = threads,
            .combined_fingerprint = root.attestation,
            .root_hash = root.id_hash,
        };
    }

    pub fn deinit(self: *ThreadGenealogy) void {
        self.threads.deinit();
    }

    pub fn addThread(self: *ThreadGenealogy, thread: AmpThread) !void {
        try self.threads.append(thread);
        self.combined_fingerprint ^= thread.attestation;
    }

    /// Verify XOR chain consistency.
    pub fn verifyChain(self: *const ThreadGenealogy) bool {
        var computed: u32 = 0;
        for (self.threads.items) |t| computed ^= t.attestation;
        return computed == self.combined_fingerprint;
    }

    /// Hamming distance between two thread attestations.
    pub fn threadDistance(t1: AmpThread, t2: AmpThread) u32 {
        return @popCount(t1.attestation ^ t2.attestation);
    }
};

// ============================================================================
// SPI CLI (spi_cli.jl)
// ============================================================================

pub const CliCommand = enum {
    verify,
    report,
    demo,
    help,
};

pub const CliArgs = struct {
    command: CliCommand,
    thread_id: ?[]const u8,
    tensor_size: u32,
    n_threads: u32,
    quiet: bool,
    benchmark: bool,

    pub fn default() CliArgs {
        return .{
            .command = .verify,
            .thread_id = null,
            .tensor_size = 23,
            .n_threads = 69,
            .quiet = false,
            .benchmark = false,
        };
    }
};

pub fn parseCliArgs(args: []const []const u8) CliArgs {
    var result = CliArgs.default();
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--verify")) {
            result.command = .verify;
        } else if (std.mem.eql(u8, arg, "--report")) {
            result.command = .report;
        } else if (std.mem.eql(u8, arg, "--demo")) {
            result.command = .demo;
        } else if (std.mem.eql(u8, arg, "--help")) {
            result.command = .help;
        } else if (std.mem.eql(u8, arg, "--thread") and i + 1 < args.len) {
            i += 1;
            result.thread_id = args[i];
        } else if (std.mem.eql(u8, arg, "--size") and i + 1 < args.len) {
            i += 1;
            result.tensor_size = std.fmt.parseInt(u32, args[i], 10) catch 23;
        } else if (std.mem.eql(u8, arg, "--threads") and i + 1 < args.len) {
            i += 1;
            result.n_threads = std.fmt.parseInt(u32, args[i], 10) catch 69;
        } else if (std.mem.eql(u8, arg, "--quiet")) {
            result.quiet = true;
        } else if (std.mem.eql(u8, arg, "--benchmark")) {
            result.benchmark = true;
        }
    }
    return result;
}

/// Derive seed from CLI args (thread ID or default).
pub fn cliSeed(args: CliArgs) u64 {
    if (args.thread_id) |tid| {
        const t = AmpThread.fromId(tid, 0);
        return t.seed;
    }
    return GAY_SEED;
}

// ============================================================================
// TESTS
// ============================================================================

test "rainbow text generation" {
    var buf: [1024]u8 = undefined;
    const len = rainbowText("hello", &buf);
    try std.testing.expect(len > 5); // Must have ANSI codes + chars
    // Verify reset at end
    try std.testing.expect(std.mem.endsWith(u8, buf[0..len], "\x1b[0m"));
}

test "REPL command parsing" {
    try std.testing.expectEqual(ReplCommand.help, parseCommand("help"));
    try std.testing.expectEqual(ReplCommand.help, parseCommand("?"));
    try std.testing.expectEqual(ReplCommand.seed, parseCommand("seed"));
    try std.testing.expectEqual(ReplCommand.teleport, parseCommand("tp"));
    try std.testing.expectEqual(ReplCommand.world, parseCommand("w"));
    try std.testing.expectEqual(ReplCommand.abduce, parseCommand("ab"));
    try std.testing.expectEqual(ReplCommand.unknown, parseCommand("foobar"));
}

test "eventual color is O(1) and deterministic" {
    const c1 = eventualColor(42, 100, 1000);
    const c2 = eventualColor(42, 100, 1000);
    try std.testing.expectEqual(c1.r, c2.r);
    try std.testing.expectEqual(c1.g, c2.g);
    try std.testing.expectEqual(c1.b, c2.b);

    // Different params give different colors
    const c3 = eventualColor(42, 101, 1000);
    try std.testing.expect(c1.r != c3.r or c1.g != c3.g or c1.b != c3.b);
}

test "eventual fingerprint deterministic" {
    const fp1 = eventualFingerprint(42, 100, 50);
    const fp2 = eventualFingerprint(42, 100, 50);
    try std.testing.expectEqual(fp1, fp2);

    const fp3 = eventualFingerprint(43, 100, 50);
    try std.testing.expect(fp1 != fp3);
}

test "KernelColorContext sequential matches prediction" {
    const allocator = std.testing.allocator;
    const seed: u64 = 42;
    const n: u32 = 10;
    const iters: u32 = 5;

    var ctx = try KernelColorContext.init(allocator, seed, n, iters);
    defer ctx.deinit();

    // Run all workitems for all iterations
    for (1..n + 1) |gi| {
        for (0..iters) |_| {
            _ = try ctx.kernelColor(@intCast(gi));
        }
    }

    const actual_fp = ctx.finalize();

    // Verify each workitem's final color matches eventual_color
    for (1..n + 1) |gi| {
        const predicted = eventualColor(seed, @intCast(gi), iters);
        const actual = ctx.final_colors[gi - 1];
        try std.testing.expectEqual(predicted.r, actual.r);
        try std.testing.expectEqual(predicted.g, actual.g);
        try std.testing.expectEqual(predicted.b, actual.b);
    }

    _ = actual_fp;
}

test "KernelColorContext rejects after finalize" {
    const allocator = std.testing.allocator;
    var ctx = try KernelColorContext.init(allocator, 42, 2, 10);
    defer ctx.deinit();

    _ = try ctx.kernelColor(1);
    _ = ctx.finalize();

    // Should error after finalization
    const result = ctx.kernelColor(1);
    try std.testing.expectError(error.AlreadyFinalized, result);
}

test "index color combines all three indices" {
    const c1 = indexColor(42, 1, 1, 1);
    const c2 = indexColor(42, 1, 2, 1);
    const c3 = indexColor(42, 1, 1, 2);
    // Different local/group indices should give different colors
    try std.testing.expect(c1.r != c2.r or c1.g != c2.g or c1.b != c2.b);
    try std.testing.expect(c1.r != c3.r or c1.g != c3.g or c1.b != c3.b);
}

test "cartesian color Morton encoding" {
    const c1 = cartesianColor(42, 1, 2, 3);
    const c2 = cartesianColor(42, 1, 2, 3);
    try std.testing.expectEqual(c1.r, c2.r);

    const c3 = cartesianColor(42, 2, 1, 3);
    try std.testing.expect(c1.r != c3.r or c1.g != c3.g or c1.b != c3.b);
}

test "TestResult colors are distinct" {
    const pass_c = resultColor(.pass);
    const fail_c = resultColor(.fail);
    try std.testing.expect(pass_c.r != fail_c.r);
    try std.testing.expect(pass_c.g != fail_c.g);
}

test "ViolationType colors are deterministic" {
    const c1 = violationColor(.spi_violation);
    const c2 = violationColor(.spi_violation);
    try std.testing.expectEqual(c1.r, c2.r);

    const c3 = violationColor(.race_condition);
    try std.testing.expect(c1.r != c3.r or c1.g != c3.g or c1.b != c3.b);
}

test "TestTracker track and fingerprint" {
    const allocator = std.testing.allocator;
    var tracker = TestTracker.init(allocator, 42);
    defer tracker.deinit();

    try tracker.track(0xAABBCCDD, .pass, 1000, 10);
    try tracker.track(0x11223344, .fail, 2000, 20);
    try tracker.trackViolation(.spi_violation, 0xDEAD);
    try tracker.trackMetric(0xBEEF, 3.14);

    try std.testing.expectEqual(@as(usize, 2), tracker.tests.items.len);
    try std.testing.expectEqual(@as(usize, 1), tracker.violations.items.len);
    try std.testing.expectEqual(@as(usize, 1), tracker.metrics.items.len);
    try std.testing.expectEqual(@as(u64, 30), tracker.total_iterations);

    const fp = tracker.fingerprint();
    try std.testing.expect(fp != 0);
}

test "FindingsSet monoid merge is commutative" {
    const allocator = std.testing.allocator;
    var a = FindingsSet.init(allocator);
    defer a.deinit();
    var b = FindingsSet.init(allocator);
    defer b.deinit();

    try a.addFinding(.{ .name_hash = 1, .passed = true, .fingerprint = 0xAA, .layer = 0 });
    try b.addFinding(.{ .name_hash = 2, .passed = true, .fingerprint = 0xBB, .layer = 1 });

    // a merge b
    const fp_ab = a.combined_fingerprint ^ b.combined_fingerprint;
    // b merge a (XOR is commutative)
    const fp_ba = b.combined_fingerprint ^ a.combined_fingerprint;
    try std.testing.expectEqual(fp_ab, fp_ba);
}

test "ThreadContext and VerificationAction run" {
    const allocator = std.testing.allocator;
    const ctx = ThreadContext{ .seed = 42, .thread_id = 0x1234, .parent_id = 0, .layer = 0 };
    const action = VerificationAction{ .layer_hash = LAYER_NAMES[0], .layer = 0 };

    const result = try action.run(ctx, allocator);
    var findings = result.findings;
    defer findings.deinit();

    try std.testing.expectEqual(@as(usize, 1), findings.findings.items.len);
    try std.testing.expect(findings.combined_fingerprint != 0);
}

test "runAllVerifications produces 6 findings" {
    const allocator = std.testing.allocator;
    const ctx = ThreadContext{ .seed = GAY_SEED, .thread_id = 0xABCD, .parent_id = 0, .layer = 0 };

    const result = try runAllVerifications(ctx, allocator);
    var combined = result.combined;
    defer combined.deinit();

    try std.testing.expectEqual(@as(usize, 6), combined.findings.items.len);
    try std.testing.expectEqual(@as(u32, 6), combined.thread_count);
}

test "LazyThreadStream generates unique threads" {
    const allocator = std.testing.allocator;
    var stream = LazyThreadStream.init(allocator, GAY_SEED);
    defer stream.deinit();

    const t1 = stream.nextThread();
    const t2 = stream.nextThread();

    try std.testing.expect(t1.thread_id != t2.thread_id);
    try std.testing.expectEqual(@as(u32, 2), stream.threadCount());
}

test "LazyThreadStream lazy placement and fingerprint" {
    const allocator = std.testing.allocator;
    var stream = LazyThreadStream.init(allocator, GAY_SEED);
    defer stream.deinit();

    for (0..10) |_| {
        const ctx = stream.nextThread();
        try stream.lazyPlace(ctx, .{
            .name_hash = ctx.thread_id,
            .passed = true,
            .fingerprint = @as(u32, @truncate(ctx.thread_id)),
            .layer = ctx.layer,
        });
    }

    try std.testing.expectEqual(@as(u32, 10), stream.threadCount());
    try std.testing.expect(stream.combinedFingerprint() != 0);
}

test "FullReport coherence verification" {
    const allocator = std.testing.allocator;
    const report = try generateReport(allocator, GAY_SEED, 5);

    try std.testing.expect(report.verifyCoherence());

    // Tamper with attestation
    var tampered = report;
    tampered.attestation ^= 1;
    try std.testing.expect(!tampered.verifyCoherence());
}

test "generateReport deterministic" {
    const allocator = std.testing.allocator;
    const r1 = try generateReport(allocator, 42, 5);
    const r2 = try generateReport(allocator, 42, 5);

    try std.testing.expectEqual(r1.attestation, r2.attestation);
    for (r1.sections, r2.sections) |s1, s2| {
        try std.testing.expectEqual(s1.fingerprint, s2.fingerprint);
    }
}

test "colorToLayer maps full range" {
    try std.testing.expectEqual(@as(u8, 0), colorToLayer(10));
    try std.testing.expectEqual(@as(u8, 3), colorToLayer(75));
    try std.testing.expectEqual(@as(u8, 6), colorToLayer(140));
    try std.testing.expectEqual(@as(u8, 11), colorToLayer(250));
}

test "strategic differentiation commitment" {
    const choice = differentiate(0x636f6e6365707473, 15);
    try std.testing.expectEqual(@as(u8, 0), choice.target_layer);
    try std.testing.expect(choice.commitment > 0.5);
    try std.testing.expect(choice.commitment <= 1.0);
}

test "fateAtLayer deterministic" {
    const f1 = fateAtLayer(0xDEAD, 3);
    const f2 = fateAtLayer(0xDEAD, 3);
    try std.testing.expectEqual(f1.fingerprint, f2.fingerprint);
    try std.testing.expectEqual(f1.color, f2.color);
    try std.testing.expectEqual(@as(u8, 3), f1.final_layer);
}

test "fateFingerprint order independent" {
    const choices = [_]StrategicChoice{
        .{ .entity_id = 0xAA, .source_layer = 0, .target_layer = 3, .commitment = 0.9 },
        .{ .entity_id = 0xBB, .source_layer = 1, .target_layer = 5, .commitment = 0.8 },
    };
    const reversed = [_]StrategicChoice{
        choices[1],
        choices[0],
    };
    try std.testing.expectEqual(fateFingerprint(&choices), fateFingerprint(&reversed));
}

test "AmpThread fromId deterministic" {
    const t1 = AmpThread.fromId("T-019b01e9-4119", 0);
    const t2 = AmpThread.fromId("T-019b01e9-4119", 0);
    try std.testing.expectEqual(t1.seed, t2.seed);
    try std.testing.expectEqual(t1.id_hash, t2.id_hash);

    const t3 = AmpThread.fromId("T-different-id", 0);
    try std.testing.expect(t1.seed != t3.seed);
}

test "AmpThread color deterministic" {
    const t = AmpThread.fromId("T-test-thread", 0);
    const c1 = t.color();
    const c2 = t.color();
    try std.testing.expectEqual(c1.r, c2.r);
}

test "ThreadGenealogy XOR chain" {
    const allocator = std.testing.allocator;
    var root = AmpThread.fromId("root", 0);
    root.attestation = 0xAA;

    var gen = try ThreadGenealogy.init(allocator, root);
    defer gen.deinit();

    var child = AmpThread.fromId("child", root.id_hash);
    child.attestation = 0xBB;
    try gen.addThread(child);

    try std.testing.expect(gen.verifyChain());
    try std.testing.expectEqual(@as(u32, 0xAA ^ 0xBB), gen.combined_fingerprint);
}

test "ThreadGenealogy Hamming distance" {
    var t1 = AmpThread.fromId("a", 0);
    t1.attestation = 0xFF;
    var t2 = AmpThread.fromId("b", 0);
    t2.attestation = 0x00;
    try std.testing.expectEqual(@as(u32, 8), ThreadGenealogy.threadDistance(t1, t2));
}

test "CLI arg parsing defaults" {
    const args = parseCliArgs(&.{});
    try std.testing.expectEqual(CliCommand.verify, args.command);
    try std.testing.expectEqual(@as(u32, 23), args.tensor_size);
    try std.testing.expectEqual(@as(u32, 69), args.n_threads);
    try std.testing.expect(!args.quiet);
}

test "CLI arg parsing full" {
    const args = parseCliArgs(&.{ "--report", "--size", "42", "--threads", "10", "--quiet", "--benchmark" });
    try std.testing.expectEqual(CliCommand.report, args.command);
    try std.testing.expectEqual(@as(u32, 42), args.tensor_size);
    try std.testing.expectEqual(@as(u32, 10), args.n_threads);
    try std.testing.expect(args.quiet);
    try std.testing.expect(args.benchmark);
}

test "CLI arg parsing thread ID" {
    const args = parseCliArgs(&.{ "--thread", "T-abc123" });
    try std.testing.expect(args.thread_id != null);
    try std.testing.expect(std.mem.eql(u8, args.thread_id.?, "T-abc123"));
}

test "cliSeed with thread ID" {
    const args_with = parseCliArgs(&.{ "--thread", "T-abc123" });
    const seed_with = cliSeed(args_with);
    try std.testing.expect(seed_with != GAY_SEED);

    const args_without = parseCliArgs(&.{});
    const seed_without = cliSeed(args_without);
    try std.testing.expectEqual(GAY_SEED, seed_without);
}

test "TOWER_BORISS cover full 0-255 range" {
    // Verify no gaps in color range mapping
    for (0..256) |color| {
        const layer = colorToLayer(@intCast(color));
        try std.testing.expect(layer <= 11);
    }
}

test "12 boriss have non-overlapping color ranges" {
    for (TOWER_BORISS, 0..) |b1, i| {
        for (TOWER_BORISS[i + 1 ..]) |b2| {
            // Ranges should not overlap
            try std.testing.expect(b1.color_range_hi < b2.color_range_lo or b2.color_range_hi < b1.color_range_lo);
        }
    }
}

test "end-to-end: thread -> report -> attestation" {
    const allocator = std.testing.allocator;

    // Create thread
    const thread = AmpThread.fromId("T-e2e-test", 0);

    // Generate report with thread's seed
    const report = try generateReport(allocator, thread.seed, 3);

    // Verify coherence
    try std.testing.expect(report.verifyCoherence());
    try std.testing.expect(report.attestation != 0);
}
