import FjallFFI

/// Errors thrown by fjall, mirrors `fjall::Error`.
public enum FjallError: Error, Sendable, Equatable, Hashable, CustomStringConvertible {
    /// I/O error.
    case io(String)
    /// Error inside the storage engine (lsm-tree).
    case storage(String)
    /// Error during journal recovery.
    case journalRecovery(String)
    /// Database format version mismatch.
    case invalidVersion(String)
    /// Decompression failed.
    case decompress(String)
    /// A lock is poisoned (a thread panicked while holding it).
    case poisoned
    /// The keyspace was deleted.
    case keyspaceDeleted
    /// The database is locked by another process.
    case locked
    /// The database is in an unrecoverable state.
    case unrecoverable
    /// The write batch was already committed and cannot be used again.
    case batchConsumed
    /// Any other error.
    case other(String)

    init(_ ffi: FfiError) {
        switch ffi {
        case .Io(let message): self = .io(message)
        case .Storage(let message): self = .storage(message)
        case .JournalRecovery(let message): self = .journalRecovery(message)
        case .InvalidVersion(let message): self = .invalidVersion(message)
        case .Decompress(let message): self = .decompress(message)
        case .Poisoned: self = .poisoned
        case .KeyspaceDeleted: self = .keyspaceDeleted
        case .Locked: self = .locked
        case .Unrecoverable: self = .unrecoverable
        case .BatchConsumed: self = .batchConsumed
        case .Other(let message): self = .other(message)
        }
    }

    public var description: String {
        switch self {
        case .io(let message): "I/O error: \(message)"
        case .storage(let message): "storage error: \(message)"
        case .journalRecovery(let message): "journal recovery error: \(message)"
        case .invalidVersion(let message): "invalid format version: \(message)"
        case .decompress(let message): "decompression error: \(message)"
        case .poisoned: "lock is poisoned"
        case .keyspaceDeleted: "keyspace was deleted"
        case .locked: "database is locked by another process"
        case .unrecoverable: "database is unrecoverable"
        case .batchConsumed: "write batch was already committed"
        case .other(let message): message
        }
    }
}

/// Runs an FFI call, rethrowing its error as a `FjallError`.
@inline(__always)
func fjallCall<T>(_ body: () throws -> T) throws -> T {
    do {
        return try body()
    } catch let error as FfiError {
        throw FjallError(error)
    }
}
