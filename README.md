# zig-syrup

[![CI](https://github.com/plurigrid/zig-syrup/actions/workflows/ci.yml/badge.svg)](https://github.com/plurigrid/zig-syrup/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

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

## Related OCapN/Syrup Repos

- ocapn/syrup: `https://github.com/ocapn/syrup`
- ocapn/ocapn: `https://github.com/ocapn/ocapn`
- ocapn/ocapn-test-suite: `https://github.com/ocapn/ocapn-test-suite`
- ocapn/syrup (guile impl): `https://github.com/ocapn/syrup/blob/master/impls/guile/syrup.scm`
- ocapn/syrup (racket impl): `https://github.com/ocapn/syrup/blob/master/impls/racket/syrup/syrup.rkt`
- cmars/ocapn-syrup: `https://github.com/cmars/ocapn-syrup`
- costa-group/syrup-python: `https://github.com/costa-group/syrup-python`

## Status

Active development. See `ZIG-SYRUP-FULL-PARITY.md` for spec alignment notes.
