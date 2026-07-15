import Foundation
import Testing

@testable import Fjall

@Suite struct IntegerKeyEncoding {
    @Test func roundtripUnsigned() throws {
        for value: UInt64 in [0, 1, 255, 256, 65_535, 1 << 32, .max] {
            let data = Data(orderPreservingKey: value)
            #expect(data.count == 8)
            #expect(UInt64(orderPreservingKey: data) == value)
        }
    }

    @Test func roundtripSigned() throws {
        for value: Int64 in [.min, -1_000_000, -1, 0, 1, 1_000_000, .max] {
            let data = Data(orderPreservingKey: value)
            #expect(data.count == 8)
            #expect(Int64(orderPreservingKey: data) == value)
        }
    }

    @Test func roundtripOtherWidths() throws {
        #expect(UInt8(orderPreservingKey: Data(orderPreservingKey: UInt8(200))) == 200)
        #expect(Int8(orderPreservingKey: Data(orderPreservingKey: Int8(-100))) == -100)
        #expect(UInt16(orderPreservingKey: Data(orderPreservingKey: UInt16(40_000))) == 40_000)
        #expect(Int32(orderPreservingKey: Data(orderPreservingKey: Int32(-123_456))) == -123_456)
    }

    @Test func wrongWidthReturnsNil() throws {
        let data = Data(orderPreservingKey: UInt32(1))  // 4 bytes
        #expect(UInt64(orderPreservingKey: data) == nil)
        #expect(UInt16(orderPreservingKey: data) == nil)
    }

    @Test func byteOrderMatchesNumericOrderUnsigned() throws {
        let values: [UInt64] = [0, 1, 2, 255, 256, 257, 65_535, 65_536, 1 << 40, .max]
        let encoded = values.map { Array(Data(orderPreservingKey: $0)) }
        for i in 0..<(values.count - 1) {
            #expect(encoded[i].lexicographicallyPrecedes(encoded[i + 1]))
        }
    }

    @Test func byteOrderMatchesNumericOrderSigned() throws {
        let values: [Int64] = [.min, -65_536, -256, -2, -1, 0, 1, 2, 256, 65_536, .max]
        let encoded = values.map { Array(Data(orderPreservingKey: $0)) }
        for i in 0..<(values.count - 1) {
            #expect(encoded[i].lexicographicallyPrecedes(encoded[i + 1]))
        }
    }

    @Test func sequentialKeysIterateInNumericOrder() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("fjall-swift-intkey-\(UUID().uuidString)").path
        let db = try Database(path: path, options: .init(temporary: true))
        let items = try db.keyspace("items")

        // Insert out of order; values chosen so string ordering would differ.
        for id: UInt64 in [1_000, 5, 256, 1, 999_999, 42] {
            try items.insert(Data(orderPreservingKey: id), Data("v\(id)".utf8))
        }

        let ids = try items.iter().collect().map { UInt64(orderPreservingKey: $0.key)! }
        #expect(ids == [1, 5, 42, 256, 1_000, 999_999])

        // Range scans with integer bounds.
        let ranged = try items.range(from: .included(UInt64(42)), to: .excluded(UInt64(1_000)))
            .collect()
            .map { UInt64(orderPreservingKey: $0.key)! }
        #expect(ranged == [42, 256])

        // First/last follow numeric order too.
        #expect(try UInt64(orderPreservingKey: items.first!.key) == 1)
        #expect(try UInt64(orderPreservingKey: items.last!.key) == 999_999)
    }
}
