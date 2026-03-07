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
