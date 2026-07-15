import Foundation
import FjallFFI

/// A single-writer transactional database, mirrors `fjall::SingleWriterTxDatabase`.
///
/// At most one write transaction is active at a time; starting a second one
/// blocks until the first commits, rolls back, or is discarded. Reads are
/// never blocked.
///
/// ```swift
/// let db = try TxDatabase(path: ".fjall_data")
/// let items = try db.keyspace("items")
///
/// try db.write { tx in
///     let value = try tx.getString("counter", in: items) ?? "0"
///     try tx.insert("counter", String(Int(value)! + 1), into: items)
/// }
/// ```
public final class TxDatabase: Sendable {
    let ffi: FfiTxDatabase

    /// Opens (or creates) a single-writer transactional database at the given path.
    public init(path: String, options: Database.Options = .init()) throws(FjallError) {
        self.ffi = try fjallCall { try FfiTxDatabase.open(path: path, config: options.ffi) }
    }

    /// Opens (or creates) a single-writer transactional database at the given file URL.
    public convenience init(url: URL, options: Database.Options = .init()) throws(FjallError) {
        try self.init(path: url.path, options: options)
    }

    /// Opens a transactional keyspace, creating it (with the given options)
    /// if it does not exist.
    public func keyspace(_ name: String, options: Keyspace.Options = .init()) throws(FjallError) -> TxKeyspace
    {
        TxKeyspace(ffi: try fjallCall { try ffi.keyspace(name: name, options: options.ffi) })
    }

    /// Returns `true` if a keyspace with this name exists.
    public func keyspaceExists(_ name: String) -> Bool {
        ffi.keyspaceExists(name: name)
    }

    /// Number of keyspaces in the database.
    public var keyspaceCount: Int {
        Int(ffi.keyspaceCount())
    }

    /// Names of all keyspaces in the database.
    public var keyspaceNames: [String] {
        ffi.listKeyspaceNames()
    }

    /// Starts a read-only transaction — a consistent snapshot of the database.
    public func readTransaction() -> Snapshot {
        Snapshot(ffi: ffi.readTx())
    }

    /// Starts a write transaction.
    ///
    /// Blocks until any other active write transaction has finished.
    /// Prefer the scoped ``write(_:)`` variant, which commits and rolls back
    /// automatically.
    public func writeTransaction() throws(FjallError) -> WriteTransaction {
        WriteTransaction(ffi: try fjallCall { try ffi.writeTx() })
    }

    /// Runs `body` inside a write transaction.
    ///
    /// The transaction is committed when `body` returns, and rolled back if
    /// it throws. `body` must not commit or roll back the transaction itself.
    public func write<T>(_ body: (WriteTransaction) throws -> T) throws -> T {
        let tx = try writeTransaction()
        do {
            let result = try body(tx)
            try tx.commit()
            return result
        } catch {
            try? tx.rollback()
            throw error
        }
    }

    /// Persists the journal to disk with the given durability level.
    public func persist(_ mode: PersistMode) throws(FjallError) {
        try fjallCall { try ffi.persist(mode: mode.ffi) }
    }

    /// Total disk space used by the database, in bytes.
    public var diskSpace: UInt64 {
        get throws(FjallError) { try fjallCall { try ffi.diskSpace() } }
    }

    /// Number of journal files.
    public var journalCount: Int {
        Int(ffi.journalCount())
    }

    /// Current size of all write buffers, in bytes.
    public var writeBufferSize: UInt64 {
        ffi.writeBufferSize()
    }
}

/// A keyspace of a single-writer transactional database,
/// mirrors `fjall::SingleWriterTxKeyspace`.
///
/// Write operations called directly on this type run as their own
/// mini-transaction. Use ``TxDatabase/write(_:)`` to group operations.
public final class TxKeyspace: Sendable {
    let ffi: FfiTxKeyspace

    /// The underlying plain keyspace handle.
    public let base: Keyspace

    init(ffi: FfiTxKeyspace) {
        self.ffi = ffi
        self.base = Keyspace(ffi: ffi.base())
    }

    /// Name of the keyspace.
    public var name: String { ffi.name() }

    /// Filesystem path of the keyspace's data.
    public var path: String { ffi.path() }

    /// Inserts a key-value pair (as its own transaction).
    public func insert(_ key: Data, _ value: Data) throws(FjallError) {
        try fjallCall { try ffi.insert(key: key, value: value) }
    }

    /// Retrieves the value for a key.
    public func get(_ key: Data) throws(FjallError) -> Data? {
        try fjallCall { try ffi.get(key: key) }
    }

    /// Removes a key (as its own transaction).
    public func remove(_ key: Data) throws(FjallError) {
        try fjallCall { try ffi.remove(key: key) }
    }

    /// Removes a key with a weak tombstone (experimental; see fjall docs).
    public func removeWeak(_ key: Data) throws(FjallError) {
        try fjallCall { try ffi.removeWeak(key: key) }
    }

    /// Atomically removes an item and returns its value, if it existed.
    public func take(_ key: Data) throws(FjallError) -> Data? {
        try fjallCall { try ffi.take(key: key) }
    }

    /// Returns `true` if the key exists.
    public func containsKey(_ key: Data) throws(FjallError) -> Bool {
        try fjallCall { try ffi.containsKey(key: key) }
    }

    /// Size of the value for a key in bytes, without fetching it.
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

    /// Fast approximation of the number of items (O(1), may overcount).
    public var approximateCount: Int {
        Int(ffi.approximateLen())
    }
}

extension TxKeyspace: KeyspaceRef {}

// MARK: - TxKeyspace string conveniences

extension TxKeyspace {
    /// Inserts a UTF-8 string key-value pair (as its own transaction).
    public func insert(_ key: String, _ value: String) throws(FjallError) {
        try insert(Data(key.utf8), Data(value.utf8))
    }

    /// Inserts a value for a UTF-8 string key (as its own transaction).
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

    /// Removes a UTF-8 string key (as its own transaction).
    public func remove(_ key: String) throws(FjallError) {
        try remove(Data(key.utf8))
    }

    /// Atomically removes a UTF-8 string key and returns its value.
    public func take(_ key: String) throws(FjallError) -> Data? {
        try take(Data(key.utf8))
    }

    /// Returns `true` if the UTF-8 string key exists.
    public func containsKey(_ key: String) throws(FjallError) -> Bool {
        try containsKey(Data(key.utf8))
    }

    /// Size of the value for a UTF-8 string key, in bytes.
    public func size(of key: String) throws(FjallError) -> Int? {
        try size(of: Data(key.utf8))
    }
}

/// A single-writer write transaction, mirrors `fjall::SingleWriterWriteTx`.
///
/// Sees a consistent snapshot of the database plus its own uncommitted
/// writes. Changes become visible atomically on ``commit()``; discarding
/// the transaction (or ``rollback()``) drops them.
public final class WriteTransaction: Sendable {
    let ffi: FfiSingleWriterTx

    init(ffi: FfiSingleWriterTx) {
        self.ffi = ffi
    }

    // MARK: Reading (sees own writes)

    /// Retrieves the value for a key, seeing the transaction's own writes.
    public func get(_ key: Data, in keyspace: TxKeyspace) throws(FjallError) -> Data? {
        try fjallCall { try ffi.get(keyspace: keyspace.ffi, key: key) }
    }

    /// Returns `true` if the key exists.
    public func containsKey(_ key: Data, in keyspace: TxKeyspace) throws(FjallError) -> Bool {
        try fjallCall { try ffi.containsKey(keyspace: keyspace.ffi, key: key) }
    }

    /// Size of the value for a key in bytes.
    public func size(of key: Data, in keyspace: TxKeyspace) throws(FjallError) -> Int? {
        try fjallCall { try ffi.sizeOf(keyspace: keyspace.ffi, key: key) }.map(Int.init)
    }

    /// Exact number of items visible to this transaction (full O(n) scan).
    public func count(of keyspace: TxKeyspace) throws(FjallError) -> Int {
        Int(try fjallCall { try ffi.len(keyspace: keyspace.ffi) })
    }

    /// Returns `true` if the keyspace is empty as seen by this transaction.
    public func isEmpty(_ keyspace: TxKeyspace) throws(FjallError) -> Bool {
        try fjallCall { try ffi.isEmpty(keyspace: keyspace.ffi) }
    }

    /// The first (minimum) key-value pair visible to this transaction.
    public func first(in keyspace: TxKeyspace) throws(FjallError) -> KeyValuePair? {
        try fjallCall { try ffi.firstKeyValue(keyspace: keyspace.ffi) }.map(KeyValuePair.init)
    }

    /// The last (maximum) key-value pair visible to this transaction.
    public func last(in keyspace: TxKeyspace) throws(FjallError) -> KeyValuePair? {
        try fjallCall { try ffi.lastKeyValue(keyspace: keyspace.ffi) }.map(KeyValuePair.init)
    }

    /// Iterates over the keyspace, including the transaction's own writes.
    public func iter(_ keyspace: TxKeyspace, batchSize: Int = 32) throws(FjallError) -> Iter {
        Iter(ffi: try fjallCall { try ffi.iter(keyspace: keyspace.ffi) }, batchSize: batchSize)
    }

    /// Iterates over a key range, including the transaction's own writes.
    public func range(
        in keyspace: TxKeyspace,
        from lower: Bound? = nil,
        to upper: Bound? = nil,
        batchSize: Int = 32
    ) throws(FjallError) -> Iter {
        Iter(
            ffi: try fjallCall {
                try ffi.range(keyspace: keyspace.ffi, lower: lower?.ffi, upper: upper?.ffi)
            },
            batchSize: batchSize
        )
    }

    /// Iterates over all keys with the given prefix, including the
    /// transaction's own writes.
    public func prefix(_ prefix: Data, in keyspace: TxKeyspace, batchSize: Int = 32) throws(FjallError) -> Iter
    {
        Iter(
            ffi: try fjallCall { try ffi.prefix(keyspace: keyspace.ffi, prefix: prefix) },
            batchSize: batchSize
        )
    }

    // MARK: Writing

    /// Stages an insert.
    public func insert(_ key: Data, _ value: Data, into keyspace: TxKeyspace) throws(FjallError) {
        try fjallCall { try ffi.insert(keyspace: keyspace.ffi, key: key, value: value) }
    }

    /// Stages a removal.
    public func remove(_ key: Data, from keyspace: TxKeyspace) throws(FjallError) {
        try fjallCall { try ffi.remove(keyspace: keyspace.ffi, key: key) }
    }

    /// Stages a weak removal (experimental; see fjall docs).
    public func removeWeak(_ key: Data, from keyspace: TxKeyspace) throws(FjallError) {
        try fjallCall { try ffi.removeWeak(keyspace: keyspace.ffi, key: key) }
    }

    /// Removes an item and returns its value, if it existed.
    public func take(_ key: Data, from keyspace: TxKeyspace) throws(FjallError) -> Data? {
        try fjallCall { try ffi.take(keyspace: keyspace.ffi, key: key) }
    }

    // MARK: Lifecycle

    /// Sets the durability level used when the transaction commits.
    /// Pass `nil` to not persist eagerly on commit.
    @discardableResult
    public func durability(_ mode: PersistMode?) throws(FjallError) -> WriteTransaction {
        try fjallCall { try ffi.setDurability(mode: mode?.ffi) }
        return self
    }

    /// Commits the transaction. It cannot be used afterwards.
    public func commit() throws(FjallError) {
        try fjallCall { try ffi.commit() }
    }

    /// Rolls the transaction back, discarding all staged changes.
    public func rollback() throws(FjallError) {
        try fjallCall { try ffi.rollback() }
    }
}

// MARK: - WriteTransaction string conveniences

extension WriteTransaction {
    /// Retrieves the value for a UTF-8 string key.
    public func get(_ key: String, in keyspace: TxKeyspace) throws(FjallError) -> Data? {
        try get(Data(key.utf8), in: keyspace)
    }

    /// Retrieves the value for a UTF-8 string key, decoded as a UTF-8 string.
    public func getString(_ key: String, in keyspace: TxKeyspace) throws(FjallError) -> String? {
        try get(key, in: keyspace).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Returns `true` if the UTF-8 string key exists.
    public func containsKey(_ key: String, in keyspace: TxKeyspace) throws(FjallError) -> Bool {
        try containsKey(Data(key.utf8), in: keyspace)
    }

    /// Stages an insert of a UTF-8 string key-value pair.
    public func insert(_ key: String, _ value: String, into keyspace: TxKeyspace) throws(FjallError) {
        try insert(Data(key.utf8), Data(value.utf8), into: keyspace)
    }

    /// Stages an insert of a value for a UTF-8 string key.
    public func insert(_ key: String, _ value: Data, into keyspace: TxKeyspace) throws(FjallError) {
        try insert(Data(key.utf8), value, into: keyspace)
    }

    /// Stages a removal of a UTF-8 string key.
    public func remove(_ key: String, from keyspace: TxKeyspace) throws(FjallError) {
        try remove(Data(key.utf8), from: keyspace)
    }

    /// Removes a UTF-8 string key and returns its value, if it existed.
    public func take(_ key: String, from keyspace: TxKeyspace) throws(FjallError) -> Data? {
        try take(Data(key.utf8), from: keyspace)
    }

    /// Iterates over all keys with the given UTF-8 string prefix.
    public func prefix(_ prefix: String, in keyspace: TxKeyspace, batchSize: Int = 32) throws(FjallError)
        -> Iter
    {
        try self.prefix(Data(prefix.utf8), in: keyspace, batchSize: batchSize)
    }
}
