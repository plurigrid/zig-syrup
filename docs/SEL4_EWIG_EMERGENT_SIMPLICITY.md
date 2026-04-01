# seL4/ewig: The Capability Kernel You Already Built

## The Claim

You don't need seL4. You already have it.

The ewig persistent storage + epoch_capability + GF(3) conservation law
IS the seL4 capability model, discovered from the build-yourself direction.

## seL4 in 6 lines

```
CNode     = table of capability slots
CSpace    = tree of CNodes reachable from a root
Mint      = create derived capability with fewer rights
Revoke    = recursively delete all derived capabilities
CPtr      = address (path through CNode tree) to a slot
CDT       = derivation tree tracking which cap came from which
```

## ewig in 6 lines

```
EventLog  = append-only history of all operations
MerkleDAG = content-addressed tree of events (Blake3)
Branch    = fork history at any point (named, composable)
Timeline  = segment-tree index: query state at any time t
Query     = SQL-like filter/aggregate over event history
Sync      = CRDT merge for multi-node reconciliation
```

## The Isomorphism

| seL4 | ewig + epoch_capability | why it's the same thing |
|------|------------------------|------------------------|
| CNode | `Branch` | both: table of named references |
| CSpace | `Ewig` (the whole tree) | both: the reachable reference graph from a root |
| capability slot | `TimelineEntry` | both: (address, content-hash, timestamp) |
| Mint | `ewig.append` with derivation | both: create new ref from old ref, possibly with fewer rights |
| Copy | `branch.merge` with no conflict | both: duplicate a reference into another table |
| Move | append + delete | both: transfer a reference |
| Delete | `branch.delete` at head | both: remove a single slot |
| Revoke | `branch.delete` + cascade derived events | both: recursively remove all derived references |
| CPtr (address) | `world_uri + timestamp` | both: a path through the tree to find a slot |
| CDT (derivation tree) | Merkle DAG child pointers | both: track which ref came from which |
| seL4_CNode_Mint | `EpochCapRef.init(slot, epoch, granter_trit)` | both: create with access-right metadata |
| E0 local / E1 cluster / E2 federated / E3 unbounded | same, literally | epoch_capability.zig has the same 4-level trust hierarchy |

## seL4/Emacs: The Other Direction

Emacs already has a capability system. It just doesn't call it that.

| seL4 | Emacs | why |
|------|-------|-----|
| CNode | keymap | a table mapping keys to commands (slots to capabilities) |
| CSpace | keymap chain (parent -> child -> ...) | the reachable set of bindings from current major mode |
| CPtr | key sequence `C-c p s` | a path through keymaps to reach a command |
| Mint | `define-key` / `transient-define-prefix` | create new binding (capability) in a keymap (CNode) |
| Revoke | `(define-key map key nil)` | remove binding and all it reached |
| CDT | `describe-key` / `where-is` | trace which keymap provided a binding |
| causal Transient menus | CNode navigation UI | literally: structured traversal of capability tables |
| causal-self-walker | CSpace auditor | walks the capability tree, records what it finds |
| buffer-local variables | per-slot capability metadata | each buffer (slot) has its own access context |

## The Emergent Simplicity

### What seL4 enforces at the hardware level:

> No access without a capability. No capability without derivation from an authorized source.

### What ewig + GF(3) enforce at the protocol level:

> No event without a content-addressed hash. No capability without a balanced trit (+1 grant, -1 validate, 0 session). No derivation without an append to the Merkle DAG.

### What Emacs + Transient enforce at the interaction level:

> No command without a key binding. No binding without a keymap. No keymap without a mode. The Transient menu IS the capability navigation interface.

## The Three-Layer Stack

```
┌─────────────────────────────────────────────────┐
│ Emacs/Transient                                 │  interaction layer
│   keymap = CNode, key-sequence = CPtr           │  (what you see)
│   causal-self-walker = capability auditor        │
├─────────────────────────────────────────────────┤
│ ewig + epoch_capability                         │  protocol layer
│   Merkle DAG = CDT, append = Mint               │  (what persists)
│   4-epoch ladder = trust hierarchy              │
│   GF(3): grant(+1) + session(0) + validate(-1) │
├─────────────────────────────────────────────────┤
│ seL4 (conceptual)                               │  kernel layer
│   we don't import it; we re-derived it          │  (what's proven)
│   the proof IS the conservation law             │
└─────────────────────────────────────────────────┘
```

## Why "Build Yourself"

seL4's 10,000-line C kernel took 11 person-years to formally verify.

ewig is 9 Zig files (~4000 lines) that give you:
- the same append-only, content-addressed, branchable authority model
- with time-travel (seL4 doesn't have this)
- with SQL queries over capability history (seL4 doesn't have this)
- with CRDT sync for multi-node capability federation (seL4 doesn't have this)
- with epoch-graded degradation under partition (seL4 assumes a single kernel)

The GF(3) conservation law gives you the invariant seL4 gets from formal
verification: every grant is balanced by a validation through a shared
session. You can't create authority from nothing (trit sum = 0).

The Emacs layer gives you what seL4 gets from the hardware MMU:
isolation between buffers (each has its own keymap/CSpace), controlled
sharing through explicit binding (Mint), and a structured navigation
interface (Transient = capability browser).

## File Map

| File | seL4 Equivalent |
|------|----------------|
| `src/worlds/ewig/ewig.zig` | kernel boot (CSpace initialization) |
| `src/worlds/ewig/store.zig` | physical memory (Merkle CAS) |
| `src/worlds/ewig/log.zig` | capability operation log |
| `src/worlds/ewig/branch.zig` | CNode tree operations (Mint/Copy/Move/Revoke) |
| `src/worlds/ewig/timeline.zig` | CPtr resolution (address lookup at time t) |
| `src/worlds/ewig/query.zig` | capability audit interface |
| `src/worlds/ewig/sync.zig` | multi-kernel federation (CRDT) |
| `src/worlds/ewig/reconstruct.zig` | CSpace reconstruction from log |
| `src/epoch_capability.zig` | the 4-epoch trust hierarchy |
| `causal/lisp/causal-self-walker.el` | CSpace auditor |
| `causal/lisp/causal-proof.el` | capability verification (5 backends) |

## seL4 / Hoot / Spritely: The Triangle

seL4, Hoot, and Spritely solve the same problem at three different altitudes.

### The Problem

How do you guarantee that a piece of code running on behalf of someone
can ONLY do what it was authorized to do, and NOTHING else?

### seL4: Prove it at the kernel

seL4 answers at the hardware boundary. The kernel is 10,000 lines of C
formally verified in Isabelle/HOL. Every memory access, every IPC, every
interrupt goes through capability lookup. The guarantee is: the C code
matches the Isabelle proof, and the Isabelle proof says no authority leak.

What you get: **unforgeable capabilities enforced by the MMU**.
What you lose: tied to one machine, one kernel, one proof artifact.

### Hoot: Compile it into the sandbox

Hoot (Spritely's Scheme-to-WASM compiler) answers at the language boundary.
Scheme is compiled to WebAssembly, which runs in a sandbox that provides
NOTHING by default -- no I/O, no memory access, no network. Every capability
must be explicitly imported into the WASM instance.

What you get: **the WASM sandbox IS a CSpace**. A module's imports ARE its
capabilities. If you don't import `fd_write`, the code cannot write. Period.
The guarantee comes from the WASM spec, verified by every browser engine.

What you lose: performance (WASM GC, tail calls), no direct hardware access.

### Goblins/OCapN: Distribute it over the network

Spritely Goblins answers at the network boundary. OCapN (CapTP + netlayers +
locators) is the protocol for passing capability references between vats on
different machines. The three specs are:

- **CapTP**: message sending, promises, promise pipelining, third-party handoffs
- **Netlayers**: transport abstraction (Tor, libp2p, IBC, or anything)
- **Locators**: how to name machines and objects (URIs for capabilities)

What you get: **capabilities that survive network partitions**. A reference
to an object on another machine works the same as a local reference.
What you lose: you need a wire format (Syrup) and a trust model (epochs).

### Where zig-syrup sits

zig-syrup is the performance layer that all three compose through:

```
seL4 (kernel caps)                    Hoot (WASM sandbox caps)
       \                                   /
        \                                 /
         \                               /
          v                             v
    zig-syrup: Syrup wire + 4-byte framing + epoch-graded caps
          |                             |
          v                             v
    ewig (persistent Merkle DAG)   goblins_ffi (C ABI to Guile)
          |                             |
          v                             v
    OCapN CapTP over TCP/WS/BLE/Tor
```

The key insight from `wgpu_compute.zig`:

```
Hoot (Scheme->Wasm):  capability coordination, actor isolation, CapTP
This module (Zig):    zero-copy buffers, SIMD fill, compute dispatch
Neither replaces the other -- they compose via shared memory.
```

### The seL4/Hoot isomorphism

| seL4 | Hoot/WASM |
|------|-----------|
| CSpace | WASM module imports |
| CNode | WASM import table |
| capability slot | imported function |
| CPtr | import index |
| Mint | `(define-foreign f)` with restricted signature |
| Revoke | don't re-instantiate with that import |
| CDT | module instantiation chain |
| MMU enforcement | WASM linear memory bounds checking |
| IPC | CapTP message (Syrup-encoded, 4-byte BE framed) |
| kernel scheduling | Goblins vat turns (event-loop actor model) |

### The seL4/ewig isomorphism (restated)

| seL4 | ewig |
|------|------|
| CSpace | Ewig persistent store |
| CNode | Branch |
| capability slot | TimelineEntry |
| Mint | ewig.append with derivation |
| Revoke | branch.delete + cascade |
| CDT | Merkle DAG child pointers |
| kernel boot | Ewig.init (CSpace initialization) |

### The conservation law that replaces the formal proof

seL4's 11 person-year Isabelle proof establishes one thing:
authority cannot be created from nothing or leaked to unauthorized parties.

GF(3) conservation establishes the same thing in one line:

```
grant(+1) + session(0) + validate(-1) = 0
```

Every authority creation (+1) is balanced by an authority check (-1)
through a shared session (0). The trit sum over any closed system is
always 0 mod 3. This is checked:

- at compile time by `gf3_conserved()` in `goblins_ffi.zig`
- at every CapTP message by the Syrup framing layer
- at every ewig append by Merkle hash verification
- at every epoch transition by `EpochCapRef.checkAndDegrade()`
- at the Emacs layer by `causal-self-walker` trit chain validation

You don't need the Isabelle proof if you have the conservation law
running at every layer simultaneously. The proof IS the protocol.
