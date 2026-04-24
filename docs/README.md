# zig-syrup docs

Package-facing documentation lives here. Example-local documentation stays beside the example it explains, and generated or historical artifacts that do not fit a Zig package layout are preserved under `.topos/`.

At the repository root, prefer only package-defining files such as `README.md`,
`LICENSE`, `build.zig`, `build.zig.zon`, `AGENTS.md`, and top-level directories
that are part of the package surface.

## Sections

- `architecture/` — transport, protocol, ontology, and system-design documents
- `benchmarks/` — benchmark reports and benchmark theory notes
- `examples/` — narrative guides for demos that deserve standalone explanation
- `operations/` — build, container, and operator-facing runbooks
- `research/` — theory-heavy notes, syntheses, and exploratory design documents
- `status/` — parity reports, implementation snapshots, and verification status

## Example-local docs

- [`examples/interop/PATH_INVARIANCE.md`](../examples/interop/PATH_INVARIANCE.md) — interop matrix and current pathway status

## Archive boundary

When a file is worth keeping but no longer fits the mold of a Zig package, it belongs in `.topos/`, not at the repo root.
