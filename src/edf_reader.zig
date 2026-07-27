//! edf_reader.zig — European Data Format (EDF/EDF+) Reader
//!
//! Parses EDF/EDF+ files for BCI data ingestion. Reads header fields
//! and extracts per-channel sample data from data records.
//!
//! EDF+ spec: https://www.edfplus.info/specs/edfplus.html

const std = @import("std");

pub const MAX_CHANNELS: usize = 256;

pub const EDFError = error{
    FileTooShort,
    InvalidVersion,
    InvalidHeaderSize,
    InvalidChannelCount,
    InvalidSamplesPerRecord,
    InvalidRecordCount,
    DataTruncated,
    ParseIntError,
    ParseFloatError,
};

pub const ChannelInfo = struct {
    label: [16]u8,
    transducer: [80]u8,
    physical_dim: [8]u8,
    physical_min: f64,
    physical_max: f64,
    digital_min: i16,
    digital_max: i16,
    samples_per_record: u16,
    prefiltering: [80]u8,

    pub fn labelStr(self: *const ChannelInfo) []const u8 {
        return trimRight(&self.label);
    }

    pub fn unitStr(self: *const ChannelInfo) []const u8 {
        return trimRight(&self.physical_dim);
    }
};

pub const EDFFile = struct {
    // General header
    version: [8]u8,
    patient_info: [80]u8,
    recording_info: [80]u8,
    start_date: [8]u8,
    start_time: [8]u8,
    header_bytes: u32,
    reserved: [44]u8,
    n_records: u32,
    record_duration: f64,
    n_channels: u16,

    // Per-channel info
    channels: [MAX_CHANNELS]ChannelInfo,

    // Raw data (not owned - points into input buffer)
    data_start: usize,
    raw_data: []const u8,

    /// Parse an EDF file from a byte buffer.
    pub fn parse(buf: []const u8) (EDFError || error{Overflow})!EDFFile {
        if (buf.len < 256) return EDFError.FileTooShort;

        // Version must start with "0"
        if (buf[0] != '0') return EDFError.InvalidVersion;

        var result: EDFFile = undefined;
        @memcpy(&result.version, buf[0..8]);
        @memcpy(&result.patient_info, buf[8..88]);
        @memcpy(&result.recording_info, buf[88..168]);
        @memcpy(&result.start_date, buf[168..176]);
        @memcpy(&result.start_time, buf[176..184]);

        result.header_bytes = try parseAsciiU32(buf[184..192]);
        @memcpy(&result.reserved, buf[192..236]);
        result.n_records = try parseAsciiU32(buf[236..244]);
        result.record_duration = try parseAsciiF64(buf[244..252]);
        result.n_channels = std.math.cast(u16, try parseAsciiU32(buf[252..256])) orelse
            return EDFError.InvalidChannelCount;

        if (result.n_channels > MAX_CHANNELS) return EDFError.InvalidChannelCount;

        const expected_hdr = @as(u32, 256) + @as(u32, result.n_channels) * 256;
        if (result.header_bytes != expected_hdr) return EDFError.InvalidHeaderSize;
        if (buf.len < result.header_bytes) return EDFError.FileTooShort;

        const n = result.n_channels;

        // Parse per-channel fields (each field spans all channels sequentially)
        var offset: usize = 256;

        // Labels (16 bytes each)
        for (0..n) |i| {
            @memcpy(&result.channels[i].label, buf[offset..][0..16]);
            offset += 16;
        }
        // Transducer (80 bytes each)
        for (0..n) |i| {
            @memcpy(&result.channels[i].transducer, buf[offset..][0..80]);
            offset += 80;
        }
        // Physical dimension (8 bytes each)
        for (0..n) |i| {
            @memcpy(&result.channels[i].physical_dim, buf[offset..][0..8]);
            offset += 8;
        }
        // Physical min (8 bytes each)
        for (0..n) |i| {
            result.channels[i].physical_min = try parseAsciiF64(buf[offset..][0..8]);
            offset += 8;
        }
        // Physical max (8 bytes each)
        for (0..n) |i| {
            result.channels[i].physical_max = try parseAsciiF64(buf[offset..][0..8]);
            offset += 8;
        }
        // Digital min (8 bytes each). An 8-char ASCII field holds values far
        // outside i16, so a bare @intCast PANICS on untrusted input ("integer
        // does not fit in destination type"). Reject out-of-range instead.
        for (0..n) |i| {
            result.channels[i].digital_min = std.math.cast(i16, try parseAsciiI32(buf[offset..][0..8])) orelse
                return EDFError.ParseIntError;
            offset += 8;
        }
        // Digital max (8 bytes each)
        for (0..n) |i| {
            result.channels[i].digital_max = std.math.cast(i16, try parseAsciiI32(buf[offset..][0..8])) orelse
                return EDFError.ParseIntError;
            offset += 8;
        }
        // Prefiltering (80 bytes each)
        for (0..n) |i| {
            @memcpy(&result.channels[i].prefiltering, buf[offset..][0..80]);
            offset += 80;
        }
        // Samples per record (8 bytes each). Same hazard: 8 ASCII digits reach
        // 99,999,999, far beyond u16.
        for (0..n) |i| {
            result.channels[i].samples_per_record = std.math.cast(u16, try parseAsciiU32(buf[offset..][0..8])) orelse
                return EDFError.ParseIntError;
            offset += 8;
        }
        // Reserved (32 bytes each) — skip
        offset += 32 * n;

        result.data_start = result.header_bytes;
        result.raw_data = buf;

        return result;
    }

    /// Get a single digital sample value from the data section.
    /// record: data record index (0-based)
    /// channel: channel index (0-based)
    /// sample: sample index within the record (0-based)
    pub fn getSample(self: *const EDFFile, record: u32, channel: u16, sample: u16) EDFError!i16 {
        if (record >= self.n_records) return EDFError.DataTruncated;
        if (channel >= self.n_channels) return EDFError.InvalidChannelCount;
        if (sample >= self.channels[channel].samples_per_record) return EDFError.InvalidSamplesPerRecord;

        // Calculate offset: skip to record, then skip channels before this one
        var record_offset: usize = 0;
        for (0..self.n_channels) |ch| {
            if (ch == channel) break;
            record_offset += @as(usize, self.channels[ch].samples_per_record) * 2;
        }
        const samples_before: usize = @as(usize, sample) * 2;
        const record_size = self.recordSize();
        const byte_offset = self.data_start + @as(usize, record) * record_size + record_offset + samples_before;

        if (byte_offset + 2 > self.raw_data.len) return EDFError.DataTruncated;

        return @bitCast([2]u8{ self.raw_data[byte_offset], self.raw_data[byte_offset + 1] });
    }

    /// Convert a digital sample to physical units using channel calibration.
    pub fn toPhysical(self: *const EDFFile, channel: u16, digital: i16) f64 {
        const ch = &self.channels[channel];
        const phys_range = ch.physical_max - ch.physical_min;
        const dig_range: f64 = @as(f64, @floatFromInt(ch.digital_max)) - @as(f64, @floatFromInt(ch.digital_min));
        if (dig_range == 0) return 0;
        return (@as(f64, @floatFromInt(digital)) - @as(f64, @floatFromInt(ch.digital_min))) / dig_range * phys_range + ch.physical_min;
    }

    /// Total size of one data record in bytes.
    pub fn recordSize(self: *const EDFFile) usize {
        var size: usize = 0;
        for (0..self.n_channels) |ch| {
            size += @as(usize, self.channels[ch].samples_per_record) * 2;
        }
        return size;
    }

    /// Total duration of the recording in seconds.
    pub fn totalDuration(self: *const EDFFile) f64 {
        return @as(f64, @floatFromInt(self.n_records)) * self.record_duration;
    }

    /// Effective sample rate for a channel.
    pub fn sampleRate(self: *const EDFFile, channel: u16) f64 {
        if (self.record_duration == 0) return 0;
        return @as(f64, @floatFromInt(self.channels[channel].samples_per_record)) / self.record_duration;
    }
};

// ============================================================================
// ASCII field parsing helpers
// ============================================================================

fn trimRight(s: []const u8) []const u8 {
    var end: usize = s.len;
    while (end > 0 and (s[end - 1] == ' ' or s[end - 1] == 0)) end -= 1;
    return s[0..end];
}

fn parseAsciiU32(field: []const u8) (EDFError || error{Overflow})!u32 {
    const trimmed = trimRight(field);
    if (trimmed.len == 0) return EDFError.ParseIntError;
    return std.fmt.parseInt(u32, trimmed, 10) catch return EDFError.ParseIntError;
}

fn parseAsciiI32(field: []const u8) (EDFError || error{Overflow})!i32 {
    const trimmed = trimRight(field);
    if (trimmed.len == 0) return EDFError.ParseIntError;
    return std.fmt.parseInt(i32, trimmed, 10) catch return EDFError.ParseIntError;
}

fn parseAsciiF64(field: []const u8) EDFError!f64 {
    const trimmed = trimRight(field);
    if (trimmed.len == 0) return EDFError.ParseFloatError;
    return std.fmt.parseFloat(f64, trimmed) catch return EDFError.ParseFloatError;
}

// ============================================================================
// TESTS
// ============================================================================

test "parse synthetic 2-channel fixture" {
    // Read the fixture file generated by Python
    const fixture = @embedFile("testdata/fixture_2ch.edf");
    const edf = try EDFFile.parse(fixture);

    try std.testing.expectEqual(@as(u16, 2), edf.n_channels);
    try std.testing.expectEqual(@as(u32, 2), edf.n_records);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), edf.record_duration, 0.001);
    try std.testing.expectEqual(@as(u32, 768), edf.header_bytes);

    // Channel labels
    try std.testing.expectEqualStrings("Fp1", edf.channels[0].labelStr());
    try std.testing.expectEqualStrings("Fp2", edf.channels[1].labelStr());

    // Units
    try std.testing.expectEqualStrings("uV", edf.channels[0].unitStr());

    // Sample rate
    try std.testing.expectEqual(@as(u16, 4), edf.channels[0].samples_per_record);
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), edf.sampleRate(0), 0.001);

    // Duration
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), edf.totalDuration(), 0.001);

    // Read digital samples from record 0
    // ch0=[100, -100, 200, -200], ch1=[50, -50, 150, -150]
    try std.testing.expectEqual(@as(i16, 100), try edf.getSample(0, 0, 0));
    try std.testing.expectEqual(@as(i16, -100), try edf.getSample(0, 0, 1));
    try std.testing.expectEqual(@as(i16, 200), try edf.getSample(0, 0, 2));
    try std.testing.expectEqual(@as(i16, -200), try edf.getSample(0, 0, 3));

    try std.testing.expectEqual(@as(i16, 50), try edf.getSample(0, 1, 0));
    try std.testing.expectEqual(@as(i16, -50), try edf.getSample(0, 1, 1));

    // Record 1: ch0=[300, -300, 400, -400]
    try std.testing.expectEqual(@as(i16, 300), try edf.getSample(1, 0, 0));
    try std.testing.expectEqual(@as(i16, -400), try edf.getSample(1, 0, 3));

    // Physical conversion: digital 100 with range [-3200, 3200] / [-32768, 32767]
    const phys = edf.toPhysical(0, 100);
    // physical = (100 - (-32768)) / (32767 - (-32768)) * (3200 - (-3200)) + (-3200)
    //          = 32868 / 65535 * 6400 - 3200 = 3209.76 - 3200 ≈ 9.76
    try std.testing.expectApproxEqAbs(@as(f64, 9.76), phys, 0.1);
}

test "parse fixture header fields" {
    const fixture = @embedFile("testdata/fixture_2ch.edf");
    const edf = try EDFFile.parse(fixture);

    // Verify version
    try std.testing.expect(edf.version[0] == '0');

    // Physical/digital ranges
    try std.testing.expectApproxEqAbs(@as(f64, -3200.0), edf.channels[0].physical_min, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 3200.0), edf.channels[0].physical_max, 0.001);
    try std.testing.expectEqual(@as(i16, -32768), edf.channels[0].digital_min);
    try std.testing.expectEqual(@as(i16, 32767), edf.channels[0].digital_max);
}

test "reject invalid EDF" {
    // Too short
    try std.testing.expectError(EDFError.FileTooShort, EDFFile.parse("short"));

    // Wrong version
    var bad_version: [256]u8 = [_]u8{' '} ** 256;
    bad_version[0] = '1';
    try std.testing.expectError(EDFError.InvalidVersion, EDFFile.parse(&bad_version));
}

test "EDF writer-reader round trip" {
    // Import edf_writer and verify round-trip compatibility
    const edf_writer = @import("edf_writer");
    const allocator = std.testing.allocator;

    const header = edf_writer.EDFHeader.defaultEEG(2, 4);
    var writer = edf_writer.EDFWriter.init(allocator, header);
    defer writer.deinit();

    const ch0 = [_]i16{ 100, -100, 200, -200 };
    const ch1 = [_]i16{ 50, -50, 150, -150 };
    const record = [_][]const i16{ &ch0, &ch1 };
    try writer.writeDataRecord(&record);

    const edf_data = try writer.finalize();
    defer allocator.free(edf_data);

    // Parse what we just wrote
    const parsed = try EDFFile.parse(edf_data);

    try std.testing.expectEqual(@as(u16, 2), parsed.n_channels);
    try std.testing.expectEqual(@as(u32, 1), parsed.n_records);
    try std.testing.expectEqualStrings("Fp1", parsed.channels[0].labelStr());
    try std.testing.expectEqualStrings("Fp2", parsed.channels[1].labelStr());

    // Verify sample values round-trip
    try std.testing.expectEqual(@as(i16, 100), try parsed.getSample(0, 0, 0));
    try std.testing.expectEqual(@as(i16, -100), try parsed.getSample(0, 0, 1));
    try std.testing.expectEqual(@as(i16, 50), try parsed.getSample(0, 1, 0));
    try std.testing.expectEqual(@as(i16, -50), try parsed.getSample(0, 1, 1));
}

test "parse MNE subsecond_starttime.edf (4ch EDF+C)" {
    const fixture = @embedFile("testdata/subsecond_starttime.edf");
    const edf = try EDFFile.parse(fixture);

    try std.testing.expectEqual(@as(u16, 4), edf.n_channels);
    try std.testing.expectEqual(@as(u32, 5), edf.n_records);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), edf.record_duration, 0.001);

    // Channel labels: Fp1, F7, T3, EDF Annotations
    try std.testing.expectEqualStrings("Fp1", edf.channels[0].labelStr());
    try std.testing.expectEqualStrings("F7", edf.channels[1].labelStr());
    try std.testing.expectEqualStrings("T3", edf.channels[2].labelStr());

    // Header size: 256 + 4*256 = 1280
    try std.testing.expectEqual(@as(u32, 1280), edf.header_bytes);

    // Should be able to read samples without error
    _ = try edf.getSample(0, 0, 0);
    _ = try edf.getSample(4, 0, 0); // last record
}

test "parse MNE test_utf8_annotations.edf (12ch EDF+C)" {
    const fixture = @embedFile("testdata/test_utf8_annotations.edf");
    const edf = try EDFFile.parse(fixture);

    try std.testing.expectEqual(@as(u16, 12), edf.n_channels);
    try std.testing.expectEqual(@as(u32, 10), edf.n_records);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), edf.record_duration, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), edf.totalDuration(), 0.001);

    // Header size: 256 + 12*256 = 3328
    try std.testing.expectEqual(@as(u32, 3328), edf.header_bytes);

    // Read a sample from the squarewave channel
    const sample = try edf.getSample(0, 0, 0);
    _ = sample; // value depends on the synthetic waveform
}
