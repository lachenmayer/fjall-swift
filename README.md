# fjall-swift

Swift bindings for [fjall](https://github.com/fjall-rs/fjall) — a log-structured (LSM-tree),
embeddable key-value storage engine written in Rust.

The API mirrors the fjall 3.x Rust API (`Database`, `Keyspace`, `WriteBatch`, `Snapshot`,
iterators, …) while staying idiomatic Swift: `throws` instead of `Result`, `Data`/`String`
keys and values, `Sendable` handles, and Swift naming conventions.

## Features

- Embedded key-value storage — a database is just a directory, no server
- Multiple keyspaces (like RocksDB column families), each an isolated LSM-tree
- Atomic cross-keyspace write batches
- Transactions: single-writer (serialized) and optimistic (SSI with conflict detection)
- Consistent point-in-time snapshots (MVCC)
- Range & prefix iteration, forwards and backwards
- LZ4 compression, optional key-value separation for large values
- Thread-safe: `Database`, `Keyspace`, `WriteBatch` and `Snapshot` are `Sendable`

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/lachenmayer/fjall-swift", from: "0.1.0")
]
```

and depend on the `Fjall` product. On Apple platforms the Rust core ships as a prebuilt
XCFramework attached to each GitHub release — no Rust toolchain needed.

> **Note:** until the first release is tagged, the package uses a locally built framework:
> run `scripts/build-xcframework.sh` first (requires a Rust toolchain).

### Linux

On Linux, build the Rust static library and point the linker at it:

```sh
cargo build --manifest-path rust/Cargo.toml --release
swift build -Xlinker -L"$PWD/rust/target/release"
```

## Usage

```swift
import Fjall

// A database is a single directory on disk.
let db = try Database(path: ".fjall_data")

// A keyspace is an isolated collection of key-value pairs (its own LSM-tree).
let items = try db.keyspace("items")

// Keys and values are bytes (Data); String overloads encode UTF-8.
try items.insert("a", "hello")
let value = try items.getString("a")  // "hello"

// Ranges and prefixes iterate in key order — forwards or backwards.
let iter = items.range(from: .included("a"), to: .excluded("f"))
while let pair = try iter.next() {
    print(pair.keyString, pair.valueString)
}

// Atomic cross-keyspace batches.
let batch = db.batch()
try batch.insert("x", "1", into: items)
try batch.remove("a", from: items)
try batch.commit()

// Consistent point-in-time snapshots.
let snapshot = db.snapshot()
try items.insert("later", "...")
try snapshot.containsKey("later", in: items)  // false

// Control durability explicitly.
try db.persist(.syncAll)
```

### Transactions

For cross-keyspace transactions with read-your-own-writes semantics, open the database
as a `TxDatabase` (single-writer: write transactions are serialized) or an
`OptimisticTxDatabase` (optimistic concurrency: transactions run in parallel and commits
fail with `FjallError.conflict` when they collide):

```swift
let db = try TxDatabase(path: ".fjall_data")
let items = try db.keyspace("items")

// Scoped: commits on return, rolls back on throw.
try db.write { tx in
    let value = try tx.getString("counter", in: items) ?? "0"
    try tx.insert("counter", String(Int(value)! + 1), into: items)
}

// Or explicit:
let tx = try db.writeTransaction()
try tx.insert("a", "1", into: items)
try tx.commit()  // or tx.rollback()

// Read-only transactions are snapshots.
let read = db.readTransaction()
```

With `OptimisticTxDatabase`, conflicting transactions can be retried automatically:

```swift
let db = try OptimisticTxDatabase(path: ".fjall_data")
let items = try db.keyspace("items")

try db.write(attempts: 5) { tx in
    let value = try tx.getString("counter", in: items) ?? "0"
    try tx.insert("counter", String(Int(value)! + 1), into: items)
}
```

### Configuration

```swift
let db = try Database(
    path: ".fjall_data",
    options: .init(
        cacheSize: 64 * 1_024 * 1_024,  // 64 MiB block cache
        temporary: false,
        workerThreads: 4
    )
)

let blobs = try db.keyspace(
    "blobs",
    options: .init(
        maxMemtableSize: 32 * 1_024 * 1_024,
        // Store large values out of line (recommended for blobs).
        kvSeparation: KvSeparationOptions(separationThreshold: 4_096)
    )
)
```

### Error handling

All fallible operations throw ``FjallError``, which mirrors `fjall::Error`:

```swift
do {
    try items.insert("a", "b")
} catch FjallError.locked {
    // another process has the database open
} catch {
    // .io, .storage, .poisoned, ...
}
```

## Architecture

```
┌────────────────────┐
│ Fjall              │  hand-written Swift API (this is what you import)
├────────────────────┤
│ FjallFFI           │  generated Swift bindings (UniFFI)
├────────────────────┤
│ CFjallFFI          │  C symbols: XCFramework (Apple) / static lib (Linux)
├────────────────────┤
│ rust/ (fjall-ffi)  │  Rust crate bridging fjall via UniFFI
└────────────────────┘
```

The Rust crate `rust/` wraps [fjall 3.x](https://docs.rs/fjall) with FFI-friendly types and
exports them via [UniFFI](https://mozilla.github.io/uniffi-rs/). The generated bindings are
committed at `Sources/FjallFFI`; the `Fjall` module wraps them in an idiomatic Swift API.

## Development

```sh
# Rust core tests
cargo test --manifest-path rust/Cargo.toml

# Regenerate Swift bindings after changing rust/src/lib.rs
scripts/generate-bindings.sh

# Swift tests on macOS (builds a native-only XCFramework first)
scripts/build-xcframework.sh --native
FJALL_USE_LOCAL_FRAMEWORK=1 swift test

# Swift tests on Linux
cargo build --manifest-path rust/Cargo.toml --release
swift test -Xlinker -L"$PWD/rust/target/release"
```

Releases are cut with the *Release* GitHub Actions workflow, which builds the full
XCFramework (macOS + iOS + simulator), rewrites `Package.swift` with the artifact URL and
checksum, tags the version, and attaches the framework to the GitHub release.

## Not (yet) wrapped

- Bulk ingestion (`start_ingestion`)
- Compaction strategy / block policy configuration
- Closure-based atomic updates (`fetch_update` / `update_fetch`) — use a
  transaction instead

## License

Licensed under either of [Apache License 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT)
at your option — the same terms as fjall itself.
