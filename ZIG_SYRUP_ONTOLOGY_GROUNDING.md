# zig-syrup Ontology Grounding (Task 19: OCapN/Spritely)

Maps zig-syrup source modules to the object ontology in `.mcp-tasks/OBJECT_ONTOLOGY_SCHEMATIC.md`.

## Span Principle (from `.topos/README.md`)

```
NOT: Vat -> Vat (direct morphism)
YES: Vat -> World <- Vat (span through shared session)
```

Every zig-syrup module either IS a world, projects INTO a world, or verifies a projection.

## Layer Map

### Layer 0: Pre-Ontological (seed, trit, time)

| Module | Role | Trit | Note |
|--------|------|------|------|
| `splitmix_trit.zig` | deterministic identity | 0 | SplitMix64 golden gamma, shared with Gay.jl |
| `gf3_palette.zig` | GF(3) color assignment | 0 | trit from `value % 3 - 1` |
| `trit_tick.zig` | universal time base | 0 | 4 epochs: flick -> trit-tick -> expanded -> extreme |
| `color_value.zig` | seed -> RGB + Trit | 0 | the pre-ontological charge carrier |

### Layer 1: Wire / Serialization

| Module | Role | Trit | Note |
|--------|------|------|------|
| `syrup.zig` | OCapN canonical binary | 0 | all 11 value types, zero-copy, canonical encoding |
| `message_frame.zig` | 4-byte BE framing | 0 | `[u32 length][Syrup payload]`, the CapTP wire |
| `fuzz_syrup.zig` | serialization fuzzer | -1 | validates wire correctness |

### Layer 2: Transport (Shared Pipes = World Surfaces)

| Module | Role | Trit | Note |
|--------|------|------|------|
| `tcp_transport.zig` | TCP framed transport | 0 | Connection as shared pipe (world surface) |
| `sendable.zig` | BLE GATT transport | +1 | projects into BLE characteristic (another world) |
| `qrtp_transport.zig` | QUIC-like transport | +1 | real-time frame transport |
| `websocket_framing.zig` | WebSocket framing | 0 | browser-side shared pipe |
| `xev_io.zig` | io_uring/epoll I/O | 0 | event-driven transport substrate |

### Layer 3: Span / World (Meeting Points)

| Module | Role | Trit | Note |
|--------|------|------|------|
| `worlds/world.zig` | 326 span vertices | 0 | A/B/C URI variants, copy-on-write |
| `worlds/world_enum.zig` | world enumeration | 0 | conserved + necklace-reduced |
| `goblins.zig` | C ABI -> Guile Goblins | +1 | projects SplitMix64, Passport, Ripser, Syrup |
| `goblins_ffi.zig` | same (canonical name) | +1 | `gf3_splitmix64_at`, `gf3_conserved` exports |
| `epoch_capability.zig` | epoch-graded caps | -1 | E0-E3 degradation under partition (CAP) |
| `continuation.zig` | continuation passing | 0 | delimited continuations for span composition |
| `homotopy.zig` | path continuity | -1 | verifies projection paths are homotopic |

### Layer 4: Perception / Identity (Reafference)

| Module | Role | Trit | Note |
|--------|------|------|------|
| `self_color.zig` | reafference loop | 0 | efference copy -> observe -> CIEDE2000 check |
| `passport.zig` | proof-of-brain identity | +1 | EEG entropy -> GF(3) trajectory -> did:gay |
| `disclosure.zig` | disclosure insurance | -1 | $REGRET externalizes cost of not protecting $GAY |
| `color_bandwidth.zig` | perceptual distance | 0 | CIEDE2000 Delta-E, JND = 2.3 |
| `lux_color.zig` | Lux color space | 0 | perceptually uniform coordinates |

### CatColab Models (`.topos/models/`)

| Model | Objects | Morphisms | Span |
|-------|---------|-----------|------|
| `ocapn-topos.json` | Vat, CapTPSession, Promise, MarkovBlanket, SturdyRef, ThirdPartyHandoff, Consent | delegate(+), validate(-), pipeline(+), enliven(+), compose_spans(+), confused_deputy(-), consent_boundary(+) | Vat -> CapTPSession <- Vat |
| `vat-triad.json` | HumanVat, World, GoblinsVat, AgentVat, CapTPSession, ReelPlane, EditPath, Actormap, BootstrapObject | left_projection(+), right_projection(-), captp_left(+), captp_right(-), tablet_to_reel(+), tree_to_editpath(+), actor_to_actormap(+), vat_to_bootstrap(+) | Human -> World <- Human |

## Ontology Meta for Task 19

```edn
{:trit "+1"
 :color "#24A61C"
 :object-type "room"
 :visibility "capability-refs-colored-and-epoch-graded"
 :agency "build-OCapN-wire-from-syrup-through-goblins-to-worlds"
 :mcp "radare2,babashka,deepwiki"
 :invariant "ref=color(seed)+name(magenc)+vat(shepherd)+epoch(E0-E3)"
 :span-principle "Vat->CapTPSession<-Vat, never Vat->Vat"
 :layers "L0:splitmix+trit_tick L1:syrup+frame L2:tcp+ws+ble L3:worlds+goblins+epoch L4:self_color+passport+disclosure"
 :catcolab-models "ocapn-topos.json, vat-triad.json"}
```

## Module Dependency Graph (Critical Path)

```
splitmix_trit.zig  trit_tick.zig  color_value.zig
       |                |               |
       v                v               v
    syrup.zig -------> message_frame.zig
       |                      |
       v                      v
  goblins_ffi.zig      tcp_transport.zig
       |                      |
       v                      v
  epoch_capability.zig   worlds/world.zig
       |                      |
       v                      v
  self_color.zig -----> passport.zig -----> disclosure.zig
```

## Balance Check

Layer trit sums:
- L0: 0+0+0+0 = 0
- L1: 0+0+(-1) = -1
- L2: 0+1+1+0+0 = 2
- L3: 0+0+1+1+(-1)+0+(-1) = 0
- L4: 0+1+(-1)+0+0 = 0

Cross-layer sum: 0+(-1)+2+0+0 = 1 (not balanced as isolated layers).
But layers are not independent objects -- they compose through the span.
Balance is checked at the span boundary (L3 worlds), which sums to 0.
