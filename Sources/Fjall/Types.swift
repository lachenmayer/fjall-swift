import Foundation
import FjallFFI

/// Durability level for persisting the journal, mirrors `fjall::PersistMode`.
public enum PersistMode: Sendable, Equatable, Hashable {
    /// Flushes data to OS buffers. Data survives an application crash,
    /// but not necessarily a power loss or OS crash.
    case buffer
    /// Flushes data using `fdatasync`.
    case syncData
    /// Flushes data and metadata using `fsync`.
    case syncAll

    var ffi: FfiPersistMode {
        switch self {
        case .buffer: .buffer
        case .syncData: .syncData
        case .syncAll: .syncAll
        }
    }
}

/// Compression algorithm, mirrors `fjall::CompressionType`.
public enum Compression: Sendable, Equatable, Hashable {
    case none
    case lz4

    var ffi: FfiCompression {
        switch self {
        case .none: .none
        case .lz4: .lz4
        }
    }
}

/// A key-value pair.
public struct KeyValuePair: Sendable, Equatable, Hashable {
    public let key: Data
    public let value: Data

    public init(key: Data, value: Data) {
        self.key = key
        self.value = value
    }

    init(_ ffi: FfiKvPair) {
        self.key = ffi.key
        self.value = ffi.value
    }

    /// The key, lossily decoded as UTF-8.
    public var keyString: String { String(decoding: key, as: UTF8.self) }

    /// The value, lossily decoded as UTF-8.
    public var valueString: String { String(decoding: value, as: UTF8.self) }
}

/// One end of a key range, mirrors `std::ops::Bound`.
public enum Bound: Sendable, Equatable, Hashable {
    case included(Data)
    case excluded(Data)

    /// An inclusive bound on a UTF-8 string key.
    public static func included(_ key: String) -> Bound { .included(Data(key.utf8)) }

    /// An exclusive bound on a UTF-8 string key.
    public static func excluded(_ key: String) -> Bound { .excluded(Data(key.utf8)) }

    var ffi: FfiBound {
        switch self {
        case .included(let key): FfiBound(key: key, inclusive: true)
        case .excluded(let key): FfiBound(key: key, inclusive: false)
        }
    }
}

/// Options for key-value separation (storing large values out of line),
/// mirrors `fjall::KvSeparationOptions`.
public struct KvSeparationOptions: Sendable, Equatable, Hashable {
    /// Values at least this many bytes are stored separately.
    public var separationThreshold: UInt32?
    /// Target size of blob files, in bytes.
    public var fileTargetSize: UInt64?
    /// Compression for blob files.
    public var compression: Compression?

    public init(
        separationThreshold: UInt32? = nil,
        fileTargetSize: UInt64? = nil,
        compression: Compression? = nil
    ) {
        self.separationThreshold = separationThreshold
        self.fileTargetSize = fileTargetSize
        self.compression = compression
    }

    var ffi: FfiKvSeparationOptions {
        FfiKvSeparationOptions(
            separationThresholdBytes: separationThreshold,
            fileTargetSizeBytes: fileTargetSize,
            compression: compression?.ffi
        )
    }
}
