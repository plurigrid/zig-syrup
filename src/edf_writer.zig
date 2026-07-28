//! edf_writer.zig — European Data Format (EDF+) Writer
//!
//! Writes EEG data in EDF+ format for archival and analysis with
//! standard tools (MNE-Python, EEGLAB, EDFBrowser).
//!
//! EDF+ spec: https://www.edfplus.info/specs/edfplus.html
//!
//! Header layout (256 + 256*ns bytes):
//!   General header:  256 bytes (version, patient, recording, date/time, etc.)
//!   Per-channel:     256*ns bytes (labels, units, physical/digital min/max, etc.)
//!
//! Data records:
//!   Each record = duration seconds (typically 1s) of data.
//!   Samples are 16-bit signed integers, little-endian, interleaved per channel.
//!
//! Digital-to-physical conversion:
//!   physical = (digital - digital_min) * (physical_max - physical_min)
//!              / (digital_max - digital_min) + physical_min

const std = @import("std");
// bci_receiver types not needed for EDF writing

// ============================================================================
// CONSTANTS
// ============================================================================

/// EDF version string (8 bytes, space-padded)
const EDF_VERSION = "0       ";

/// Maximum channels supported in this implementation
pub const MAX_EDF_CHANNELS: usize = 64;

/// EDF header fixed size (general part)
const HEADER_GENERAL_SIZE: usize = 256;

/// EDF header per-channel size
const HEADER_CHANNEL_SIZE: usize = 256;

/// Default data record duration in seconds
pub const DEFAULT_RECORD_DURATION: f64 = 1.0;

/// 10-20 system channel labels for standard EEG montage
pub const LABELS_10_20 = [_][]const u8{
    "Fp1", "Fp2", "F7", "F3", "Fz", "F4", "F8", "T3",
    "C3",  "Cz",  "C4", "T4", "T5", "P3", "Pz", "P4",
    "T6",  "O1",  "Oz", "O2", "A1", "A2", "F9", "F10",
};

// ============================================================================
// EDF HEADER
// ============================================================================

pub const EDFHeader = struct {
    /// Patient info (80 bytes in EDF)
    patient_info: [80]u8 = @splat(' '),

    /// Recording info (80 bytes in EDF)
    recording_info: [80]u8 = @splat(' '),

    /// Start date DD.MM.YY (8 bytes)
    start_date: [8]u8 = "01.01.00".*,

    /// Start time HH.MM.SS (8 bytes)
    start_time: [8]u8 = "00.00.00".*,

    /// Number of channels
    n_channels: u16 = 0,

    /// Duration of each data record in seconds
    record_duration: f64 = DEFAULT_RECORD_DURATION,

    /// Per-channel labels (max 16 chars each in EDF)
    labels: [MAX_EDF_CHANNELS][16]u8 = @splat(@as([16]u8, @splat(' '))),

    /// Per-channel transducer type (max 80 chars)
    transducer: [MAX_EDF_CHANNELS][80]u8 = @splat(@as([80]u8, @splat(' '))),

    /// Per-channel physical dimension/unit (max 8 chars, e.g., "uV")
    physical_dim: [MAX_EDF_CHANNELS][8]u8 = @splat(@as([8]u8, @splat(' '))),

    /// Per-channel physical minimum
    physical_min: [MAX_EDF_CHANNELS]f64 = @splat(-3200.0),

    /// Per-channel physical maximum
    physical_max: [MAX_EDF_CHANNELS]f64 = @splat(3200.0),

    /// Per-channel digital minimum
    digital_min: [MAX_EDF_CHANNELS]i16 = @splat(-32768),

    /// Per-channel digital maximum
    digital_max: [MAX_EDF_CHANNELS]i16 = @splat(32767),

    /// Per-channel sample rate (samples per data record)
    samples_per_record: [MAX_EDF_CHANNELS]u16 = @splat(250),

    /// Set channel label from a string slice
    pub fn setLabel(self: *EDFHeader, channel: usize, label: []const u8) void {
        if (channel >= MAX_EDF_CHANNELS) return;
        @memset(&self.labels[channel], ' ');
        const len = @min(label.len, 16);
        @memcpy(self.labels[channel][0..len], label[0..len]);
    }

    /// Set patient info from string
    pub fn setPatientInfo(self: *EDFHeader, info: []const u8) void {
        @memset(&self.patient_info, ' ');
        const len = @min(info.len, 80);
        @memcpy(self.patient_info[0..len], info[0..len]);
    }

    /// Set recording info from string
    pub fn setRecordingInfo(self: *EDFHeader, info: []const u8) void {
        @memset(&self.recording_info, ' ');
        const len = @min(info.len, 80);
        @memcpy(self.recording_info[0..len], info[0..len]);
    }

    /// Set physical unit for a channel
    pub fn setPhysicalDim(self: *EDFHeader, channel: usize, dim: []const u8) void {
        if (channel >= MAX_EDF_CHANNELS) return;
        @memset(&self.physical_dim[channel], ' ');
        const len = @min(dim.len, 8);
        @memcpy(self.physical_dim[channel][0..len], dim[0..len]);
    }

    /// Compute total header size
    pub fn headerSize(self: *const EDFHeader) usize {
        return HEADER_GENERAL_SIZE + @as(usize, self.n_channels) * HEADER_CHANNEL_SIZE;
    }

    /// Create default header for standard 8-channel EEG
    pub fn defaultEEG(n_channels: u16, sample_rate: u16) EDFHeader {
        var hdr = EDFHeader{};
        hdr.n_channels = @min(n_channels, MAX_EDF_CHANNELS);
        for (0..hdr.n_channels) |i| {
            if (i < LABELS_10_20.len) {
                hdr.setLabel(i, LABELS_10_20[i]);
            }
            hdr.setPhysicalDim(i, "uV");
            hdr.samples_per_record[i] = sample_rate;
            hdr.physical_min[i] = -3200.0;
            hdr.physical_max[i] = 3200.0;
            hdr.digital_min[i] = -32768;
            hdr.digital_max[i] = 32767;
        }
        hdr.setPatientInfo("X X X X");
        hdr.setRecordingInfo("Startdate X X X X");
        return hdr;
    }
};

// ============================================================================
// EDF WRITER
// ============================================================================

pub const EDFWriter = struct {
    header: EDFHeader,
    n_records: u32,
    file_buf: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    /// Initialize writer with header.
    /// Header is buffered and written to output when close() is called,
    /// because n_records is not known until all data is written.
    pub fn init(allocator: std.mem.Allocator, header: EDFHeader) EDFWriter {
        return .{
            .header = header,
            .n_records = 0,
            .file_buf = .empty,
            .allocator = allocator,
        };
    }

    /// Write one data record (typically 1 second of data).
    ///
    /// samples[channel][sample_index] -- one data record per channel.
    /// Each channel has samples_per_record[ch] samples.
    /// Samples are 16-bit signed integers (already digital-scaled).
    pub fn writeDataRecord(self: *EDFWriter, samples: []const []const i16) !void {
        const n_ch = @min(samples.len, self.header.n_channels);
        for (0..n_ch) |ch| {
            const n_samp = @min(samples[ch].len, self.header.samples_per_record[ch]);
            for (0..n_samp) |s| {
                const val = samples[ch][s];
                try self.file_buf.append(self.allocator, @as(u8, @truncate(@as(u16, @bitCast(val)))));
                try self.file_buf.append(self.allocator, @as(u8, @truncate(@as(u16, @bitCast(val)) >> 8)));
            }
        }
        self.n_records += 1;
    }

    /// Finalize and return the complete EDF file as a byte buffer.
    /// Caller owns the returned slice.
    pub fn finalize(self: *EDFWriter) ![]u8 {
        const allocator = self.allocator;
        const hdr_size = self.header.headerSize();
        const data = try self.file_buf.toOwnedSlice(allocator);
        defer allocator.free(data);

        var result: std.ArrayList(u8) = .empty;
        try result.ensureTotalCapacity(allocator, hdr_size + data.len);

        // Write general header (256 bytes)
        try appendFixedStr(&result, allocator, EDF_VERSION, 8); // version
        try appendFixedStr(&result, allocator, &self.header.patient_info, 80); // patient
        try appendFixedStr(&result, allocator, &self.header.recording_info, 80); // recording
        try appendFixedStr(&result, allocator, &self.header.start_date, 8); // date
        try appendFixedStr(&result, allocator, &self.header.start_time, 8); // time
        try appendFixedInt(&result, allocator, @as(i64, @intCast(hdr_size)), 8); // header bytes
        try appendFixedStr(&result, allocator, "EDF+C" ++ "                                 ", 44); // reserved (EDF+C)
        try appendFixedInt(&result, allocator, self.n_records, 8); // n_records
        try appendFixedFloat(&result, allocator, self.header.record_duration, 8); // duration
        try appendFixedInt(&result, allocator, self.header.n_channels, 4); // n_channels

        const n_ch = self.header.n_channels;

        // Per-channel fields (each field for all channels, then next field)
        // Labels (16 bytes each)
        for (0..n_ch) |i| try appendFixedStr(&result, allocator, &self.header.labels[i], 16);
        // Transducer (80 bytes each)
        for (0..n_ch) |i| try appendFixedStr(&result, allocator, &self.header.transducer[i], 80);
        // Physical dimension (8 bytes each)
        for (0..n_ch) |i| try appendFixedStr(&result, allocator, &self.header.physical_dim[i], 8);
        // Physical min (8 bytes each)
        for (0..n_ch) |i| try appendFixedFloat(&result, allocator, self.header.physical_min[i], 8);
        // Physical max (8 bytes each)
        for (0..n_ch) |i| try appendFixedFloat(&result, allocator, self.header.physical_max[i], 8);
        // Digital min (8 bytes each)
        for (0..n_ch) |i| try appendFixedInt(&result, allocator, self.header.digital_min[i], 8);
        // Digital max (8 bytes each)
        for (0..n_ch) |i| try appendFixedInt(&result, allocator, self.header.digital_max[i], 8);
        // Prefiltering (80 bytes each)
        for (0..n_ch) |_| try appendFixedStr(&result, allocator, &@as([80]u8, @splat(' ')), 80);
        // Samples per record (8 bytes each)
        for (0..n_ch) |i| try appendFixedInt(&result, allocator, self.header.samples_per_record[i], 8);
        // Reserved (32 bytes each)
        for (0..n_ch) |_| try appendFixedStr(&result, allocator, &@as([32]u8, @splat(' ')), 32);

        // Append data records
        try result.appendSlice(allocator, data);

        return try result.toOwnedSlice(allocator);
    }

    /// Free internal buffers
    pub fn deinit(self: *EDFWriter) void {
        self.file_buf.deinit(self.allocator);
    }
};

// ============================================================================
// HELPER FUNCTIONS — EDF field formatting
// ============================================================================

/// Write a fixed-width ASCII string field (space-padded)
fn appendFixedStr(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, str: []const u8, width: usize) !void {
    const len = @min(str.len, width);
    try buf.appendSlice(allocator, str[0..len]);
    // Pad with spaces
    for (0..width - len) |_| try buf.append(allocator, ' ');
}

/// Write an integer as ASCII in a fixed-width field (space-padded)
fn appendFixedInt(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: anytype, width: usize) !void {
    var tmp: [32]u8 = undefined;
    const int_val = @as(i64, @intCast(value));
    const slice = std.fmt.bufPrint(&tmp, "{d}", .{int_val}) catch &tmp;
    try appendFixedStr(buf, allocator, slice, width);
}

/// Write a float as ASCII in a fixed-width field (space-padded)
fn appendFixedFloat(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: f64, width: usize) !void {
    var tmp: [32]u8 = undefined;
    // EDF uses plain decimal notation
    if (value == @trunc(value)) {
        const slice = std.fmt.bufPrint(&tmp, "{d}", .{@as(i64, @intFromFloat(value))}) catch &tmp;
        try appendFixedStr(buf, allocator, slice, width);
    } else {
        const slice = std.fmt.bufPrint(&tmp, "{d:.6}", .{value}) catch &tmp;
        // Trim trailing zeros after decimal point
        var end: usize = slice.len;
        while (end > 1 and slice[end - 1] == '0') end -= 1;
        if (end > 0 and slice[end - 1] == '.') end -= 1;
        try appendFixedStr(buf, allocator, slice[0..end], width);
    }
}

/// Convert physical value to digital (i16) using EDF scaling
pub fn physicalToDigital(
    physical: f64,
    phys_min: f64,
    phys_max: f64,
    dig_min: i16,
    dig_max: i16,
) i16 {
    const phys_range = phys_max - phys_min;
    const dig_range: f64 = @as(f64, @floatFromInt(dig_max)) - @as(f64, @floatFromInt(dig_min));
    if (phys_range == 0) return 0;
    const digital_f = (physical - phys_min) / phys_range * dig_range + @as(f64, @floatFromInt(dig_min));
    // Clamp to i16 range
    const clamped = @max(@as(f64, -32768.0), @min(32767.0, digital_f));
    return @intFromFloat(clamped);
}

/// Convert digital value to physical using EDF scaling
pub fn digitalToPhysical(
    digital: i16,
    phys_min: f64,
    phys_max: f64,
    dig_min: i16,
    dig_max: i16,
) f64 {
    const phys_range = phys_max - phys_min;
    const dig_range: f64 = @as(f64, @floatFromInt(dig_max)) - @as(f64, @floatFromInt(dig_min));
    if (dig_range == 0) return 0;
    return (@as(f64, @floatFromInt(digital)) - @as(f64, @floatFromInt(dig_min))) / dig_range * phys_range + phys_min;
}

// ============================================================================
// TESTS
// ============================================================================

test "EDFHeader defaults" {
    const hdr = EDFHeader.defaultEEG(8, 250);
    try std.testing.expectEqual(@as(u16, 8), hdr.n_channels);
    try std.testing.expectEqual(@as(u16, 250), hdr.samples_per_record[0]);
    // Header size: 256 + 8*256 = 2304
    try std.testing.expectEqual(@as(usize, 256 + 8 * 256), hdr.headerSize());
    // Label should start with "Fp1"
    try std.testing.expect(std.mem.startsWith(u8, &hdr.labels[0], "Fp1"));
    // Physical dim should be "uV"
    try std.testing.expect(std.mem.startsWith(u8, &hdr.physical_dim[0], "uV"));
}

test "EDFHeader setLabel" {
    var hdr = EDFHeader{};
    hdr.n_channels = 2;
    hdr.setLabel(0, "Cz");
    hdr.setLabel(1, "Pz");
    try std.testing.expect(std.mem.startsWith(u8, &hdr.labels[0], "Cz"));
    try std.testing.expect(std.mem.startsWith(u8, &hdr.labels[1], "Pz"));
}

test "physicalToDigital and digitalToPhysical roundtrip" {
    const phys_min: f64 = -3200.0;
    const phys_max: f64 = 3200.0;
    const dig_min: i16 = -32768;
    const dig_max: i16 = 32767;

    // Zero physical should map to ~0 digital
    const d0 = physicalToDigital(0.0, phys_min, phys_max, dig_min, dig_max);
    try std.testing.expect(@abs(@as(i32, d0)) < 2); // allow +-1 rounding

    // Roundtrip: physical -> digital -> physical
    const test_vals = [_]f64{ 0.0, 100.0, -100.0, 3200.0, -3200.0 };
    for (test_vals) |pv| {
        const dv = physicalToDigital(pv, phys_min, phys_max, dig_min, dig_max);
        const pv2 = digitalToPhysical(dv, phys_min, phys_max, dig_min, dig_max);
        // Allow ~0.1 uV error from quantization
        try std.testing.expect(@abs(pv - pv2) < 0.2);
    }
}

test "EDFWriter synthetic EEG" {
    const allocator = std.testing.allocator;

    // Create 2-channel, 4Hz header (tiny for testing)
    var hdr = EDFHeader.defaultEEG(2, 4);
    hdr.start_date = "07.03.26".*;
    hdr.start_time = "12.00.00".*;

    var writer = EDFWriter.init(allocator, hdr);
    defer writer.deinit();

    // Write 2 data records (2 seconds of data)
    // Each record: 2 channels x 4 samples = 8 samples = 16 bytes
    const ch0_r1 = [_]i16{ 100, 200, 300, 400 };
    const ch1_r1 = [_]i16{ -100, -200, -300, -400 };
    const record1 = [_][]const i16{ &ch0_r1, &ch1_r1 };
    try writer.writeDataRecord(&record1);

    const ch0_r2 = [_]i16{ 500, 600, 700, 800 };
    const ch1_r2 = [_]i16{ -500, -600, -700, -800 };
    const record2 = [_][]const i16{ &ch0_r2, &ch1_r2 };
    try writer.writeDataRecord(&record2);

    // Finalize
    const edf_data = try writer.finalize();
    defer allocator.free(edf_data);

    // Verify header structure
    const expected_hdr_size: usize = 256 + 2 * 256; // 768 bytes
    try std.testing.expect(edf_data.len > expected_hdr_size);

    // Check version field (first 8 bytes)
    try std.testing.expect(std.mem.startsWith(u8, edf_data, "0"));

    // Check data section size: 2 records x 2 channels x 4 samples x 2 bytes = 32
    try std.testing.expectEqual(expected_hdr_size + 32, edf_data.len);

    // Verify first sample of first channel (little-endian i16 = 100)
    const first_sample = @as(i16, @bitCast([2]u8{ edf_data[expected_hdr_size], edf_data[expected_hdr_size + 1] }));
    try std.testing.expectEqual(@as(i16, 100), first_sample);
}

test "EDFWriter n_records tracking" {
    const allocator = std.testing.allocator;
    const hdr = EDFHeader.defaultEEG(1, 2);
    var writer = EDFWriter.init(allocator, hdr);
    defer writer.deinit();

    try std.testing.expectEqual(@as(u32, 0), writer.n_records);

    const ch0 = [_]i16{ 10, 20 };
    const record = [_][]const i16{&ch0};
    try writer.writeDataRecord(&record);
    try std.testing.expectEqual(@as(u32, 1), writer.n_records);

    try writer.writeDataRecord(&record);
    try std.testing.expectEqual(@as(u32, 2), writer.n_records);

    const edf_data = try writer.finalize();
    defer allocator.free(edf_data);

    // Verify the data exists
    try std.testing.expect(edf_data.len > 0);
}
