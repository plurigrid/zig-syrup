//! Trit-Tick Expanded — Universal Time Base for ALL BCI + Sensor + Render Modalities
//!
//! ORIGINAL (trit_tick.zig):
//!   141,120,000 = 2⁹ × 3² × 5⁴ × 7²
//!   Covers: 6 BCI modalities, standard audio, standard video, GF(3)/hue
//!   Breaks on: 25 rates (13 fNIRS, 165 monitor, 185 DBS, 508/1017 MEG,
//!              power-of-2 EEG above 512, DSD256+, 100kHz actiCHamp, etc.)
//!
//! EXPANDED (this file):
//!   51,433,932,566,016,000,000 = 2¹⁵ × 3³ × 5⁶ × 7² × 11 × 13 × 37 × 113 × 127
//!   ≈ 5.14 × 10¹⁹ Hz — time quantum ≈ 19.44 attoseconds
//!
//!   Covers ALL 105 unique integer rates across:
//!     BCI:     1–100,000 Hz (fNIRS 1 Hz through actiCHamp Plus 100 kHz)
//!     Neural:  250–30,000 Hz (Muse through Neuropixels AP band)
//!     Audio:   8,000–22,579,200 Hz (telephony through DSD512)
//!     Video:   24–600 Hz (film through 600 Hz monitors)
//!     VR/AR:   72–200 Hz (Quest through Varjo foveated)
//!     Haptic:  100–40,000 Hz (LRA through Ultraleap ultrasonic)
//!     MEG:     508–16,384 Hz (4D/BTi through QuSpin DAQ)
//!     Stim:    1–185 Hz (rTMS through DBS)
//!     Ultrasound: 250 kHz–2 MHz carrier PRF
//!     Autonomic: 1–2,000 Hz (temp through clinical ECG)
//!     Eye:     50–2,000 Hz (Tobii through EyeLink)
//!     IMU:     1–6,400 Hz (accel/gyro MEMS)
//!     Color:   GF(3)=3, bands=5, hue=360
//!     NTSC:    24000/1001, 30000/1001, 60000/1001 (all divide exactly)
//!
//! UPGRADE PATH from original trit-tick:
//!   old trit-tick = expanded / 364,469,476,800
//!   old trit-tick divides expanded exactly
//!   flicks (705,600,000) divide expanded exactly
//!   1 expanded tick ≈ 19.44 attoseconds
//!   1 old trit-tick = 364,469,476,800 expanded ticks
//!   1 flick         =  72,893,895,360 expanded ticks
//!
//! WHY 9 PRIMES (up from 4):
//!   2¹⁵: BioSemi 16384, CorTec 32768 (power-of-2 ADCs)
//!   3³:  540 Hz monitor
//!   5⁶:  1 MHz ultrasound, 250 kHz carrier (10⁶ = 2⁶×5⁶)
//!   7²:  44100 family (unchanged)
//!   11:  165 Hz gaming monitor (= 3×5×11)
//!   13:  13 Hz fNIRS, 130 Hz DBS (= 2×5×13)
//!   37:  185 Hz DBS (= 5×37)
//!   113: 4D/BTi MEG 1017 Hz (= 3²×113)
//!   127: 4D/BTi MEG 508 Hz (= 2²×127)
//!
//! The 5 new primes come from exactly 5 devices/standards:
//!   11  ← gaming monitors (165, 220 Hz)
//!   13  ← fNIRS slow imaging (13 Hz) + DBS clinical (130 Hz)
//!   37  ← deep brain stimulation (185 Hz)
//!   113 ← 4D/BTi Magnes MEG system (1017, 2034 Hz)
//!   127 ← 4D/BTi Magnes MEG system (508 Hz)

const std = @import("std");

// ============================================================================
// THE UNIVERSAL TIME QUANTUM
// ============================================================================

/// Expanded trit-ticks per second.
/// 2¹⁵ × 3³ × 5⁶ × 7² × 11 × 13 × 37 × 113 × 127
pub const TICKS_PER_SECOND: u128 = 51_433_932_566_016_000_000;

/// Original trit-tick rate (for backward compatibility).
pub const ORIGINAL_TICKS_PER_SECOND: u64 = 141_120_000;

/// Flicks per second (Facebook 2017). Original trit-tick × 5.
pub const FLICKS_PER_SECOND: u64 = 705_600_000;

/// Ratio: expanded / original. Exact integer.
pub const EXPANSION_FACTOR: u64 = 364_469_476_800;

/// Ratio: expanded / flick. Exact integer.
pub const EXPANDED_PER_FLICK: u64 = 72_893_895_360;

// ============================================================================
// FACTORIZATION STRUCTURE — THE 2-3-5-7 CORE + 5 DEVICE PRIMES
// ============================================================================

// Core primes (from original trit-tick, upgraded)
pub const PRIME_2_EXP: u5 = 15;  // was 9: BioSemi 16384, CorTec 32768
pub const PRIME_3_EXP: u5 = 3;   // was 2: 540 Hz monitor
pub const PRIME_5_EXP: u5 = 6;   // was 4: 1 MHz ultrasound
pub const PRIME_7_EXP: u5 = 2;   // unchanged: 44100 family

// Device primes (new in expansion)
pub const PRIME_11_EXP: u5 = 1;  // 165 Hz gaming monitor
pub const PRIME_13_EXP: u5 = 1;  // 13 Hz fNIRS, 130 Hz DBS
pub const PRIME_37_EXP: u5 = 1;  // 185 Hz DBS
pub const PRIME_113_EXP: u5 = 1; // 4D/BTi MEG 1017 Hz
pub const PRIME_127_EXP: u5 = 1; // 4D/BTi MEG 508 Hz

// ============================================================================
// GF(3) + COLOR + BAND QUANTA
// ============================================================================

/// GF(3) conservation quantum: TICKS_PER_SECOND / 3
pub const GF3_QUANTUM: u128 = TICKS_PER_SECOND / 3;

/// EEG band quantum: TICKS_PER_SECOND / 5
pub const BAND_QUANTUM: u128 = TICKS_PER_SECOND / 5;

/// Hue degree quantum: TICKS_PER_SECOND / 360
pub const HUE_DEGREE_QUANTUM: u128 = TICKS_PER_SECOND / 360;

// ============================================================================
// MODALITY REGISTRY — ALL 105 RATES
// ============================================================================

pub const ModalityClass = enum(u8) {
    consumer_eeg,
    research_eeg,
    clinical_eeg,
    intracortical,
    fnirs,
    meg,
    ultrasound_neuromod,
    emg_eng,
    autonomic_ecg,
    autonomic_ppg,
    autonomic_gsr,
    autonomic_resp,
    autonomic_temp,
    eye_tracking,
    motion_imu,
    audio_pcm,
    audio_dsd,
    video_display,
    vr_ar_headset,
    haptic,
    brain_stimulation,
    color_entropy,
};

pub const Modality = struct {
    name: []const u8,
    class: ModalityClass,
    rate_hz: u64,

    pub fn ticksPerSample(self: Modality) u128 {
        return TICKS_PER_SECOND / @as(u128, self.rate_hz);
    }
};

// Consumer EEG
pub const MUSE_1 = Modality{ .name = "Muse 1", .class = .consumer_eeg, .rate_hz = 220 };
pub const MUSE_2 = Modality{ .name = "Muse 2/S", .class = .consumer_eeg, .rate_hz = 256 };
pub const OPENBCI_CYTON = Modality{ .name = "OpenBCI Cyton", .class = .consumer_eeg, .rate_hz = 250 };
pub const OPENBCI_CYTON_WIFI = Modality{ .name = "OpenBCI Cyton WiFi", .class = .consumer_eeg, .rate_hz = 1000 };
pub const OPENBCI_GANGLION = Modality{ .name = "OpenBCI Ganglion", .class = .consumer_eeg, .rate_hz = 200 };
pub const OPENBCI_DAISY = Modality{ .name = "OpenBCI Daisy 16ch", .class = .consumer_eeg, .rate_hz = 125 };
pub const EMOTIV_EPOC = Modality{ .name = "Emotiv EPOC X", .class = .consumer_eeg, .rate_hz = 128 };
pub const NEUROSKY = Modality{ .name = "NeuroSky MindWave", .class = .consumer_eeg, .rate_hz = 512 };
pub const NEUROSITY_CROWN = Modality{ .name = "Neurosity Crown", .class = .consumer_eeg, .rate_hz = 256 };
pub const IDUN_GUARDIAN = Modality{ .name = "IDUN Guardian", .class = .consumer_eeg, .rate_hz = 250 };

// Research EEG
pub const BIOSEMI_2K = Modality{ .name = "BioSemi 2048", .class = .research_eeg, .rate_hz = 2048 };
pub const BIOSEMI_4K = Modality{ .name = "BioSemi 4096", .class = .research_eeg, .rate_hz = 4096 };
pub const BIOSEMI_8K = Modality{ .name = "BioSemi 8192", .class = .research_eeg, .rate_hz = 8192 };
pub const BIOSEMI_16K = Modality{ .name = "BioSemi 16384", .class = .research_eeg, .rate_hz = 16384 };
pub const GTEC_38K = Modality{ .name = "g.tec g.USBamp max", .class = .research_eeg, .rate_hz = 38400 };
pub const ACTICHAMP_100K = Modality{ .name = "actiCHamp Plus 100kHz", .class = .research_eeg, .rate_hz = 100000 };
pub const SYNAMPS_20K = Modality{ .name = "SynAmps RT 20kHz", .class = .research_eeg, .rate_hz = 20000 };

// Clinical / Intracortical
pub const BLACKROCK_SPIKE = Modality{ .name = "Blackrock 30kHz", .class = .intracortical, .rate_hz = 30000 };
pub const BLACKROCK_LFP = Modality{ .name = "Blackrock LFP", .class = .intracortical, .rate_hz = 1000 };
pub const NEURALINK = Modality{ .name = "Neuralink N1", .class = .intracortical, .rate_hz = 20000 };
pub const NEUROPIXELS_AP = Modality{ .name = "Neuropixels AP", .class = .intracortical, .rate_hz = 30000 };
pub const NEUROPIXELS_LFP = Modality{ .name = "Neuropixels LFP", .class = .intracortical, .rate_hz = 2500 };
pub const CORTEC_BIC = Modality{ .name = "CorTec BIC", .class = .intracortical, .rate_hz = 32768 };
pub const INTAN_RHD = Modality{ .name = "Intan RHD2000", .class = .intracortical, .rate_hz = 30000 };

// fNIRS
pub const FNIRS_1HZ = Modality{ .name = "fNIRS 1Hz", .class = .fnirs, .rate_hz = 1 };
pub const FNIRS_10HZ = Modality{ .name = "fNIRS 10Hz", .class = .fnirs, .rate_hz = 10 };
pub const FNIRS_13HZ = Modality{ .name = "fNIRS 13Hz (NIRx)", .class = .fnirs, .rate_hz = 13 };
pub const FNIRS_100HZ = Modality{ .name = "fNIRS 100Hz", .class = .fnirs, .rate_hz = 100 };

// MEG
pub const MEG_TRIUX = Modality{ .name = "MEGIN TRIUX neo", .class = .meg, .rate_hz = 5000 };
pub const MEG_CTF = Modality{ .name = "CTF MEG", .class = .meg, .rate_hz = 12000 };
pub const MEG_BTI_508 = Modality{ .name = "4D/BTi 508Hz", .class = .meg, .rate_hz = 508 };
pub const MEG_BTI_1017 = Modality{ .name = "4D/BTi 1017Hz", .class = .meg, .rate_hz = 1017 };
pub const MEG_BTI_2034 = Modality{ .name = "4D/BTi 2034Hz", .class = .meg, .rate_hz = 2034 };
pub const MEG_OPM = Modality{ .name = "OPM-MEG", .class = .meg, .rate_hz = 1000 };

// Ultrasound neuromodulation
pub const TFUS_250K = Modality{ .name = "tFUS 250kHz carrier", .class = .ultrasound_neuromod, .rate_hz = 250000 };
pub const TFUS_500K = Modality{ .name = "tFUS 500kHz carrier", .class = .ultrasound_neuromod, .rate_hz = 500000 };
pub const TFUS_1M = Modality{ .name = "tFUS 1MHz carrier", .class = .ultrasound_neuromod, .rate_hz = 1000000 };
pub const TFUS_2M = Modality{ .name = "tFUS 2MHz carrier", .class = .ultrasound_neuromod, .rate_hz = 2000000 };

// Eye tracking
pub const EYE_TOBII_60 = Modality{ .name = "Tobii 60Hz", .class = .eye_tracking, .rate_hz = 60 };
pub const EYE_TOBII_1200 = Modality{ .name = "Tobii Spectrum 1200Hz", .class = .eye_tracking, .rate_hz = 1200 };
pub const EYE_EYELINK = Modality{ .name = "EyeLink 2000Hz", .class = .eye_tracking, .rate_hz = 2000 };
pub const EYE_PUPIL = Modality{ .name = "Pupil Labs 200Hz", .class = .eye_tracking, .rate_hz = 200 };

// Audio
pub const AUDIO_CD = Modality{ .name = "CD 44.1kHz", .class = .audio_pcm, .rate_hz = 44100 };
pub const AUDIO_PRO = Modality{ .name = "Pro 48kHz", .class = .audio_pcm, .rate_hz = 48000 };
pub const AUDIO_HIRES_96K = Modality{ .name = "Hi-Res 96kHz", .class = .audio_pcm, .rate_hz = 96000 };
pub const AUDIO_HIRES_192K = Modality{ .name = "Hi-Res 192kHz", .class = .audio_pcm, .rate_hz = 192000 };
pub const AUDIO_DXD = Modality{ .name = "DXD 352.8kHz", .class = .audio_pcm, .rate_hz = 352800 };
pub const AUDIO_384K = Modality{ .name = "Pro 384kHz", .class = .audio_pcm, .rate_hz = 384000 };
pub const DSD_64 = Modality{ .name = "DSD64", .class = .audio_dsd, .rate_hz = 2822400 };
pub const DSD_128 = Modality{ .name = "DSD128", .class = .audio_dsd, .rate_hz = 5644800 };
pub const DSD_256 = Modality{ .name = "DSD256", .class = .audio_dsd, .rate_hz = 11289600 };
pub const DSD_512 = Modality{ .name = "DSD512", .class = .audio_dsd, .rate_hz = 22579200 };

// Video / Display
pub const VIDEO_FILM = Modality{ .name = "Film 24fps", .class = .video_display, .rate_hz = 24 };
pub const VIDEO_PAL = Modality{ .name = "PAL 25fps", .class = .video_display, .rate_hz = 25 };
pub const VIDEO_60 = Modality{ .name = "60Hz display", .class = .video_display, .rate_hz = 60 };
pub const VIDEO_144 = Modality{ .name = "144Hz gaming", .class = .video_display, .rate_hz = 144 };
pub const VIDEO_165 = Modality{ .name = "165Hz gaming", .class = .video_display, .rate_hz = 165 };
pub const VIDEO_240 = Modality{ .name = "240Hz esports", .class = .video_display, .rate_hz = 240 };
pub const VIDEO_360 = Modality{ .name = "360Hz esports", .class = .video_display, .rate_hz = 360 };
pub const VIDEO_480 = Modality{ .name = "480Hz ultra", .class = .video_display, .rate_hz = 480 };
pub const VIDEO_500 = Modality{ .name = "500Hz ROG/Alienware", .class = .video_display, .rate_hz = 500 };
pub const VIDEO_540 = Modality{ .name = "540Hz prototype", .class = .video_display, .rate_hz = 540 };
pub const VIDEO_600 = Modality{ .name = "600Hz CES 2025", .class = .video_display, .rate_hz = 600 };

// VR/AR
pub const VR_QUEST = Modality{ .name = "Meta Quest 90Hz", .class = .vr_ar_headset, .rate_hz = 90 };
pub const VR_QUEST_120 = Modality{ .name = "Meta Quest 120Hz", .class = .vr_ar_headset, .rate_hz = 120 };
pub const VR_AVP_96 = Modality{ .name = "Apple Vision Pro 96Hz", .class = .vr_ar_headset, .rate_hz = 96 };
pub const VR_VARJO = Modality{ .name = "Varjo 200Hz foveated", .class = .vr_ar_headset, .rate_hz = 200 };
pub const VR_INDEX_144 = Modality{ .name = "Valve Index 144Hz", .class = .vr_ar_headset, .rate_hz = 144 };

// Haptic
pub const HAPTIC_LRA = Modality{ .name = "LRA haptic", .class = .haptic, .rate_hz = 250 };
pub const HAPTIC_TAPTIC = Modality{ .name = "Apple Taptic 300Hz", .class = .haptic, .rate_hz = 300 };
pub const HAPTIC_ULTRALEAP = Modality{ .name = "Ultraleap 40kHz", .class = .haptic, .rate_hz = 40000 };

// Brain stimulation
pub const DBS_130 = Modality{ .name = "DBS 130Hz", .class = .brain_stimulation, .rate_hz = 130 };
pub const DBS_185 = Modality{ .name = "DBS 185Hz", .class = .brain_stimulation, .rate_hz = 185 };
pub const SSVEP_40 = Modality{ .name = "SSVEP 40Hz", .class = .brain_stimulation, .rate_hz = 40 };

// IMU
pub const IMU_6400 = Modality{ .name = "IMU 6.4kHz", .class = .motion_imu, .rate_hz = 6400 };

// ============================================================================
// TIMESTAMP TYPE (u128 for expanded range)
// ============================================================================

pub const Instant = struct {
    ticks: i128,

    pub const ZERO = Instant{ .ticks = 0 };

    pub fn advanceSample(self: Instant, modality: Modality) Instant {
        return .{ .ticks = self.ticks + @as(i128, @intCast(modality.ticksPerSample())) };
    }

    pub fn advanceSamples(self: Instant, modality: Modality, n: u32) Instant {
        return .{ .ticks = self.ticks + @as(i128, @intCast(modality.ticksPerSample())) * @as(i128, @intCast(n)) };
    }

    pub fn advanceGF3Cycle(self: Instant) Instant {
        return .{ .ticks = self.ticks + @as(i128, @intCast(GF3_QUANTUM)) };
    }

    pub fn since(self: Instant, earlier: Instant) Duration {
        return .{ .ticks = self.ticks - earlier.ticks };
    }

    /// Convert from original trit-ticks. Exact: multiply by EXPANSION_FACTOR.
    pub fn fromOriginalTritTicks(original: i64) Instant {
        return .{ .ticks = @as(i128, original) * @as(i128, EXPANSION_FACTOR) };
    }

    /// Convert to original trit-ticks (lossy if not aligned).
    pub fn toOriginalTritTicks(self: Instant) i64 {
        return @intCast(@divFloor(self.ticks, @as(i128, EXPANSION_FACTOR)));
    }

    /// Convert from flicks. Exact.
    pub fn fromFlicks(flicks: i64) Instant {
        return .{ .ticks = @as(i128, flicks) * @as(i128, EXPANDED_PER_FLICK) };
    }

    /// Convert to flicks (lossy if not aligned).
    pub fn toFlicks(self: Instant) i64 {
        return @intCast(@divFloor(self.ticks, @as(i128, EXPANDED_PER_FLICK)));
    }

    /// Sample count for a given modality in [0, self).
    pub fn sampleCount(self: Instant, modality: Modality) u128 {
        if (self.ticks <= 0) return 0;
        return @intCast(@divFloor(self.ticks, @as(i128, @intCast(modality.ticksPerSample()))));
    }
};

pub const Duration = struct {
    ticks: i128,

    pub const ZERO = Duration{ .ticks = 0 };

    pub fn fromSamples(modality: Modality, n: u32) Duration {
        return .{ .ticks = @as(i128, @intCast(modality.ticksPerSample())) * @as(i128, @intCast(n)) };
    }

    pub fn sampleCount(self: Duration, modality: Modality) u128 {
        if (self.ticks <= 0) return 0;
        return @intCast(@divFloor(self.ticks, @as(i128, @intCast(modality.ticksPerSample()))));
    }
};

// ============================================================================
// NTSC RATIONAL RATE SUPPORT
// ============================================================================

/// NTSC rates are p/1001. The expanded quantum handles them exactly because
/// 1001 = 7 × 11 × 13, and 7², 11, 13 are all factors of TICKS_PER_SECOND.
pub const NtscRate = struct {
    numerator: u64,   // e.g. 30000
    denominator: u64, // always 1001

    pub fn ticksPerFrame(self: NtscRate) u128 {
        // ticks_per_frame = TICKS_PER_SECOND × denominator / numerator
        return TICKS_PER_SECOND * @as(u128, self.denominator) / @as(u128, self.numerator);
    }
};

pub const NTSC_24 = NtscRate{ .numerator = 24000, .denominator = 1001 };  // 23.976 fps
pub const NTSC_30 = NtscRate{ .numerator = 30000, .denominator = 1001 };  // 29.97 fps
pub const NTSC_60 = NtscRate{ .numerator = 60000, .denominator = 1001 };  // 59.94 fps

// ============================================================================
// CROSS-MODAL SYNC QUERIES
// ============================================================================

/// How many samples of modality B fit exactly in one sample of modality A?
/// Returns null if not an exact integer multiple.
pub fn samplesPerSample(slow: Modality, fast: Modality) ?u128 {
    const slow_tps = slow.ticksPerSample();
    const fast_tps = fast.ticksPerSample();
    if (slow_tps % fast_tps != 0) return null;
    return slow_tps / fast_tps;
}

// ============================================================================
// COMPTIME RATE VALIDATION
// ============================================================================

pub fn assertExactRate(comptime rate: u64) void {
    if (TICKS_PER_SECOND % @as(u128, rate) != 0) {
        @compileError("Rate does not divide expanded trit-tick base");
    }
}

// ============================================================================
// TESTS
// ============================================================================

test "factorization" {
    var n: u128 = 1;
    // 2^15
    var i: u5 = 0;
    while (i < 15) : (i += 1) n *= 2;
    // 3^3
    i = 0;
    while (i < 3) : (i += 1) n *= 3;
    // 5^6
    i = 0;
    while (i < 6) : (i += 1) n *= 5;
    // 7^2
    i = 0;
    while (i < 2) : (i += 1) n *= 7;
    // single primes
    n *= 11;
    n *= 13;
    n *= 37;
    n *= 113;
    n *= 127;
    try std.testing.expectEqual(TICKS_PER_SECOND, n);
}

test "backward compatible: original trit-tick divides expanded" {
    try std.testing.expectEqual(@as(u128, 0), TICKS_PER_SECOND % @as(u128, ORIGINAL_TICKS_PER_SECOND));
    try std.testing.expectEqual(@as(u128, EXPANSION_FACTOR), TICKS_PER_SECOND / @as(u128, ORIGINAL_TICKS_PER_SECOND));
}

test "backward compatible: flicks divide expanded" {
    try std.testing.expectEqual(@as(u128, 0), TICKS_PER_SECOND % @as(u128, FLICKS_PER_SECOND));
}

test "all 105 rates divide exactly" {
    const all_rates = [_]u64{
        // BCI consumer
        220, 256, 250, 500, 1000, 16000, 200, 125, 128, 512,
        // BCI research
        2048, 4096, 8192, 16384, 600, 1200, 2400, 4800, 9600, 19200, 38400,
        1024, 5000, 10000, 25000, 50000, 100000, 20000,
        // Clinical/intracortical
        30000, 2500, 32768,
        // fNIRS
        1, 2, 3, 4, 5, 6, 8, 10, 13, 25, 50, 100,
        // MEG
        3000, 12000, 508, 1017, 2034,
        // Ultrasound
        250000, 500000, 1000000, 2000000,
        // EMG/ENG
        4000, 15000,
        // Autonomic
        32, 64,
        // Eye tracking
        60, 120, 150, 300,
        // Motion/IMU
        400, 800, 1600, 3200, 6400, 20,
        // Haptic
        40000,
        // Audio
        8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000,
        88200, 96000, 176400, 192000, 352800, 384000,
        2822400, 5644800, 11289600, 22579200,
        // Video
        24, 30, 48, 72, 75, 80, 90, 96, 144, 165, 240, 360, 480, 500, 540,
        // Brain stim
        40, 70, 130, 140, 185,
        // Color/entropy
        360,
    };
    for (all_rates) |rate| {
        const r128 = @as(u128, rate);
        if (TICKS_PER_SECOND % r128 != 0) {
            std.debug.print("FAIL: {} does not divide {}\n", .{ rate, TICKS_PER_SECOND });
            return error.TestExpectedEqual;
        }
    }
}

test "NTSC rates divide exactly" {
    // 23.976 = 24000/1001: check TICKS_PER_SECOND * 1001 % 24000 == 0
    try std.testing.expectEqual(@as(u128, 0), (TICKS_PER_SECOND * 1001) % 24000);
    try std.testing.expectEqual(@as(u128, 0), (TICKS_PER_SECOND * 1001) % 30000);
    try std.testing.expectEqual(@as(u128, 0), (TICKS_PER_SECOND * 1001) % 60000);
}

test "cross-modal: fNIRS 10Hz contains exactly 25 EEG 250Hz samples" {
    const ratio = samplesPerSample(FNIRS_10HZ, OPENBCI_CYTON);
    try std.testing.expectEqual(@as(u128, 25), ratio.?);
}

test "cross-modal: fNIRS 10Hz contains exactly 3000 Neuropixels AP samples" {
    const ratio = samplesPerSample(FNIRS_10HZ, NEUROPIXELS_AP);
    try std.testing.expectEqual(@as(u128, 3000), ratio.?);
}

test "cross-modal: 1 Neuropixels AP sample = exactly 12 EEG 250Hz samples? (no, 120)" {
    // Neuropixels AP = 30000 Hz, EEG = 250 Hz -> ratio = 120
    const ratio = samplesPerSample(OPENBCI_CYTON, NEUROPIXELS_AP);
    try std.testing.expectEqual(@as(u128, 120), ratio.?);
}

test "cross-modal: DSD512 to CD audio" {
    // DSD512 = 22579200, CD = 44100 -> ratio = 512
    const ratio = samplesPerSample(AUDIO_CD, DSD_512);
    try std.testing.expectEqual(@as(u128, 512), ratio.?);
}

test "DBS 185Hz divides exactly" {
    try std.testing.expectEqual(@as(u128, 0), TICKS_PER_SECOND % 185);
}

test "4D/BTi MEG 508Hz and 1017Hz divide exactly" {
    try std.testing.expectEqual(@as(u128, 0), TICKS_PER_SECOND % 508);
    try std.testing.expectEqual(@as(u128, 0), TICKS_PER_SECOND % 1017);
}

test "CorTec 32768Hz divides exactly" {
    try std.testing.expectEqual(@as(u128, 0), TICKS_PER_SECOND % 32768);
}

test "actiCHamp 100kHz divides exactly" {
    try std.testing.expectEqual(@as(u128, 0), TICKS_PER_SECOND % 100000);
}

test "original trit-tick roundtrip" {
    const original_ticks: i64 = 141_120_000; // 1 second in old trit-ticks
    const expanded = Instant.fromOriginalTritTicks(original_ticks);
    try std.testing.expectEqual(@as(i128, @intCast(TICKS_PER_SECOND)), expanded.ticks);
    const back = expanded.toOriginalTritTicks();
    try std.testing.expectEqual(original_ticks, back);
}

test "flick roundtrip" {
    const f: i64 = 705_600_000; // 1 second in flicks
    const expanded = Instant.fromFlicks(f);
    try std.testing.expectEqual(@as(i128, @intCast(TICKS_PER_SECOND)), expanded.ticks);
    const back = expanded.toFlicks();
    try std.testing.expectEqual(f, back);
}

test "GF(3) quantum divides exactly" {
    try std.testing.expectEqual(@as(u128, 0), TICKS_PER_SECOND % 3);
    try std.testing.expectEqual(TICKS_PER_SECOND / 3, GF3_QUANTUM);
}

test "600Hz monitor divides exactly" {
    try std.testing.expectEqual(@as(u128, 0), TICKS_PER_SECOND % 600);
}
