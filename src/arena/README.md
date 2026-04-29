# arena/ — substrate-arbitration policy for OCapN compliance

This is the runtime side of the "use Racket or Guile when zig-syrup's
depth-unverified path fires, then learn which substrate to consult"
design. Three escalating tiers:

| Tier | File | What it gives you |
|------|------|-------------------|
| 0 | `substrate.zig` (`RandomSelector`) | Random fallback to a reference implementation. Ships in a day. |
| 1 | `bandit.zig` (`Bandit`) | Thompson-sampled posterior per `(fingerprint, substrate)` cell. Closes the loop on observed outcomes. |
| 2 | (next iteration) `counterfactual.zig` + `opengame.zig` | Off-policy updates from re-encoded traces; open-game equilibrium with diegetic self-Other. |

## Wiring

`arena.zig`'s `Arena.runOne` is the single entry point. The substrate
runners — racket and guile — are function pointers the caller fills in
at session time. There are two practical sources:

1. **MCP-mediated bridge.** The `lorj` MCP exposes `goblins_call`,
   `guile_eval`, `goblins_spawn_vat`, etc. Wrap each in a runner that
   takes `(allocator, CallSpec)` and returns an `Outcome`. The wrappers
   live outside this file because they require host-mediated tool
   approval; this file stays substrate-agnostic.
2. **Subprocess.** Spawn `racket -u <bridge.rkt>`/ `guile <bridge.scm>`
   over stdio with a tiny request-response protocol. Slower but
   self-contained.

Use (1) during interactive development, (2) in CI.

## Build wiring

`build.zig` doesn't currently know about `src/arena/`. To enable:

```zig
// in build.zig
const arena_mod = b.addModule("arena", .{
    .root_source_file = b.path("src/arena/arena.zig"),
    .imports = &.{ .{ .name = "syrup", .module = syrup_module } },
});
exe.root_module.addImport("arena", arena_mod);

// tests
const arena_tests = b.addTest(.{
    .root_module = arena_mod,
});
test_step.dependOn(&b.addRunArtifact(arena_tests).step);
```

## Bandit persistence

`Bandit.save` / `Bandit.load` write a 12 KiB binary file with a header
carrying the OCapN spec hash. On spec bump:

```zig
const new_hash = computeSpecHash(...);
const b = bandit_mod.Bandit.load(reader, rng, new_hash) catch |e| switch (e) {
    error.SpecMismatch, error.BadMagic, error.Truncated => bandit_mod.Bandit.init(rng, new_hash),
    else => return e,
};
```

A hash mismatch resets the table — better than learning against a stale
spec.

## Provenance

- The fingerprint flag set is the minimum that distinguishes
  "depth-verified" from "depth-unverified" surfaces in the compliance
  audit (see prior session: ~70% on security, ~60% on handoff).
- Thompson Beta-Bernoulli is the simplest sample-efficient bandit that
  takes off-policy updates without a separate importance-weight pass.
- The Tier 2 escalation to open-games + counterfactual self-Other is
  what `parametrised-optics-cybernetics` and `oxgame-cross-substrate`
  are for.

## Status

- [x] Tier 0 dispatcher
- [x] Tier 1 bandit (Thompson, persistence, off-policy hook)
- [x] Fingerprint extractor over `syrup.Value`
- [x] Arena runner with cross-check
- [ ] Counterfactual evaluator (next iteration)
- [ ] Open-game optic (next iteration)
- [ ] Racket interop bridge wired through `lorj.goblins_call`
- [ ] Guile interop bridge wired through `lorj.guile_eval`
- [ ] OCapN spec-hash extraction
