import Foundation
import FjallFFI

/// A fjall database, mirrors `fjall::Database`.
///
/// A database is a single directory on disk containing any number of
/// keyspaces. All handles are thread-safe (`Sendable`) and cheap to share.
///
/// ```swift
/// let db = try Database(path: ".fjall_data")
/// let items = try db.keyspace("items")
/// try items.insert("a", "hello")
/// let bytes = try items.get("a")
/// ```
public final class Database: Sendable {
    /// Database-level configuration, mirrors `fjall::DatabaseBuilder`.
    public struct Options: Sendable, Equatable {
        /// Size of the block cache in bytes (`nil` keeps fjall's default).
        public var cacheSize: UInt64?
        /// If `true`, the database directory is deleted when the database is closed.
        public var temporary: Bool
        /// If `true`, the journal is only persisted on explicit ``Database/persist(_:)`` calls.
        public var manualJournalPersist: Bool
        /// Maximum size of the journal before forcing a flush (`nil` keeps fjall's default).
        public var maxJournalingSize: UInt64?
        /// Compression to use for the journal (`nil` keeps fjall's default).
        public var journalCompression: Compression?
        /// Number of background worker threads (`nil` keeps fjall's default).
        public var workerThreads: Int?

        public init(
            cacheSize: UInt64? = nil,
            temporary: Bool = false,
            manualJournalPersist: Bool = false,
            maxJournalingSize: UInt64? = nil,
            journalCompression: Compression? = nil,
            workerThreads: Int? = nil
        ) {
            self.cacheSize = cacheSize
            self.temporary = temporary
            self.manualJournalPersist = manualJournalPersist
            self.maxJournalingSize = maxJournalingSize
            self.journalCompression = journalCompression
            self.workerThreads = workerThreads
        }

        var ffi: FfiDatabaseConfig {
            FfiDatabaseConfig(
                cacheSizeBytes: cacheSize,
                temporary: temporary ? true : nil,
                manualJournalPersist: manualJournalPersist ? true : nil,
                maxJournalingSizeBytes: maxJournalingSize,
                journalCompression: journalCompression?.ffi,
                workerThreads: workerThreads.map(UInt32.init)
            )
        }
    }

    let ffi: FfiDatabase

    /// Opens (or creates) a database at the given path.
    public init(path: String, options: Options = Options()) throws {
        self.ffi = try fjallCall { try FfiDatabase.open(path: path, config: options.ffi) }
    }

    /// Opens (or creates) a database at the given file URL.
    public convenience init(url: URL, options: Options = Options()) throws {
        try self.init(path: url.path, options: options)
    }

    /// Opens a keyspace, creating it (with the given options) if it does not exist.
    ///
    /// The options only take effect when the keyspace is first created.
    public func keyspace(_ name: String, options: Keyspace.Options = .init()) throws -> Keyspace {
        Keyspace(ffi: try fjallCall { try ffi.keyspace(name: name, options: options.ffi) })
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

    /// Deletes a keyspace and all its data.
    ///
    /// Any further use of the keyspace handle throws ``FjallError/keyspaceDeleted``.
    public func deleteKeyspace(_ keyspace: Keyspace) throws {
        try fjallCall { try ffi.deleteKeyspace(keyspace: keyspace.ffi) }
    }

    /// Persists the journal to disk with the given durability level.
    public func persist(_ mode: PersistMode) throws {
        try fjallCall { try ffi.persist(mode: mode.ffi) }
    }

    /// Creates a new atomic write batch.
    public func batch() -> WriteBatch {
        WriteBatch(ffi: ffi.batch())
    }

    /// Creates a cross-keyspace snapshot for consistent reads.
    ///
    /// Keep snapshots short-lived: old data cannot be garbage-collected
    /// while a snapshot still references it.
    public func snapshot() -> Snapshot {
        Snapshot(ffi: ffi.snapshot())
    }

    /// Total disk space used by the database, in bytes.
    public var diskSpace: UInt64 {
        get throws { try fjallCall { try ffi.diskSpace() } }
    }

    /// Disk space used by the journal, in bytes.
    public var journalDiskSpace: UInt64 {
        get throws { try fjallCall { try ffi.journalDiskSpace() } }
    }

    /// Number of journal files.
    public var journalCount: Int {
        Int(ffi.journalCount())
    }

    /// Current size of the block cache, in bytes.
    public var cacheSize: UInt64 {
        ffi.cacheSize()
    }

    /// Capacity of the block cache, in bytes.
    public var cacheCapacity: UInt64 {
        ffi.cacheCapacity()
    }

    /// Current size of all write buffers, in bytes.
    public var writeBufferSize: UInt64 {
        ffi.writeBufferSize()
    }
}
