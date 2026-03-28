//! edf_physionet_test.zig — Validate EDF reader against real PhysioNet data
//!
//! Reads testdata/S001R01.edf (1.2MB, 65-channel BCI2000 motor imagery)
//! downloaded from physionet.org/files/eegmmidb/1.0.0/S001/S001R01.edf
//!
//! Download: curl -sL -o testdata/S001R01.edf \
//!   "https://physionet.org/files/eegmmidb/1.0.0/S001/S001R01.edf"

const std = @import("std");
const edf_reader = @import("edf_reader");

test "PhysioNet EEG Motor Movement: parse real 65ch EDF" {
    const allocator = std.testing.allocator;

    // Read file from disk (skip if not downloaded)
    const file = std.fs.cwd().openFile("testdata/S001R01.edf", .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("SKIP: testdata/S001R01.edf not found (download with: curl -sL -o testdata/S001R01.edf \"https://physionet.org/files/eegmmidb/1.0.0/S001/S001R01.edf\")\n", .{});
            return;
        }
        return err;
    };
    defer file.close();

    const buf = try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(buf);

    const edf = try edf_reader.EDFFile.parse(buf);

    // 65 channels (64 EEG + 1 annotation)
    try std.testing.expectEqual(@as(u16, 65), edf.n_channels);

    // 61 data records at 1s each = 61s recording
    try std.testing.expectEqual(@as(u32, 61), edf.n_records);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), edf.record_duration, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 61.0), edf.totalDuration(), 0.001);

    // EEG channels at 160 Hz
    try std.testing.expectEqual(@as(u16, 160), edf.channels[0].samples_per_record);
    try std.testing.expectApproxEqAbs(@as(f64, 160.0), edf.sampleRate(0), 0.001);

    // First channel label: "Fc5." (10-5 system, BCI2000 convention)
    try std.testing.expectEqualStrings("Fc5.", edf.channels[0].labelStr());

    // Physical range for EEG channels: [-8092, 8092] µV
    try std.testing.expectApproxEqAbs(@as(f64, -8092.0), edf.channels[0].physical_min, 0.1);
    try std.testing.expectApproxEqAbs(@as(f64, 8092.0), edf.channels[0].physical_max, 0.1);

    // Digital range matches (identity mapping in this dataset)
    try std.testing.expectEqual(@as(i16, -8092), edf.channels[0].digital_min);
    try std.testing.expectEqual(@as(i16, 8092), edf.channels[0].digital_max);

    // Read first few EEG samples from channel 0
    const s0 = try edf.getSample(0, 0, 0);
    const s1 = try edf.getSample(0, 0, 1);
    // Known values from hex dump: -16, -56
    try std.testing.expectEqual(@as(i16, -16), s0);
    try std.testing.expectEqual(@as(i16, -56), s1);

    // Physical conversion: with identity digital-physical mapping,
    // digital -16 → physical -16.0 µV
    const phys = edf.toPhysical(0, s0);
    try std.testing.expectApproxEqAbs(@as(f64, -16.0), phys, 0.1);

    // File size check
    try std.testing.expectEqual(@as(usize, 1275936), buf.len);

    // Header size: 256 + 65*256 = 16896
    try std.testing.expectEqual(@as(u32, 16896), edf.header_bytes);

    std.debug.print("PhysioNet EDF: {d} channels, {d} Hz, {d}s, {d} samples total\n", .{
        edf.n_channels,
        @as(u32, edf.channels[0].samples_per_record),
        edf.n_records,
        @as(u64, edf.n_records) * edf.channels[0].samples_per_record,
    });
}
