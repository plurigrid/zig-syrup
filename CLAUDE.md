# zig-syrup

Zig implementation of OCapN Syrup serialization with propagator networks, spatial coloring, BCI integration, and ACP bridge.

## Build

```bash
zig build              # all default targets
zig build test         # run all tests
zig build mcp-server   # build MCP stdio server
```

## MCP Server

The MCP server (`src/mcp_server.zig`) exposes zig-syrup capabilities over JSON-RPC 2.0 stdio transport. Tools: `syrup_encode`, `syrup_decode`, `virion_create`, `virion_recombine`, `world_list`, `world_signature`, `cid_compute`, `czernowitz_query`, `capability_domains`.

Run: `zig build mcp-server`

## Key Modules

| Module | File | Purpose |
|--------|------|---------|
| syrup | `src/syrup.zig` | OCapN canonical binary serialization (all 11 types) |
| jsonrpc_bridge | `src/jsonrpc_bridge.zig` | JSON-RPC 2.0 ↔ Syrup record translation + ACP bridge |
| goblins_ffi | `src/goblins_ffi.zig` | C ABI for Guile Goblins (SplitMix64, GF(3), Ripser, Syrup) |
| virion | `src/virion.zig` | Skill propagation via non-monotonic lattice (gain-of-function) |
| propagator | `src/propagator.zig` | Radul-Sussman partial information lattice |
| message_frame | `src/message_frame.zig` | Length-prefix framing (4-byte BE, 4MB limit) |
| tcp_transport | `src/tcp_transport.zig` | TCP netlayer for OCapN |
| czernowitz | `src/czernowitz.zig` | Location codes + speculator metadata |
| ghostty_ix_http | `src/ghostty_ix_http.zig` | HTTP :7071 monitoring (CORS: localhost only) |

## GF(3) Conservation

All operations preserve GF(3) balance: trit sum = 0 (mod 3). Trits: -1 (MINUS/validator), 0 (ERGODIC/coordinator), +1 (PLUS/generator).

## Wire Formats

- **Syrup**: OCapN canonical binary (`<'label field1 field2>`)
- **JSON-RPC 2.0**: NDJSON over stdio (MCP) or TCP :9999 (Nashator)
- **WebSocket**: Length-prefixed binary frames (ghostty-emacs)
- **TCP**: 4-byte BE length prefix (message_frame.zig, matches Nashator)

## Security Notes

- HTTP endpoints restricted to `localhost` origin (CORS)
- No TLS on TCP transport — use SSH tunnel or Tailscale for remote
- WebSocket framing lacks per-message DoS limit (message_frame.zig has 4MB)
- jsonrpc_bridge trusts incoming without capability validation
- virion lattice is non-monotonic — needs sandbox for gain-of-function
