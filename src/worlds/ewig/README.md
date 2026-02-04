# Ewig - Eternal Persistent Storage for World History

**"Ewig"** = eternal/forever in German

A comprehensive append-only persistent storage system for world state history with time-travel queries, branching, and multi-node synchronization.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         Ewig System                              │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐          │
│  │   Event Log  │  │     CAS      │  │   Timeline   │          │
│  │  (log.zig)   │  │ (store.zig)  │  │(timeline.zig)│          │
│  │              │  │              │  │              │          │
│  │ • Append-only│  │ • Merkle DAG │  │ • Time index │          │
│  │ • Checksums  │  │ • Deduplicate│  │ • Segment tree│         │
│  │ • Iterator   │  │ • GC support │  │ • Branch detect│        │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘          │
│         │                 │                 │                  │
│  ┌──────▼───────┐  ┌──────▼───────┐  ┌──────▼───────┐          │
│  │    Branch    │  │  Reconstruct │  │     Sync     │          │
│  │(branch.zig)  │  │(reconstruct.zig)│  │ (sync.zig)  │          │
│  │              │  │              │  │              │          │
│  │ • Git-like   │  │ • Replay     │  │ • Merkle sync│          │
│  │ • 3-way merge│  │ • Snapshots  │  │ • CRDT merge │          │
│  │ • Visualize  │  │ • Parallel   │  │ • Delta enc  │          │
│  └──────────────┘  └──────────────┘  └──────────────┘          │
│                                                                │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │                   Query Engine (query.zig)                │ │
│  │  • SQL-like syntax  • Aggregation  • Temporal queries    │ │
│  └──────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

## Module Reference

### 1. `format.zig` - Storage Formats
- Binary format specification with 100-byte fixed headers
- SHA-256 hashing utilities
- CRC32 checksums for integrity
- AES-256-GCM encryption support
- JSON export/import
- Block-based storage format

### 2. `log.zig` - Append-Only Event Log
- **Event struct**: timestamp, seq, hash, parent, world_uri, type, payload
- **EventLog**: Thread-safe append-only log with:
  - In-memory and file-based persistence
  - Hash-based indexing for O(1) lookups
  - Sequence-based indexing
  - Forward and backward iterators
  - Filtered iteration
  - Event batching
  - Crash-safe writes (fsync)

### 3. `store.zig` - Content-Addressed Storage
- **MerkleTree**: Efficient content verification
  - Build trees from leaf hashes
  - Generate and verify proofs
- **MerkleNode**: DAG nodes with content hashing
- **MemoryStore**: In-memory CAS with:
  - Reference counting
  - Garbage collection
  - Deduplication
- **FileStore**: Persistent file-based CAS
- **CAS interface**: Abstract interface for storage backends

### 4. `timeline.zig` - Time-Travel Queries
- **Timeline**: Per-world history tracking
  - `at(timestamp)`: Get state at exact time
  - `range(start, end)`: Get events in range
  - Segment tree for efficient queries
- **TimelineManager**: Multi-world timeline management
- **BranchDetector**: Find divergence points
- **WorldSnapshot**: Multi-world state at a point in time

### 5. `branch.zig` - Branching and Merging
- **Branch**: Named branch with head, base, metadata
- **BranchManager**: Git-like branch operations
  - Create, switch, delete branches
  - List branches
- **MergeEngine**: 3-way merge with:
  - Fast-forward detection
  - Ours/Theirs/3-way/Recursive strategies
  - Conflict detection and resolution
- **BranchVisualizer**: ASCII and Graphviz DOT output

### 6. `reconstruct.zig` - State Reconstruction
- **StateSnapshot**: Point-in-time state with hash
- **SnapshotCache**: LRU cache for reconstructed states
- **StateReconstructor**: Replay events to build state
  - Nearest cached ancestor optimization
  - Event application
  - Checkpointing
- **IncrementalReconstructor**: Efficient incremental updates
- **ParallelReconstructor**: Parallel processing for large histories
- **StateVerifier**: Verify chain integrity

### 7. `sync.zig` - Multi-Node Synchronization
- **MerkleSync**: Efficient difference detection
- **DeltaEncoder**: Compress event differences
- **CRDTMerge**: Conflict-free replicated data types
- **SyncEngine**: Main synchronization
  - Bidirectional sync
  - Conflict resolution strategies
- **SyncMessage**: Network protocol messages
- **SyncTransport**: Network abstraction

### 8. `query.zig` - Query Language
- **Query AST**: Structured query representation
  - Select, Aggregate, Temporal, Diff, Custom
- **QueryExecutor**: Execute queries against logs
- **QueryParser**: SQL-like syntax parser
- **Expr**: Expression evaluation with:
  - Binary/Unary operations
  - Column references
  - Literals
- **QueryResult**: Structured results with JSON output

### 9. `ewig.zig` - Main API
- **Ewig**: Main system integrating all modules
- **EventBuilder**: Fluent API for creating events
- **Config**: System configuration

## Data Model

```zig
const Event = struct {
    timestamp: i64,           // Nanoseconds since epoch
    seq: u64,                 // Strictly increasing
    hash: [32]u8,             // SHA-256 of content
    parent: [32]u8,           // Previous event hash
    world_uri: []const u8,    // a://, b://, c://
    type: EventType,          // WorldCreated, StateChanged, etc.
    payload: []const u8,      // Event-specific data
};

const EventType = enum(u8) {
    WorldCreated = 0x01,
    WorldDestroyed = 0x02,
    Checkpoint = 0x03,
    StateChanged = 0x10,
    StateBatch = 0x11,
    PlayerAction = 0x20,
    PlayerJoined = 0x21,
    PlayerLeft = 0x22,
    ObjectCreated = 0x30,
    ObjectDestroyed = 0x31,
    ObjectMoved = 0x32,
    Custom = 0x80,
};
```

## Usage Examples

### Basic Event Logging
```zig
var ewig = try Ewig.init(allocator, ".ewig_data", .{});
defer ewig.deinit();

// Append event
const event = try ewig.append(.PlayerAction, "a://world", "{\"jump\":true}");

// Or with struct
const action = .{ .type = "jump", .player = "Alice" };
const event2 = try ewig.appendStruct(.PlayerAction, "a://world", action);
```

### Time-Travel Queries
```zig
// Get state at time T
const state_hash = try ewig.at("a://world", 1699123456789);

// Query range
const result = try ewig.range("a://world", t1, t2);
defer result.deinit();

// Reconstruct full state
const snapshot = try ewig.reconstruct(event_hash);
defer allocator.free(snapshot.data);
```

### Branching
```zig
// Create branch from point
const branch = try ewig.createBranch("experiment", "a://world", event_hash);

// Switch to branch
try ewig.switchBranch("experiment");

// Merge back
const result = try ewig.merge("main", .ThreeWay);
```

### Querying
```zig
// SQL-like queries
const result = try ewig.querySql(
    "SELECT * FROM events WHERE type = 'PlayerAction' AND timestamp > 1000"
);
defer result.deinit();

// Programmatic queries
const actions = try ewig.queryByType(.PlayerAction, 100);
defer allocator.free(actions);

// Aggregate queries
const count = try ewig.query(.{
    .Aggregate = .{
        .function = .Count,
        .column = "*",
        .from = "events",
        .where = filter_expr,
    }
});
```

### Synchronization
```zig
// Sync with another node
const result = try ewig.syncWith(&other_ewig);
std.log.info("Synced: {d} sent, {d} received", .{result.events_sent, result.events_received});
```

## Persistence Guarantees

1. **Append-Only**: Events are never modified once written
2. **Crash-Safe**: fsync ensures durability
3. **Checksums**: CRC32 for header integrity
4. **Hash Chain**: Each event references parent, forming chain
5. **Content-Addressed**: Same content = same hash = deduplicated

## Performance Characteristics

| Operation | Complexity | Notes |
|-----------|-----------|-------|
| Append | O(1) | Amortized, with fsync |
| Get by hash | O(1) | Hash map lookup |
| Get by seq | O(1) | Index lookup |
| Range query | O(log n) | Segment tree |
| Reconstruct | O(k) | k = events since snapshot |
| Sync diff | O(log n) | Merkle tree comparison |

## Files Created

```
src/worlds/ewig/
├── format.zig      # Binary formats, hashing, encryption
├── log.zig         # Append-only event log
├── store.zig       # Content-addressed storage, Merkle trees
├── timeline.zig    # Time-travel queries
├── branch.zig      # Branching and merging
├── reconstruct.zig # State reconstruction
├── sync.zig        # Multi-node synchronization
├── query.zig       # Query language
├── ewig.zig        # Main API
└── README.md       # This file
```

## Future Enhancements

1. **Streaming sync**: For large histories
2. **Compression**: zstd/lz4 for storage efficiency
3. **Encryption at rest**: Full database encryption
4. **Sharding**: Distribute worlds across nodes
5. **Compaction**: Merge small log files
6. **Metrics**: Performance and usage statistics
