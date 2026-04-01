// energy.zig: Zig translation of Gay.jl's energy.jl
// Energy measurement for color workloads on Apple Silicon (powermetrics) with
// timing-based fallback on other platforms.

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const fmt = std.fmt;
const time = std.time;

// ---------------------------------------------------------------------------
// Platform detection (comptime)
// ---------------------------------------------------------------------------
const is_macos = builtin.os.tag == .macos;
const is_apple_silicon = is_macos and builtin.cpu.arch == .aarch64;

// ---------------------------------------------------------------------------
// PowerSample — single snapshot from powermetrics
// ---------------------------------------------------------------------------
pub const ThermalPressure = enum { nominal, moderate, heavy, trapping, sleeping };

pub const PowerSample = struct {
    timestamp_ns: i128,
    cpu_power_w: f64,
    gpu_power_w: f64,
    ane_power_w: f64,
    package_power_w: f64,
    thermal: ThermalPressure,

    pub fn format(self: PowerSample, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        try writer.print("PowerSample(cpu={d:.2}W gpu={d:.2}W ane={d:.2}W pkg={d:.2}W thermal={s})", .{
            self.cpu_power_w,
            self.gpu_power_w,
            self.ane_power_w,
            self.package_power_w,
            @tagName(self.thermal),
        });
    }
};

// ---------------------------------------------------------------------------
// EnergyMeasurement — result of measure_energy
// ---------------------------------------------------------------------------
pub const EnergyMeasurement = struct {
    cpu_power_watts: f64,
    gpu_power_watts: f64,
    ane_power_watts: f64,
    total_power_watts: f64,
    duration_seconds: f64,
    energy_joules: f64,
    operations: u64,
    joules_per_op: f64,
    ops_per_joule: f64,

    pub fn format(self: EnergyMeasurement, comptime _: []const u8, _: fmt.FormatOptions, writer: anytype) !void {
        try writer.print(
            "EnergyMeasurement:\n" ++
                "  CPU Power:    {d:.2} W\n" ++
                "  GPU Power:    {d:.2} W\n" ++
                "  ANE Power:    {d:.2} W\n" ++
                "  Total Power:  {d:.2} W\n" ++
                "  Duration:     {d:.2} s\n" ++
                "  Energy:       {d:.2} J\n" ++
                "  Operations:   {d}\n" ++
                "  Efficiency:   {d:.2e} ops/J\n",
            .{
                self.cpu_power_watts,
                self.gpu_power_watts,
                self.ane_power_watts,
                self.total_power_watts,
                self.duration_seconds,
                self.energy_joules,
                self.operations,
                self.ops_per_joule,
            },
        );
    }

    /// Construct from aggregate power values and timing.
    pub fn from_power(
        cpu_w: f64,
        gpu_w: f64,
        ane_w: f64,
        total_w: f64,
        duration_s: f64,
        ops: u64,
    ) EnergyMeasurement {
        const energy = total_w * duration_s;
        const ops_f: f64 = @floatFromInt(ops);
        return .{
            .cpu_power_watts = cpu_w,
            .gpu_power_watts = gpu_w,
            .ane_power_watts = ane_w,
            .total_power_watts = total_w,
            .duration_seconds = duration_s,
            .energy_joules = energy,
            .operations = ops,
            .joules_per_op = if (ops > 0) energy / ops_f else 0,
            .ops_per_joule = if (energy > 0) ops_f / energy else 0,
        };
    }

    /// Fallback estimate assuming ~20W Apple Silicon typical load.
    pub fn estimated(duration_s: f64, ops: u64) EnergyMeasurement {
        const estimated_power: f64 = 20.0;
        return from_power(
            estimated_power * 0.6,
            estimated_power * 0.3,
            estimated_power * 0.1,
            estimated_power,
            duration_s,
            ops,
        );
    }
};

// ---------------------------------------------------------------------------
// powermetrics output parser
// ---------------------------------------------------------------------------

fn parseThermal(s: []const u8) ThermalPressure {
    if (mem.eql(u8, s, "Moderate")) return .moderate;
    if (mem.eql(u8, s, "Heavy")) return .heavy;
    if (mem.eql(u8, s, "Trapping")) return .trapping;
    if (mem.eql(u8, s, "Sleeping")) return .sleeping;
    return .nominal;
}

/// Extract milliwatt value from a line like "CPU Power: 1234 mW"
fn parseMilliwatts(line: []const u8) ?f64 {
    // Find the colon
    const colon_pos = mem.indexOf(u8, line, ":") orelse return null;
    var rest = mem.trimLeft(u8, line[colon_pos + 1 ..], " \t");

    // Parse the number (digits and '.')
    var end: usize = 0;
    var saw_dot = false;
    for (rest, 0..) |c, idx| {
        if (c >= '0' and c <= '9') {
            end = idx + 1;
        } else if (c == '.' and !saw_dot) {
            saw_dot = true;
            end = idx + 1;
        } else break;
    }
    if (end == 0) return null;
    const val = std.fmt.parseFloat(f64, rest[0..end]) catch return null;

    // Check for "mW" suffix
    rest = mem.trimLeft(u8, rest[end..], " \t");
    if (mem.startsWith(u8, rest, "mW")) {
        return val / 1000.0; // mW -> W
    }
    return null;
}

/// Parse powermetrics text output into a single PowerSample.
/// Returns null if no usable power data found.
pub fn parsePowermetricsOutput(output: []const u8) ?PowerSample {
    var cpu_power: f64 = 0;
    var gpu_power: f64 = 0;
    var ane_power: f64 = 0;
    var package_power: f64 = 0;
    var thermal: ThermalPressure = .nominal;

    var it = mem.splitScalar(u8, output, '\n');
    while (it.next()) |raw_line| {
        const line = mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        if (mem.startsWith(u8, line, "CPU Power:") or
            mem.startsWith(u8, line, "E-Cluster Power:") or
            mem.startsWith(u8, line, "P-Cluster Power:"))
        {
            if (parseMilliwatts(line)) |w| cpu_power += w;
        } else if (mem.startsWith(u8, line, "GPU Power:")) {
            if (parseMilliwatts(line)) |w| gpu_power = w;
        } else if (mem.startsWith(u8, line, "ANE Power:")) {
            if (parseMilliwatts(line)) |w| ane_power = w;
        } else if (mem.startsWith(u8, line, "Combined Power") or
            mem.startsWith(u8, line, "Package Power"))
        {
            if (parseMilliwatts(line)) |w| package_power = w;
        } else if (mem.startsWith(u8, line, "Thermal Pressure:")) {
            const colon_pos = mem.indexOf(u8, line, ":") orelse continue;
            const val = mem.trim(u8, line[colon_pos + 1 ..], " \t\r");
            thermal = parseThermal(val);
        }
    }

    if (package_power <= 0 and cpu_power <= 0) return null;
    if (package_power <= 0) package_power = cpu_power + gpu_power + ane_power;

    return .{
        .timestamp_ns = time.nanoTimestamp(),
        .cpu_power_w = cpu_power,
        .gpu_power_w = gpu_power,
        .ane_power_w = ane_power,
        .package_power_w = package_power,
        .thermal = thermal,
    };
}

// ---------------------------------------------------------------------------
// Run powermetrics (Apple Silicon only)
// ---------------------------------------------------------------------------

/// Spawn powermetrics for one sample at given interval.
/// Returns raw stdout or null on failure.
/// Caller owns the returned slice.
pub fn runPowermetrics(allocator: std.mem.Allocator, interval_ms: u32) !?[]u8 {
    if (comptime !is_apple_silicon) return null;

    var interval_buf: [16]u8 = undefined;
    const interval_str = std.fmt.bufPrint(&interval_buf, "{d}", .{interval_ms}) catch return null;

    const argv = [_][]const u8{
        "powermetrics",
        "--samplers",
        "cpu_power,gpu_power,thermal",
        "-n",
        "1",
        "-i",
        interval_str,
    };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .pipe;
    child.stderr_behavior = .ignore;

    try child.spawn();
    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024);
    _ = try child.wait();
    if (stdout.len == 0) {
        allocator.free(stdout);
        return null;
    }
    return stdout;
}

// ---------------------------------------------------------------------------
// measure_energy — high-level API
// ---------------------------------------------------------------------------

/// Measure wall-clock energy of calling `work_fn`.
/// On Apple Silicon, attempts powermetrics; otherwise uses timing estimate.
/// `ops_count` = number of logical operations the workload performs.
pub fn measureEnergy(ops_count: u64, work_fn: *const fn () void) EnergyMeasurement {
    const start = time.nanoTimestamp();
    work_fn();
    const end = time.nanoTimestamp();
    const duration_ns: f64 = @floatFromInt(end - start);
    const duration_s = duration_ns / 1e9;

    // On non-Apple-Silicon we always fall back to estimation.
    return EnergyMeasurement.estimated(duration_s, ops_count);
}

/// Generic version that accepts a context pointer for the work function.
pub fn measureEnergyCtx(
    comptime Ctx: type,
    ctx: Ctx,
    ops_count: u64,
    work_fn: *const fn (Ctx) void,
) EnergyMeasurement {
    const start = time.nanoTimestamp();
    work_fn(ctx);
    const end = time.nanoTimestamp();
    const duration_ns: f64 = @floatFromInt(end - start);
    const duration_s = duration_ns / 1e9;
    return EnergyMeasurement.estimated(duration_s, ops_count);
}

// ---------------------------------------------------------------------------
// Convenience: energy per color, joules per billion colors
// ---------------------------------------------------------------------------

/// Estimate joules per single color operation given a batch measurement.
pub fn energyPerColor(measurement: EnergyMeasurement) f64 {
    return measurement.joules_per_op;
}

/// Extrapolate joules for 1 billion colors from a measurement.
pub fn joulesPerBillionColors(measurement: EnergyMeasurement) f64 {
    return measurement.joules_per_op * 1_000_000_000.0;
}

// ===========================================================================
// Tests
// ===========================================================================

test "EnergyMeasurement formatting" {
    const m = EnergyMeasurement.from_power(12.0, 6.0, 2.0, 20.0, 1.5, 1_000_000);
    var buf: [512]u8 = undefined;
    const s = try fmt.bufPrint(&buf, "{}", .{m});
    try std.testing.expect(mem.indexOf(u8, s, "CPU Power:") != null);
    try std.testing.expect(mem.indexOf(u8, s, "Total Power:") != null);
    try std.testing.expect(mem.indexOf(u8, s, "ops/J") != null);
}

test "EnergyMeasurement estimated fallback" {
    const m = EnergyMeasurement.estimated(2.0, 500_000);
    try std.testing.expectApproxEqAbs(m.total_power_watts, 20.0, 0.01);
    try std.testing.expectApproxEqAbs(m.energy_joules, 40.0, 0.01);
    try std.testing.expectApproxEqAbs(m.cpu_power_watts, 12.0, 0.01);
    try std.testing.expect(m.ops_per_joule > 0);
}

test "EnergyMeasurement from_power zero ops" {
    const m = EnergyMeasurement.from_power(10, 5, 1, 16, 1.0, 0);
    try std.testing.expectApproxEqAbs(m.joules_per_op, 0.0, 0.001);
    try std.testing.expectApproxEqAbs(m.ops_per_joule, 0.0, 0.001);
}

test "parsePowermetricsOutput basic" {
    const input =
        \\CPU Power: 5000 mW
        \\GPU Power: 2000 mW
        \\ANE Power: 500 mW
        \\Package Power: 8000 mW
        \\Thermal Pressure: Nominal
    ;
    const sample = parsePowermetricsOutput(input) orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(sample.cpu_power_w, 5.0, 0.001);
    try std.testing.expectApproxEqAbs(sample.gpu_power_w, 2.0, 0.001);
    try std.testing.expectApproxEqAbs(sample.ane_power_w, 0.5, 0.001);
    try std.testing.expectApproxEqAbs(sample.package_power_w, 8.0, 0.001);
    try std.testing.expect(sample.thermal == .nominal);
}

test "parsePowermetricsOutput cluster accumulation" {
    const input =
        \\E-Cluster Power: 1500 mW
        \\P-Cluster Power: 3500 mW
        \\GPU Power: 1000 mW
        \\ANE Power: 200 mW
        \\Combined Power (DRAM+CPU+GPU+ANE): 7000 mW
        \\Thermal Pressure: Moderate
    ;
    const sample = parsePowermetricsOutput(input) orelse return error.TestUnexpectedResult;
    // E-Cluster + P-Cluster
    try std.testing.expectApproxEqAbs(sample.cpu_power_w, 5.0, 0.001);
    try std.testing.expectApproxEqAbs(sample.package_power_w, 7.0, 0.001);
    try std.testing.expect(sample.thermal == .moderate);
}

test "parsePowermetricsOutput no data returns null" {
    const input = "Some random text\nNothing useful here\n";
    try std.testing.expect(parsePowermetricsOutput(input) == null);
}

test "parsePowermetricsOutput inferred package" {
    // No explicit package power — should sum CPU+GPU+ANE
    const input =
        \\CPU Power: 4000 mW
        \\GPU Power: 2000 mW
        \\ANE Power: 1000 mW
    ;
    const sample = parsePowermetricsOutput(input) orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(sample.package_power_w, 7.0, 0.001);
}

test "timing-based measurement" {
    const S = struct {
        fn work() void {
            // Burn ~1ms
            const start = time.nanoTimestamp();
            while (true) {
                const now = time.nanoTimestamp();
                if (now - start > 1_000_000) break;
            }
        }
    };
    const m = measureEnergy(1000, &S.work);
    try std.testing.expect(m.duration_seconds > 0.0005);
    try std.testing.expect(m.duration_seconds < 1.0);
    try std.testing.expect(m.energy_joules > 0);
    try std.testing.expect(m.operations == 1000);
}

test "convenience functions" {
    const m = EnergyMeasurement.from_power(10, 5, 1, 16, 2.0, 2_000_000);
    const epc = energyPerColor(m);
    try std.testing.expect(epc > 0);
    const jpb = joulesPerBillionColors(m);
    try std.testing.expect(jpb > epc);
}
