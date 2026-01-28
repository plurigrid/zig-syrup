# zig-syrup

High-performance Zig implementation of the OCapN Syrup data format with CapTP-focused optimizations.

## Features

- Fast encode/decode for Syrup values
- CapTP descriptor helpers and arena sizing utilities
- OCapN model coverage: undefined, null, tagged, error
- Benchmarks for encode/decode/CID and CapTP-specific paths

## Build

```bash
zig build
```

## Test

```bash
zig build test
```

## Benchmarks

```bash
zig build bench
```

## Docs

- `BENCHMARK-RESULTS.md`
- `CAPTP-OPTIMIZATIONS.md`
- `ZIG-SYRUP-FULL-PARITY.md`

## Status

Active development. See `ZIG-SYRUP-FULL-PARITY.md` for spec alignment notes.
