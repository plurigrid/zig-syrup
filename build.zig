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

    // Cyton Parser module (OpenBCI packet parsing)
    const cyton_parser_mod = b.addModule("cyton_parser", .{
        .root_source_file = b.path("src/cyton_parser.zig"),
        .target = target,
        .optimize = optimize,
    });

    // FFT Bands module (Frequency analysis)
    const fft_bands_mod = b.addModule("fft_bands", .{
        .root_source_file = b.path("src/fft_bands.zig"),
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

    // ACP mnx.fi extensions module (defined first for dependency ordering)
    const acp_mnxfi_mod = b.addModule("acp_mnxfi", .{
        .root_source_file = b.path("src/acp_mnxfi.zig"),
        .target = target,
        .optimize = optimize,
    });
    acp_mnxfi_mod.addImport("syrup", syrup_mod);

    // ACP module (Agent Client Protocol)
    const acp_mod = b.addModule("acp", .{
        .root_source_file = b.path("src/acp.zig"),
        .target = target,
        .optimize = optimize,
    });
    acp_mod.addImport("syrup", syrup_mod);
    acp_mod.addImport("xev_io", xev_io_mod);
    acp_mod.addImport("acp_mnxfi", acp_mnxfi_mod);

    // Continuation module
    const continuation_mod = b.addModule("continuation", .{
        .root_source_file = b.path("src/continuation.zig"),
        .target = target,
        .optimize = optimize,
    });
    continuation_mod.addImport("syrup", syrup_mod);

    // Homotopy module (needs continuation)
    const homotopy_mod = b.addModule("homotopy", .{
        .root_source_file = b.path("src/homotopy.zig"),
        .target = target,
        .optimize = optimize,
    });
    homotopy_mod.addImport("syrup", syrup_mod);
    homotopy_mod.addImport("continuation", continuation_mod);

    // BCI Homotopy module
    const bci_mod = b.addModule("bci_homotopy", .{
        .root_source_file = b.path("src/bci_homotopy.zig"),
        .target = target,
        .optimize = optimize,
    });
    bci_mod.addImport("syrup", syrup_mod);
    bci_mod.addImport("continuation", continuation_mod);
    bci_mod.addImport("homotopy", homotopy_mod);

    // CSV SIMD module (Bridge 9 optimization)
    _ = b.addModule("csv_simd", .{
        .root_source_file = b.path("src/csv_simd.zig"),
        .target = target,
        .optimize = optimize,
    });

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

    // EEG Processing Binary (Tier 1)
    const eeg_mod = b.createModule(.{
        .root_source_file = b.path("src/eeg.zig"),
        .target = target,
        .optimize = optimize,
    });
    eeg_mod.addImport("cyton_parser", cyton_parser_mod);
    eeg_mod.addImport("fft_bands", fft_bands_mod);

    const eeg_exe = b.addExecutable(.{
        .name = "eeg",
        .root_module = eeg_mod,
    });
    b.installArtifact(eeg_exe);

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
    acp_test_mod.addImport("acp_mnxfi", acp_mnxfi_mod);

    // Tests for ACP
    const acp_tests = b.addTest(.{
        .root_module = acp_test_mod,
    });
    const run_acp_tests = b.addRunArtifact(acp_tests);

    // Create test module for acp_mnxfi.zig
    const acp_mnxfi_test_mod = b.createModule(.{
        .root_source_file = b.path("src/acp_mnxfi.zig"),
        .target = target,
        .optimize = optimize,
    });
    acp_mnxfi_test_mod.addImport("syrup", syrup_mod);

    // Tests for ACP mnx.fi
    const acp_mnxfi_tests = b.addTest(.{
        .root_module = acp_mnxfi_test_mod,
    });
    const run_acp_mnxfi_tests = b.addRunArtifact(acp_mnxfi_tests);

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

    // BCI Homotopy module tests
    const bci_test_mod = b.createModule(.{
        .root_source_file = b.path("src/bci_homotopy.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bci_tests = b.addTest(.{ .root_module = bci_test_mod });
    const run_bci_tests = b.addRunArtifact(bci_tests);

    // Prigogine module (dissipative structures & non-equilibrium thermodynamics)
    _ = b.addModule("prigogine", .{
        .root_source_file = b.path("src/prigogine.zig"),
        .target = target,
        .optimize = optimize,
    });

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

    // Spectral Tensor tests
    const spectral_tensor_test_mod = b.createModule(.{
        .root_source_file = b.path("src/spectral_tensor.zig"),
        .target = target,
        .optimize = optimize,
    });
    const spectral_tensor_tests = b.addTest(.{ .root_module = spectral_tensor_test_mod });
    const run_spectral_tensor_tests = b.addRunArtifact(spectral_tensor_tests);

    // FEM module
    _ = b.addModule("fem", .{
        .root_source_file = b.path("src/fem.zig"),
        .target = target,
        .optimize = optimize,
    });

    // FEM module tests
    const fem_test_mod = b.createModule(.{
        .root_source_file = b.path("src/fem.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fem_tests = b.addTest(.{ .root_module = fem_test_mod });
    const run_fem_tests = b.addRunArtifact(fem_tests);

    // Color SIMD module (Vectorized color space conversions)
    _ = b.addModule("color_simd", .{
        .root_source_file = b.path("src/color_simd.zig"),
        .target = target,
        .optimize = optimize,
    });


    // Color SIMD module tests
    const color_simd_test_mod = b.createModule(.{
        .root_source_file = b.path("src/color_simd.zig"),
        .target = target,
        .optimize = optimize,
    });
    const color_simd_tests = b.addTest(.{ .root_module = color_simd_test_mod });
    const run_color_simd_tests = b.addRunArtifact(color_simd_tests);

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

    // ========================================
    // Color Modules (for Colored Operads)
    // ========================================

    // Lux color module (GF(3) operadic coloring) - standalone, no dependencies
    const lux_color_mod = b.addModule("lux_color", .{
        .root_source_file = b.path("src/lux_color.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tileable Shader module (pixel-perfect embarrassingly parallel tiles)
    const tileable_shader_mod = b.addModule("tileable_shader", .{
        .root_source_file = b.path("src/tileable_shader.zig"),
        .target = target,
        .optimize = optimize,
    });
    tileable_shader_mod.addImport("lux_color", lux_color_mod);
    tileable_shader_mod.addImport("cell_dispatch", cell_dispatch_mod);

    // Tileable Shader module tests
    const tileable_shader_test_mod = b.createModule(.{
        .root_source_file = b.path("src/tileable_shader.zig"),
        .target = target,
        .optimize = optimize,
    });
    tileable_shader_test_mod.addImport("lux_color", lux_color_mod);
    tileable_shader_test_mod.addImport("cell_dispatch", cell_dispatch_mod);
    const tileable_shader_tests = b.addTest(.{ .root_module = tileable_shader_test_mod });
    const run_tileable_shader_tests = b.addRunArtifact(tileable_shader_tests);

    // ========================================
    // Worlds Module (A/B Testing, Multiplayer, OpenBCI Integration)
    // ========================================

    // Main worlds module (using mod.zig as entry point)
    const worlds_mod = b.addModule("worlds", .{
        .root_source_file = b.path("src/worlds/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    worlds_mod.addImport("syrup", syrup_mod);
    worlds_mod.addImport("bristol", bristol_lib);
    worlds_mod.addImport("bci_homotopy", bci_mod);
    worlds_mod.addImport("continuation", continuation_mod);
    worlds_mod.addImport("homotopy", homotopy_mod);
    worlds_mod.addImport("lux_color", lux_color_mod);
    worlds_mod.addImport("spectral_tensor", spectral_tensor_mod);

    // Persistent data structures (persistent.zig - Immer/Ewig-style)
    const persistent_test_mod = b.createModule(.{
        .root_source_file = b.path("src/worlds/persistent.zig"),
        .target = target,
        .optimize = optimize,
    });
    const persistent_tests = b.addTest(.{ .root_module = persistent_test_mod });
    const run_persistent_tests = b.addRunArtifact(persistent_tests);

    // Syrup adapter for world-tile integration
    const syrup_adapter_test_mod = b.createModule(.{
        .root_source_file = b.path("src/worlds/syrup_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    syrup_adapter_test_mod.addImport("syrup", syrup_mod);
    const syrup_adapter_tests = b.addTest(.{ .root_module = syrup_adapter_test_mod });
    const run_syrup_adapter_tests = b.addRunArtifact(syrup_adapter_tests);

    // Core world module (world.zig)
    const world_test_mod = b.createModule(.{
        .root_source_file = b.path("src/worlds/world.zig"),
        .target = target,
        .optimize = optimize,
    });
    const world_tests = b.addTest(.{ .root_module = world_test_mod });
    const run_world_tests = b.addRunArtifact(world_tests);

    // A/B Testing module
    const ab_test_test_mod = b.createModule(.{
        .root_source_file = b.path("src/worlds/ab_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ab_test_tests = b.addTest(.{ .root_module = ab_test_test_mod });
    const run_ab_test_tests = b.addRunArtifact(ab_test_tests);

    // Benchmark adapter
    const benchmark_adapter_test_mod = b.createModule(.{
        .root_source_file = b.path("src/worlds/benchmark_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    benchmark_adapter_test_mod.addImport("syrup", syrup_mod);
    const benchmark_adapter_tests = b.addTest(.{ .root_module = benchmark_adapter_test_mod });
    const run_benchmark_adapter_tests = b.addRunArtifact(benchmark_adapter_tests);

    // Circuit world for ZK proofs
    const circuit_world_test_mod = b.createModule(.{
        .root_source_file = b.path("src/worlds/circuit_world.zig"),
        .target = target,
        .optimize = optimize,
    });
    circuit_world_test_mod.addImport("syrup", syrup_mod);
    circuit_world_test_mod.addImport("bristol", bristol_lib);
    const circuit_world_tests = b.addTest(.{ .root_module = circuit_world_test_mod });
    const run_circuit_world_tests = b.addRunArtifact(circuit_world_tests);

    // OpenBCI bridge for neurofeedback
    const openbci_bridge_test_mod = b.createModule(.{
        .root_source_file = b.path("src/worlds/openbci_bridge.zig"),
        .target = target,
        .optimize = optimize,
    });
    openbci_bridge_test_mod.addImport("syrup", syrup_mod);
    const openbci_bridge_tests = b.addTest(.{ .root_module = openbci_bridge_test_mod });
    const run_openbci_bridge_tests = b.addRunArtifact(openbci_bridge_tests);

    // BCI-Aptos Bridge module
    const bci_aptos_test_mod = b.createModule(.{
        .root_source_file = b.path("src/worlds/bci_aptos.zig"),
        .target = target,
        .optimize = optimize,
    });
    bci_aptos_test_mod.addImport("syrup", syrup_mod);
    bci_aptos_test_mod.addImport("bci_homotopy", bci_mod);
    bci_aptos_test_mod.addImport("continuation", continuation_mod);
    // Note: bci_aptos uses relative import for openbci_bridge.zig, which is in same dir

    const bci_aptos_tests = b.addTest(.{ .root_module = bci_aptos_test_mod });
    const run_bci_aptos_tests = b.addRunArtifact(bci_aptos_tests);

    // World Enumeration module (326 worlds)
    const world_enum_test_mod = b.createModule(.{
        .root_source_file = b.path("src/worlds/world_enum.zig"),
        .target = target,
        .optimize = optimize,
    });
    world_enum_test_mod.addImport("lux_color", lux_color_mod);
    const world_enum_tests = b.addTest(.{ .root_module = world_enum_test_mod });
    const run_world_enum_tests = b.addRunArtifact(world_enum_tests);

    // Colored Parentheses World module
    const colored_parens_test_mod = b.createModule(.{
        .root_source_file = b.path("src/worlds/colored_parens.zig"),
        .target = target,
        .optimize = optimize,
    });
    colored_parens_test_mod.addImport("lux_color", lux_color_mod);
    const colored_parens_tests = b.addTest(.{ .root_module = colored_parens_test_mod });
    const run_colored_parens_tests = b.addRunArtifact(colored_parens_tests);

    // Worlds integration tests
    const worlds_integration_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/worlds_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    worlds_integration_test_mod.addImport("syrup", syrup_mod);
    worlds_integration_test_mod.addImport("worlds", worlds_mod);
    const worlds_integration_tests = b.addTest(.{ .root_module = worlds_integration_test_mod });
    const run_worlds_integration_tests = b.addRunArtifact(worlds_integration_tests);

    // World Demo executable
    const world_demo_mod = b.createModule(.{
        .root_source_file = b.path("examples/world_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    world_demo_mod.addImport("syrup", syrup_mod);
    world_demo_mod.addImport("worlds", worlds_mod);
    
    const world_demo_exe = b.addExecutable(.{
        .name = "world-demo",
        .root_module = world_demo_mod,
    });
    // Not part of default build (aspirational API demo)
    // b.installArtifact(world_demo_exe);

    const world_demo_cmd = b.addRunArtifact(world_demo_exe);
    const world_demo_step = b.step("world-demo", "Run world A/B testing demo");
    world_demo_step.dependOn(&world_demo_cmd.step);

    // BCI Propagator module (SDF Ch 7)
    const propagator_mod = b.addModule("propagator", .{
        .root_source_file = b.path("src/propagator.zig"),
        .target = target,
        .optimize = optimize,
    });

    // BCI Demo executable
    const bci_demo_mod = b.createModule(.{
        .root_source_file = b.path("examples/bci_demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    bci_demo_mod.addImport("syrup", syrup_mod);
    bci_demo_mod.addImport("worlds", worlds_mod);
    bci_demo_mod.addImport("propagator", propagator_mod);
    
    const bci_demo_exe = b.addExecutable(.{
        .name = "bci-demo",
        .root_module = bci_demo_mod,
    });
    // bci_demo_exe.root_module.link_libc = true;

    // Not part of default build (aspirational API demo)
    // b.installArtifact(bci_demo_exe);

    const bci_demo_cmd = b.addRunArtifact(bci_demo_exe);
    const bci_demo_step = b.step("bci-demo", "Run BCI-Aptos bridge demo");
    bci_demo_step.dependOn(&bci_demo_cmd.step);

    // Spatial Propagator module (SplitTree topology → cell dispatch bridge)
    const spatial_propagator_mod = b.addModule("spatial_propagator", .{
        .root_source_file = b.path("src/spatial_propagator.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Spatial Propagator tests
    const spatial_propagator_test_mod = b.createModule(.{
        .root_source_file = b.path("src/spatial_propagator.zig"),
        .target = target,
        .optimize = optimize,
    });
    const spatial_propagator_tests = b.addTest(.{ .root_module = spatial_propagator_test_mod });
    const run_spatial_propagator_tests = b.addRunArtifact(spatial_propagator_tests);

    // Spatial Propagator shared library (C ABI for Swift bridge)
    // Quantization tests (terminal palette reduction)
    const quantize_test_mod = b.createModule(.{
        .root_source_file = b.path("src/quantize.zig"),
        .target = target,
        .optimize = optimize,
    });
    const quantize_tests = b.addTest(.{ .root_module = quantize_test_mod });
    const run_quantize_tests = b.addRunArtifact(quantize_tests);

    const spatial_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/spatial_propagator.zig"),
        .target = target,
        .optimize = optimize,
    });
    const spatial_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "spatial_propagator",
        .root_module = spatial_lib_mod,
    });
    b.installArtifact(spatial_lib);

    // GF(3) Goblins FFI — shared library for Guile Goblins integration
    const goblins_ffi_mod = b.createModule(.{
        .root_source_file = b.path("src/goblins_ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    const goblins_ffi_lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "gf3_goblins",
        .root_module = goblins_ffi_mod,
    });
    b.installArtifact(goblins_ffi_lib);

    // Cross-Runtime Exchange Demo (Syrup CLJ ↔ Rust ↔ Zig)
    const cross_runtime_mod = b.createModule(.{
        .root_source_file = b.path("examples/cross_runtime_exchange.zig"),
        .target = target,
        .optimize = optimize,
    });
    cross_runtime_mod.addImport("syrup", syrup_mod);
    
    const cross_runtime_exe = b.addExecutable(.{
        .name = "cross-runtime-exchange",
        .root_module = cross_runtime_mod,
    });
    b.installArtifact(cross_runtime_exe);
    
    const cross_runtime_cmd = b.addRunArtifact(cross_runtime_exe);
    const cross_runtime_step = b.step("cross-runtime", "Run cross-runtime syrup exchange demo");
    cross_runtime_step.dependOn(&cross_runtime_cmd.step);
    
    // Bandwidth Benchmark
    const bandwidth_mod = b.createModule(.{
        .root_source_file = b.path("benchmarks/bandwidth_benchmark.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bandwidth_mod.addImport("syrup", syrup_mod);
    
    const bandwidth_exe = b.addExecutable(.{
        .name = "bandwidth-benchmark",
        .root_module = bandwidth_mod,
    });
    b.installArtifact(bandwidth_exe);
    
    const bandwidth_cmd = b.addRunArtifact(bandwidth_exe);
    const bandwidth_step = b.step("bandwidth", "Run bandwidth benchmark");
    bandwidth_step.dependOn(&bandwidth_cmd.step);

    // Legacy modules (currently have compilation issues)
    // TODO: Fix immer.zig, uri.zig, ewig.zig, multiplayer.zig, simulation.zig, root.zig

    // Persistent storage (ewig.zig)
    // const ewig_test_mod = b.createModule(.{
    //     .root_source_file = b.path("src/worlds/ewig.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // const ewig_tests = b.addTest(.{ .root_module = ewig_test_mod });
    // const run_ewig_tests = b.addRunArtifact(ewig_tests);

    // Multiplayer module (multiplayer.zig)
    // const multiplayer_test_mod = b.createModule(.{
    //     .root_source_file = b.path("src/worlds/multiplayer.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // const multiplayer_tests = b.addTest(.{ .root_module = multiplayer_test_mod });
    // const run_multiplayer_tests = b.addRunArtifact(multiplayer_tests);

    // Simulation module (simulation.zig)
    // const simulation_test_mod = b.createModule(.{
    //     .root_source_file = b.path("src/worlds/simulation.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // const simulation_tests = b.addTest(.{ .root_module = simulation_test_mod });
    // const run_simulation_tests = b.addRunArtifact(simulation_tests);

    // A/B testing engine (ab_test.zig)
    // Removed duplicate block here


    // Worlds root module integration tests
    // const worlds_test_mod = b.createModule(.{
    //     .root_source_file = b.path("src/worlds/root.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // const worlds_tests = b.addTest(.{ .root_module = worlds_test_mod });
    // const run_worlds_tests = b.addRunArtifact(worlds_tests);

    // Worlds-specific test step
    const test_worlds_step = b.step("test-worlds", "Run worlds module tests");
    // test_worlds_step.dependOn(&run_persistent_tests.step);
    // test_worlds_step.dependOn(&run_syrup_adapter_tests.step);
    // test_worlds_step.dependOn(&run_world_tests.step);
    // test_worlds_step.dependOn(&run_ab_test_tests.step);
    // test_worlds_step.dependOn(&run_benchmark_adapter_tests.step);
    // test_worlds_step.dependOn(&run_circuit_world_tests.step);
    // test_worlds_step.dependOn(&run_openbci_bridge_tests.step);
    test_worlds_step.dependOn(&run_bci_aptos_tests.step);
    test_worlds_step.dependOn(&run_world_enum_tests.step);
    test_worlds_step.dependOn(&run_colored_parens_tests.step);
    // test_worlds_step.dependOn(&run_worlds_integration_tests.step);

    // Fuzz testing step — `zig build fuzz-worlds --fuzz` for continuous fuzzing
    const fuzz_world_enum_mod = b.createModule(.{
        .root_source_file = b.path("src/worlds/world_enum.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_world_enum_mod.addImport("lux_color", lux_color_mod);
    const fuzz_world_enum = b.addTest(.{ .root_module = fuzz_world_enum_mod });
    fuzz_world_enum.root_module.fuzz = true;
    const run_fuzz_world_enum = b.addRunArtifact(fuzz_world_enum);

    const fuzz_colored_parens_mod = b.createModule(.{
        .root_source_file = b.path("src/worlds/colored_parens.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_colored_parens_mod.addImport("lux_color", lux_color_mod);
    const fuzz_colored_parens = b.addTest(.{ .root_module = fuzz_colored_parens_mod });
    fuzz_colored_parens.root_module.fuzz = true;
    const run_fuzz_colored_parens = b.addRunArtifact(fuzz_colored_parens);

    const fuzz_worlds_step = b.step("fuzz-worlds", "Fuzz test worlds modules");
    fuzz_worlds_step.dependOn(&run_fuzz_world_enum.step);
    fuzz_worlds_step.dependOn(&run_fuzz_colored_parens.step);

    // Tests for Cyton Parser
    const cyton_parser_test_mod = b.createModule(.{
        .root_source_file = b.path("src/cyton_parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    const cyton_parser_tests = b.addTest(.{ .root_module = cyton_parser_test_mod });
    const run_cyton_parser_tests = b.addRunArtifact(cyton_parser_tests);

    // Tests for FFT Bands
    const fft_bands_test_mod = b.createModule(.{
        .root_source_file = b.path("src/fft_bands.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fft_bands_tests = b.addTest(.{ .root_module = fft_bands_test_mod });
    const run_fft_bands_tests = b.addRunArtifact(fft_bands_tests);

    // Tests for CSV SIMD
    const csv_simd_test_mod = b.createModule(.{
        .root_source_file = b.path("src/csv_simd.zig"),
        .target = target,
        .optimize = optimize,
    });
    const csv_simd_tests = b.addTest(.{ .root_module = csv_simd_test_mod });
    const run_csv_simd_tests = b.addRunArtifact(csv_simd_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_xev_tests.step);
    test_step.dependOn(&run_geo_tests.step);
    test_step.dependOn(&run_bridge_tests.step);
    test_step.dependOn(&run_acp_tests.step);
    test_step.dependOn(&run_acp_mnxfi_tests.step);
    test_step.dependOn(&run_liveness_tests.step);
    test_step.dependOn(&run_czernowitz_tests.step);
    test_step.dependOn(&run_snapshot_tests.step);
    test_step.dependOn(&run_rainbow_tests.step);
    test_step.dependOn(&run_damage_tests.step);
    test_step.dependOn(&run_cell_dispatch_tests.step);
    test_step.dependOn(&run_tileable_shader_tests.step);
    test_step.dependOn(&run_homotopy_tests.step);
    test_step.dependOn(&run_linalg_tests.step);
    test_step.dependOn(&run_ripser_tests.step);
    test_step.dependOn(&run_scs_tests.step);
    test_step.dependOn(&run_continuation_tests.step);
    test_step.dependOn(&run_bci_tests.step);
    test_step.dependOn(&run_fem_tests.step);
    test_step.dependOn(&run_spectral_tensor_tests.step);
    test_step.dependOn(&run_prigogine_tests.step);
    test_step.dependOn(&run_spectrum_tests.step);
    test_step.dependOn(&run_cell_sync_tests.step);
    test_step.dependOn(&run_qasm_tests.step);
    test_step.dependOn(&run_color_simd_tests.step);
    // Worlds module tests (new implementation)
    test_step.dependOn(&run_persistent_tests.step);
    test_step.dependOn(&run_syrup_adapter_tests.step);
    test_step.dependOn(&run_world_tests.step);
    test_step.dependOn(&run_ab_test_tests.step);
    test_step.dependOn(&run_benchmark_adapter_tests.step);
    test_step.dependOn(&run_circuit_world_tests.step);
    test_step.dependOn(&run_openbci_bridge_tests.step);
    test_step.dependOn(&run_worlds_integration_tests.step);
    test_step.dependOn(&run_cyton_parser_tests.step);
    test_step.dependOn(&run_fft_bands_tests.step);
    test_step.dependOn(&run_csv_simd_tests.step);
    test_step.dependOn(&run_spatial_propagator_tests.step);
    test_step.dependOn(&run_quantize_tests.step);

    // Message Framing module + tests
    const message_frame_mod = b.addModule("message_frame", .{
        .root_source_file = b.path("src/message_frame.zig"),
        .target = target,
        .optimize = optimize,
    });
    const message_frame_test_mod = b.createModule(.{
        .root_source_file = b.path("src/message_frame.zig"),
        .target = target,
        .optimize = optimize,
    });
    const message_frame_tests = b.addTest(.{ .root_module = message_frame_test_mod });
    const run_message_frame_tests = b.addRunArtifact(message_frame_tests);
    test_step.dependOn(&run_message_frame_tests.step);

    // WebSocket Framing module (Ghostty-Emacs protocol) + tests
    const websocket_framing_mod = b.addModule("websocket_framing", .{
        .root_source_file = b.path("src/websocket_framing.zig"),
        .target = target,
        .optimize = optimize,
    });
    const websocket_framing_test_mod = b.createModule(.{
        .root_source_file = b.path("src/websocket_framing.zig"),
        .target = target,
        .optimize = optimize,
    });
    const websocket_framing_tests = b.addTest(.{ .root_module = websocket_framing_test_mod });
    const run_websocket_framing_tests = b.addRunArtifact(websocket_framing_tests);
    test_step.dependOn(&run_websocket_framing_tests.step);

    // Ghostty Web Server module
    const ghostty_web_server_mod = b.createModule(.{
        .root_source_file = b.path("src/ghostty_web_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    ghostty_web_server_mod.addImport("websocket_framing", websocket_framing_mod);

    const ghostty_web_exe = b.addExecutable(.{
        .name = "ghostty-web",
        .root_module = ghostty_web_server_mod,
    });
    b.installArtifact(ghostty_web_exe);

    // Ghostty IX (Interactive Execution) module
    const ghostty_ix_mod = b.addModule("ghostty_ix", .{
        .root_source_file = b.path("src/ghostty_ix.zig"),
        .target = target,
        .optimize = optimize,
    });
    ghostty_ix_mod.addImport("websocket_framing", websocket_framing_mod);
    ghostty_ix_mod.addImport("spatial_propagator", spatial_propagator_mod);
    ghostty_ix_mod.addImport("propagator", propagator_mod);

    // Tests for ghostty_ix
    const ghostty_ix_test_mod = b.createModule(.{
        .root_source_file = b.path("src/ghostty_ix.zig"),
        .target = target,
        .optimize = optimize,
    });
    ghostty_ix_test_mod.addImport("websocket_framing", websocket_framing_mod);
    ghostty_ix_test_mod.addImport("spatial_propagator", spatial_propagator_mod);
    ghostty_ix_test_mod.addImport("propagator", propagator_mod);

    const ghostty_ix_tests = b.addTest(.{ .root_module = ghostty_ix_test_mod });
    const run_ghostty_ix_tests = b.addRunArtifact(ghostty_ix_tests);
    test_step.dependOn(&run_ghostty_ix_tests.step);

    // Ghostty IX Shell Executor module
    const ghostty_ix_shell_mod = b.addModule("ghostty_ix_shell", .{
        .root_source_file = b.path("src/ghostty_ix_shell.zig"),
        .target = target,
        .optimize = optimize,
    });
    ghostty_ix_shell_mod.addImport("ghostty_ix", ghostty_ix_mod);

    // Note: shell/spatial/continuation/bim/http sub-module tests are run
    // transitively via ghostty_ix_test_mod (avoids circular module dependency)

    // Update ghostty_ix_mod to include shell executor
    ghostty_ix_mod.addImport("ghostty_ix_shell", ghostty_ix_shell_mod);
    ghostty_ix_test_mod.addImport("ghostty_ix_shell", ghostty_ix_shell_mod);

    // Ghostty IX Spatial Executor module
    const ghostty_ix_spatial_mod = b.addModule("ghostty_ix_spatial", .{
        .root_source_file = b.path("src/ghostty_ix_spatial.zig"),
        .target = target,
        .optimize = optimize,
    });
    ghostty_ix_spatial_mod.addImport("ghostty_ix", ghostty_ix_mod);
    ghostty_ix_spatial_mod.addImport("spatial_propagator", spatial_propagator_mod);

    // Spatial test runs via ghostty_ix_test_mod (avoids circular dependency)

    // Update ghostty_ix_mod to include spatial executor
    ghostty_ix_mod.addImport("ghostty_ix_spatial", ghostty_ix_spatial_mod);
    ghostty_ix_test_mod.addImport("ghostty_ix_spatial", ghostty_ix_spatial_mod);

    // Continuation Executor module (Phase 4 - OCapN + Boxxy integration)
    const ghostty_ix_continuation_mod = b.addModule("ghostty_ix_continuation", .{
        .root_source_file = b.path("src/ghostty_ix_continuation.zig"),
        .target = target,
        .optimize = optimize,
    });
    ghostty_ix_continuation_mod.addImport("ghostty_ix", ghostty_ix_mod);

    // Continuation test runs via ghostty_ix_test_mod (avoids circular dependency)

    // BIM (Basic Interaction Machine) module (Phase 4 - Bytecode VM for unification)
    const ghostty_ix_bim_mod = b.addModule("ghostty_ix_bim", .{
        .root_source_file = b.path("src/ghostty_ix_bim.zig"),
        .target = target,
        .optimize = optimize,
    });
    ghostty_ix_bim_mod.addImport("ghostty_ix", ghostty_ix_mod);

    // BIM test runs via ghostty_ix_test_mod (avoids circular dependency)

    // Update ghostty_ix_mod to include Phase 4 modules
    ghostty_ix_mod.addImport("ghostty_ix_continuation", ghostty_ix_continuation_mod);
    ghostty_ix_test_mod.addImport("ghostty_ix_continuation", ghostty_ix_continuation_mod);
    ghostty_ix_mod.addImport("ghostty_ix_bim", ghostty_ix_bim_mod);
    ghostty_ix_test_mod.addImport("ghostty_ix_bim", ghostty_ix_bim_mod);

    // HTTP Server module (Phase 5 - Monitoring & Feedback on :7071)
    const ghostty_ix_http_mod = b.addModule("ghostty_ix_http", .{
        .root_source_file = b.path("src/ghostty_ix_http.zig"),
        .target = target,
        .optimize = optimize,
    });
    ghostty_ix_http_mod.addImport("ghostty_ix", ghostty_ix_mod);

    // HTTP test runs via ghostty_ix_test_mod (avoids circular dependency)

    // Update ghostty_ix_mod to include HTTP server
    ghostty_ix_mod.addImport("ghostty_ix_http", ghostty_ix_http_mod);
    ghostty_ix_test_mod.addImport("ghostty_ix_http", ghostty_ix_http_mod);

    // TCP Transport module + tests
    const tcp_transport_mod = b.addModule("tcp_transport", .{
        .root_source_file = b.path("src/tcp_transport.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tcp_transport_test_mod = b.createModule(.{
        .root_source_file = b.path("src/tcp_transport.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tcp_transport_tests = b.addTest(.{ .root_module = tcp_transport_test_mod });
    const run_tcp_transport_tests = b.addRunArtifact(tcp_transport_tests);
    test_step.dependOn(&run_tcp_transport_tests.step);

    // Fountain module (Luby Transform rateless erasure codes)
    const fountain_mod = b.addModule("fountain", .{
        .root_source_file = b.path("src/fountain.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fountain_test_mod = b.createModule(.{
        .root_source_file = b.path("src/fountain.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fountain_tests = b.addTest(.{ .root_module = fountain_test_mod });
    const run_fountain_tests = b.addRunArtifact(fountain_tests);
    test_step.dependOn(&run_fountain_tests.step);

    // SplitMixTrit module (Triadic PRNG: ChaCha × SplitMix64 × Rybka)
    _ = b.addModule("splitmix_trit", .{
        .root_source_file = b.path("src/splitmix_trit.zig"),
        .target = target,
        .optimize = optimize,
    });
    const splitmix_trit_test_mod = b.createModule(.{
        .root_source_file = b.path("src/splitmix_trit.zig"),
        .target = target,
        .optimize = optimize,
    });
    const splitmix_trit_tests = b.addTest(.{ .root_module = splitmix_trit_test_mod });
    const run_splitmix_trit_tests = b.addRunArtifact(splitmix_trit_tests);
    test_step.dependOn(&run_splitmix_trit_tests.step);

    // QRTP Frame module (QR Transfer Protocol framing as Syrup records)
    const qrtp_frame_mod = b.addModule("qrtp_frame", .{
        .root_source_file = b.path("src/qrtp_frame.zig"),
        .target = target,
        .optimize = optimize,
    });
    qrtp_frame_mod.addImport("fountain", fountain_mod);
    const qrtp_frame_test_mod = b.createModule(.{
        .root_source_file = b.path("src/qrtp_frame.zig"),
        .target = target,
        .optimize = optimize,
    });
    qrtp_frame_test_mod.addImport("fountain", fountain_mod);
    const qrtp_frame_tests = b.addTest(.{ .root_module = qrtp_frame_test_mod });
    const run_qrtp_frame_tests = b.addRunArtifact(qrtp_frame_tests);
    test_step.dependOn(&run_qrtp_frame_tests.step);

    // QRTP Transport module (screen↔camera air-gapped transport)
    const qrtp_transport_mod = b.addModule("qrtp_transport", .{
        .root_source_file = b.path("src/qrtp_transport.zig"),
        .target = target,
        .optimize = optimize,
    });
    qrtp_transport_mod.addImport("fountain", fountain_mod);
    qrtp_transport_mod.addImport("qrtp_frame", qrtp_frame_mod);
    const qrtp_transport_test_mod = b.createModule(.{
        .root_source_file = b.path("src/qrtp_transport.zig"),
        .target = target,
        .optimize = optimize,
    });
    qrtp_transport_test_mod.addImport("fountain", fountain_mod);
    qrtp_transport_test_mod.addImport("qrtp_frame", qrtp_frame_mod);
    const qrtp_transport_tests = b.addTest(.{ .root_module = qrtp_transport_test_mod });
    const run_qrtp_transport_tests = b.addRunArtifact(qrtp_transport_tests);
    test_step.dependOn(&run_qrtp_transport_tests.step);

    // UR Robot Adapter module (Bridge 9 Phase 3) + tests
    const ur_robot_adapter_mod = b.addModule("ur_robot_adapter", .{
        .root_source_file = b.path("src/ur_robot_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    ur_robot_adapter_mod.addImport("message_frame", message_frame_mod);
    ur_robot_adapter_mod.addImport("tcp_transport", tcp_transport_mod);
    ur_robot_adapter_mod.addImport("syrup", syrup_mod);

    const ur_robot_adapter_test_mod = b.createModule(.{
        .root_source_file = b.path("src/ur_robot_adapter.zig"),
        .target = target,
        .optimize = optimize,
    });
    ur_robot_adapter_test_mod.addImport("message_frame", message_frame_mod);
    ur_robot_adapter_test_mod.addImport("tcp_transport", tcp_transport_mod);
    ur_robot_adapter_test_mod.addImport("syrup", syrup_mod);

    const ur_robot_adapter_tests = b.addTest(.{ .root_module = ur_robot_adapter_test_mod });
    const run_ur_robot_adapter_tests = b.addRunArtifact(ur_robot_adapter_tests);
    test_step.dependOn(&run_ur_robot_adapter_tests.step);

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

    // ========================================
    // Stellogen Compiler (wasm32-standalone target)
    // ========================================

    // Stellogen module (native target for CLI/tests)
    const stellogen_mod = b.addModule("stellogen", .{
        .root_source_file = b.path("src/stellogen/mod.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Stellogen tests (native)
    const stellogen_test_mod = b.createModule(.{
        .root_source_file = b.path("src/stellogen/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    const stellogen_tests = b.addTest(.{ .root_module = stellogen_test_mod });
    const run_stellogen_tests = b.addRunArtifact(stellogen_tests);
    test_step.dependOn(&run_stellogen_tests.step);

    // Stellogen AST tests
    const stellogen_ast_test_mod = b.createModule(.{
        .root_source_file = b.path("src/stellogen/ast.zig"),
        .target = target,
        .optimize = optimize,
    });
    const stellogen_ast_tests = b.addTest(.{ .root_module = stellogen_ast_test_mod });
    const run_stellogen_ast_tests = b.addRunArtifact(stellogen_ast_tests);
    test_step.dependOn(&run_stellogen_ast_tests.step);

    // Stellogen Unify tests
    const stellogen_unify_test_mod = b.createModule(.{
        .root_source_file = b.path("src/stellogen/unify.zig"),
        .target = target,
        .optimize = optimize,
    });
    const stellogen_unify_tests = b.addTest(.{ .root_module = stellogen_unify_test_mod });
    const run_stellogen_unify_tests = b.addRunArtifact(stellogen_unify_tests);
    test_step.dependOn(&run_stellogen_unify_tests.step);

    // Stellogen Lexer tests
    const stellogen_lexer_test_mod = b.createModule(.{
        .root_source_file = b.path("src/stellogen/lexer.zig"),
        .target = target,
        .optimize = optimize,
    });
    const stellogen_lexer_tests = b.addTest(.{ .root_module = stellogen_lexer_test_mod });
    const run_stellogen_lexer_tests = b.addRunArtifact(stellogen_lexer_tests);
    test_step.dependOn(&run_stellogen_lexer_tests.step);

    // Stellogen Parser tests
    const stellogen_parser_test_mod = b.createModule(.{
        .root_source_file = b.path("src/stellogen/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    const stellogen_parser_tests = b.addTest(.{ .root_module = stellogen_parser_test_mod });
    const run_stellogen_parser_tests = b.addRunArtifact(stellogen_parser_tests);
    test_step.dependOn(&run_stellogen_parser_tests.step);

    // Stellogen Executor tests
    const stellogen_executor_test_mod = b.createModule(.{
        .root_source_file = b.path("src/stellogen/executor.zig"),
        .target = target,
        .optimize = optimize,
    });
    const stellogen_executor_tests = b.addTest(.{ .root_module = stellogen_executor_test_mod });
    const run_stellogen_executor_tests = b.addRunArtifact(stellogen_executor_tests);
    test_step.dependOn(&run_stellogen_executor_tests.step);

    // Stellogen Codegen tests
    const stellogen_codegen_test_mod = b.createModule(.{
        .root_source_file = b.path("src/stellogen/codegen.zig"),
        .target = target,
        .optimize = optimize,
    });
    const stellogen_codegen_tests = b.addTest(.{ .root_module = stellogen_codegen_test_mod });
    const run_stellogen_codegen_tests = b.addRunArtifact(stellogen_codegen_tests);
    test_step.dependOn(&run_stellogen_codegen_tests.step);

    // Stellogen CLI compiler
    const stellogen_cli_mod = b.createModule(.{
        .root_source_file = b.path("tools/stellogen_cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    stellogen_cli_mod.addImport("stellogen", stellogen_mod);

    const stellogen_cli_exe = b.addExecutable(.{
        .name = "stellogen",
        .root_module = stellogen_cli_mod,
    });
    b.installArtifact(stellogen_cli_exe);

    const run_stellogen_cli = b.addRunArtifact(stellogen_cli_exe);
    if (b.args) |args| {
        run_stellogen_cli.addArgs(args);
    }
    const stellogen_step = b.step("stellogen", "Run Stellogen compiler");
    stellogen_step.dependOn(&run_stellogen_cli.step);

    // Stellogen WASM library (wasm32-standalone target)
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const stellogen_wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/stellogen/wasm_runtime.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });

    const stellogen_wasm = b.addExecutable(.{
        .name = "stellogen-runtime",
        .root_module = stellogen_wasm_mod,
    });
    stellogen_wasm.entry = .disabled; // Library, not executable
    stellogen_wasm.rdynamic = true; // Export symbols
    b.installArtifact(stellogen_wasm);

    // ========================================
    // Entangled Terminal (CNOT₃ quantum control circuit)
    // ========================================

    // Entangle module (GF(3) qutrit gate for terminal cells)
    _ = b.addModule("entangle", .{
        .root_source_file = b.path("src/entangle.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Entangle module tests
    const entangle_test_mod = b.createModule(.{
        .root_source_file = b.path("src/entangle.zig"),
        .target = target,
        .optimize = optimize,
    });
    const entangle_tests = b.addTest(.{ .root_module = entangle_test_mod });
    const run_entangle_tests = b.addRunArtifact(entangle_tests);
    test_step.dependOn(&run_entangle_tests.step);

    // GF(3)⁵ Palette module (243-color successor to xterm-256)
    _ = b.addModule("gf3_palette", .{
        .root_source_file = b.path("src/gf3_palette.zig"),
        .target = target,
        .optimize = optimize,
    });

    // GF(3)⁵ Palette tests
    const gf3_palette_test_mod = b.createModule(.{
        .root_source_file = b.path("src/gf3_palette.zig"),
        .target = target,
        .optimize = optimize,
    });
    const gf3_palette_tests = b.addTest(.{ .root_module = gf3_palette_test_mod });
    const run_gf3_palette_tests = b.addRunArtifact(gf3_palette_tests);
    test_step.dependOn(&run_gf3_palette_tests.step);

    // Supermap module (Cyberphysical affordances × RF phase space × quantum supermaps)
    _ = b.addModule("supermap", .{
        .root_source_file = b.path("src/supermap.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Supermap tests
    const supermap_test_mod = b.createModule(.{
        .root_source_file = b.path("src/supermap.zig"),
        .target = target,
        .optimize = optimize,
    });
    const supermap_tests = b.addTest(.{ .root_module = supermap_test_mod });
    const run_supermap_tests = b.addRunArtifact(supermap_tests);
    test_step.dependOn(&run_supermap_tests.step);

    // Disclosure module (REGRET/GAY insurance protocol over internet phase space)
    _ = b.addModule("disclosure", .{
        .root_source_file = b.path("src/disclosure.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Disclosure tests
    const disclosure_test_mod = b.createModule(.{
        .root_source_file = b.path("src/disclosure.zig"),
        .target = target,
        .optimize = optimize,
    });
    const disclosure_tests = b.addTest(.{ .root_module = disclosure_test_mod });
    const run_disclosure_tests = b.addRunArtifact(disclosure_tests);
    test_step.dependOn(&run_disclosure_tests.step);

    // ========================================
    // Tapo P15 Energy Monitor (L14: Physical Energy Layer)
    // ========================================

    const tapo_energy_mod = b.addModule("tapo_energy", .{
        .root_source_file = b.path("src/tapo_energy.zig"),
        .target = target,
        .optimize = optimize,
    });
    tapo_energy_mod.addImport("syrup", syrup_mod);

    const tapo_energy_test_mod = b.createModule(.{
        .root_source_file = b.path("src/tapo_energy.zig"),
        .target = target,
        .optimize = optimize,
    });
    tapo_energy_test_mod.addImport("syrup", syrup_mod);
    const tapo_energy_tests = b.addTest(.{ .root_module = tapo_energy_test_mod });
    const run_tapo_energy_tests = b.addRunArtifact(tapo_energy_tests);
    test_step.dependOn(&run_tapo_energy_tests.step);

    const test_tapo_step = b.step("test-tapo", "Run Tapo P15 energy monitor tests");
    test_tapo_step.dependOn(&run_tapo_energy_tests.step);

    // ========================================
    // Universal BCI Receiver (nRF5340)
    // ========================================

    const bci_receiver_mod = b.addModule("bci_receiver", .{
        .root_source_file = b.path("src/bci_receiver.zig"),
        .target = target,
        .optimize = optimize,
    });
    bci_receiver_mod.addImport("syrup", syrup_mod);

    const bci_receiver_test_mod = b.createModule(.{
        .root_source_file = b.path("src/bci_receiver.zig"),
        .target = target,
        .optimize = optimize,
    });
    bci_receiver_test_mod.addImport("syrup", syrup_mod);
    const bci_receiver_tests = b.addTest(.{ .root_module = bci_receiver_test_mod });
    const run_bci_receiver_tests = b.addRunArtifact(bci_receiver_tests);
    test_step.dependOn(&run_bci_receiver_tests.step);

    const test_bci_step = b.step("test-bci", "Run universal BCI receiver tests");
    test_bci_step.dependOn(&run_bci_receiver_tests.step);

    // ========================================
    // Terminal Pipeline (terminal:// protocol)
    // ========================================

    // Terminal module (native, for library use)
    const terminal_mod = b.addModule("terminal", .{
        .root_source_file = b.path("src/terminal.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Terminal tests (native)
    const terminal_test_mod = b.createModule(.{
        .root_source_file = b.path("src/terminal.zig"),
        .target = target,
        .optimize = optimize,
    });
    const terminal_tests = b.addTest(.{ .root_module = terminal_test_mod });
    const run_terminal_tests = b.addRunArtifact(terminal_tests);
    test_step.dependOn(&run_terminal_tests.step);

    // Retty module (ratatui-like widget/layout engine)
    const retty_mod = b.addModule("retty", .{
        .root_source_file = b.path("src/retty.zig"),
        .target = target,
        .optimize = optimize,
    });
    retty_mod.addImport("terminal", terminal_mod);

    // Retty tests
    const retty_test_mod = b.createModule(.{
        .root_source_file = b.path("src/retty.zig"),
        .target = target,
        .optimize = optimize,
    });
    retty_test_mod.addImport("terminal", terminal_mod);
    const retty_tests = b.addTest(.{ .root_module = retty_test_mod });
    const run_retty_tests = b.addRunArtifact(retty_tests);
    test_step.dependOn(&run_retty_tests.step);

    // Retty-specific test step
    const test_retty_step = b.step("test-retty", "Run retty widget engine tests");
    test_retty_step.dependOn(&run_retty_tests.step);

    // Transient module (Emacs transient.el popup menus as retty widgets)
    _ = b.addModule("transient", .{
        .root_source_file = b.path("src/transient.zig"),
        .target = target,
        .optimize = optimize,
    });
    const transient_test_mod = b.createModule(.{
        .root_source_file = b.path("src/transient.zig"),
        .target = target,
        .optimize = optimize,
    });
    transient_test_mod.addImport("retty", retty_mod);
    const transient_tests = b.addTest(.{ .root_module = transient_test_mod });
    const run_transient_tests = b.addRunArtifact(transient_tests);
    test_step.dependOn(&run_transient_tests.step);

    const test_transient_step = b.step("test-transient", "Run transient widget tests");
    test_transient_step.dependOn(&run_transient_tests.step);

    // GoI module (Geometry of Interaction — proof nets, token machine, cut elimination)
    _ = b.addModule("goi", .{
        .root_source_file = b.path("src/goi.zig"),
        .target = target,
        .optimize = optimize,
    });
    const goi_test_mod = b.createModule(.{
        .root_source_file = b.path("src/goi.zig"),
        .target = target,
        .optimize = optimize,
    });
    const goi_tests = b.addTest(.{ .root_module = goi_test_mod });
    const run_goi_tests = b.addRunArtifact(goi_tests);
    test_step.dependOn(&run_goi_tests.step);

    const test_goi_step = b.step("test-goi", "Run Geometry of Interaction tests");
    test_goi_step.dependOn(&run_goi_tests.step);

    // Terminal WASM library (wasm32-freestanding target)
    const terminal_wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/terminal_wasm.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });

    const terminal_wasm = b.addExecutable(.{
        .name = "terminal-runtime",
        .root_module = terminal_wasm_mod,
    });
    terminal_wasm.entry = .disabled; // Library, not executable
    terminal_wasm.rdynamic = true; // Export symbols
    b.installArtifact(terminal_wasm);

    // Zoad Executable (Zig Toad) - TUI ACP Client
    const zoad_mod = b.createModule(.{
        .root_source_file = b.path("src/zoad.zig"),
        .target = target,
        .optimize = optimize,
    });
    zoad_mod.addImport("retty", retty_mod);
    zoad_mod.addImport("acp", acp_mod);
    zoad_mod.addImport("syrup", syrup_mod);
    zoad_mod.addImport("terminal", terminal_mod);
    
    // Notcurses backend module
    const nc_backend_mod = b.createModule(.{
        .root_source_file = b.path("src/notcurses_backend.zig"),
        .target = target,
        .optimize = optimize,
    });
    nc_backend_mod.addImport("retty", retty_mod);
    nc_backend_mod.addIncludePath(.{ .cwd_relative = "/nix/store/vp4mqyfj800wyhc92d888g3glzl3dzn7-notcurses-3.0.17-dev/include" });
    
    // Simple TCP module
    const simple_tcp_mod = b.createModule(.{
        .root_source_file = b.path("src/simple_tcp.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tape recorder module
    const tape_mod = b.createModule(.{
        .root_source_file = b.path("src/tape_recorder.zig"),
        .target = target,
        .optimize = optimize,
    });
    tape_mod.addImport("syrup", syrup_mod);
    tape_mod.addImport("damage", damage_mod);

    zoad_mod.addImport("notcurses_backend", nc_backend_mod);
    zoad_mod.addImport("simple_tcp", simple_tcp_mod);
    zoad_mod.addImport("tape_recorder", tape_mod);
    zoad_mod.addImport("damage", damage_mod);

    const zoad_exe = b.addExecutable(.{
        .name = "zoad",
        .root_module = zoad_mod,
    });
    zoad_exe.addLibraryPath(.{ .cwd_relative = "/nix/store/2fv3qgr6wnsxkxanhl31sry78rn1vk74-notcurses-3.0.17/lib" });
    zoad_exe.linkLibC();
    zoad_exe.linkSystemLibrary("notcurses");
    zoad_exe.linkSystemLibrary("notcurses-core");
    
    b.installArtifact(zoad_exe);

    const run_zoad = b.addRunArtifact(zoad_exe);
    const run_zoad_step = b.step("zoad", "Run ZOAD TUI");
    run_zoad_step.dependOn(&run_zoad.step);

    worlds_mod.addImport("retty", retty_mod);

    // Zeta CLI Executable
    const zeta_cli_mod = b.createModule(.{
        .root_source_file = b.path("src/zeta_cli.zig"),
        .target = target,
        .optimize = optimize,
    });
    zeta_cli_mod.addImport("retty", retty_mod);
    zeta_cli_mod.addImport("worlds", worlds_mod);

    const zeta_exe = b.addExecutable(.{
        .name = "zeta-cli",
        .root_module = zeta_cli_mod,
    });
    b.installArtifact(zeta_exe);

    const run_zeta = b.addRunArtifact(zeta_exe);
    const run_zeta_step = b.step("run-zeta", "Run Zeta World CLI");
    run_zeta_step.dependOn(&run_zeta.step);

    // Zeta World tests (Test as World)
    const zeta_test_mod = b.createModule(.{
        .root_source_file = b.path("src/worlds/zeta/zeta_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    zeta_test_mod.addImport("spectral_tensor", spectral_tensor_mod);
    zeta_test_mod.addImport("retty", retty_mod);
    zeta_test_mod.addImport("lux_color", lux_color_mod);
    
    const zeta_tests = b.addTest(.{ .root_module = zeta_test_mod });
    const run_zeta_tests = b.addRunArtifact(zeta_tests);
    test_step.dependOn(&run_zeta_tests.step);
    
    const test_zeta_step = b.step("test-zeta", "Run Zeta World tests");
    test_zeta_step.dependOn(&run_zeta_tests.step);

}
