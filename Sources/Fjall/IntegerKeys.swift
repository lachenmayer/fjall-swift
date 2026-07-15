import Foundation

// fjall orders keys by raw byte comparison. These helpers encode integers
// so that byte order equals numeric order:
//
// - fixed width (so shorter values don't sort as prefixes),
// - big-endian (most significant byte first),
// - and, for signed integers, with the sign bit flipped so negative
//   values sort before positive ones.

extension Data {
    /// Encodes an integer as a fixed-width, order-preserving fjall key.
    ///
    /// The encoding is big-endian; signed integers additionally have their
    /// sign bit flipped so that byte order matches numeric order across
    /// negative and positive values.
    ///
    /// ```swift
    /// try items.insert(Data(orderPreservingKey: UInt64(42)), payload)
    /// ```
    ///
    /// Decode with ``Swift/FixedWidthInteger/init(orderPreservingKey:)``.
    /// Use one fixed integer type per keyspace — keys of different widths
    /// do not sort meaningfully against each other.
    public init(orderPreservingKey value: some FixedWidthInteger) {
        var bigEndian = value.bigEndian
        var data = Swift.withUnsafeBytes(of: &bigEndian) { Data($0) }
        if type(of: value).isSigned {
            data[data.startIndex] ^= 0x80
        }
        self = data
    }
}

extension FixedWidthInteger {
    /// Decodes an integer from its order-preserving fjall key encoding
    /// (see ``Foundation/Data/init(orderPreservingKey:)``).
    ///
    /// Returns `nil` if `data` is not exactly `Self.bitWidth / 8` bytes.
    ///
    /// ```swift
    /// let id = UInt64(orderPreservingKey: pair.key)
    /// ```
    public init?(orderPreservingKey data: Data) {
        guard data.count == Self.bitWidth / 8 else { return nil }
        var magnitude = Magnitude(0)
        for (offset, byte) in data.enumerated() {
            var byte = byte
            if offset == 0 && Self.isSigned {
                byte ^= 0x80
            }
            magnitude = (magnitude << 8) | Magnitude(byte)
        }
        self = Self(truncatingIfNeeded: magnitude)
    }
}

extension Bound {
    /// An inclusive bound on an order-preserving integer key.
    public static func included(_ key: some FixedWidthInteger) -> Bound {
        .included(Data(orderPreservingKey: key))
    }

    /// An exclusive bound on an order-preserving integer key.
    public static func excluded(_ key: some FixedWidthInteger) -> Bound {
        .excluded(Data(orderPreservingKey: key))
    }
}
