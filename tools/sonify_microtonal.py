#!/usr/bin/env python3
"""Full microtonal sonification of the E/CapTP capability taxonomy.

Models the harmonic structure itself as capability relationships:
  - Consonance (small-ratio intervals) = implemented dependencies
  - Dissonance (complex ratios) = gaps and partials
  - Spectral fusion = layers that compose cleanly
  - Beating = where the architecture has tension

Tuning system: 30-tone Pythagorean gamut (3-limit JI) plus the
Syntonic comma (81:80) as a "drift tone" marking where 3-limit
and 5-limit diverge — the microtonal signature of incompleteness.

Structure:
  Phase 1 (0-8s):   GF(3) trichord drone fades in
  Phase 2 (8-32s):  Each layer enters as a chord (features simultaneous)
  Phase 3 (32-48s): Cross-layer arpeggiation (dependency arcs as intervals)
  Phase 4 (48-60s): Full taxonomy chord → spectral morph to gaps-only
  Phase 5 (60-72s): Resolution — gaps dissolve into the drone
"""

import numpy as np
import wave
import struct
import os

SR = 48000
BASE = 110.0  # A2

# --- Taxonomy ---

LAYERS = [
    ("Core E/CapTP", [
        ("Swiss numbers",        "implemented", 1),
        ("Eventual-send",        "implemented", 1),
        ("Promise pipelining",   "partial",     0),
        ("Near/far transparency","partial",     0),
        ("Sturdy refs",          "implemented", 1),
    ]),
    ("Rights", [
        ("Attenuation",          "implemented", -1),
        ("Amplification",        "implemented",  1),
        ("Facets",               "implemented",  0),
        ("Composition",          "implemented",  1),
        ("Default-deny/POLA",    "implemented", -1),
    ]),
    ("Lifecycle", [
        ("Vat quiescence",       "implemented",  0),
        ("Hierarchical cancel",  "implemented", -1),
        ("Distributed GC",       "implemented",  1),
        ("Time-limited caps",    "implemented",  0),
        ("Revocation",           "implemented", -1),
    ]),
    ("Confinement", [
        ("V8 isolates",          "absent",       0),
        ("Sealed traits",        "partial",     -1),
        ("Membrane proxy",       "implemented",  1),
        ("bwrap sandboxes",      "absent",       0),
        ("Confined vats",        "implemented",  0),
    ]),
    ("Cryptographic", [
        ("Sealer/unsealer",      "implemented",  1),
        ("Opaque cursors",       "partial",      0),
        ("Swiss-number SIDs",    "implemented", -1),
    ]),
    ("Operational", [
        ("Provenance (Horton)",  "implemented",  1),
        ("Replay",               "implemented",  0),
        ("Backpressure",         "implemented", -1),
        ("Mailbox ordering",     "implemented",  0),
        ("Resource budgets",     "implemented",  1),
    ]),
]

# --- Pythagorean tuning + JI extensions ---

def pyth_ratio(fifths):
    """Ratio from stacking `fifths` pure 3:2 intervals, octave-reduced."""
    r = (3.0 / 2.0) ** fifths
    while r >= 2.0: r /= 2.0
    while r < 1.0:  r *= 2.0
    return r

# 30-tone Pythagorean gamut: fifths from -7 to +22
PYTH_RATIOS = [pyth_ratio(i) for i in range(-7, 23)]
PYTH_RATIOS.sort()

# Just intonation "color" intervals for trit-based harmony
JI_RATIOS = {
    "unison":      1/1,
    "minor_2nd":   256/243,    # Pythagorean limma
    "major_2nd":   9/8,
    "minor_3rd":   32/27,
    "major_3rd":   81/64,      # Pythagorean ditone (408 cents, NOT 5-limit 5/4)
    "fourth":      4/3,
    "tritone":     729/512,    # Pythagorean augmented 4th
    "fifth":       3/2,
    "minor_6th":   128/81,
    "major_6th":   27/16,
    "minor_7th":   16/9,
    "major_7th":   243/128,
    "comma":       531441/524288,  # Pythagorean comma (~23.46 cents)
}

def freq_for_feature(layer_idx, feat_idx, n_features):
    """Assign frequency: layer sets octave register, feature selects
    from the Pythagorean gamut within that register."""
    octave = 1.0 + layer_idx * 0.4  # layers span ~2.4 octaves
    gamut_idx = (layer_idx * 5 + feat_idx) % len(PYTH_RATIOS)
    return BASE * PYTH_RATIOS[gamut_idx] * octave

# --- Additive synthesis engine ---

def sine(freq, dur, phase=0):
    t = np.arange(int(SR * dur)) / SR
    return np.sin(2 * np.pi * freq * t + phase)

def harmonic_tone(freq, dur, partials, amplitudes):
    """Additive synthesis with explicit partial/amplitude control."""
    sig = np.zeros(int(SR * dur))
    for p, a in zip(partials, amplitudes):
        sig += a * sine(freq * p, dur)
    return sig

def implemented_tone(freq, dur):
    """3-limit harmonic series: partials at 1, 3/2, 2, 3, 4, 9/2, 6.
    Only powers of 2 and 3 — the "pure" GF(3) sound."""
    partials = [1, 3/2, 2, 3, 4, 9/2, 6, 8, 9]
    amps = [1.0, 0.5, 0.35, 0.2, 0.15, 0.1, 0.08, 0.05, 0.04]
    return harmonic_tone(freq, dur, partials, amps)

def partial_tone(freq, dur):
    """Mixed series: 3-limit base + 5-limit and 7-limit partials that
    create audible beating with the pure tones — the sound of "almost"."""
    partials = [1, 5/4, 3/2, 7/4, 2, 5/2, 3, 7/2]
    amps = [1.0, 0.4, 0.45, 0.3, 0.25, 0.15, 0.12, 0.08]
    return harmonic_tone(freq, dur, partials, amps)

def absent_tone(freq, dur):
    """11-limit and 13-limit partials only — maximally foreign to 3-limit.
    The missing capability: you can hear where it should be but isn't."""
    partials = [1, 11/8, 13/8, 11/4, 13/4, 11/2]
    amps = [0.6, 0.5, 0.45, 0.3, 0.25, 0.15]
    sig = harmonic_tone(freq, dur, partials, amps)
    # Add sub-audio pulsation (the "warning")
    t = np.arange(int(SR * dur)) / SR
    sig *= 0.6 + 0.4 * np.sin(2 * np.pi * 3.0 * t)
    return sig

def synth_feature(freq, status, dur):
    if status == "implemented":
        return implemented_tone(freq, dur)
    elif status == "partial":
        return partial_tone(freq, dur)
    else:
        return absent_tone(freq, dur)

# --- Envelopes ---

def adsr(n, a=0.03, d=0.05, s=0.7, r=0.2):
    env = np.ones(n)
    a_n, d_n, r_n = int(a * SR), int(d * SR), int(r * SR)
    if a_n > 0: env[:min(a_n, n)] = np.linspace(0, 1, min(a_n, n))
    d_end = min(a_n + d_n, n)
    if d_n > 0 and a_n < n: env[a_n:d_end] = np.linspace(1, s, d_end - a_n)
    if n > r_n: env[max(0, n - r_n):] = np.linspace(s, 0, min(r_n, n))
    return env

def fade_in(n, dur_s=2.0):
    f = int(dur_s * SR)
    env = np.ones(n)
    env[:min(f, n)] = np.linspace(0, 1, min(f, n))
    return env

def fade_out(n, dur_s=3.0):
    f = int(dur_s * SR)
    env = np.ones(n)
    env[max(0, n - f):] = np.linspace(1, 0, min(f, n))
    return env

# --- Stereo ---

def pan(mono, p):
    """p: 0=left, 1=right. Constant-power."""
    a = p * (np.pi / 2)
    return mono * np.cos(a), mono * np.sin(a)

def mix_into(left, right, mono, pan_val, offset, amp=1.0):
    """Mix mono signal into stereo buffers at sample offset."""
    n = len(mono)
    end = min(offset + n, len(left))
    seg = mono[:end - offset] * amp
    l, r = pan(seg, pan_val)
    left[offset:end] += l
    right[offset:end] += r

# --- Phase 1: GF(3) trichord drone ---

def gf3_drone(total_n):
    """Three-voice drone at the GF(3) trit frequencies.
    Slow phase rotation creates evolving microtonal beating."""
    t = np.arange(total_n) / SR
    # -1 trit: 2/3 of base (subharmonic)
    v_minus = 0.12 * np.sin(2 * np.pi * (BASE * 2/3) * t)
    # 0 trit: base
    v_zero = 0.10 * np.sin(2 * np.pi * BASE * t + 0.3 * np.sin(2 * np.pi * 0.1 * t))
    # +1 trit: 3/2 of base (perfect fifth)
    v_plus = 0.11 * np.sin(2 * np.pi * (BASE * 3/2) * t)
    # Pythagorean comma ghost — barely audible, the sound of mathematical imperfection
    comma_freq = BASE * JI_RATIOS["comma"]
    v_comma = 0.03 * np.sin(2 * np.pi * comma_freq * t)
    drone = v_minus + v_zero + v_plus + v_comma
    return drone

# --- Phase 2: Layer chords ---

def build_layer_chords(total_n):
    """Each layer enters as a sustained chord, staggered by 4 seconds."""
    left = np.zeros(total_n)
    right = np.zeros(total_n)

    for li, (layer_name, features) in enumerate(LAYERS):
        enter_time = 8.0 + li * 4.0  # stagger entries
        chord_dur = 28.0 - li * 2.0  # earlier layers sustain longer
        pan_val = 0.08 + (li / 5.0) * 0.84

        for fi, (fname, status, trit) in enumerate(features):
            freq = freq_for_feature(li, fi, len(features))
            # Micro-detune by trit: -1 drops 5 cents, +1 raises 5 cents
            detune = 2 ** (trit * 5 / 1200)
            freq *= detune

            tone = synth_feature(freq, status, chord_dur)
            env = adsr(len(tone), a=0.5 + fi * 0.1, d=0.3, s=0.6, r=1.5)
            tone *= env

            # Slight pan spread within each layer
            feat_pan = np.clip(pan_val + (fi - 2) * 0.04, 0.02, 0.98)
            amp = {"implemented": 0.08, "partial": 0.06, "absent": 0.05}[status]
            offset = int(enter_time * SR)
            mix_into(left, right, tone, feat_pan, offset, amp)

    return left, right

# --- Phase 3: Cross-layer arpeggiation ---

def build_arpeggios(total_n):
    """Dependency arcs between layers as ascending/descending arpeggios.
    The interval between notes encodes the relationship type."""
    left = np.zeros(total_n)
    right = np.zeros(total_n)

    # Dependency arcs: (from_layer, from_feat, to_layer, to_feat)
    arcs = [
        (0, 0, 3, 4),  # Swiss numbers → Confined vats
        (0, 4, 4, 2),  # Sturdy refs → Swiss-number SIDs
        (1, 0, 2, 4),  # Attenuation → Revocation
        (1, 3, 3, 2),  # Composition → Membrane proxy
        (2, 2, 5, 0),  # Distributed GC → Provenance
        (4, 0, 3, 2),  # Sealer/unsealer → Membrane proxy
        (5, 1, 2, 0),  # Replay → Vat quiescence
        (5, 3, 5, 2),  # Mailbox ordering → Backpressure
        (1, 4, 3, 0),  # POLA → V8 isolates (gap arc!)
        (2, 1, 3, 3),  # Hierarchical cancel → bwrap (gap arc!)
    ]

    start_time = 32.0
    arc_dur = 1.2  # each arc takes 1.2s
    note_dur = 0.25

    for ai, (fl, ff, tl, tf) in enumerate(arcs):
        _, from_feats = LAYERS[fl]
        _, to_feats = LAYERS[tl]
        from_freq = freq_for_feature(fl, ff, len(from_feats))
        to_freq = freq_for_feature(tl, tf, len(to_feats))
        from_status = from_feats[ff][1]
        to_status = to_feats[tf][1]

        # 4-note arpeggio: from → midpoint → midpoint2 → to
        mid1 = from_freq * (3/2)  # go up a fifth
        while mid1 > to_freq * 1.5: mid1 /= 2
        mid2 = to_freq * (4/3)  # approach from a fourth below
        while mid2 < from_freq * 0.75: mid2 *= 2
        notes = [from_freq, mid1, mid2, to_freq]
        statuses = [from_status, from_status, to_status, to_status]

        arc_offset = start_time + ai * arc_dur
        arc_pan = 0.15 + ai * 0.07

        for ni, (nf, ns) in enumerate(zip(notes, statuses)):
            t_offset = int((arc_offset + ni * note_dur) * SR)
            tone = synth_feature(nf, ns, note_dur)
            tone *= adsr(len(tone), a=0.005, d=0.02, s=0.8, r=0.08)
            mix_into(left, right, tone, arc_pan, t_offset, 0.12)

    return left, right

# --- Phase 4: Full chord → spectral morph to gaps ---

def build_morph(total_n):
    """All 28 features sound together, then implemented tones fade out
    leaving only the partial/absent tones exposed — the sound of gaps."""
    left = np.zeros(total_n)
    right = np.zeros(total_n)

    morph_start = 48.0
    morph_dur = 12.0

    all_features = []
    for li, (_, feats) in enumerate(LAYERS):
        for fi, (fname, status, trit) in enumerate(feats):
            freq = freq_for_feature(li, fi, len(feats))
            freq *= 2 ** (trit * 5 / 1200)
            all_features.append((freq, status, li, fi))

    for freq, status, li, fi in all_features:
        tone = synth_feature(freq, status, morph_dur)
        env = adsr(len(tone), a=0.8, d=0.5, s=0.7, r=2.0)

        if status == "implemented":
            # Fade out implemented tones in second half
            fade = np.ones(len(tone))
            half = len(tone) // 2
            fade[half:] = np.linspace(1, 0, len(tone) - half)
            env *= fade

        tone *= env
        p = 0.1 + (li / 5.0) * 0.8 + (fi - 2) * 0.03
        p = np.clip(p, 0.02, 0.98)
        offset = int(morph_start * SR)
        amp = 0.04
        mix_into(left, right, tone, p, offset, amp)

    return left, right

# --- Phase 5: Resolution ---

def build_resolution(total_n):
    """Gaps dissolve into the GF(3) drone. The absent features descend
    chromatically through the Pythagorean gamut back to the trichord root."""
    left = np.zeros(total_n)
    right = np.zeros(total_n)

    res_start = 60.0
    res_dur = 10.0

    # Find the gap features
    gaps = []
    for li, (_, feats) in enumerate(LAYERS):
        for fi, (fname, status, trit) in enumerate(feats):
            if status in ("absent", "partial"):
                freq = freq_for_feature(li, fi, len(feats))
                gaps.append((freq, status, li))

    # Each gap tone descends through Pythagorean intervals to the drone root
    for gi, (freq, status, li) in enumerate(gaps):
        step_dur = res_dur / 8
        descent_steps = 6
        for si in range(descent_steps):
            t_off = int((res_start + gi * 0.8 + si * step_dur * 0.4) * SR)
            # Descend by Pythagorean limma (256/243 ≈ 90 cents) each step
            step_freq = freq / (256/243) ** si
            # Approach the drone root
            blend = si / descent_steps
            step_freq = step_freq * (1 - blend) + BASE * (1 + blend * 0.5)

            tone = synth_feature(step_freq, status if si < 3 else "implemented", step_dur)
            tone *= adsr(len(tone), a=0.01, d=0.05, s=0.5, r=step_dur * 0.3)
            amp = 0.07 * (1 - si / descent_steps)
            p = 0.3 + li * 0.1
            mix_into(left, right, tone, p, t_off, amp)

    return left, right

# --- Master composition ---

def compose():
    total_dur = 72.0
    total_n = int(SR * total_dur)

    left = np.zeros(total_n)
    right = np.zeros(total_n)

    # Phase 1: GF(3) drone (entire piece)
    drone = gf3_drone(total_n)
    drone *= fade_in(total_n, 4.0) * fade_out(total_n, 4.0)
    dl, dr = pan(drone, 0.5)
    left += dl
    right += dr

    # Phase 2: Layer chords (8s-36s)
    cl, cr = build_layer_chords(total_n)
    left += cl
    right += cr

    # Phase 3: Cross-layer arpeggios (32s-48s)
    al, ar = build_arpeggios(total_n)
    left += al
    right += ar

    # Phase 4: Full chord → morph to gaps (48s-60s)
    ml, mr = build_morph(total_n)
    left += ml
    right += mr

    # Phase 5: Resolution (60s-70s)
    rl, rr = build_resolution(total_n)
    left += rl
    right += rr

    # Master normalize + gentle limiting
    peak = max(np.max(np.abs(left)), np.max(np.abs(right)), 1e-6)
    left = np.tanh(left / peak * 1.2) * 0.9
    right = np.tanh(right / peak * 1.2) * 0.9

    return left, right

def write_wav(path, left, right):
    with wave.open(path, 'w') as wf:
        wf.setnchannels(2)
        wf.setsampwidth(2)
        wf.setframerate(SR)
        n = len(left)
        frames = np.column_stack([
            np.clip(left * 32767, -32767, 32767).astype(np.int16),
            np.clip(right * 32767, -32767, 32767).astype(np.int16),
        ])
        wf.writeframes(frames.tobytes())

def main():
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "ecaptp_microtonal.wav")
    print("Composing full microtonal sonification...")
    print(f"  Tuning: 30-tone Pythagorean gamut (3-limit JI)")
    print(f"  Base: {BASE} Hz  |  Comma ghost: {BASE * JI_RATIOS['comma']:.4f} Hz")
    print(f"  Duration: 72s  |  5 phases")
    print(f"  Timbre: 3-limit harmonics (implemented), 5/7-limit (partial), 11/13-limit (absent)")
    print()

    print("Pitch map:")
    for li, (lname, feats) in enumerate(LAYERS):
        print(f"  [{lname}]")
        for fi, (fname, status, trit) in enumerate(feats):
            f = freq_for_feature(li, fi, len(feats))
            f *= 2 ** (trit * 5 / 1200)
            trit_s = {-1: "-", 0: "0", 1: "+"}[trit]
            stat_s = {"implemented": "###", "partial": "##.", "absent": "#.."}[status]
            cents = 1200 * np.log2(f / BASE)
            print(f"    {stat_s} {trit_s} {fname:24s} {f:8.2f} Hz  {cents:+8.1f}c")
    print()

    left, right = compose()
    write_wav(out, left, right)
    sz = os.path.getsize(out)
    print(f"Wrote {out}")
    print(f"  {sz / 1024 / 1024:.1f} MB  |  48kHz/16-bit stereo  |  72.0s")
    return out

if __name__ == "__main__":
    import sys
    path = main()
    if "--play" in sys.argv:
        os.system(f"afplay '{path}'")
