//! bci_integration_test.zig — End-to-end multimodal BCI pipeline test
//!
//! Validates the complete signal chain:
//!   DSI-24 raw packet → parse → EEG channels → trit
//!   PLUX fNIRS raw optical → mBLL → HbO/HbR → trit
//!   Eye tracker → IVT classify → fixation/saccade → trit
//!   Pose bridge → joint angles → movement trit
//!   All modalities → LSL StreamSynchronizer → AlignedEpoch
//!   EDF writer → export
//!   GF(3) conservation check across all trits

const std = @import("std");
const dsi24 = @import("dsi24_parser");
const fnirs = @import("fnirs_processor");
const eye = @import("eyetracking");
// pose_bridge uses @import("bci_receiver.zig") file import which conflicts
// with the bci_receiver module import in this compilation unit.
// pose_bridge tests run standalone via test-bci step.
const lsl = @import("lsl_inlet");
const edf = @import("edf_writer");
const edf_reader = @import("edf_reader");
const bci = @import("bci_receiver");
const propagator = @import("propagator");
const fft_bands = @import("fft_bands");
const erc = @import("erc");

// ============================================================================
// TEST 1: DSI-24 → parse → verify channel count + scale
// ============================================================================

test "integration: DSI-24 parse and scale" {
    // Construct a synthetic 84-byte DSI-24 packet
    var packet: [dsi24.DSI24_PACKET_LEN]u8 = [_]u8{0} ** dsi24.DSI24_PACKET_LEN;
    packet[0] = dsi24.DSI24_PACKET_TYPE_EEG; // packet type

    // Set sample counter = 1 (big-endian u32 at bytes 1-4)
    packet[4] = 1;

    // Set channel 0 (Fp1) to ADC value 0x001000 = 4096
    // 3 bytes starting at offset 9: big-endian 24-bit
    packet[9] = 0x00;
    packet[10] = 0x10;
    packet[11] = 0x00;

    const sample = try dsi24.parseDSI24Packet(&packet);
    try std.testing.expectEqual(@as(u32, 1), sample.sample_counter);

    // Channel 0 (Fp1) should have the converted µV value
    const expected_uv: f32 = 4096.0 * @as(f32, @floatCast(dsi24.DSI24_SCALE));
    try std.testing.expectApproxEqAbs(expected_uv, sample.eeg_channels[0], 0.001);

    // Other EEG channels should be 0
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), sample.eeg_channels[1], 0.001);

    // All 21 EEG + 3 AUX channels accessible
    const all = sample.allChannels();
    try std.testing.expectEqual(@as(usize, 24), all.len);
}

// ============================================================================
// TEST 2: fNIRS mBLL pipeline (raw optical → HbO/HbR → trit)
// ============================================================================

test "integration: fNIRS mBLL full pipeline" {
    const config = fnirs.WavelengthPair.plux();

    // Simulate strong activation: large OD changes
    // PLUX config: dpf1=6.51, dpf2=5.60, sd_separation=3.0cm
    // norm_od = delta_od / (dpf * sd) → need larger delta_od for significant HbO
    const delta_od1: f32 = 0.5; // 660nm: moderate
    const delta_od2: f32 = 1.2; // 860nm: large (HbO dominant at 860nm)

    const hemo = fnirs.beerLambert(delta_od1, delta_od2, config);

    // HbO should be positive (cortical activation)
    try std.testing.expect(hemo.hbo > 0);
    // HbT = HbO + HbR
    try std.testing.expectApproxEqAbs(hemo.hbo + hemo.hbr, hemo.hbt, 0.001);

    // Classify: positive HbO above threshold → PLUS trit (activation)
    const reading = fnirs.FNIRSReading.fromConcentration(hemo, 1000, 0.001);
    try std.testing.expectEqual(fnirs.Trit.plus, reading.trit);
}

// ============================================================================
// TEST 3: Eye tracking IVT → trit classification
// ============================================================================

test "integration: eye tracking fixation and saccade" {
    // Fixation: two nearby gaze points
    const fix1 = eye.GazeSample{
        .gaze_x = 0.5,
        .gaze_y = 0.5,
        .pupil_left = 4.0,
        .pupil_right = 4.0,
        .timestamp_ms = 0,
        .confidence = 1.0,
    };
    const fix2 = eye.GazeSample{
        .gaze_x = 0.501,
        .gaze_y = 0.501,
        .pupil_left = 4.0,
        .pupil_right = 4.0,
        .timestamp_ms = 8, // ~120Hz interval in ms
        .confidence = 1.0,
    };

    const fix_result = eye.classifyIVT(fix2, fix1, .{});
    try std.testing.expectEqual(eye.GazeEvent.fixation, fix_result.event);
    try std.testing.expectEqual(eye.Trit.zero, fix_result.event.toTrit()); // ERGODIC

    // Saccade: large jump
    const sac = eye.GazeSample{
        .gaze_x = 0.9,
        .gaze_y = 0.1,
        .pupil_left = 4.0,
        .pupil_right = 4.0,
        .timestamp_ms = 16,
        .confidence = 1.0,
    };

    const sac_result = eye.classifyIVT(sac, fix2, .{});
    try std.testing.expectEqual(eye.GazeEvent.saccade, sac_result.event);
    try std.testing.expectEqual(eye.Trit.plus, sac_result.event.toTrit()); // GENERATOR
}

// ============================================================================
// TEST 4: Pose classification logic (standalone, mirrors pose_bridge thresholds)
// ============================================================================

test "integration: pose movement trit classification logic" {
    // pose_bridge.zig thresholds: VELOCITY_HIGH=0.15, VELOCITY_LOW=0.02, TREMOR_FREQ=4.0
    const VELOCITY_HIGH: f32 = 0.15;
    const VELOCITY_LOW: f32 = 0.02;
    const TREMOR_FREQ: f32 = 4.0;

    const classifyMovement = struct {
        fn f(velocity: f32, frequency: f32) bci.Trit {
            if (velocity > VELOCITY_HIGH) return .plus;
            if (velocity < VELOCITY_LOW and frequency > TREMOR_FREQ) return .minus;
            return .zero;
        }
    }.f;

    try std.testing.expectEqual(bci.Trit.zero, classifyMovement(0.05, 0.5));
    try std.testing.expectEqual(bci.Trit.plus, classifyMovement(2.5, 1.0));
    try std.testing.expectEqual(bci.Trit.minus, classifyMovement(0.01, 5.0));
}

// ============================================================================
// TEST 5: LSL StreamSynchronizer — multi-modal registration + trit mapping
// ============================================================================

test "integration: LSL sync registers streams and trit mapping" {
    var sync = lsl.StreamSynchronizer.init();

    // Register three modality streams at different rates
    const eeg_id = try sync.addStream(.{
        .stream_type = .eeg,
        .nominal_rate = 300.0,
        .channel_count = 24,
        .name = "DSI-24",
        .source_id = "dsi24-001",
    });
    try std.testing.expectEqual(@as(u8, 0), eeg_id);

    const fnirs_id = try sync.addStream(.{
        .stream_type = .fnirs,
        .nominal_rate = 10.0,
        .channel_count = 3,
        .name = "PLUX",
        .source_id = "plux-001",
    });
    try std.testing.expectEqual(@as(u8, 1), fnirs_id);

    const eye_id = try sync.addStream(.{
        .stream_type = .eye_tracking,
        .nominal_rate = 120.0,
        .channel_count = 4,
        .name = "aSee",
        .source_id = "asee-001",
    });
    try std.testing.expectEqual(@as(u8, 2), eye_id);

    // Verify stream type → trit mapping (GF(3))
    try std.testing.expectEqual(@as(i8, 0), lsl.StreamType.eeg.trit()); // ERGODIC
    try std.testing.expectEqual(@as(i8, 1), lsl.StreamType.fnirs.trit()); // PLUS
    try std.testing.expectEqual(@as(i8, -1), lsl.StreamType.eye_tracking.trit()); // MINUS
    // Sum = 0 + 1 + (-1) = 0 GF(3) balanced
}

// ============================================================================
// TEST 6: EDF writer — export EEG data
// ============================================================================

test "integration: EDF export round-trip" {
    const allocator = std.testing.allocator;

    const header = edf.EDFHeader.defaultEEG(2, 4); // 2 channels, 4 samples/record
    var writer = edf.EDFWriter.init(allocator, header);
    defer writer.deinit();

    const ch0 = [_]i16{ 100, -100, 200, -200 };
    const ch1 = [_]i16{ 50, -50, 150, -150 };
    const record = [_][]const i16{ &ch0, &ch1 };
    try writer.writeDataRecord(&record);
    try std.testing.expectEqual(@as(u32, 1), writer.n_records);

    const edf_data = try writer.finalize();
    defer allocator.free(edf_data);

    // Must start with EDF version "0"
    try std.testing.expect(std.mem.startsWith(u8, edf_data, "0"));
    // Header: 256 (general) + 256 * 2 (channels) = 768 bytes
    // Data: 1 record * 2 channels * 4 samples * 2 bytes = 16 bytes
    try std.testing.expectEqual(@as(usize, 768 + 16), edf_data.len);
}

// ============================================================================
// TEST 7: BCI receiver — 9 modalities registered
// ============================================================================

test "integration: BCI receiver all modalities" {
    const receiver = bci.UniversalReceiver.init(0xCAFE);

    // All 9 modalities initialized with valid config
    for (0..9) |i| {
        const sensor = receiver.sensors[i];
        try std.testing.expect(sensor.sample_rate > 0);
        try std.testing.expect(sensor.channelCount() > 0);
    }

    // EEG at DSI-24 native rate
    try std.testing.expectEqual(@as(u16, 300), receiver.sensors[0].sample_rate);

    // fNIRS at PLUX raw rate
    try std.testing.expectEqual(@as(u16, 500), receiver.sensors[5].sample_rate);

    // Eye tracking
    try std.testing.expectEqual(@as(u16, 120), receiver.sensors[6].sample_rate);

    // Body tracking (pose)
    try std.testing.expectEqual(@as(u16, 30), receiver.sensors[8].sample_rate);
}

// ============================================================================
// TEST 8: GF(3) conservation — trit sum across modality types = 0 mod 3
// ============================================================================

test "integration: GF(3) conservation across pipeline" {
    // LSL StreamType trits form a balanced triad:
    //   eeg(0) + fnirs(+1) + eye(-1) = 0
    const eeg_trit: i8 = lsl.StreamType.eeg.trit();
    const fnirs_trit: i8 = lsl.StreamType.fnirs.trit();
    const eye_trit: i8 = lsl.StreamType.eye_tracking.trit();

    const sum = eeg_trit + fnirs_trit + eye_trit;
    try std.testing.expectEqual(@as(i8, 0), @as(i8, @intCast(@mod(sum + 3, 3))));
}

// ============================================================================
// TEST 9: Cross-module type compatibility
// ============================================================================

test "integration: Trit types compatible across modules" {
    // All modules define Trit with same semantics (-1, 0, +1)
    try std.testing.expectEqual(@as(i8, 1), @intFromEnum(fnirs.Trit.plus));
    try std.testing.expectEqual(@as(i8, 1), @intFromEnum(eye.Trit.plus));
    try std.testing.expectEqual(@as(i8, 1), @intFromEnum(bci.Trit.plus));

    // GF(3) addition across module trits: fnirs(+1) + eye(-1) + bci(0) = 0
    const cross_sum = @intFromEnum(fnirs.Trit.plus) + @intFromEnum(eye.Trit.minus) + @intFromEnum(bci.Trit.zero);
    try std.testing.expectEqual(@as(i8, 0), @as(i8, @intCast(@mod(cross_sum + 3, 3))));
}

// ============================================================================
// TEST 10: EDF writer → reader round-trip via edf_reader module
// ============================================================================

test "integration: EDF writer-reader round trip" {
    const allocator = std.testing.allocator;

    // Write a 3-channel, 8-sample EDF
    var header = edf.EDFHeader.defaultEEG(3, 8);
    header.start_date = "07.03.26".*;
    header.start_time = "15.30.00".*;

    var writer = edf.EDFWriter.init(allocator, header);
    defer writer.deinit();

    const ch0 = [_]i16{ 100, -100, 200, -200, 300, -300, 400, -400 };
    const ch1 = [_]i16{ 50, -50, 150, -150, 250, -250, 350, -350 };
    const ch2 = [_]i16{ 10, -10, 20, -20, 30, -30, 40, -40 };
    const record = [_][]const i16{ &ch0, &ch1, &ch2 };
    try writer.writeDataRecord(&record);

    const edf_data = try writer.finalize();
    defer allocator.free(edf_data);

    // Parse it back
    const parsed = try edf_reader.EDFFile.parse(edf_data);
    try std.testing.expectEqual(@as(u16, 3), parsed.n_channels);
    try std.testing.expectEqual(@as(u32, 1), parsed.n_records);
    try std.testing.expectEqualStrings("Fp1", parsed.channels[0].labelStr());
    try std.testing.expectEqualStrings("F7", parsed.channels[2].labelStr());

    // Verify sample values survived the round trip
    try std.testing.expectEqual(@as(i16, 100), try parsed.getSample(0, 0, 0));
    try std.testing.expectEqual(@as(i16, -400), try parsed.getSample(0, 0, 7));
    try std.testing.expectEqual(@as(i16, 50), try parsed.getSample(0, 1, 0));
    try std.testing.expectEqual(@as(i16, -40), try parsed.getSample(0, 2, 7));

    // Physical value check: digital 100 in [-3200,3200]/[-32768,32767]
    const phys = parsed.toPhysical(0, 100);
    try std.testing.expectApproxEqAbs(@as(f64, 9.76), phys, 0.2);
}

// ============================================================================
// TEST 11: Parse real PhysioNet EDF fixture (embedded 2ch synthetic)
// ============================================================================

test "integration: parse PhysioNet-format EDF fixture" {
    // fixture_2ch.edf: 2 channels (Fp1, Fp2), 4 Hz, 2 records, 800 bytes
    const fixture = @embedFile("testdata/fixture_2ch.edf");
    const parsed = try edf_reader.EDFFile.parse(fixture);

    try std.testing.expectEqual(@as(u16, 2), parsed.n_channels);
    try std.testing.expectEqual(@as(u32, 2), parsed.n_records);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), parsed.record_duration, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), parsed.totalDuration(), 0.001);

    // Channel labels
    try std.testing.expectEqualStrings("Fp1", parsed.channels[0].labelStr());
    try std.testing.expectEqualStrings("Fp2", parsed.channels[1].labelStr());

    // Sample values from record 0: ch0=[100, -100, 200, -200]
    try std.testing.expectEqual(@as(i16, 100), try parsed.getSample(0, 0, 0));
    try std.testing.expectEqual(@as(i16, -200), try parsed.getSample(0, 0, 3));

    // Record 1, ch1: [75, -75, 175, -175]
    try std.testing.expectEqual(@as(i16, 75), try parsed.getSample(1, 1, 0));
    try std.testing.expectEqual(@as(i16, -175), try parsed.getSample(1, 1, 3));

    // Sample rate
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), parsed.sampleRate(0), 0.001);
}

// ============================================================================
// TEST 12: Full pipeline — EEG → FFT → BandPowers → Propagator → Action
// Bridges fft_bands.zig and propagator.zig (SDF Ch7 recommendation)
// ============================================================================

test "integration: EEG FFT bands into propagator network" {
    const allocator = std.testing.allocator;

    // --- Stage 1: Generate synthetic EEG (strong 10Hz alpha + weak beta noise) ---
    const sample_rate: f64 = 250.0;
    const n_samples: usize = 250; // 1 second epoch
    const samples = try allocator.alloc(f32, n_samples);
    defer allocator.free(samples);

    for (0..n_samples) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatCast(sample_rate));
        // Strong alpha (10Hz) + weak beta (20Hz) — simulates relaxed but alert state
        samples[i] = 1.0 * @sin(2.0 * std.math.pi * 10.0 * t) +
            0.2 * @sin(2.0 * std.math.pi * 20.0 * t);
    }

    // --- Stage 2: Extract EEG band powers via comptime-memoized FFT ---
    const bands = try fft_bands.extractBands(samples, sample_rate, allocator);

    // Alpha should dominate (10Hz sine)
    try std.testing.expect(bands.alpha > bands.delta);
    try std.testing.expect(bands.alpha > bands.theta);
    try std.testing.expect(bands.alpha > bands.beta);

    // --- Stage 3: Compute focus and relaxation from band powers ---
    // Focus metric: beta / (alpha + beta) — low when alpha dominates
    const total_ab = bands.alpha + bands.beta;
    const focus_level: f32 = if (total_ab > 0) bands.beta / total_ab else 0.0;
    // Relaxation metric: theta / (theta + beta) — moderate here
    const total_tb = bands.theta + bands.beta;
    const relax_level: f32 = if (total_tb > 0) bands.theta / total_tb else 0.0;

    // --- Stage 4: Wire into propagator cells ---
    const CellF32 = propagator.Cell(f32, comptime propagator.defaultMerge(f32));

    var focus_cell = CellF32.init(allocator, "eeg_focus");
    defer focus_cell.deinit();
    var relax_cell = CellF32.init(allocator, "eeg_relax");
    defer relax_cell.deinit();
    var threshold_cell = CellF32.init(allocator, "threshold");
    defer threshold_cell.deinit();
    var action_cell = CellF32.init(allocator, "action");
    defer action_cell.deinit();

    // Set cell values from BCI signal processing
    try focus_cell.set_content(focus_level);
    try relax_cell.set_content(relax_level);
    try threshold_cell.set_content(0.5); // neurofeedback threshold

    // --- Stage 5: Apply neurofeedback_gate propagator function ---
    const gate_result = propagator.neurofeedback_gate(&.{
        focus_cell.get_content(),
        relax_cell.get_content(),
        threshold_cell.get_content(),
    });

    // With strong alpha (focus_level low, ~0.04), gate should NOT trigger
    try std.testing.expect(gate_result != null);
    try action_cell.set_content(gate_result.?);
    try std.testing.expectEqual(@as(?f32, 0.0), action_cell.get_content());

    // --- Stage 6: Verify focus_brightness propagator ---
    const brightness = propagator.focus_brightness(&.{focus_cell.get_content()});
    try std.testing.expect(brightness != null);
    // Low focus → brightness near 0.6 (dim)
    try std.testing.expect(brightness.? < 0.7);
    try std.testing.expect(brightness.? >= 0.6);
}

// ============================================================================
// TEST 13: Multi-modal propagator fusion — EEG + fNIRS + Eye → unified trit
// ============================================================================

test "integration: multi-modal propagator fusion with GF(3) balance" {
    const allocator = std.testing.allocator;
    const LCell = propagator.Cell(f32, comptime propagator.latticeMerge(f32));

    // Create cells for each modality's trit output (as f32: -1, 0, +1)
    var eeg_trit_cell = LCell.init(allocator, "eeg_trit");
    defer eeg_trit_cell.deinit();
    var fnirs_trit_cell = LCell.init(allocator, "fnirs_trit");
    defer fnirs_trit_cell.deinit();
    var eye_trit_cell = LCell.init(allocator, "eye_trit");
    defer eye_trit_cell.deinit();

    // EEG → ERGODIC (0), fNIRS → PLUS (+1), Eye → MINUS (-1)
    try eeg_trit_cell.set_content(0.0);
    try fnirs_trit_cell.set_content(1.0);
    try eye_trit_cell.set_content(-1.0);

    // Verify lattice merge is idempotent (setting same value again)
    try eeg_trit_cell.set_content(0.0);
    try std.testing.expectEqual(@as(?f32, 0.0), eeg_trit_cell.get_content());

    // Setting contradictory value triggers contradiction
    try fnirs_trit_cell.set_content(-1.0); // was +1, now -1 → contradiction
    try std.testing.expect(fnirs_trit_cell.get_cell_value().isContradiction());

    // GF(3) conservation: sum of non-contradicted modalities
    // eeg(0) + eye(-1) = -1, missing fnirs(+1) to balance
    const eeg_val = eeg_trit_cell.get_content() orelse 0.0;
    const eye_val = eye_trit_cell.get_content() orelse 0.0;
    // fnirs is in contradiction — detectable!
    try std.testing.expect(fnirs_trit_cell.get_cell_value().isContradiction());

    // Only balanced if all three are coherent
    const partial_sum = @as(i8, @intFromFloat(eeg_val + eye_val));
    try std.testing.expectEqual(@as(i8, -1), partial_sum); // Unbalanced — contradiction detected
}

// ============================================================================
// TEST 14: ERC multi-channel ensemble → trit with propagator integration
// ============================================================================

test "integration: ERC 8-channel ensemble to propagator cell" {
    const allocator = std.testing.allocator;

    // Generate 8 channels of synthetic EEG (alpha-dominant, ~10Hz)
    const sample_rate: f64 = 250.0;
    const n_samples: usize = 250;
    var all_bands: [8]fft_bands.BandPowers = undefined;

    for (0..8) |ch| {
        const samples = try allocator.alloc(f32, n_samples);
        defer allocator.free(samples);

        for (0..n_samples) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatCast(sample_rate));
            // 10Hz alpha + small per-channel phase offset (spatial multiplexing)
            const phase = @as(f32, @floatFromInt(ch)) * 0.3;
            samples[i] = 1.0 * @sin(2.0 * std.math.pi * 10.0 * t + phase) +
                0.1 * @sin(2.0 * std.math.pi * 25.0 * t); // weak beta noise
        }

        all_bands[ch] = try fft_bands.extractBands(samples, sample_rate, allocator);
    }

    // ERC classification
    var reservoir = erc.Cyton.init(.uniform);
    const result = reservoir.processFromBandPowers(all_bands);

    // Alpha-dominant → ZERO (relaxed baseline)
    try std.testing.expectEqual(bci.Trit.zero, result.trit);
    try std.testing.expect(result.confidence > 0.3);

    // Wire ERC output into propagator cell
    const CellF32 = propagator.Cell(f32, comptime propagator.defaultMerge(f32));
    var erc_cell = CellF32.init(allocator, "erc_trit");
    defer erc_cell.deinit();

    const cv = reservoir.toCellValue();
    try erc_cell.set_cell_value(cv);
    try std.testing.expectEqual(@as(?f32, 0.0), erc_cell.get_content()); // zero trit

    // GF(3) balance: erc(0) + fnirs(+1) + eye(-1) = 0
    const erc_trit: i8 = @intFromEnum(result.trit);
    const fnirs_trit: i8 = @intFromEnum(fnirs.Trit.plus);
    const eye_trit_val: i8 = @intFromEnum(eye.Trit.minus);
    const gf3_sum = erc_trit + fnirs_trit + eye_trit_val;
    try std.testing.expectEqual(@as(i8, 0), @as(i8, @intCast(@mod(gf3_sum + 3, 3))));
}

// ============================================================================
// TEST 15: ERC entropy-weighted denoising through full pipeline
// ============================================================================

test "integration: ERC entropy-weighted denoises bad channel" {
    const allocator = std.testing.allocator;

    const sample_rate: f64 = 250.0;
    const n_samples: usize = 250;
    var all_bands: [4]fft_bands.BandPowers = undefined;

    // Channels 0-2: clean beta-dominant (25Hz) → should classify as PLUS
    for (0..3) |ch| {
        const samples = try allocator.alloc(f32, n_samples);
        defer allocator.free(samples);

        for (0..n_samples) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatCast(sample_rate));
            samples[i] = 1.0 * @sin(2.0 * std.math.pi * 25.0 * t);
        }
        all_bands[ch] = try fft_bands.extractBands(samples, sample_rate, allocator);
    }

    // Channel 3: pure noise (flat spectrum from white noise approximation)
    {
        const samples = try allocator.alloc(f32, n_samples);
        defer allocator.free(samples);
        // Create broadband signal: sum of many frequencies
        for (0..n_samples) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatCast(sample_rate));
            samples[i] = @sin(2.0 * std.math.pi * 2.0 * t) + // delta
                @sin(2.0 * std.math.pi * 6.0 * t) + // theta
                @sin(2.0 * std.math.pi * 10.0 * t) + // alpha
                @sin(2.0 * std.math.pi * 20.0 * t) + // beta
                @sin(2.0 * std.math.pi * 40.0 * t); // gamma
        }
        all_bands[3] = try fft_bands.extractBands(samples, sample_rate, allocator);
    }

    // Both modes should classify as PLUS (beta dominant in clean channels)
    var erc_weighted = erc.ERC(4).init(.entropy_weighted);
    const result_weighted = erc_weighted.processFromBandPowers(all_bands);
    try std.testing.expectEqual(bci.Trit.plus, result_weighted.trit);

    // Verify the ERC output is compatible with neurofeedback_gate
    const focus = result_weighted.confidence; // high confidence → focused
    const gate = propagator.neurofeedback_gate(&.{ focus, 0.1, 0.5 });
    // If confidence > 0.5 and relax < 0.3, gate triggers
    if (focus > 0.5) {
        try std.testing.expectEqual(@as(?f32, 1.0), gate);
    }
}

// ============================================================================
// TEST 16: Online ERC adaptation — learn from zero, classify real FFT data
// Full pipeline: synthetic EEG → FFT → ERC(zero weights) → LMS adapt → correct trit
// ============================================================================

test "integration: ERC online learning from zero weights with FFT pipeline" {
    const allocator = std.testing.allocator;
    const sample_rate: f64 = 250.0;
    const n_samples: usize = 250;
    const config = erc.LearningConfig{ .learning_rate = 0.5, .weight_decay = 0.0001, .nlms_epsilon = 1.0 };

    // Initialize ERC with ZERO weights (no domain knowledge)
    var reservoir = erc.ERC(4).init(.uniform);
    reservoir.readout = erc.ReadoutLayer(4).initZero();

    // --- Generate training data: 3 classes of 4-channel synthetic EEG ---

    // Class ZERO: 10Hz alpha-dominant
    var alpha_bands: [4]fft_bands.BandPowers = undefined;
    for (0..4) |ch| {
        const samples = try allocator.alloc(f32, n_samples);
        defer allocator.free(samples);
        for (0..n_samples) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatCast(sample_rate));
            const phase = @as(f32, @floatFromInt(ch)) * 0.2;
            samples[i] = 1.0 * @sin(2.0 * std.math.pi * 10.0 * t + phase);
        }
        alpha_bands[ch] = try fft_bands.extractBands(samples, sample_rate, allocator);
    }

    // Class PLUS: 25Hz beta-dominant
    var beta_bands: [4]fft_bands.BandPowers = undefined;
    for (0..4) |ch| {
        const samples = try allocator.alloc(f32, n_samples);
        defer allocator.free(samples);
        for (0..n_samples) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatCast(sample_rate));
            const phase = @as(f32, @floatFromInt(ch)) * 0.2;
            samples[i] = 1.0 * @sin(2.0 * std.math.pi * 25.0 * t + phase);
        }
        beta_bands[ch] = try fft_bands.extractBands(samples, sample_rate, allocator);
    }

    // Class MINUS: 2Hz delta-dominant
    var delta_bands: [4]fft_bands.BandPowers = undefined;
    for (0..4) |ch| {
        const samples = try allocator.alloc(f32, n_samples);
        defer allocator.free(samples);
        for (0..n_samples) |i| {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatCast(sample_rate));
            const phase = @as(f32, @floatFromInt(ch)) * 0.2;
            samples[i] = 1.0 * @sin(2.0 * std.math.pi * 2.0 * t + phase);
        }
        delta_bands[ch] = try fft_bands.extractBands(samples, sample_rate, allocator);
    }

    // --- Before training: zero weights → near-uniform confidence ---
    const pre = reservoir.processFromBandPowers(alpha_bands);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0 / 3.0), pre.confidence, 0.05);

    // --- Train for 200 epochs (FFT features have large magnitudes, need more iterations) ---
    var last_mse: f32 = 1.0;
    for (0..200) |_| {
        _ = reservoir.adaptFromBandPowers(alpha_bands, .zero, config);
        _ = reservoir.adaptFromBandPowers(beta_bands, .plus, config);
        last_mse = reservoir.adaptFromBandPowers(delta_bands, .minus, config);
    }

    // MSE should converge
    try std.testing.expect(last_mse < 0.25);

    // --- After training: correct classification ---
    const r_alpha = reservoir.processFromBandPowers(alpha_bands);
    const r_beta = reservoir.processFromBandPowers(beta_bands);
    const r_delta = reservoir.processFromBandPowers(delta_bands);

    try std.testing.expectEqual(bci.Trit.zero, r_alpha.trit);
    try std.testing.expectEqual(bci.Trit.plus, r_beta.trit);
    try std.testing.expectEqual(bci.Trit.minus, r_delta.trit);

    // Confidence above chance (1/3)
    try std.testing.expect(r_alpha.confidence > 0.4);
    try std.testing.expect(r_beta.confidence > 0.4);
    try std.testing.expect(r_delta.confidence > 0.4);

    // Wire the learned output into propagator
    const CellF32 = propagator.Cell(f32, comptime propagator.defaultMerge(f32));
    var cell = CellF32.init(allocator, "erc_learned");
    defer cell.deinit();
    const cv = reservoir.toCellValue();
    try cell.set_cell_value(cv);

    // Last processed was delta → minus → -1.0
    try std.testing.expectEqual(@as(?f32, -1.0), cell.get_content());
}

// ============================================================================
// TEST 17: Substrate witness gate — EEG trit through Church-Turing witness
// ============================================================================

test "integration: substrate witness gate detects divergence" {
    const allocator = std.testing.allocator;
    const LCell = propagator.Cell(f32, comptime propagator.latticeMerge(f32));

    // Simulate Cyton epoch: 8 channels classified as trits
    // Pattern from real recording: [+1 0 +1 +1 +1 +1 +1 -1] sum=+5
    const epoch_trits = [8]f32{ 1, 0, 1, 1, 1, 1, 1, -1 };
    var trit_sum: f32 = 0;
    for (epoch_trits) |t| trit_sum += t;
    try std.testing.expectEqual(@as(f32, 5.0), trit_sum);

    // Substrate witness results (from nanoclj semi-decide):
    // tree-walk says sum matches target (true), inet says it doesn't (false)
    const tw_answer: f32 = 1.0; // true
    const inet_answer: f32 = 0.0; // false — substrates disagree

    // witness_gate returns null on disagreement
    const gate_result = propagator.witness_gate(&.{ tw_answer, inet_answer, trit_sum });
    try std.testing.expect(gate_result == null);

    // When substrates agree, gate passes the trit sum through
    const agree_result = propagator.witness_gate(&.{ 1.0, 1.0, trit_sum });
    try std.testing.expectEqual(@as(?f32, 5.0), agree_result);

    // Wire into lattice cell: two epochs with different trit sums → contradiction
    var epoch_cell = LCell.init(allocator, "epoch_witness");
    defer epoch_cell.deinit();

    // Epoch 0: pattern sum=+5
    try epoch_cell.set_content(5.0);
    try std.testing.expectEqual(@as(?f32, 5.0), epoch_cell.get_content());

    // Epoch 1: different pattern sum=+3
    try epoch_cell.set_content(3.0);
    try std.testing.expect(epoch_cell.get_cell_value().isContradiction());

    // SubstrateWitness: tree-walk + lokke agree, inet diverges
    const witness = propagator.SubstrateWitness{
        .tree_walk_answer = true,
        .inet_answer = false,
        .lokke_answer = true,
        .both_halted = true,
        .inet_trit_balanced = true,
    };
    try std.testing.expect(!witness.agrees());
    try std.testing.expect(witness.sequentialAgree());
}

// ============================================================================
// TEST 18: Full Cyton epoch pipeline — trit classify → witness gate → lattice
// Simulates 29 epochs from real Cyton recording patterns.
// ============================================================================

test "integration: 29-epoch Cyton witness pipeline with glimpse timestamps" {
    const allocator = std.testing.allocator;
    const LCell = propagator.Cell(f32, comptime propagator.latticeMerge(f32));
    const glimpse = @import("glimpse");

    const SAMPLE_RATE: u64 = 250;
    const TICKS_PER_SAMPLE = glimpse.TICKS_PER_SECOND / SAMPLE_RATE;

    // Verify exact division
    try std.testing.expectEqual(@as(u64, 0), glimpse.TICKS_PER_SECOND % SAMPLE_RATE);
    try std.testing.expectEqual(@as(u64, 564_480), TICKS_PER_SAMPLE);

    // Real Cyton patterns: 27 epochs of sum=+5, 2 epochs of sum=+3
    const EPOCHS = 29;
    var witness_results: [EPOCHS]struct { sum: f32, tw: f32, inet: f32 } = undefined;
    for (0..EPOCHS) |ep| {
        if (ep == 7 or ep == 19) {
            // Pattern B: [+1 0 -1 +1 +1 +1 +1 -1] sum=+3
            witness_results[ep] = .{ .sum = 3.0, .tw = 1.0, .inet = 0.0 };
        } else {
            // Pattern A: [+1 0 +1 +1 +1 +1 +1 -1] sum=+5
            witness_results[ep] = .{ .sum = 5.0, .tw = 1.0, .inet = 0.0 };
        }
    }

    // Process each epoch through witness_gate
    var agreed: u32 = 0;
    var disagreed: u32 = 0;
    var lattice_cell = LCell.init(allocator, "cyton_witness");
    defer lattice_cell.deinit();

    for (0..EPOCHS) |ep| {
        const w = witness_results[ep];
        const epoch_glimpse = ep * SAMPLE_RATE * TICKS_PER_SAMPLE;
        _ = epoch_glimpse;

        const gate = propagator.witness_gate(&.{ w.tw, w.inet, w.sum });
        if (gate != null) {
            agreed += 1;
        } else {
            disagreed += 1;
        }
    }

    // All 29 epochs should show substrate disagreement (tw=true, inet=false)
    try std.testing.expectEqual(@as(u32, 0), agreed);
    try std.testing.expectEqual(@as(u32, 29), disagreed);

    // Lattice merge of different trit sums produces contradiction
    try lattice_cell.set_content(5.0);
    try std.testing.expectEqual(@as(?f32, 5.0), lattice_cell.get_content());
    try lattice_cell.set_content(3.0);
    try std.testing.expect(lattice_cell.get_cell_value().isContradiction());

    // Total glimpse span for 29 epochs: 29 * 250 * 564,480
    const total_glimpses = EPOCHS * SAMPLE_RATE * TICKS_PER_SAMPLE;
    try std.testing.expectEqual(@as(u64, 4_092_480_000), total_glimpses);
}

// ============================================================================
// TEST 19: Classifier substrate divergence — range vs stddev on Ch7 E15
// ============================================================================
test "19. classifier substrate divergence on channel 7 epoch 15" {
    const LCell = propagator.Cell(f32, comptime propagator.latticeMerge(f32));

    // Real Cyton data: Ch7 oscillates ~11k-44k uV
    // Range = 32601 < 50000 threshold -> trit = 0 (clean)
    // StdDev = 17077 > 5000 threshold -> trit = 1 (flicker)
    const cw = propagator.ClassifierWitness{
        .channel = 7,
        .range_trit = 0, // range method: clean
        .stddev_trit = 1, // stddev method: flicker
    };
    try std.testing.expect(!cw.agrees());

    // classifier_gate returns null on divergence -> lattice contradiction
    const args = [_]?f32{ 0.0, 1.0 };
    const result = propagator.classifier_gate(&args);
    try std.testing.expect(result == null);

    // This gives us TWO kinds of ill-posedness:
    // 1. Church-Turing: tree-walk vs inet (same expression, different answers)
    // 2. Classifier:    range vs stddev   (same data, different trits)
    // Both are captured in the propagator lattice as contradictions.
    var cell = LCell.init(std.testing.allocator, "ch7_classifier");
    defer cell.deinit();

    // Range says sum=4 for E15 (Ch7=0), stddev says sum=5 (Ch7=1)
    try cell.set_content(4.0);
    try cell.set_content(5.0);
    try std.testing.expect(cell.get_cell_value().isContradiction());
}
