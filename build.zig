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

    // Czernowitz location codes module
    const czernowitz_mod = b.addModule("czernowitz", .{
        .root_source_file = b.path("src/czernowitz.zig"),
        .target = target,
        .optimize = optimize,
    });
    czernowitz_mod.addImport("geo", geo_mod);
    czernowitz_mod.addImport("syrup", syrup_mod);

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

    // Cell Sync Benchmark Tool (flamegraph visualization)
    const bench_cell_sync = b.createModule(.{
        .root_source_file = b.path("src/cell_sync.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench_cs_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/bench_cell_sync.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_cs_mod.addImport("cell_sync", bench_cell_sync);

    const bench_cs_exe = b.addExecutable(.{
        .name = "bench-cell-sync",
        .root_module = bench_cs_mod,
    });
    const run_bench_cs = b.addRunArtifact(bench_cs_exe);
    const bench_cs_step = b.step("bench-cell-sync", "Run cell sync benchmarks with flamegraph viz");
    bench_cs_step.dependOn(&run_bench_cs.step);

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

    // Create test module for czernowitz.zig
    const czernowitz_test_mod = b.createModule(.{
        .root_source_file = b.path("src/czernowitz.zig"),
        .target = target,
        .optimize = optimize,
    });
    czernowitz_test_mod.addImport("geo", geo_mod);
    czernowitz_test_mod.addImport("syrup", syrup_mod);

    // Tests for Czernowitz
    const czernowitz_tests = b.addTest(.{
        .root_module = czernowitz_test_mod,
    });
    const run_czernowitz_tests = b.addRunArtifact(czernowitz_tests);

    // Create test module for snapshot_test.zig
    const snapshot_test_mod = b.createModule(.{
        .root_source_file = b.path("test/snapshot_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    snapshot_test_mod.addImport("syrup", syrup_mod);

    // Tests for Snapshot
    const snapshot_tests = b.addTest(.{
        .root_module = snapshot_test_mod,
    });
    const run_snapshot_tests = b.addRunArtifact(snapshot_tests);

    // Rainbow module tests (uses relative imports, no module deps needed)
    const rainbow_test_mod = b.createModule(.{
        .root_source_file = b.path("src/rainbow.zig"),
        .target = target,
        .optimize = optimize,
    });
    const rainbow_tests = b.addTest(.{ .root_module = rainbow_test_mod });
    const run_rainbow_tests = b.addRunArtifact(rainbow_tests);

    // Damage module
    const damage_mod = b.addModule("damage", .{
        .root_source_file = b.path("src/damage.zig"),
        .target = target,
        .optimize = optimize,
    });
    damage_mod.addImport("syrup", syrup_mod);

    // Damage module tests
    const damage_test_mod = b.createModule(.{
        .root_source_file = b.path("src/damage.zig"),
        .target = target,
        .optimize = optimize,
    });
    damage_test_mod.addImport("syrup", syrup_mod);
    const damage_tests = b.addTest(.{ .root_module = damage_test_mod });
    const run_damage_tests = b.addRunArtifact(damage_tests);

    // Cell Dispatch module (transducer-based parallel cell rendering)
    const cell_dispatch_mod = b.addModule("cell_dispatch", .{
        .root_source_file = b.path("src/cell_dispatch.zig"),
        .target = target,
        .optimize = optimize,
    });
    cell_dispatch_mod.addImport("syrup", syrup_mod);
    cell_dispatch_mod.addImport("damage", damage_mod);

    // Cell Dispatch module tests
    const cell_dispatch_test_mod = b.createModule(.{
        .root_source_file = b.path("src/cell_dispatch.zig"),
        .target = target,
        .optimize = optimize,
    });
    cell_dispatch_test_mod.addImport("syrup", syrup_mod);
    cell_dispatch_test_mod.addImport("damage", damage_mod);
    const cell_dispatch_tests = b.addTest(.{ .root_module = cell_dispatch_test_mod });
    const run_cell_dispatch_tests = b.addRunArtifact(cell_dispatch_tests);

    // Homotopy module tests
    const homotopy_test_mod = b.createModule(.{
        .root_source_file = b.path("src/homotopy.zig"),
        .target = target,
        .optimize = optimize,
    });
    const homotopy_tests = b.addTest(.{ .root_module = homotopy_test_mod });
    const run_homotopy_tests = b.addRunArtifact(homotopy_tests);

    // Linalg module tests
    const linalg_test_mod = b.createModule(.{
        .root_source_file = b.path("src/linalg.zig"),
        .target = target,
        .optimize = optimize,
    });
    const linalg_tests = b.addTest(.{ .root_module = linalg_test_mod });
    const run_linalg_tests = b.addRunArtifact(linalg_tests);

    // Ripser module tests (persistent homology)
    const ripser_test_mod = b.createModule(.{
        .root_source_file = b.path("src/ripser.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ripser_tests = b.addTest(.{ .root_module = ripser_test_mod });
    const run_ripser_tests = b.addRunArtifact(ripser_tests);

    // SCS wrapper module tests (conic optimization)
    const scs_test_mod = b.createModule(.{
        .root_source_file = b.path("src/scs_wrapper.zig"),
        .target = target,
        .optimize = optimize,
    });
    const scs_tests = b.addTest(.{ .root_module = scs_test_mod });
    const run_scs_tests = b.addRunArtifact(scs_tests);

    // Continuation module tests
    const continuation_test_mod = b.createModule(.{
        .root_source_file = b.path("src/continuation.zig"),
        .target = target,
        .optimize = optimize,
    });
    const continuation_tests = b.addTest(.{ .root_module = continuation_test_mod });
    const run_continuation_tests = b.addRunArtifact(continuation_tests);

    // Prigogine module (dissipative structures & non-equilibrium thermodynamics)
    const prigogine_mod = b.addModule("prigogine", .{
        .root_source_file = b.path("src/prigogine.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = prigogine_mod;

    // Prigogine tests
    const prigogine_test_mod = b.createModule(.{
        .root_source_file = b.path("src/prigogine.zig"),
        .target = target,
        .optimize = optimize,
    });
    const prigogine_tests = b.addTest(.{ .root_module = prigogine_test_mod });
    const run_prigogine_tests = b.addRunArtifact(prigogine_tests);

    // Spectral Tensor module (thalamocortical integration)
    const spectral_tensor_mod = b.addModule("spectral_tensor", .{
        .root_source_file = b.path("src/spectral_tensor.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = spectral_tensor_mod;

    // Spectral Tensor tests
    const spectral_tensor_test_mod = b.createModule(.{
        .root_source_file = b.path("src/spectral_tensor.zig"),
        .target = target,
        .optimize = optimize,
    });
    const spectral_tensor_tests = b.addTest(.{ .root_module = spectral_tensor_test_mod });
    const run_spectral_tensor_tests = b.addRunArtifact(spectral_tensor_tests);

    // FEM module
    const fem_mod = b.addModule("fem", .{
        .root_source_file = b.path("src/fem.zig"),
        .target = target,
        .optimize = optimize,
    });
    _ = fem_mod;

    // FEM module tests
    const fem_test_mod = b.createModule(.{
        .root_source_file = b.path("src/fem.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fem_tests = b.addTest(.{ .root_module = fem_test_mod });
    const run_fem_tests = b.addRunArtifact(fem_tests);

    // Spectrum module (GF(3) triadic color bridge)
    const spectrum_test_mod = b.createModule(.{
        .root_source_file = b.path("src/spectrum.zig"),
        .target = target,
        .optimize = optimize,
    });
    const spectrum_tests = b.addTest(.{ .root_module = spectrum_test_mod });
    const run_spectrum_tests = b.addRunArtifact(spectrum_tests);

    // Cell Sync module (distributed terminal cell synchronization)
    const cell_sync_test_mod = b.createModule(.{
        .root_source_file = b.path("src/cell_sync.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cell_sync_tests = b.addTest(.{ .root_module = cell_sync_test_mod });
    const run_cell_sync_tests = b.addRunArtifact(cell_sync_tests);

    // QASM renderer module (quantum circuit ASCII art)
    const qasm_test_mod = b.createModule(.{
        .root_source_file = b.path("src/qasm.zig"),
        .target = target,
        .optimize = optimize,
    });
    const qasm_tests = b.addTest(.{ .root_module = qasm_test_mod });
    const run_qasm_tests = b.addRunArtifact(qasm_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_xev_tests.step);
    test_step.dependOn(&run_geo_tests.step);
    test_step.dependOn(&run_bridge_tests.step);
    test_step.dependOn(&run_acp_tests.step);
    test_step.dependOn(&run_liveness_tests.step);
    test_step.dependOn(&run_czernowitz_tests.step);
    test_step.dependOn(&run_snapshot_tests.step);
    test_step.dependOn(&run_rainbow_tests.step);
    test_step.dependOn(&run_damage_tests.step);
    test_step.dependOn(&run_cell_dispatch_tests.step);
    test_step.dependOn(&run_homotopy_tests.step);
    test_step.dependOn(&run_linalg_tests.step);
    test_step.dependOn(&run_ripser_tests.step);
    test_step.dependOn(&run_scs_tests.step);
    test_step.dependOn(&run_continuation_tests.step);
    test_step.dependOn(&run_fem_tests.step);
    test_step.dependOn(&run_spectral_tensor_tests.step);
    test_step.dependOn(&run_prigogine_tests.step);
    test_step.dependOn(&run_spectrum_tests.step);
    test_step.dependOn(&run_cell_sync_tests.step);
    test_step.dependOn(&run_qasm_tests.step);

    // Shader Viz Tool
    const shader_mod = b.createModule(.{
        .root_source_file = b.path("tools/shader_viz.zig"),
        .target = target,
        .optimize = optimize,
    });
    shader_mod.addImport("syrup", syrup_mod);

    const shader_exe = b.addExecutable(.{
        .name = "shader-viz",
        .root_module = shader_mod,
    });
    const run_shader = b.addRunArtifact(shader_exe);
    const shader_step = b.step("shader", "Run terminal shader visualization");
    shader_step.dependOn(&run_shader.step);

    // Test Viz Tool
    const test_viz_mod = b.createModule(.{
        .root_source_file = b.path("tools/test_viz.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_viz_mod.addImport("syrup", syrup_mod);

    const test_viz_exe = b.addExecutable(.{
        .name = "test-viz",
        .root_module = test_viz_mod,
    });
    const run_test_viz = b.addRunArtifact(test_viz_exe);
    const test_viz_step = b.step("test-viz", "Run visual test runner");
    test_viz_step.dependOn(&run_test_viz.step);

    // Persistence Viz Tool
    const persistence_mod = b.createModule(.{
        .root_source_file = b.path("tools/persistence_viz.zig"),
        .target = target,
        .optimize = optimize,
    });

    const persistence_exe = b.addExecutable(.{
        .name = "persistence-viz",
        .root_module = persistence_mod,
    });
    const run_persistence = b.addRunArtifact(persistence_exe);
    const persistence_step = b.step("persistence", "Render persistence diagram in terminal");
    persistence_step.dependOn(&run_persistence.step);

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
