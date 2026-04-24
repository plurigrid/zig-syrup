# zig-syrup Zig 0.16 migration ledger

Last updated: 2026-04-24
Repo head: `eca24b2c56008c26e45933fb4773ff4d87bd3ad9` (main)

## Pinned versions

- **zig**: `0.16.0` (via `mlugg/setup-zig@v2`, pinned in `.github/workflows/ci.yml`)
- **ci**: self-contained; no cross-repo clones

## Landed via merge train 2026-04-24

| PR  | SHA on main                                | Summary                                               |
|-----|--------------------------------------------|-------------------------------------------------------|
| #5  | eca24b2c56008c26e45933fb4773ff4d87bd3ad9   | radical(zig): 0.16.0-native; rip compat.zig; std.Io   |
| #2  | (earlier)                                  | multimodal BCI pipeline with PhysioNet EDF validation |

## Open PRs

| PR | Disposition | Next action                                                                   |
|----|-------------|-------------------------------------------------------------------------------|
| #4 | PATCH       | update-branch pulled in #5 (2026-04-24); verify `zig build test --summary all` |

## Closed without merge

| PR | Reason                                                                                       |
|----|----------------------------------------------------------------------------------------------|
| #1 | Superseded by #5 (fix now lives in 0.16 native path); CONFLICTING + 02-12 stale at closure. |

## Cross-repo assumptions

- `plurigrid/nanoclj-zig` CI clones this repo's default branch (`main`) as a sibling. That pin is stable as long as main continues to contain the 0.16 native path. A breaking change here requires a coordinated nanoclj-zig CI update.

## Verification commands

```
zig fmt --check .
zig build
zig build test --summary all
```

All must pass on ubuntu-latest and macos-latest under CI matrix.
