//! lsl_inlet.zig — Lab Streaming Layer inlet bindings
//!
//! C FFI to liblsl for receiving real-time data streams from
//! LSL-compatible devices (DSI-24, PLUX, BrainFlow, etc.)
//!
//! liblsl is dynamically linked — build with: zig build -Dlsl=true
//!
//! Architecture:
//!   Device1 -> LSL Outlet1 --\
//!   Device2 -> LSL Outlet2 ---+--> LSL Network --> lsl_inlet.zig --> bci_receiver.zig
//!   Device3 -> LSL Outlet3 --/
//!
//! All streams share a unified clock via LSL's built-in clock synchronization
//! (NTP-like, sub-millisecond accuracy on LAN).
//!
//! Supported stream types:
//!   "EEG"  -- electroencephalography (DSI-24, OpenBCI, g.tec, etc.)
//!   "NIRS" -- functional near-infrared spectroscopy (PLUX fNIRS)
//!   "Gaze" -- eye tracking (Tobii, Pupil Labs)
//!   "EMG"  -- electromyography
//!   "ECoG" -- electrocorticography
//!   "Markers" -- event triggers, TTL
//!
//! When liblsl is not available, falls back to a software-only timestamp
//! alignment mode using monotonic clock + configurable offsets.
//!
//! License: MIT OR Apache-2.0

const std = @import("std");

// ============================================================================
// COMPILE-TIME FEATURE DETECTION
// ============================================================================

/// True when building with liblsl linked. Without liblsl, all C-dependent
/// operations return LSLError.LiblslUnavailable, but the module still
/// compiles and the software-only synchronizer works.
pub const has_liblsl = blk: {
    // The build.zig sets this via a root declaration when -Dlsl=true
    if (@hasDecl(@import("root"), "lsl_enabled")) {
        break :blk @import("root").lsl_enabled;
    }
    break :blk false;
};

// ============================================================================
// ERROR TYPES
// ============================================================================

pub const LSLError = error{
    /// liblsl shared library not linked / not found
    LiblslUnavailable,
    /// No streams matching the query were found within the timeout
    StreamNotFound,
    /// Failed to open inlet (stream disappeared, network error, etc.)
    InletOpenFailed,
    /// Pull timed out (no sample available within the requested window)
    PullTimeout,
    /// Channel count mismatch between stream info and pull buffer
    ChannelMismatch,
    /// Null pointer returned from liblsl
    NullPointer,
    /// Generic liblsl error (negative return code)
    LiblslError,
    /// Too many streams registered
    TooManyStreams,
};

// ============================================================================
// C FFI DECLARATIONS -- liblsl
// ============================================================================

/// Opaque C handles from liblsl
pub const lsl_streaminfo = opaque {};
pub const lsl_inlet = opaque {};
pub const lsl_xml_ptr = opaque {};

/// Channel format enum matching lsl_channel_format_t
pub const ChannelFormat = enum(c_int) {
    cf_undefined = 0,
    cf_float32 = 1,
    cf_double64 = 2,
    cf_string = 3,
    cf_int32 = 4,
    cf_int16 = 5,
    cf_int8 = 6,
    cf_int64 = 7,
};

/// Raw C function declarations -- only usable when has_liblsl is true.
/// These map directly to the liblsl C API (lsl_c.h).
pub const c = if (has_liblsl) struct {
    // -- Stream resolution --
    pub extern "lsl" fn lsl_resolve_byprop(
        buffer: [*]*lsl_streaminfo,
        buffer_elements: c_int,
        prop: [*:0]const u8,
        value: [*:0]const u8,
        minimum: c_int,
        timeout: f64,
    ) c_int;

    pub extern "lsl" fn lsl_resolve_all(
        buffer: [*]*lsl_streaminfo,
        buffer_elements: c_int,
        timeout: f64,
    ) c_int;

    // -- Stream info accessors --
    pub extern "lsl" fn lsl_get_name(info: *lsl_streaminfo) [*:0]const u8;
    pub extern "lsl" fn lsl_get_type(info: *lsl_streaminfo) [*:0]const u8;
    pub extern "lsl" fn lsl_get_channel_count(info: *lsl_streaminfo) c_int;
    pub extern "lsl" fn lsl_get_nominal_srate(info: *lsl_streaminfo) f64;
    pub extern "lsl" fn lsl_get_source_id(info: *lsl_streaminfo) [*:0]const u8;
    pub extern "lsl" fn lsl_get_uid(info: *lsl_streaminfo) [*:0]const u8;
    pub extern "lsl" fn lsl_get_channel_format(info: *lsl_streaminfo) ChannelFormat;
    pub extern "lsl" fn lsl_get_hostname(info: *lsl_streaminfo) [*:0]const u8;

    // -- Stream info lifecycle --
    pub extern "lsl" fn lsl_destroy_streaminfo(info: *lsl_streaminfo) void;
    pub extern "lsl" fn lsl_copy_streaminfo(info: *lsl_streaminfo) *lsl_streaminfo;

    // -- Inlet --
    pub extern "lsl" fn lsl_create_inlet(
        info: *lsl_streaminfo,
        max_buflen: c_int,
        max_chunklen: c_int,
        recover: c_int,
    ) ?*lsl_inlet;

    pub extern "lsl" fn lsl_destroy_inlet(inlet: *lsl_inlet) void;

    pub extern "lsl" fn lsl_pull_sample_f(
        inlet: *lsl_inlet,
        buffer: [*]f32,
        buffer_elements: c_int,
        timeout: f64,
        ec: *c_int,
    ) f64;

    pub extern "lsl" fn lsl_pull_sample_d(
        inlet: *lsl_inlet,
        buffer: [*]f64,
        buffer_elements: c_int,
        timeout: f64,
        ec: *c_int,
    ) f64;

    pub extern "lsl" fn lsl_samples_available(inlet: *lsl_inlet) c_uint;

    // -- XML metadata --
    pub extern "lsl" fn lsl_get_desc(info: *lsl_streaminfo) ?*lsl_xml_ptr;

    // -- Time --
    pub extern "lsl" fn lsl_local_clock() f64;
} else struct {
    // Stubs -- allow compilation without liblsl. No function bodies needed;
    // all call sites are gated behind `if (has_liblsl)`.
};

// ============================================================================
// STREAM CONTENT TYPE (Zig enum)
// ============================================================================

/// Stream content type identifiers (LSL convention strings)
pub const StreamType = enum {
    eeg,
    fnirs,
    eye_tracking,
    markers,
    accelerometer,
    emg,
    ecog,
    video_sync,
    unknown,

    pub fn lslType(self: StreamType) []const u8 {
        return switch (self) {
            .eeg => "EEG",
            .fnirs => "NIRS",
            .eye_tracking => "Gaze",
            .markers => "Markers",
            .accelerometer => "Accelerometer",
            .emg => "EMG",
            .ecog => "ECoG",
            .video_sync => "VideoSync",
            .unknown => "",
        };
    }

    /// Parse an LSL type string into a StreamType enum
    pub fn fromLslType(type_str: []const u8) StreamType {
        if (std.mem.eql(u8, type_str, "EEG")) return .eeg;
        if (std.mem.eql(u8, type_str, "NIRS") or std.mem.eql(u8, type_str, "fNIRS")) return .fnirs;
        if (std.mem.eql(u8, type_str, "Gaze")) return .eye_tracking;
        if (std.mem.eql(u8, type_str, "Markers")) return .markers;
        if (std.mem.eql(u8, type_str, "Accelerometer")) return .accelerometer;
        if (std.mem.eql(u8, type_str, "EMG")) return .emg;
        if (std.mem.eql(u8, type_str, "ECoG")) return .ecog;
        return .unknown;
    }

    /// GF(3) trit assignment: EEG = 0 (ERGODIC), NIRS/ECoG = +1 (PLUS), EMG/Gaze = -1 (MINUS)
    /// Conservation: EEG + NIRS + EMG = 0 + 1 + (-1) = 0
    pub fn trit(self: StreamType) i8 {
        return switch (self) {
            .eeg => 0, // ERGODIC
            .fnirs => 1, // PLUS
            .ecog => 1, // PLUS
            .emg => -1, // MINUS
            .eye_tracking => -1, // MINUS
            .markers => 0,
            .accelerometer => 0,
            .video_sync => 0,
            .unknown => 0,
        };
    }

    /// Map to BCI Modality ordinal from bci_receiver.zig
    pub fn toModalityOrdinal(self: StreamType) ?u8 {
        return switch (self) {
            .eeg => 0,
            .fnirs => 5,
            .emg => 2,
            .ecog => 4,
            else => null,
        };
    }
};

// ============================================================================
// STREAM INFO -- Zig-idiomatic wrapper
// ============================================================================

/// Maximum stream name / type string length
pub const MAX_NAME_LEN: usize = 256;

/// Maximum number of channels we track per stream
pub const MAX_CHANNELS: usize = 128;

/// Discovered stream metadata (Zig-owned copy, safe after C pointers freed)
pub const StreamInfo = struct {
    name_buf: [MAX_NAME_LEN]u8 = [_]u8{0} ** MAX_NAME_LEN,
    name_len: usize = 0,
    type_buf: [MAX_NAME_LEN]u8 = [_]u8{0} ** MAX_NAME_LEN,
    type_len: usize = 0,
    source_id_buf: [MAX_NAME_LEN]u8 = [_]u8{0} ** MAX_NAME_LEN,
    source_id_len: usize = 0,
    hostname_buf: [MAX_NAME_LEN]u8 = [_]u8{0} ** MAX_NAME_LEN,
    hostname_len: usize = 0,
    channel_count: u32 = 0,
    nominal_srate: f64 = 0,
    channel_format: ChannelFormat = .cf_undefined,
    /// Time offset for software sync fallback (seconds)
    clock_offset: f64 = 0,

    /// Create from a raw liblsl streaminfo pointer
    pub fn fromRaw(raw: *lsl_streaminfo) StreamInfo {
        var info = StreamInfo{};

        if (has_liblsl) {
            const name_ptr = c.lsl_get_name(raw);
            const name_slice = std.mem.span(name_ptr);
            const n_len = @min(name_slice.len, MAX_NAME_LEN);
            @memcpy(info.name_buf[0..n_len], name_slice[0..n_len]);
            info.name_len = n_len;

            const type_ptr = c.lsl_get_type(raw);
            const type_slice = std.mem.span(type_ptr);
            const t_len = @min(type_slice.len, MAX_NAME_LEN);
            @memcpy(info.type_buf[0..t_len], type_slice[0..t_len]);
            info.type_len = t_len;

            const src_ptr = c.lsl_get_source_id(raw);
            const src_slice = std.mem.span(src_ptr);
            const s_len = @min(src_slice.len, MAX_NAME_LEN);
            @memcpy(info.source_id_buf[0..s_len], src_slice[0..s_len]);
            info.source_id_len = s_len;

            const host_ptr = c.lsl_get_hostname(raw);
            const host_slice = std.mem.span(host_ptr);
            const h_len = @min(host_slice.len, MAX_NAME_LEN);
            @memcpy(info.hostname_buf[0..h_len], host_slice[0..h_len]);
            info.hostname_len = h_len;

            info.channel_count = @intCast(@max(c.lsl_get_channel_count(raw), 0));
            info.nominal_srate = c.lsl_get_nominal_srate(raw);
            info.channel_format = c.lsl_get_channel_format(raw);
        }

        return info;
    }

    /// Create a synthetic StreamInfo for testing (no liblsl needed)
    pub fn synthetic(name: []const u8, stream_type: []const u8, channels: u32, rate: f64) StreamInfo {
        var info = StreamInfo{};
        const n_len = @min(name.len, MAX_NAME_LEN);
        @memcpy(info.name_buf[0..n_len], name[0..n_len]);
        info.name_len = n_len;

        const t_len = @min(stream_type.len, MAX_NAME_LEN);
        @memcpy(info.type_buf[0..t_len], stream_type[0..t_len]);
        info.type_len = t_len;

        info.channel_count = channels;
        info.nominal_srate = rate;
        info.channel_format = .cf_float32;
        return info;
    }

    pub fn getName(self: *const StreamInfo) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn getType(self: *const StreamInfo) []const u8 {
        return self.type_buf[0..self.type_len];
    }

    pub fn getSourceId(self: *const StreamInfo) []const u8 {
        return self.source_id_buf[0..self.source_id_len];
    }

    pub fn getHostname(self: *const StreamInfo) []const u8 {
        return self.hostname_buf[0..self.hostname_len];
    }

    /// Get the StreamType enum for this info
    pub fn streamType(self: *const StreamInfo) StreamType {
        return StreamType.fromLslType(self.getType());
    }
};

// ============================================================================
// UNIFIED TIMESTAMP (software fallback)
// ============================================================================

/// Unified timestamp across all modalities.
/// When LSL is available, uses LSL's corrected timestamps.
/// Otherwise, uses monotonic clock + manual offsets.
pub const UnifiedTimestamp = struct {
    /// Seconds since LSL epoch (or monotonic clock start)
    time_s: f64,
    /// Stream this sample originated from
    stream_type: StreamType,
    /// Sample index within the stream
    sample_index: u64,

    /// Convert to milliseconds (for bci_receiver.zig compatibility)
    pub fn toMillis(self: UnifiedTimestamp) u64 {
        return @intFromFloat(self.time_s * 1000.0);
    }

    /// Time difference between two timestamps (seconds)
    pub fn diff(self: UnifiedTimestamp, other: UnifiedTimestamp) f64 {
        return self.time_s - other.time_s;
    }
};

// ============================================================================
// LSL RESOLVER -- stream discovery
// ============================================================================

/// Maximum concurrent streams we can resolve
pub const MAX_RESOLVED_STREAMS: usize = 16;

pub const LSLResolver = struct {
    /// Discovered stream infos (Zig copies, safe to use after raw pointers freed)
    streams: [MAX_RESOLVED_STREAMS]StreamInfo = undefined,
    count: usize = 0,

    /// Raw liblsl stream info pointers (for creating inlets)
    raw_ptrs: [MAX_RESOLVED_STREAMS]?*lsl_streaminfo = [_]?*lsl_streaminfo{null} ** MAX_RESOLVED_STREAMS,
    raw_count: usize = 0,

    /// Resolve streams by property (e.g., "type", "EEG")
    pub fn resolveByProp(
        self: *LSLResolver,
        prop: [*:0]const u8,
        value: [*:0]const u8,
        timeout: f64,
    ) LSLError!usize {
        if (!has_liblsl) return LSLError.LiblslUnavailable;

        self.destroyRaw();

        var raw_buf: [MAX_RESOLVED_STREAMS]*lsl_streaminfo = undefined;
        const found = c.lsl_resolve_byprop(
            &raw_buf,
            @intCast(MAX_RESOLVED_STREAMS),
            prop,
            value,
            1,
            timeout,
        );

        if (found <= 0) return LSLError.StreamNotFound;

        const n: usize = @intCast(found);
        self.count = @min(n, MAX_RESOLVED_STREAMS);
        self.raw_count = self.count;

        for (0..self.count) |i| {
            self.raw_ptrs[i] = raw_buf[i];
            self.streams[i] = StreamInfo.fromRaw(raw_buf[i]);
        }

        return self.count;
    }

    /// Resolve all available streams on the network
    pub fn resolveAll(self: *LSLResolver, timeout: f64) LSLError!usize {
        if (!has_liblsl) return LSLError.LiblslUnavailable;

        self.destroyRaw();

        var raw_buf: [MAX_RESOLVED_STREAMS]*lsl_streaminfo = undefined;
        const found = c.lsl_resolve_all(
            &raw_buf,
            @intCast(MAX_RESOLVED_STREAMS),
            timeout,
        );

        if (found <= 0) return LSLError.StreamNotFound;

        const n: usize = @intCast(found);
        self.count = @min(n, MAX_RESOLVED_STREAMS);
        self.raw_count = self.count;

        for (0..self.count) |i| {
            self.raw_ptrs[i] = raw_buf[i];
            self.streams[i] = StreamInfo.fromRaw(raw_buf[i]);
        }

        return self.count;
    }

    /// Get stream info at index
    pub fn getStream(self: *const LSLResolver, idx: usize) ?*const StreamInfo {
        if (idx >= self.count) return null;
        return &self.streams[idx];
    }

    /// Destroy raw liblsl pointers
    fn destroyRaw(self: *LSLResolver) void {
        if (has_liblsl) {
            for (0..self.raw_count) |i| {
                if (self.raw_ptrs[i]) |ptr| {
                    c.lsl_destroy_streaminfo(ptr);
                    self.raw_ptrs[i] = null;
                }
            }
        }
        self.raw_count = 0;
        self.count = 0;
    }

    /// Clean up all resources
    pub fn deinit(self: *LSLResolver) void {
        self.destroyRaw();
    }
};

// ============================================================================
// LSL INLET -- sample pulling
// ============================================================================

/// A single pulled sample with timestamp
pub const Sample = struct {
    /// Channel data (float32). Only channels[0..channel_count] are valid.
    channels: [MAX_CHANNELS]f32 = [_]f32{0} ** MAX_CHANNELS,
    channel_count: u32 = 0,
    /// LSL timestamp (seconds since some epoch, monotonic)
    timestamp: f64 = 0,
    /// Whether this sample contains valid data
    valid: bool = false,
};

pub const LSLInlet = struct {
    raw_inlet: ?*lsl_inlet = null,
    info: StreamInfo = .{},
    /// Raw streaminfo pointer (kept alive for the inlet's lifetime)
    raw_info: ?*lsl_streaminfo = null,
    is_open: bool = false,

    /// Open an inlet from a resolved stream (by index into resolver)
    pub fn init(resolver: *const LSLResolver, stream_idx: usize) LSLError!LSLInlet {
        if (!has_liblsl) return LSLError.LiblslUnavailable;
        if (stream_idx >= resolver.raw_count) return LSLError.StreamNotFound;

        const raw_info = resolver.raw_ptrs[stream_idx] orelse return LSLError.NullPointer;

        const inlet_ptr = c.lsl_create_inlet(
            raw_info,
            360, // max_buflen: 360 seconds
            0, // max_chunklen: 0 = no chunking
            1, // recover: 1 = auto-recover
        ) orelse return LSLError.InletOpenFailed;

        return LSLInlet{
            .raw_inlet = inlet_ptr,
            .info = resolver.streams[stream_idx],
            .raw_info = raw_info,
            .is_open = true,
        };
    }

    /// Open an inlet directly from a raw streaminfo pointer
    pub fn initFromRaw(raw_info: *lsl_streaminfo) LSLError!LSLInlet {
        if (!has_liblsl) return LSLError.LiblslUnavailable;

        const inlet_ptr = c.lsl_create_inlet(
            raw_info,
            360,
            0,
            1,
        ) orelse return LSLError.InletOpenFailed;

        return LSLInlet{
            .raw_inlet = inlet_ptr,
            .info = StreamInfo.fromRaw(raw_info),
            .raw_info = raw_info,
            .is_open = true,
        };
    }

    /// Pull a single float32 sample. Returns error.PullTimeout if no data
    /// is available within `timeout` seconds.
    pub fn pullSample(self: *LSLInlet, timeout: f64) LSLError!Sample {
        if (!has_liblsl) return LSLError.LiblslUnavailable;
        if (!self.is_open) return LSLError.InletOpenFailed;

        const inlet_ptr = self.raw_inlet orelse return LSLError.NullPointer;
        const n_ch: c_int = @intCast(@min(self.info.channel_count, MAX_CHANNELS));

        var sample = Sample{
            .channel_count = @intCast(n_ch),
        };
        var ec: c_int = 0;

        const ts = c.lsl_pull_sample_f(
            inlet_ptr,
            &sample.channels,
            n_ch,
            timeout,
            &ec,
        );

        if (ec != 0) return LSLError.LiblslError;
        if (ts == 0.0) return LSLError.PullTimeout;

        sample.timestamp = ts;
        sample.valid = true;
        return sample;
    }

    /// Pull a single float64 sample into a provided buffer.
    pub fn pullSampleDouble(self: *LSLInlet, buf: []f64, timeout: f64) LSLError!f64 {
        if (!has_liblsl) return LSLError.LiblslUnavailable;
        if (!self.is_open) return LSLError.InletOpenFailed;

        const inlet_ptr = self.raw_inlet orelse return LSLError.NullPointer;
        const n_ch: c_int = @intCast(@min(self.info.channel_count, @as(u32, @intCast(buf.len))));

        var ec: c_int = 0;
        const ts = c.lsl_pull_sample_d(
            inlet_ptr,
            buf.ptr,
            n_ch,
            timeout,
            &ec,
        );

        if (ec != 0) return LSLError.LiblslError;
        if (ts == 0.0) return LSLError.PullTimeout;

        return ts;
    }

    /// Check how many samples are buffered
    pub fn samplesAvailable(self: *const LSLInlet) u32 {
        if (!has_liblsl) return 0;
        if (!self.is_open) return 0;
        const inlet_ptr = self.raw_inlet orelse return 0;
        return @intCast(c.lsl_samples_available(inlet_ptr));
    }

    /// Get stream info
    pub fn getInfo(self: *const LSLInlet) *const StreamInfo {
        return &self.info;
    }

    /// Close and destroy the inlet
    pub fn deinit(self: *LSLInlet) void {
        if (has_liblsl) {
            if (self.raw_inlet) |ptr| {
                c.lsl_destroy_inlet(ptr);
            }
        }
        self.raw_inlet = null;
        self.is_open = false;
    }
};

// ============================================================================
// MULTI-STREAM SYNCHRONIZER (SOFTWARE FALLBACK)
// ============================================================================

/// Maximum concurrent streams for software sync
pub const MAX_STREAMS: usize = 8;

/// Synchronizes multiple data streams without liblsl.
/// Uses monotonic clock + per-stream offsets for alignment.
pub const StreamSynchronizer = struct {
    streams: [MAX_STREAMS]?SyncStreamInfo,
    n_streams: u8,
    epoch_start: i128, // nanoseconds (from std.time.nanoTimestamp)
    sample_counts: [MAX_STREAMS]u64,

    pub const SyncStreamInfo = struct {
        name: []const u8,
        stream_type: StreamType,
        channel_count: u32,
        nominal_rate: f64,
        source_id: []const u8,
        clock_offset: f64 = 0,
    };

    pub fn init() StreamSynchronizer {
        return .{
            .streams = [_]?SyncStreamInfo{null} ** MAX_STREAMS,
            .n_streams = 0,
            .epoch_start = std.time.nanoTimestamp(),
            .sample_counts = [_]u64{0} ** MAX_STREAMS,
        };
    }

    /// Register a new stream. Returns stream index.
    pub fn addStream(self: *StreamSynchronizer, info: SyncStreamInfo) LSLError!u8 {
        if (self.n_streams >= MAX_STREAMS) return LSLError.TooManyStreams;
        const idx = self.n_streams;
        self.streams[idx] = info;
        self.n_streams += 1;
        return idx;
    }

    /// Get unified timestamp for a sample from a given stream
    pub fn timestamp(self: *StreamSynchronizer, stream_idx: u8) UnifiedTimestamp {
        const now_ns = std.time.nanoTimestamp();
        const elapsed_s: f64 = @as(f64, @floatFromInt(now_ns - self.epoch_start)) / 1e9;

        const stream = self.streams[stream_idx] orelse {
            return .{
                .time_s = elapsed_s,
                .stream_type = .markers,
                .sample_index = 0,
            };
        };

        const corrected = elapsed_s + stream.clock_offset;
        const idx = self.sample_counts[stream_idx];
        self.sample_counts[stream_idx] = idx + 1;

        return .{
            .time_s = corrected,
            .stream_type = stream.stream_type,
            .sample_index = idx,
        };
    }

    /// Estimate clock offset between two streams using cross-correlation
    /// of shared event markers.
    pub fn estimateOffset(
        markers_a: []const f64,
        markers_b: []const f64,
    ) f64 {
        if (markers_a.len == 0 or markers_b.len == 0) return 0;
        const n = @min(markers_a.len, markers_b.len);
        var total_offset: f64 = 0;
        for (0..n) |i| {
            total_offset += markers_b[i] - markers_a[i];
        }
        return total_offset / @as(f64, @floatFromInt(n));
    }
};

// ============================================================================
// RESAMPLER
// ============================================================================

/// Resample a signal from source_rate to target_rate using linear interpolation.
/// Used to align fNIRS (10Hz) with EEG (300Hz) for epoch-level fusion.
pub fn resample(
    input: []const f32,
    source_rate: f64,
    target_rate: f64,
    allocator: std.mem.Allocator,
) ![]f32 {
    if (input.len == 0) return try allocator.alloc(f32, 0);

    const duration = @as(f64, @floatFromInt(input.len)) / source_rate;
    const n_output: usize = @intFromFloat(duration * target_rate);
    if (n_output == 0) return try allocator.alloc(f32, 0);

    const output = try allocator.alloc(f32, n_output);

    for (0..n_output) |i| {
        const t = @as(f64, @floatFromInt(i)) / target_rate;
        const src_idx = t * source_rate;
        const idx_lo: usize = @intFromFloat(@floor(src_idx));
        const idx_hi: usize = @min(idx_lo + 1, input.len - 1);
        const frac: f32 = @floatCast(src_idx - @as(f64, @floatFromInt(idx_lo)));

        output[i] = input[idx_lo] * (1.0 - frac) + input[idx_hi] * frac;
    }

    return output;
}

// ============================================================================
// EPOCH ALIGNER
// ============================================================================

/// Aligned multi-modal epoch: EEG + fNIRS + markers at a single time point.
pub const AlignedEpoch = struct {
    timestamp: UnifiedTimestamp,
    eeg_present: bool,
    fnirs_present: bool,
    eye_present: bool,
    /// EEG band powers (from fft_bands.zig, 5 bands)
    eeg_bands: [5]f32,
    /// fNIRS concentrations (HbO, HbR per channel, max 8 channels)
    fnirs_hbo: [8]f32,
    fnirs_hbr: [8]f32,
    fnirs_n_channels: u8,
    /// Eye tracking
    gaze_x: f32,
    gaze_y: f32,
    pupil_diameter: f32,
    /// Event marker (0 = no event)
    marker: u8,
};

// ============================================================================
// CONVENIENCE: LSL LOCAL CLOCK
// ============================================================================

/// Current local clock time (seconds). Uses liblsl if available,
/// falls back to std.time.
pub fn localClock() f64 {
    if (has_liblsl) {
        return c.lsl_local_clock();
    }
    return @as(f64, @floatFromInt(std.time.milliTimestamp())) / 1000.0;
}

// ============================================================================
// TESTS -- all work WITHOUT liblsl
// ============================================================================

test "StreamInfo synthetic creation" {
    const info = StreamInfo.synthetic("DSI-24", "EEG", 24, 300.0);
    try std.testing.expectEqualStrings("DSI-24", info.getName());
    try std.testing.expectEqualStrings("EEG", info.getType());
    try std.testing.expectEqual(@as(u32, 24), info.channel_count);
    try std.testing.expectApproxEqAbs(@as(f64, 300.0), info.nominal_srate, 0.001);
    try std.testing.expectEqual(ChannelFormat.cf_float32, info.channel_format);
}

test "StreamInfo long name truncation" {
    var long_name: [512]u8 = undefined;
    @memset(&long_name, 'A');
    const info = StreamInfo.synthetic(&long_name, "EEG", 8, 250.0);
    try std.testing.expectEqual(@as(usize, MAX_NAME_LEN), info.name_len);
}

test "StreamInfo getters on empty info" {
    const info = StreamInfo{};
    try std.testing.expectEqual(@as(usize, 0), info.getName().len);
    try std.testing.expectEqual(@as(usize, 0), info.getType().len);
    try std.testing.expectEqual(@as(usize, 0), info.getSourceId().len);
    try std.testing.expectEqual(@as(usize, 0), info.getHostname().len);
}

test "StreamInfo streamType from synthetic" {
    const info = StreamInfo.synthetic("Test", "NIRS", 3, 10.0);
    try std.testing.expectEqual(StreamType.fnirs, info.streamType());
}

test "Sample default state" {
    const sample = Sample{};
    try std.testing.expect(!sample.valid);
    try std.testing.expectEqual(@as(u32, 0), sample.channel_count);
    try std.testing.expectApproxEqAbs(@as(f64, 0), sample.timestamp, 0.001);
    for (sample.channels) |ch| {
        try std.testing.expectApproxEqAbs(@as(f32, 0), ch, 0.001);
    }
}

test "LSLResolver initial state" {
    var resolver = LSLResolver{};
    try std.testing.expectEqual(@as(usize, 0), resolver.count);
    try std.testing.expect(resolver.getStream(0) == null);
    resolver.deinit();
}

test "LSLResolver resolve without liblsl" {
    if (!has_liblsl) {
        var resolver = LSLResolver{};
        defer resolver.deinit();

        const result = resolver.resolveByProp("type", "EEG", 1.0);
        try std.testing.expectError(LSLError.LiblslUnavailable, result);

        const result2 = resolver.resolveAll(1.0);
        try std.testing.expectError(LSLError.LiblslUnavailable, result2);
    }
}

test "LSLInlet init without liblsl" {
    if (!has_liblsl) {
        var resolver = LSLResolver{};
        defer resolver.deinit();
        const result = LSLInlet.init(&resolver, 0);
        try std.testing.expectError(LSLError.LiblslUnavailable, result);
    }
}

test "LSLInlet pullSample without liblsl" {
    if (!has_liblsl) {
        var inlet = LSLInlet{};
        const result = inlet.pullSample(0.1);
        try std.testing.expectError(LSLError.LiblslUnavailable, result);
    }
}

test "LSLInlet pullSampleDouble without liblsl" {
    if (!has_liblsl) {
        var inlet = LSLInlet{};
        var buf: [8]f64 = undefined;
        const result = inlet.pullSampleDouble(&buf, 0.1);
        try std.testing.expectError(LSLError.LiblslUnavailable, result);
    }
}

test "LSLInlet samplesAvailable without liblsl" {
    if (!has_liblsl) {
        const inlet = LSLInlet{};
        try std.testing.expectEqual(@as(u32, 0), inlet.samplesAvailable());
    }
}

test "LSLInlet deinit is safe on unopened inlet" {
    var inlet = LSLInlet{};
    inlet.deinit();
    try std.testing.expect(!inlet.is_open);
}

test "StreamType LSL name roundtrip" {
    try std.testing.expectEqualStrings("EEG", StreamType.eeg.lslType());
    try std.testing.expectEqualStrings("NIRS", StreamType.fnirs.lslType());
    try std.testing.expectEqualStrings("Gaze", StreamType.eye_tracking.lslType());
    try std.testing.expectEqualStrings("EMG", StreamType.emg.lslType());
    try std.testing.expectEqualStrings("ECoG", StreamType.ecog.lslType());
}

test "StreamType fromLslType parsing" {
    try std.testing.expectEqual(StreamType.eeg, StreamType.fromLslType("EEG"));
    try std.testing.expectEqual(StreamType.fnirs, StreamType.fromLslType("NIRS"));
    try std.testing.expectEqual(StreamType.fnirs, StreamType.fromLslType("fNIRS"));
    try std.testing.expectEqual(StreamType.eye_tracking, StreamType.fromLslType("Gaze"));
    try std.testing.expectEqual(StreamType.unknown, StreamType.fromLslType("FooBar"));
}

test "StreamType GF(3) trit conservation" {
    // EEG(0) + NIRS(+1) + EMG(-1) = 0
    const sum = StreamType.eeg.trit() + StreamType.fnirs.trit() + StreamType.emg.trit();
    try std.testing.expectEqual(@as(i8, 0), sum);

    // EEG(0) + ECoG(+1) + Gaze(-1) = 0
    const sum2 = StreamType.eeg.trit() + StreamType.ecog.trit() + StreamType.eye_tracking.trit();
    try std.testing.expectEqual(@as(i8, 0), sum2);
}

test "StreamType modality ordinal mapping" {
    try std.testing.expectEqual(@as(?u8, 0), StreamType.eeg.toModalityOrdinal());
    try std.testing.expectEqual(@as(?u8, 5), StreamType.fnirs.toModalityOrdinal());
    try std.testing.expectEqual(@as(?u8, 2), StreamType.emg.toModalityOrdinal());
    try std.testing.expectEqual(@as(?u8, 4), StreamType.ecog.toModalityOrdinal());
    try std.testing.expectEqual(@as(?u8, null), StreamType.markers.toModalityOrdinal());
    try std.testing.expectEqual(@as(?u8, null), StreamType.eye_tracking.toModalityOrdinal());
}

test "ChannelFormat enum values match liblsl" {
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(ChannelFormat.cf_float32));
    try std.testing.expectEqual(@as(c_int, 2), @intFromEnum(ChannelFormat.cf_double64));
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(ChannelFormat.cf_undefined));
    try std.testing.expectEqual(@as(c_int, 7), @intFromEnum(ChannelFormat.cf_int64));
}

test "MAX_CHANNELS sufficient for common devices" {
    // DSI-24 = 24ch, OpenBCI Cyton Daisy = 16ch, g.tec Nautilus = 64ch
    try std.testing.expect(MAX_CHANNELS >= 128);
}

test "localClock returns positive time" {
    const t = localClock();
    try std.testing.expect(t > 0);
}

test "stream synchronizer init and add" {
    var sync = StreamSynchronizer.init();
    const eeg_idx = try sync.addStream(.{
        .name = "DSI-24",
        .stream_type = .eeg,
        .channel_count = 21,
        .nominal_rate = 300.0,
        .source_id = "DSI24-0001",
    });
    try std.testing.expectEqual(@as(u8, 0), eeg_idx);

    const fnirs_idx = try sync.addStream(.{
        .name = "PLUX-fNIRS",
        .stream_type = .fnirs,
        .channel_count = 3,
        .nominal_rate = 10.0,
        .source_id = "PLUX-0001",
    });
    try std.testing.expectEqual(@as(u8, 1), fnirs_idx);
    try std.testing.expectEqual(@as(u8, 2), sync.n_streams);
}

test "unified timestamp monotonicity" {
    var sync = StreamSynchronizer.init();
    _ = try sync.addStream(.{
        .name = "test",
        .stream_type = .eeg,
        .channel_count = 1,
        .nominal_rate = 250.0,
        .source_id = "test",
    });

    const t1 = sync.timestamp(0);
    const t2 = sync.timestamp(0);
    try std.testing.expect(t2.time_s >= t1.time_s);
    try std.testing.expectEqual(@as(u64, 0), t1.sample_index);
    try std.testing.expectEqual(@as(u64, 1), t2.sample_index);
}

test "estimate offset from markers" {
    const markers_a = [_]f64{ 1.0, 2.0, 3.0, 4.0 };
    const markers_b = [_]f64{ 1.1, 2.1, 3.1, 4.1 };
    const offset = StreamSynchronizer.estimateOffset(&markers_a, &markers_b);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), offset, 0.001);
}

test "timestamp to millis" {
    const ts = UnifiedTimestamp{
        .time_s = 1.5,
        .stream_type = .eeg,
        .sample_index = 0,
    };
    try std.testing.expectEqual(@as(u64, 1500), ts.toMillis());
}

test "max streams limit" {
    var sync = StreamSynchronizer.init();
    for (0..MAX_STREAMS) |_| {
        _ = try sync.addStream(.{
            .name = "test",
            .stream_type = .eeg,
            .channel_count = 1,
            .nominal_rate = 250.0,
            .source_id = "test",
        });
    }
    try std.testing.expectError(LSLError.TooManyStreams, sync.addStream(.{
        .name = "overflow",
        .stream_type = .eeg,
        .channel_count = 1,
        .nominal_rate = 250.0,
        .source_id = "overflow",
    }));
}

test "resample: upsample 10Hz to 300Hz" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input: [10]f32 = undefined;
    for (0..10) |i| {
        input[i] = @floatFromInt(i);
    }

    const output = try resample(&input, 10.0, 300.0, allocator);
    defer allocator.free(output);

    // ~300 samples for 1 second at 300Hz
    try std.testing.expect(output.len >= 290 and output.len <= 310);
    try std.testing.expectApproxEqAbs(input[0], output[0], 0.01);
}

test "resample: downsample 300Hz to 10Hz" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var input: [300]f32 = undefined;
    for (0..300) |_i| {
        input[_i] = 42.0;
    }

    const output = try resample(&input, 300.0, 10.0, allocator);
    defer allocator.free(output);

    try std.testing.expect(output.len >= 9 and output.len <= 11);
    for (output) |v| {
        try std.testing.expectApproxEqAbs(@as(f32, 42.0), v, 0.01);
    }
}
