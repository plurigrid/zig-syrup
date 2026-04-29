#!/usr/bin/env python3
"""Microtonal sonification of the E/CapTP capability taxonomy.

Maps the 30-feature audit to a 3-limit (Pythagorean) tuning system where
every interval is a ratio of powers of 2 and 3 — matching the GF(3)
conservation law that governs zig-syrup's capability architecture.

Tuning: Pythagorean chain of perfect fifths (3:2) from a base frequency,
generating microtonal intervals that diverge from 12-TET by the
Pythagorean comma (~23.46 cents). Each capability layer occupies a
distinct register; each feature is a specific pitch in the chain.

Timbre:
  IMPLEMENTED → pure triangle wave (odd harmonics, warm)
  PARTIAL     → sawtooth (all harmonics, buzzy/restless)
  ABSENT      → square wave with noise (harsh, hollow)

Spatial: 6 layers pan across the stereo field L→R.

Output: WAV file at 48kHz/16-bit stereo.
"""

import numpy as np
import wave
import struct
import sys
import os

SR = 48000  # sample rate
BASE_FREQ = 110.0  # A2 — root of the Pythagorean chain

# --- Capability taxonomy with audit results ---

LAYERS = [
    ("Core E/CapTP", [
        ("Swiss numbers",       "implemented"),
        ("Eventual-send",       "implemented"),
        ("Promise pipelining",  "partial"),
        ("Near/far transparency","partial"),
        ("Sturdy refs",         "implemented"),
    ]),
    ("Rights", [
        ("Attenuation",         "implemented"),
        ("Amplification",       "implemented"),
        ("Facets",              "implemented"),
        ("Composition",         "implemented"),
        ("Default-deny/POLA",   "implemented"),
    ]),
    ("Lifecycle", [
        ("Vat quiescence",      "implemented"),
        ("Hierarchical cancel", "implemented"),
        ("Distributed GC",      "implemented"),
        ("Time-limited caps",   "implemented"),
        ("Revocation",          "implemented"),
    ]),
    ("Confinement", [
        ("V8 isolates",         "absent"),
        ("Sealed traits",       "partial"),
        ("Membrane proxy",      "implemented"),
        ("bwrap sandboxes",     "absent"),
        ("Confined vats",       "implemented"),
    ]),
    ("Cryptographic", [
        ("Sealer/unsealer",     "implemented"),
        ("Opaque cursors",      "partial"),
        ("Swiss-number SIDs",   "implemented"),
    ]),
    ("Operational", [
        ("Provenance (Horton)", "implemented"),
        ("Replay",              "implemented"),
        ("Backpressure",        "implemented"),
        ("Mailbox ordering",    "implemented"),
        ("Resource budgets",    "implemented"),
    ]),
]

# --- Pythagorean (3-limit) tuning ---
# Generate pitches by stacking perfect fifths (ratio 3/2) and octave-reducing.
# This produces microtonal intervals: the Pythagorean major third (81/64) is
# ~408 cents vs 12-TET's 400 cents; the wolf fifth at position 12 is ~678 cents.

def pythagorean_freq(base, fifth_steps):
    """Frequency from stacking `fifth_steps` perfect fifths above base,
    then octave-reducing to within one octave of base."""
    ratio = (3.0 / 2.0) ** fifth_steps
    while ratio >= 2.0:
        ratio /= 2.0
    while ratio < 1.0:
        ratio *= 2.0
    return base * ratio

def build_pitch_map():
    """Assign each feature a Pythagorean pitch. Layers get octave offsets;
    features within a layer step by fifths."""
    pitches = []
    fifth_idx = 0
    for layer_idx, (layer_name, features) in enumerate(LAYERS):
        octave_shift = 2 ** (layer_idx / 3.0)  # spread layers across ~2 octaves
        for feat_name, status in features:
            freq = pythagorean_freq(BASE_FREQ, fifth_idx) * octave_shift
            pitches.append((layer_name, feat_name, status, freq, layer_idx))
            fifth_idx += 1
    return pitches

# --- Waveform synthesis ---

def triangle_wave(freq, duration, sr=SR):
    """Odd harmonics with 1/n^2 rolloff — warm, clear."""
    t = np.linspace(0, duration, int(sr * duration), endpoint=False)
    sig = np.zeros_like(t)
    for k in range(1, 12, 2):  # odd harmonics 1,3,5,...,11
        sig += ((-1) ** ((k - 1) // 2)) * np.sin(2 * np.pi * freq * k * t) / (k * k)
    return sig * (8 / (np.pi ** 2))

def sawtooth_wave(freq, duration, sr=SR):
    """All harmonics with 1/n rolloff — buzzy, restless."""
    t = np.linspace(0, duration, int(sr * duration), endpoint=False)
    sig = np.zeros_like(t)
    for k in range(1, 16):
        sig += ((-1) ** (k + 1)) * np.sin(2 * np.pi * freq * k * t) / k
    return sig * (2 / np.pi)

def square_noise_wave(freq, duration, sr=SR):
    """Square wave (odd harmonics, 1/n) mixed with filtered noise — harsh."""
    t = np.linspace(0, duration, int(sr * duration), endpoint=False)
    sig = np.zeros_like(t)
    for k in range(1, 10, 2):
        sig += np.sin(2 * np.pi * freq * k * t) / k
    sig *= (4 / np.pi)
    noise = np.random.default_rng(42).normal(0, 0.15, len(t))
    # Band-limit noise around the fundamental
    from numpy.fft import rfft, irfft
    N = len(noise)
    F = rfft(noise)
    freqs = np.fft.rfftfreq(N, 1.0 / sr)
    band = (freqs > freq * 0.5) & (freqs < freq * 4.0)
    F[~band] = 0
    noise = irfft(F, N)
    return sig * 0.7 + noise * 0.3

def apply_envelope(sig, attack=0.02, decay=0.05, sustain_level=0.7, release=0.15, sr=SR):
    """ADSR envelope."""
    n = len(sig)
    env = np.ones(n)
    a_samp = int(attack * sr)
    d_samp = int(decay * sr)
    r_samp = int(release * sr)
    # Attack
    if a_samp > 0:
        env[:a_samp] = np.linspace(0, 1, a_samp)
    # Decay
    d_end = a_samp + d_samp
    if d_samp > 0 and d_end < n:
        env[a_samp:d_end] = np.linspace(1, sustain_level, d_samp)
    # Sustain
    if d_end < n - r_samp:
        env[d_end:n - r_samp] = sustain_level
    # Release
    if r_samp > 0:
        env[n - r_samp:] = np.linspace(sustain_level, 0, r_samp)
    return sig * env

def synthesize_tone(freq, status, duration=0.6):
    """Pick waveform by status, apply envelope."""
    if status == "implemented":
        sig = triangle_wave(freq, duration)
        sig = apply_envelope(sig, attack=0.01, decay=0.04, sustain_level=0.8, release=0.12)
    elif status == "partial":
        sig = sawtooth_wave(freq, duration)
        sig = apply_envelope(sig, attack=0.03, decay=0.08, sustain_level=0.5, release=0.2)
    else:  # absent
        sig = square_noise_wave(freq, duration)
        sig = apply_envelope(sig, attack=0.05, decay=0.1, sustain_level=0.3, release=0.3)
    return sig

# --- Stereo panning ---

def pan_stereo(mono, pan):
    """Pan 0.0=left, 0.5=center, 1.0=right. Constant-power law."""
    angle = pan * (np.pi / 2)
    left = mono * np.cos(angle)
    right = mono * np.sin(angle)
    return left, right

# --- GF(3) drone layer ---

def gf3_drone(duration, sr=SR):
    """Sustained microtonal drone based on the three GF(3) trits.
    -1 (MINUS): sub-bass at base * 2/3
     0 (ERGODIC): base frequency
    +1 (PLUS): base * 3/2
    Sum of these three = the Pythagorean trichord. Slow beating from
    the non-tempered intervals creates the characteristic microtonal shimmer."""
    t = np.linspace(0, duration, int(sr * duration), endpoint=False)
    minus_freq = BASE_FREQ * 2 / 3   # ~73.3 Hz — below the root
    zero_freq = BASE_FREQ             # 110 Hz
    plus_freq = BASE_FREQ * 3 / 2    # 165 Hz
    # Each trit gets a slightly different waveform for spatial separation
    minus = np.sin(2 * np.pi * minus_freq * t) * 0.12
    zero = triangle_wave(zero_freq, duration) * 0.08
    plus = np.sin(2 * np.pi * plus_freq * t) * 0.10
    # Slow amplitude modulation — the "breathing" of the conservation law
    lfo = 0.5 + 0.5 * np.sin(2 * np.pi * 0.25 * t)  # 0.25 Hz
    drone = (minus + zero + plus) * lfo
    return drone

# --- Main composition ---

def compose():
    pitches = build_pitch_map()
    total_features = len(pitches)

    # Each feature gets a note; slight overlap for legato.
    note_dur = 0.55
    note_gap = 0.35  # time between note onsets
    total_dur = total_features * note_gap + note_dur + 2.0  # +2s for intro/outro drone
    total_samples = int(SR * total_dur)

    left = np.zeros(total_samples)
    right = np.zeros(total_samples)

    # Layer the GF(3) drone underneath everything
    drone = gf3_drone(total_dur)
    drone_l, drone_r = pan_stereo(drone, 0.5)
    left[:len(drone_l)] += drone_l
    right[:len(drone_r)] += drone_r

    # Render each feature as a note
    for i, (layer_name, feat_name, status, freq, layer_idx) in enumerate(pitches):
        onset = int((1.0 + i * note_gap) * SR)  # 1s intro before first note
        tone = synthesize_tone(freq, status, note_dur)
        # Pan: 6 layers spread L(0.1) to R(0.9)
        pan = 0.1 + (layer_idx / 5.0) * 0.8
        tone_l, tone_r = pan_stereo(tone, pan)

        # Amplitude: implemented=0.6, partial=0.45, absent=0.35
        amp = {"implemented": 0.6, "partial": 0.45, "absent": 0.35}[status]
        tone_l *= amp
        tone_r *= amp

        end = onset + len(tone_l)
        if end > total_samples:
            end = total_samples
            tone_l = tone_l[:end - onset]
            tone_r = tone_r[:end - onset]
        left[onset:end] += tone_l
        right[onset:end] += tone_r

    # Normalize to prevent clipping
    peak = max(np.max(np.abs(left)), np.max(np.abs(right)))
    if peak > 0:
        left /= peak
        right /= peak
    left *= 0.85
    right *= 0.85

    return left, right

def write_wav(filename, left, right, sr=SR):
    """Write stereo 16-bit WAV."""
    with wave.open(filename, 'w') as wf:
        wf.setnchannels(2)
        wf.setsampwidth(2)
        wf.setframerate(sr)
        n = len(left)
        data = bytearray()
        for i in range(n):
            l_sample = int(np.clip(left[i], -1, 1) * 32767)
            r_sample = int(np.clip(right[i], -1, 1) * 32767)
            data += struct.pack('<hh', l_sample, r_sample)
        wf.writeframes(bytes(data))

def main():
    out_dir = os.path.dirname(os.path.abspath(__file__))
    out_path = os.path.join(out_dir, "ecaptp_sonification.wav")

    print("Composing microtonal sonification...")
    print(f"  Tuning: Pythagorean 3-limit (GF(3)-native)")
    print(f"  Base: {BASE_FREQ} Hz (A2)")
    print(f"  Features: {sum(len(fs) for _, fs in LAYERS)}")

    pitches = build_pitch_map()
    print("\nPitch map (Pythagorean chain of fifths):")
    current_layer = None
    for layer, feat, status, freq, _ in pitches:
        if layer != current_layer:
            print(f"\n  [{layer}]")
            current_layer = layer
        cents_from_12tet = 1200 * np.log2(freq / BASE_FREQ) % 1200
        marker = {"implemented": "+", "partial": "~", "absent": "-"}[status]
        print(f"    {marker} {feat:24s} {freq:8.2f} Hz  ({cents_from_12tet:6.1f} cents)")

    left, right = compose()
    write_wav(out_path, left, right)
    dur = len(left) / SR
    print(f"\nWrote {out_path}")
    print(f"  Duration: {dur:.1f}s  |  48kHz/16-bit stereo")
    return out_path

if __name__ == "__main__":
    path = main()
    if "--play" in sys.argv:
        os.system(f"afplay '{path}'")
