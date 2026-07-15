# Changelog

## 0.1.1

- Order-preserving integer key encoding: `Data(orderPreservingKey:)` and a
  matching failable decoder for any `FixedWidthInteger` (fixed-width,
  big-endian, sign bit flipped for signed types, so byte order equals
  numeric order), plus integer overloads on `Bound` for range scans

## 0.1.0

Initial release, wrapping [fjall](https://github.com/fjall-rs/fjall) 3.1.

- `Database` / `Keyspace`: get, insert, remove (strong & weak), contains,
  value size, exact & approximate counts, first/last, clear, major compaction
- Iteration: full scan, range (with `Bound.included`/`.excluded`), and prefix —
  forwards and backwards, with batched FFI transfer
- `WriteBatch`: atomic cross-keyspace batches with configurable durability
- `Snapshot`: consistent cross-keyspace point-in-time reads
- Transactions:
  - `TxDatabase` — single-writer transactions (serialized writers)
  - `OptimisticTxDatabase` — optimistic transactions (SSI) with
    conflict detection and automatic retry (`write(attempts:)`)
- Typed throws: all fallible API surface is `throws(FjallError)`
- `Data` keys/values with UTF-8 `String` convenience overloads throughout
- All handles are `Sendable`; strict Swift 6 concurrency
- Apple platforms ship a prebuilt XCFramework; Linux builds against the
  Rust static library
