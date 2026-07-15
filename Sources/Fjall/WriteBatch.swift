import Foundation
import FjallFFI

/// An atomic write batch across any number of keyspaces,
/// mirrors `fjall::OwnedWriteBatch`.
///
/// Stage operations with ``insert(_:_:into:)`` and ``remove(_:from:)``,
/// then apply them all at once with ``commit()``. Either all operations
/// become visible, or none do.
///
/// ```swift
/// let batch = db.batch()
/// try batch.insert("a", "1", into: items)
/// try batch.remove("b", from: items)
/// try batch.commit()
/// ```
///
/// A batch can only be committed once; further use throws
/// ``FjallError/batchConsumed``.
public final class WriteBatch: Sendable {
    let ffi: FfiWriteBatch

    init(ffi: FfiWriteBatch) {
        self.ffi = ffi
    }

    /// Stages an insert into a keyspace.
    public func insert(_ key: Data, _ value: Data, into keyspace: Keyspace) throws(FjallError) {
        try fjallCall { try ffi.insert(keyspace: keyspace.ffi, key: key, value: value) }
    }

    /// Stages a removal from a keyspace.
    public func remove(_ key: Data, from keyspace: Keyspace) throws(FjallError) {
        try fjallCall { try ffi.remove(keyspace: keyspace.ffi, key: key) }
    }

    /// Stages a weak removal (experimental; see fjall docs).
    public func removeWeak(_ key: Data, from keyspace: Keyspace) throws(FjallError) {
        try fjallCall { try ffi.removeWeak(keyspace: keyspace.ffi, key: key) }
    }

    /// Number of staged operations.
    public var count: Int {
        get throws(FjallError) { Int(try fjallCall { try ffi.len() }) }
    }

    /// Returns `true` if no operations are staged.
    public var isEmpty: Bool {
        get throws(FjallError) { try fjallCall { try ffi.isEmpty() } }
    }

    /// Sets the durability level used when the batch commits.
    /// Pass `nil` to not persist eagerly on commit.
    @discardableResult
    public func durability(_ mode: PersistMode?) throws(FjallError) -> WriteBatch {
        try fjallCall { try ffi.setDurability(mode: mode?.ffi) }
        return self
    }

    /// Atomically commits all staged operations.
    public func commit() throws(FjallError) {
        try fjallCall { try ffi.commit() }
    }
}

// MARK: - String conveniences

extension WriteBatch {
    /// Stages an insert of a UTF-8 string key-value pair.
    public func insert(_ key: String, _ value: String, into keyspace: Keyspace) throws(FjallError) {
        try insert(Data(key.utf8), Data(value.utf8), into: keyspace)
    }

    /// Stages an insert of a value for a UTF-8 string key.
    public func insert(_ key: String, _ value: Data, into keyspace: Keyspace) throws(FjallError) {
        try insert(Data(key.utf8), value, into: keyspace)
    }

    /// Stages a removal of a UTF-8 string key.
    public func remove(_ key: String, from keyspace: Keyspace) throws(FjallError) {
        try remove(Data(key.utf8), from: keyspace)
    }
}
