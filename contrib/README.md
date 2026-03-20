# contrib/

Standalone Zig scripts and evolutionary predecessors. These are **archived for reference** — the canonical versions live in `src/`.

## Trit-Tick Evolution

These files show the design progression. All three are superseded by `src/trit_tick.zig` (55 tests, 4 epochs unified).

| File | Epoch | What | Status |
|------|-------|------|--------|
| `trit_tick_expanded.zig` | 2 | 9-prime LCM, u128, 105 rates | 17/17 tests pass |
| `trit_tick_extreme.zig` | 3 | 16-prime, Fibonacci/Padovan closure | Has old constant (corrected in src/) |
| `trit_tick_unbounded.zig` | Beyond | Prime exponent vectors | BoundedArray API changed in zig 0.15 |

## Geo / OLC Scripts

Self-contained programs using inlined OLC encoding (canonical version: `src/geo.zig`). Each is a complete `pub fn main()` program.

| File | What |
|------|------|
| `pixel_triangulate.zig` | Multi-signal weighted centroid, spiral search, confidence zones |
| `pixel_simplex_trace.zig` | Forward simplex trace: SF → Palo Alto via Caltrain corridor |
| `pixel_simplex_reverse.zig` | Reverse simplex: Palo Alto → SF with forensic evidence |
| `pixel_reverse_trace.zig` | Reverse + OLC prefix hierarchy, GeoACSet speed tiers |
| `pixel_tile_search.zig` | OLC tile grid for device recovery search area |
| `bibliography_olc.zig` | Geocode 32 academic institutions to OLC+GF(3) trits |

## Other

| File | What |
|------|------|
| `coloring.zig` | Graph coloring algorithms |
| `dwt.zig` | Discrete wavelet transform |
| `tritplane.zig` | GF(3) plane geometry |
