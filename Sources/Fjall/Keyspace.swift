import Foundation
import FjallFFI

/// Any handle that refers to a keyspace — plain (``Keyspace``) or
/// transactional (``TxKeyspace``, ``OptimisticTxKeyspace``).
///
/// Lets snapshots read through any kind of keyspace handle.
public protocol KeyspaceRef: Sendable {
    /// The underlying plain keyspace handle.
    var base: Keyspace { get }
}

/// A keyspace — a single LSM-tree inside a database, mirrors `fjall::Keyspace`.
///
/// Comparable to a "column family" in RocksDB. Each keyspace is physically
/// isolated from other keyspaces and can be configured independently.
///
/// Keys and values are arbitrary bytes (`Data`). String-keyed convenience
/// overloads encode keys and values as UTF-8.
public final class Keyspace: Sendable {
    /// Options used when creating a keyspace, mirrors `fjall::KeyspaceCreateOptions`.
    public struct Options: Sendable, Equatable {
        /// Maximum size of this keyspace's memtable, in bytes (`nil` keeps fjall's default).
        public var maxMemtableSize: UInt64?
        /// If `true`, journal writes are only persisted on explicit ``Database/persist(_:)`` calls.
        public var manualJournalPersist: Bool
        /// Enable key-value separation (recommended for large values).
        public var kvSeparation: KvSeparationOptions?

        public init(
            maxMemtableSize: UInt64? = nil,
            manualJournalPersist: Bool = false,
            kvSeparation: KvSeparationOptions? = nil
        ) {
            self.maxMemtableSize = maxMemtableSize
            self.manualJournalPersist = manualJournalPersist
            self.kvSeparation = kvSeparation
        }

        var ffi: FfiKeyspaceOptions {
            FfiKeyspaceOptions(
                maxMemtableSizeBytes: maxMemtableSize,
                manualJournalPersist: manualJournalPersist ? true : nil,
                kvSeparation: kvSeparation?.ffi
            )
        }
    }

    let ffi: FfiKeyspace

    init(ffi: FfiKeyspace) {
        self.ffi = ffi
    }

    /// Name of the keyspace.
    public var name: String { ffi.name() }

    /// Filesystem path of the keyspace's data.
    public var path: String { ffi.path() }

    // MARK: - Writing

    /// Inserts a key-value pair, overwriting any previous value.
    public func insert(_ key: Data, _ value: Data) throws(FjallError) {
        try fjallCall { try ffi.insert(key: key, value: value) }
    }

    /// Removes a key (leaves a tombstone).
    public func remove(_ key: Data) throws(FjallError) {
        try fjallCall { try ffi.remove(key: key) }
    }

    /// Removes a key with a weak tombstone (experimental; see fjall docs).
    public func removeWeak(_ key: Data) throws(FjallError) {
        try fjallCall { try ffi.removeWeak(key: key) }
    }

    /// Removes all items from the keyspace in O(1).
    public func clear() throws(FjallError) {
        try fjallCall { try ffi.clear() }
    }

    // MARK: - Reading

    /// Retrieves the value for a key, or `nil` if it does not exist.
    public func get(_ key: Data) throws(FjallError) -> Data? {
        try fjallCall { try ffi.get(key: key) }
    }

    /// Returns `true` if the key exists.
    public func containsKey(_ key: Data) throws(FjallError) -> Bool {
        try fjallCall { try ffi.containsKey(key: key) }
    }

    /// Size of the value for a key in bytes, without fetching it.
    /// Returns `nil` if the key does not exist.
    public func size(of key: Data) throws(FjallError) -> Int? {
        try fjallCall { try ffi.sizeOf(key: key) }.map(Int.init)
    }

    /// The first (minimum) key-value pair.
    public var first: KeyValuePair? {
        get throws(FjallError) { try fjallCall { try ffi.firstKeyValue() }.map(KeyValuePair.init) }
    }

    /// The last (maximum) key-value pair.
    public var last: KeyValuePair? {
        get throws(FjallError) { try fjallCall { try ffi.lastKeyValue() }.map(KeyValuePair.init) }
    }

    /// Exact number of items. This requires a full O(n) scan —
    /// prefer ``approximateCount`` where possible.
    public var count: Int {
        get throws(FjallError) { Int(try fjallCall { try ffi.len() }) }
    }

    /// Returns `true` if the keyspace contains no items (O(log n)).
    public var isEmpty: Bool {
        get throws(FjallError) { try fjallCall { try ffi.isEmpty() } }
    }

    /// Fast approximation of the number of items (O(1), may overcount).
    public var approximateCount: Int {
        Int(ffi.approximateLen())
    }

    /// Disk space used by this keyspace, in bytes.
    public var diskSpace: UInt64 {
        ffi.diskSpace()
    }

    // MARK: - Iteration

    /// Iterates over all key-value pairs in key order.
    ///
    /// The iterator sees a consistent snapshot of the keyspace.
    /// - Parameter batchSize: how many pairs to fetch per FFI round-trip.
    public func iter(batchSize: Int = 32) -> Iter {
        Iter(ffi: ffi.iter(), batchSize: batchSize)
    }

    /// Iterates over a range of keys in key order. Unset bounds are unbounded.
    ///
    /// ```swift
    /// for pair in try keyspace.range(from: .included("a"), to: .excluded("b")).collect() { ... }
    /// ```
    public func range(from lower: Bound? = nil, to upper: Bound? = nil, batchSize: Int = 32) -> Iter {
        Iter(ffi: ffi.range(lower: lower?.ffi, upper: upper?.ffi), batchSize: batchSize)
    }

    /// Iterates over all keys starting with the given prefix, in key order.
    public func prefix(_ prefix: Data, batchSize: Int = 32) -> Iter {
        Iter(ffi: ffi.prefix(prefix: prefix), batchSize: batchSize)
    }

    // MARK: - Maintenance

    /// Runs a major compaction, merging everything into one run.
    public func majorCompact() throws(FjallError) {
        try fjallCall { try ffi.majorCompact() }
    }
}

extension Keyspace: KeyspaceRef {
    public var base: Keyspace { self }
}

// MARK: - String conveniences

extension Keyspace {
    /// Inserts a UTF-8 string key-value pair, overwriting any previous value.
    public func insert(_ key: String, _ value: String) throws(FjallError) {
        try insert(Data(key.utf8), Data(value.utf8))
    }

    /// Inserts a value for a UTF-8 string key, overwriting any previous value.
    public func insert(_ key: String, _ value: Data) throws(FjallError) {
        try insert(Data(key.utf8), value)
    }

    /// Retrieves the value for a UTF-8 string key.
    public func get(_ key: String) throws(FjallError) -> Data? {
        try get(Data(key.utf8))
    }

    /// Retrieves the value for a UTF-8 string key, decoded as a UTF-8 string.
    public func getString(_ key: String) throws(FjallError) -> String? {
        try get(key).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Removes a UTF-8 string key.
    public func remove(_ key: String) throws(FjallError) {
        try remove(Data(key.utf8))
    }

    /// Returns `true` if the UTF-8 string key exists.
    public func containsKey(_ key: String) throws(FjallError) -> Bool {
        try containsKey(Data(key.utf8))
    }

    /// Size of the value for a UTF-8 string key, in bytes.
    public func size(of key: String) throws(FjallError) -> Int? {
        try size(of: Data(key.utf8))
    }

    /// Iterates over all keys starting with the given UTF-8 string prefix.
    public func prefix(_ prefix: String, batchSize: Int = 32) -> Iter {
        self.prefix(Data(prefix.utf8), batchSize: batchSize)
    }
}
