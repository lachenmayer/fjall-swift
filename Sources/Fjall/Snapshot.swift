import Foundation
import FjallFFI

/// A consistent, cross-keyspace, point-in-time view of the database,
/// mirrors `fjall::Snapshot`.
///
/// Also serves as the read-only transaction type of the transactional
/// databases (``TxDatabase/readTransaction()``,
/// ``OptimisticTxDatabase/readTransaction()``) — reads accept any kind of
/// keyspace handle.
///
/// Keep snapshots short-lived: old data cannot be garbage-collected while
/// a snapshot still references it.
public final class Snapshot: Sendable {
    let ffi: FfiSnapshot

    init(ffi: FfiSnapshot) {
        self.ffi = ffi
    }

    /// Retrieves the value for a key as of this snapshot.
    public func get(_ key: Data, in keyspace: some KeyspaceRef) throws(FjallError) -> Data? {
        try fjallCall { try ffi.get(keyspace: keyspace.base.ffi, key: key) }
    }

    /// Returns `true` if the key exists in this snapshot.
    public func containsKey(_ key: Data, in keyspace: some KeyspaceRef) throws(FjallError) -> Bool {
        try fjallCall { try ffi.containsKey(keyspace: keyspace.base.ffi, key: key) }
    }

    /// Size of the value for a key in bytes as of this snapshot.
    public func size(of key: Data, in keyspace: some KeyspaceRef) throws(FjallError) -> Int? {
        try fjallCall { try ffi.sizeOf(keyspace: keyspace.base.ffi, key: key) }.map(Int.init)
    }

    /// Exact number of items in this snapshot (full O(n) scan).
    public func count(of keyspace: some KeyspaceRef) throws(FjallError) -> Int {
        Int(try fjallCall { try ffi.len(keyspace: keyspace.base.ffi) })
    }

    /// Returns `true` if the keyspace is empty in this snapshot.
    public func isEmpty(_ keyspace: some KeyspaceRef) throws(FjallError) -> Bool {
        try fjallCall { try ffi.isEmpty(keyspace: keyspace.base.ffi) }
    }

    /// The first (minimum) key-value pair in this snapshot.
    public func first(in keyspace: some KeyspaceRef) throws(FjallError) -> KeyValuePair? {
        try fjallCall { try ffi.firstKeyValue(keyspace: keyspace.base.ffi) }.map(KeyValuePair.init)
    }

    /// The last (maximum) key-value pair in this snapshot.
    public func last(in keyspace: some KeyspaceRef) throws(FjallError) -> KeyValuePair? {
        try fjallCall { try ffi.lastKeyValue(keyspace: keyspace.base.ffi) }.map(KeyValuePair.init)
    }

    /// Iterates over all key-value pairs in a keyspace as of this snapshot.
    public func iter(_ keyspace: some KeyspaceRef, batchSize: Int = 32) -> Iter {
        Iter(ffi: ffi.iter(keyspace: keyspace.base.ffi), batchSize: batchSize)
    }

    /// Iterates over a range of keys as of this snapshot. Unset bounds are unbounded.
    public func range(
        in keyspace: some KeyspaceRef,
        from lower: Bound? = nil,
        to upper: Bound? = nil,
        batchSize: Int = 32
    ) -> Iter {
        Iter(
            ffi: ffi.range(keyspace: keyspace.base.ffi, lower: lower?.ffi, upper: upper?.ffi),
            batchSize: batchSize
        )
    }

    /// Iterates over all keys starting with the given prefix, as of this snapshot.
    public func prefix(_ prefix: Data, in keyspace: some KeyspaceRef, batchSize: Int = 32) -> Iter {
        Iter(ffi: ffi.prefix(keyspace: keyspace.base.ffi, prefix: prefix), batchSize: batchSize)
    }
}

// MARK: - String conveniences

extension Snapshot {
    /// Retrieves the value for a UTF-8 string key as of this snapshot.
    public func get(_ key: String, in keyspace: some KeyspaceRef) throws(FjallError) -> Data? {
        try get(Data(key.utf8), in: keyspace)
    }

    /// Retrieves the value for a UTF-8 string key, decoded as a UTF-8 string.
    public func getString(_ key: String, in keyspace: some KeyspaceRef) throws(FjallError) -> String? {
        try get(key, in: keyspace).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Returns `true` if the UTF-8 string key exists in this snapshot.
    public func containsKey(_ key: String, in keyspace: some KeyspaceRef) throws(FjallError) -> Bool {
        try containsKey(Data(key.utf8), in: keyspace)
    }

    /// Iterates over all keys starting with the given UTF-8 string prefix.
    public func prefix(_ prefix: String, in keyspace: some KeyspaceRef, batchSize: Int = 32) -> Iter
    {
        self.prefix(Data(prefix.utf8), in: keyspace, batchSize: batchSize)
    }
}
