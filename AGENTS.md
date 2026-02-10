# Repository Guidelines

## Project Structure & Module Organization
- `src/` holds the core Zig modules (Syrup serialization, transports, terminal, identity, topology, worlds).
- `tests/` and `test/` contain Zig test files and fixtures used by `zig build test`.
- `examples/` contains runnable demos; `benchmarks/` and `benchmark/` hold benchmark drivers and results.
- `docs/` and top-level `*.md` files document architecture and status (see `README.md`).
- `tools/`, `processors/`, and `bci_orchestrator/` host supporting utilities and BCI-related pipelines.

## Build, Test, and Development Commands
Run these from the repo root:
- `zig build` — default build.
- `zig build test` — run all Zig module tests.
- `zig build bench` — run ReleaseFast benchmarks.
- `zig build bench-cell-sync` — cell sync flamegraph benchmarks.
- `zig build shader` — terminal fragment shader visualization.
- `zig build test-viz` — visual test runner (ANSI 24-bit color).
- `zig build vibesnipe` — vibesnipe generator.
- `zig build bristol` — Bristol circuit converter.
- `zig build world-demo` — world A/B testing demo.
- `zig build bci-demo` — BCI-Aptos bridge demo.

## Coding Style & Naming Conventions
- Use Zig’s standard style (`zig fmt`) and keep formatting stable before commits.
- Prefer `snake_case.zig` filenames and descriptive module names (e.g., `message_frame.zig`, `tcp_transport.zig`).
- Keep tests close to their modules and use `test "..." {}` blocks for Zig tests.

## Testing Guidelines
- Primary framework: Zig’s built-in `std.testing` via `zig build test`.
- Add tests for new wire formats, parsers, and serialization edge cases.
- If a test depends on fixtures, place them under `test/` and reference with relative paths.

## Commit & Pull Request Guidelines
- Commit history trends toward Conventional Commits (e.g., `feat: ...`, `feat(scope): ...`), with occasional plain “Add …”.
- Prefer `feat:`, `fix:`, or `docs:` prefixes; include a scope when it clarifies the change.
- PRs should include a short summary, test evidence (commands run), and links to relevant docs/issues.

## Security & Configuration Tips
- Network-facing modules (e.g., transports, web sockets) should include bounds/limits in tests.
- Container-related files live at `Containerfile.bci-processor` and `build_apple_container.sh`.
