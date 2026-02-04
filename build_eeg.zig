const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Define modules
    const cyton_parser_mod = b.addModule("cyton_parser", .{
        .root_source_file = b.path("src/cyton_parser.zig"),
        .target = target,
        .optimize = optimize,
    });

    const fft_bands_mod = b.addModule("fft_bands", .{
        .root_source_file = b.path("src/fft_bands.zig"),
        .target = target,
        .optimize = optimize,
    });

    // EEG Processing Binary
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
}
