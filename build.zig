const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module
    const syrup_mod = b.addModule("syrup", .{
        .root_source_file = b.path("src/syrup.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Geo module (Open Location Code / Plus Codes)
    const geo_mod = b.addModule("geo", .{
        .root_source_file = b.path("src/geo.zig"),
        .target = target,
        .optimize = optimize,
    });
    geo_mod.addImport("syrup", syrup_mod);

    // XEV I/O module
    const xev_io_mod = b.addModule("xev_io", .{
        .root_source_file = b.path("src/xev_io.zig"),
        .target = target,
        .optimize = optimize,
    });
    xev_io_mod.addImport("syrup", syrup_mod);

    // ACP module (Agent Client Protocol)
    const acp_mod = b.addModule("acp", .{
        .root_source_file = b.path("src/acp.zig"),
        .target = target,
        .optimize = optimize,
    });
    acp_mod.addImport("syrup", syrup_mod);
    acp_mod.addImport("xev_io", xev_io_mod);

    // Create module for main.zig
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_mod.addImport("syrup", syrup_mod);

    // Test executable for CID verification
    const exe = b.addExecutable(.{
        .name = "syrup-verify",
        .root_module = main_mod,
    });
    b.installArtifact(exe);

    // CLI executable for JSON <-> Syrup conversion
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("syrup", syrup_mod);

    const cli_exe = b.addExecutable(.{
        .name = "syrup",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);


    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run CID verification");
    run_step.dependOn(&run_cmd.step);

    // Create test module for syrup.zig
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/syrup.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests for syrup
    const lib_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    // Create test module for xev_io.zig
    const xev_test_mod = b.createModule(.{
        .root_source_file = b.path("src/xev_io.zig"),
        .target = target,
        .optimize = optimize,
    });
    xev_test_mod.addImport("syrup", syrup_mod);

    // Tests for xev_io
    const xev_tests = b.addTest(.{
        .root_module = xev_test_mod,
    });
    const run_xev_tests = b.addRunArtifact(xev_tests);

    // Create test module for geo.zig
    const geo_test_mod = b.createModule(.{
        .root_source_file = b.path("src/geo.zig"),
        .target = target,
        .optimize = optimize,
    });
    geo_test_mod.addImport("syrup", syrup_mod);

    // Tests for geo
    const geo_tests = b.addTest(.{
        .root_module = geo_test_mod,
    });
    const run_geo_tests = b.addRunArtifact(geo_tests);

    // JSON-RPC Bridge module
    const bridge_mod = b.addModule("jsonrpc_bridge", .{
        .root_source_file = b.path("src/jsonrpc_bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    bridge_mod.addImport("syrup", syrup_mod);
    bridge_mod.addImport("acp", acp_mod);

    // Create test module for jsonrpc_bridge.zig
    const bridge_test_mod = b.createModule(.{
        .root_source_file = b.path("src/jsonrpc_bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    bridge_test_mod.addImport("syrup", syrup_mod);
    bridge_test_mod.addImport("acp", acp_mod);

    // Tests for JSON-RPC Bridge
    const bridge_tests = b.addTest(.{
        .root_module = bridge_test_mod,
    });
    const run_bridge_tests = b.addRunArtifact(bridge_tests);

    // Create test module for acp.zig
    const acp_test_mod = b.createModule(.{
        .root_source_file = b.path("src/acp.zig"),
        .target = target,
        .optimize = optimize,
    });
    acp_test_mod.addImport("syrup", syrup_mod);
    acp_test_mod.addImport("xev_io", xev_io_mod);

    // Tests for ACP
    const acp_tests = b.addTest(.{
        .root_module = acp_test_mod,
    });
    const run_acp_tests = b.addRunArtifact(acp_tests);

    // Liveness module (terminal probes)
    const liveness_mod = b.addModule("liveness", .{
        .root_source_file = b.path("src/liveness.zig"),
        .target = target,
        .optimize = optimize,
    });
    liveness_mod.addImport("syrup", syrup_mod);
    liveness_mod.addImport("acp", acp_mod);

    // Create test module for liveness.zig
    const liveness_test_mod = b.createModule(.{
        .root_source_file = b.path("src/liveness.zig"),
        .target = target,
        .optimize = optimize,
    });
    liveness_test_mod.addImport("syrup", syrup_mod);
    liveness_test_mod.addImport("acp", acp_mod);

    // Tests for Liveness
    const liveness_tests = b.addTest(.{
        .root_module = liveness_test_mod,
    });
    const run_liveness_tests = b.addRunArtifact(liveness_tests);

    // Parity Check Tool
    const parity_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/parity_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    parity_mod.addImport("syrup", syrup_mod);

    const parity_exe = b.addExecutable(.{
        .name = "parity-check",
        .root_module = parity_mod,
    });
    const run_parity = b.addRunArtifact(parity_exe);
    const parity_step = b.step("parity", "Run the parity check");
    parity_step.dependOn(&run_parity.step);

    // Benchmark Tool
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/bench_zig.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addImport("syrup", syrup_mod);

    const bench_exe = b.addExecutable(.{
        .name = "bench-zig",
        .root_module = bench_mod,
    });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run the benchmark");
    bench_step.dependOn(&run_bench.step);

    // Bristol Converter Tool
    const bristol_mod = b.createModule(.{
        .root_source_file = b.path("tools/bristol_converter.zig"),
        .target = target,
        .optimize = optimize,
    });
    bristol_mod.addImport("syrup", syrup_mod);
    
    // Bristol module (for reusability)
    const bristol_lib = b.addModule("bristol", .{
        .root_source_file = b.path("src/bristol.zig"),
        .target = target,
        .optimize = optimize,
    });
    bristol_lib.addImport("syrup", syrup_mod);
    bristol_mod.addImport("bristol", bristol_lib);

    const bristol_exe = b.addExecutable(.{
        .name = "bristol-syrup",
        .root_module = bristol_mod,
    });
    const run_bristol = b.addRunArtifact(bristol_exe);
    const bristol_step = b.step("bristol", "Run Bristol circuit conversion");
    bristol_step.dependOn(&run_bristol.step);

    // Vibesnipe Tool
    const vibesnipe_mod = b.createModule(.{
        .root_source_file = b.path("tools/vibesnipe.zig"),
        .target = target,
        .optimize = optimize,
    });
    vibesnipe_mod.addImport("syrup", syrup_mod);

    const vibesnipe_exe = b.addExecutable(.{
        .name = "vibesnipe",
        .root_module = vibesnipe_mod,
    });
    const run_vibesnipe = b.addRunArtifact(vibesnipe_exe);
    const vibesnipe_step = b.step("vibesnipe", "Run the vibesnipe generator");
    vibesnipe_step.dependOn(&run_vibesnipe.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_xev_tests.step);
    test_step.dependOn(&run_geo_tests.step);
    test_step.dependOn(&run_bridge_tests.step);
    test_step.dependOn(&run_acp_tests.step);
    test_step.dependOn(&run_liveness_tests.step);

    // Benchmark executable
    // const bench_mod = b.createModule(.{
    //     .root_source_file = b.path("benchmark/bench_zig.zig"),
    //     .target = target,
    //     .optimize = .ReleaseFast,
    // });
    // bench_mod.addImport("syrup", syrup_mod);

    // const bench_exe = b.addExecutable(.{
    //     .name = "bench",
    //     .root_module = bench_mod,
    // });
    // b.installArtifact(bench_exe);

    // const bench_cmd = b.addRunArtifact(bench_exe);
    // bench_cmd.step.dependOn(b.getInstallStep());
    // const bench_step = b.step("bench", "Run benchmarks");
    // bench_step.dependOn(&bench_cmd.step);
}
