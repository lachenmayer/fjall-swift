import Foundation
import FjallFFI

/// A double-ended iterator over key-value pairs, mirrors `fjall::Iter`.
///
/// The iterator holds a snapshot of the database, so it sees a consistent
/// view even while the keyspace is being written to. Iteration can throw,
/// so `Iter` does not conform to `IteratorProtocol`; use `while let` or
/// ``collect()``:
///
/// ```swift
/// let iter = keyspace.iter()
/// while let pair = try iter.next() {
///     print(pair.keyString, pair.valueString)
/// }
/// ```
///
/// To reduce FFI overhead, pairs are fetched from Rust in batches.
/// `Iter` is single-owner and not thread-safe (like a Rust iterator).
public final class Iter {
    private let ffi: FfiIterator
    private let batchSize: UInt32

    // Pairs already pulled out of the Rust iterator but not yet returned.
    // `front` is in ascending order, `back` in descending order.
    private var front: [FfiKvPair] = []
    private var frontIndex = 0
    private var back: [FfiKvPair] = []
    private var backIndex = 0

    // Once the Rust iterator is drained, only the buffers remain.
    private var rustExhausted = false

    init(ffi: FfiIterator, batchSize: Int) {
        self.ffi = ffi
        self.batchSize = UInt32(max(1, batchSize))
    }

    /// Returns the next pair from the front, or `nil` when the iterator is exhausted.
    public func next() throws(FjallError) -> KeyValuePair? {
        if frontIndex < front.count {
            defer { frontIndex += 1 }
            return KeyValuePair(front[frontIndex])
        }
        if !rustExhausted {
            front = try fjallCall { try ffi.nextMany(count: batchSize) }
            frontIndex = 0
            if front.count < batchSize { rustExhausted = true }
            if !front.isEmpty {
                frontIndex = 1
                return KeyValuePair(front[0])
            }
        }
        // Rust is drained; the remaining smallest key is at the *end* of `back`.
        if backIndex < back.count {
            defer { back.removeLast() }
            return KeyValuePair(back[back.count - 1])
        }
        return nil
    }

    /// Returns the next pair from the back (i.e. in descending key order),
    /// or `nil` when the iterator is exhausted.
    public func nextBack() throws(FjallError) -> KeyValuePair? {
        if backIndex < back.count {
            defer { backIndex += 1 }
            return KeyValuePair(back[backIndex])
        }
        if !rustExhausted {
            back = try fjallCall { try ffi.nextBackMany(count: batchSize) }
            backIndex = 0
            if back.count < batchSize { rustExhausted = true }
            if !back.isEmpty {
                backIndex = 1
                return KeyValuePair(back[0])
            }
        }
        // Rust is drained; the remaining largest key is at the *end* of `front`.
        if frontIndex < front.count {
            defer { front.removeLast() }
            return KeyValuePair(front[front.count - 1])
        }
        return nil
    }

    /// Collects all remaining pairs (from the front) into an array.
    public func collect() throws(FjallError) -> [KeyValuePair] {
        var result: [KeyValuePair] = []
        while let pair = try next() {
            result.append(pair)
        }
        return result
    }

    /// Collects all remaining pairs from the back (descending key order) into an array.
    public func collectReversed() throws(FjallError) -> [KeyValuePair] {
        var result: [KeyValuePair] = []
        while let pair = try nextBack() {
            result.append(pair)
        }
        return result
    }

    /// Calls `body` for each remaining pair, in ascending key order.
    public func forEach(_ body: (KeyValuePair) throws -> Void) throws {
        while let pair = try next() {
            try body(pair)
        }
    }
}
