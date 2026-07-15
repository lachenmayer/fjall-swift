import Foundation
import FjallFFI

/// An optimistic (serializable snapshot isolation) transactional database,
/// mirrors `fjall::OptimisticTxDatabase`.
///
/// Multiple write transactions can run concurrently. On commit, a
/// transaction fails with ``FjallError/conflict`` if another transaction
/// modified the same keys — retry the whole transaction in that case
/// (or use ``write(attempts:_:)``).
///
/// ```swift
/// let db = try OptimisticTxDatabase(path: ".fjall_data")
/// let items = try db.keyspace("items")
///
/// try db.write(attempts: 5) { tx in
///     let value = try tx.getString("counter", in: items) ?? "0"
///     try tx.insert("counter", String(Int(value)! + 1), into: items)
/// }
/// ```
public final class OptimisticTxDatabase: Sendable {
    let ffi: FfiOptimisticTxDatabase

    /// Opens (or creates) an optimistic transactional database at the given path.
    public init(path: String, options: Database.Options = .init()) throws(FjallError) {
        self.ffi = try fjallCall {
            try FfiOptimisticTxDatabase.open(path: path, config: options.ffi)
        }
    }

    /// Opens (or creates) an optimistic transactional database at the given file URL.
    public convenience init(url: URL, options: Database.Options = .init()) throws(FjallError) {
        try self.init(path: url.path, options: options)
    }

    /// Opens a transactional keyspace, creating it (with the given options)
    /// if it does not exist.
    public func keyspace(_ name: String, options: Keyspace.Options = .init()) throws(FjallError)
        -> OptimisticTxKeyspace
    {
        OptimisticTxKeyspace(
            ffi: try fjallCall { try ffi.keyspace(name: name, options: options.ffi) })
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
    /// Prefer the scoped ``write(attempts:_:)`` variant, which commits,
    /// rolls back, and retries conflicts automatically.
    public func writeTransaction() throws(FjallError) -> OptimisticWriteTransaction {
        OptimisticWriteTransaction(ffi: try fjallCall { try ffi.writeTx() })
    }

    /// Runs `body` inside a write transaction.
    ///
    /// The transaction is committed when `body` returns, and rolled back if
    /// it throws. If the commit conflicts with another transaction, the whole
    /// transaction is retried up to `attempts` times in total before
    /// ``FjallError/conflict`` is thrown. `body` must not commit or roll back
    /// the transaction itself.
    public func write<T>(
        attempts: Int = 1,
        _ body: (OptimisticWriteTransaction) throws -> T
    ) throws -> T {
        precondition(attempts >= 1, "attempts must be at least 1")
        for _ in 0..<(attempts - 1) {
            do {
                return try writeOnce(body)
            } catch FjallError.conflict {
                continue
            }
        }
        return try writeOnce(body)
    }

    private func writeOnce<T>(_ body: (OptimisticWriteTransaction) throws -> T) throws -> T {
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

/// A keyspace of an optimistic transactional database,
/// mirrors `fjall::OptimisticTxKeyspace`.
///
/// Write operations called directly on this type run as their own
/// mini-transaction. Use ``OptimisticTxDatabase/write(attempts:_:)`` to
/// group operations.
public final class OptimisticTxKeyspace: Sendable {
    let ffi: FfiOptimisticTxKeyspace

    /// The underlying plain keyspace handle.
    public let base: Keyspace

    init(ffi: FfiOptimisticTxKeyspace) {
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

extension OptimisticTxKeyspace: KeyspaceRef {}

// MARK: - OptimisticTxKeyspace string conveniences

extension OptimisticTxKeyspace {
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

/// An optimistic write transaction, mirrors `fjall::OptimisticWriteTx`.
///
/// Sees a consistent snapshot of the database plus its own uncommitted
/// writes. ``commit()`` throws ``FjallError/conflict`` if another
/// transaction modified the same keys since this transaction started.
public final class OptimisticWriteTransaction: Sendable {
    let ffi: FfiOptimisticTx

    init(ffi: FfiOptimisticTx) {
        self.ffi = ffi
    }

    // MARK: Reading (sees own writes)

    /// Retrieves the value for a key, seeing the transaction's own writes.
    public func get(_ key: Data, in keyspace: OptimisticTxKeyspace) throws(FjallError) -> Data? {
        try fjallCall { try ffi.get(keyspace: keyspace.ffi, key: key) }
    }

    /// Returns `true` if the key exists.
    public func containsKey(_ key: Data, in keyspace: OptimisticTxKeyspace) throws(FjallError) -> Bool {
        try fjallCall { try ffi.containsKey(keyspace: keyspace.ffi, key: key) }
    }

    /// Size of the value for a key in bytes.
    public func size(of key: Data, in keyspace: OptimisticTxKeyspace) throws(FjallError) -> Int? {
        try fjallCall { try ffi.sizeOf(keyspace: keyspace.ffi, key: key) }.map(Int.init)
    }

    /// Exact number of items visible to this transaction (full O(n) scan).
    public func count(of keyspace: OptimisticTxKeyspace) throws(FjallError) -> Int {
        Int(try fjallCall { try ffi.len(keyspace: keyspace.ffi) })
    }

    /// Returns `true` if the keyspace is empty as seen by this transaction.
    public func isEmpty(_ keyspace: OptimisticTxKeyspace) throws(FjallError) -> Bool {
        try fjallCall { try ffi.isEmpty(keyspace: keyspace.ffi) }
    }

    /// The first (minimum) key-value pair visible to this transaction.
    public func first(in keyspace: OptimisticTxKeyspace) throws(FjallError) -> KeyValuePair? {
        try fjallCall { try ffi.firstKeyValue(keyspace: keyspace.ffi) }.map(KeyValuePair.init)
    }

    /// The last (maximum) key-value pair visible to this transaction.
    public func last(in keyspace: OptimisticTxKeyspace) throws(FjallError) -> KeyValuePair? {
        try fjallCall { try ffi.lastKeyValue(keyspace: keyspace.ffi) }.map(KeyValuePair.init)
    }

    /// Iterates over the keyspace, including the transaction's own writes.
    public func iter(_ keyspace: OptimisticTxKeyspace, batchSize: Int = 32) throws(FjallError) -> Iter {
        Iter(ffi: try fjallCall { try ffi.iter(keyspace: keyspace.ffi) }, batchSize: batchSize)
    }

    /// Iterates over a key range, including the transaction's own writes.
    public func range(
        in keyspace: OptimisticTxKeyspace,
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
    public func prefix(_ prefix: Data, in keyspace: OptimisticTxKeyspace, batchSize: Int = 32)
        throws -> Iter
    {
        Iter(
            ffi: try fjallCall { try ffi.prefix(keyspace: keyspace.ffi, prefix: prefix) },
            batchSize: batchSize
        )
    }

    // MARK: Writing

    /// Stages an insert.
    public func insert(_ key: Data, _ value: Data, into keyspace: OptimisticTxKeyspace) throws(FjallError) {
        try fjallCall { try ffi.insert(keyspace: keyspace.ffi, key: key, value: value) }
    }

    /// Stages a removal.
    public func remove(_ key: Data, from keyspace: OptimisticTxKeyspace) throws(FjallError) {
        try fjallCall { try ffi.remove(keyspace: keyspace.ffi, key: key) }
    }

    /// Stages a weak removal (experimental; see fjall docs).
    public func removeWeak(_ key: Data, from keyspace: OptimisticTxKeyspace) throws(FjallError) {
        try fjallCall { try ffi.removeWeak(keyspace: keyspace.ffi, key: key) }
    }

    /// Removes an item and returns its value, if it existed.
    public func take(_ key: Data, from keyspace: OptimisticTxKeyspace) throws(FjallError) -> Data? {
        try fjallCall { try ffi.take(keyspace: keyspace.ffi, key: key) }
    }

    // MARK: Lifecycle

    /// Sets the durability level used when the transaction commits.
    /// Pass `nil` to not persist eagerly on commit.
    @discardableResult
    public func durability(_ mode: PersistMode?) throws(FjallError) -> OptimisticWriteTransaction {
        try fjallCall { try ffi.setDurability(mode: mode?.ffi) }
        return self
    }

    /// Commits the transaction. It cannot be used afterwards.
    ///
    /// Throws ``FjallError/conflict`` if another transaction modified the
    /// same keys since this transaction started.
    public func commit() throws(FjallError) {
        try fjallCall { try ffi.commit() }
    }

    /// Rolls the transaction back, discarding all staged changes.
    public func rollback() throws(FjallError) {
        try fjallCall { try ffi.rollback() }
    }
}

// MARK: - OptimisticWriteTransaction string conveniences

extension OptimisticWriteTransaction {
    /// Retrieves the value for a UTF-8 string key.
    public func get(_ key: String, in keyspace: OptimisticTxKeyspace) throws(FjallError) -> Data? {
        try get(Data(key.utf8), in: keyspace)
    }

    /// Retrieves the value for a UTF-8 string key, decoded as a UTF-8 string.
    public func getString(_ key: String, in keyspace: OptimisticTxKeyspace) throws(FjallError) -> String? {
        try get(key, in: keyspace).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Returns `true` if the UTF-8 string key exists.
    public func containsKey(_ key: String, in keyspace: OptimisticTxKeyspace) throws(FjallError) -> Bool {
        try containsKey(Data(key.utf8), in: keyspace)
    }

    /// Stages an insert of a UTF-8 string key-value pair.
    public func insert(_ key: String, _ value: String, into keyspace: OptimisticTxKeyspace) throws(FjallError)
    {
        try insert(Data(key.utf8), Data(value.utf8), into: keyspace)
    }

    /// Stages an insert of a value for a UTF-8 string key.
    public func insert(_ key: String, _ value: Data, into keyspace: OptimisticTxKeyspace) throws(FjallError) {
        try insert(Data(key.utf8), value, into: keyspace)
    }

    /// Stages a removal of a UTF-8 string key.
    public func remove(_ key: String, from keyspace: OptimisticTxKeyspace) throws(FjallError) {
        try remove(Data(key.utf8), from: keyspace)
    }

    /// Removes a UTF-8 string key and returns its value, if it existed.
    public func take(_ key: String, from keyspace: OptimisticTxKeyspace) throws(FjallError) -> Data? {
        try take(Data(key.utf8), from: keyspace)
    }

    /// Iterates over all keys with the given UTF-8 string prefix.
    public func prefix(_ prefix: String, in keyspace: OptimisticTxKeyspace, batchSize: Int = 32)
        throws -> Iter
    {
        try self.prefix(Data(prefix.utf8), in: keyspace, batchSize: batchSize)
    }
}
