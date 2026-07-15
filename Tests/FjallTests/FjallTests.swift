import Foundation
import Testing

@testable import Fjall

/// Creates a unique temporary path for a test database.
private func tempPath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("fjall-swift-tests-\(UUID().uuidString)")
        .path
}

private func withDatabase<T>(
    options: Database.Options = .init(temporary: true),
    _ body: (Database) throws -> T
) throws -> T {
    let db = try Database(path: tempPath(), options: options)
    return try body(db)
}

@Suite struct BasicOperations {
    @Test func roundtrip() throws {
        try withDatabase { db in
            let items = try db.keyspace("items")

            #expect(try items.isEmpty)
            try items.insert(Data("a".utf8), Data("hello".utf8))
            try items.insert(Data("b".utf8), Data("world".utf8))

            #expect(try items.get(Data("a".utf8)) == Data("hello".utf8))
            #expect(try items.get(Data("missing".utf8)) == nil)
            #expect(try items.containsKey(Data("b".utf8)))
            #expect(try items.count == 2)
            #expect(try !items.isEmpty)
            #expect(items.approximateCount >= 2)

            try items.remove(Data("a".utf8))
            #expect(try items.get(Data("a".utf8)) == nil)
            #expect(try items.count == 1)
        }
    }

    @Test func stringConveniences() throws {
        try withDatabase { db in
            let items = try db.keyspace("items")

            try items.insert("greeting", "hello")
            #expect(try items.getString("greeting") == "hello")
            #expect(try items.containsKey("greeting"))
            #expect(try items.size(of: "greeting") == 5)

            try items.remove("greeting")
            #expect(try items.getString("greeting") == nil)
        }
    }

    @Test func firstAndLast() throws {
        try withDatabase { db in
            let items = try db.keyspace("items")

            #expect(try items.first == nil)
            #expect(try items.last == nil)

            try items.insert("a", "1")
            try items.insert("m", "2")
            try items.insert("z", "3")

            #expect(try items.first?.keyString == "a")
            #expect(try items.last?.keyString == "z")
        }
    }

    @Test func clear() throws {
        try withDatabase { db in
            let items = try db.keyspace("items")
            try items.insert("a", "1")
            try items.insert("b", "2")
            try items.clear()
            #expect(try items.isEmpty)
        }
    }

    @Test func binaryKeysAndValues() throws {
        try withDatabase { db in
            let items = try db.keyspace("items")
            let key = Data([0x00, 0xFF, 0x10, 0x80])
            let value = Data((0...255).map { UInt8($0) })
            try items.insert(key, value)
            #expect(try items.get(key) == value)
        }
    }
}

@Suite struct Iteration {
    private func populated(_ db: Database) throws -> Keyspace {
        let items = try db.keyspace("items")
        for i in 0..<10 {
            try items.insert("key-\(i)", "value-\(i)")
        }
        return items
    }

    @Test(arguments: [1, 2, 3, 32])
    func forwardIteration(batchSize: Int) throws {
        try withDatabase { db in
            let items = try populated(db)
            let pairs = try items.iter(batchSize: batchSize).collect()
            #expect(pairs.count == 10)
            #expect(pairs.map(\.keyString) == (0..<10).map { "key-\($0)" })
        }
    }

    @Test(arguments: [1, 2, 3, 32])
    func backwardIteration(batchSize: Int) throws {
        try withDatabase { db in
            let items = try populated(db)
            let pairs = try items.iter(batchSize: batchSize).collectReversed()
            #expect(pairs.map(\.keyString) == (0..<10).reversed().map { "key-\($0)" })
        }
    }

    @Test(arguments: [1, 2, 3, 32])
    func interleavedIteration(batchSize: Int) throws {
        try withDatabase { db in
            let items = try populated(db)
            let iter = items.iter(batchSize: batchSize)

            var seen: [String] = []
            var fromFront = true
            while true {
                let pair = fromFront ? try iter.next() : try iter.nextBack()
                guard let pair else { break }
                seen.append(pair.keyString)
                fromFront.toggle()
            }

            // Every key exactly once: fronts ascending, backs descending.
            #expect(seen.count == 10)
            #expect(Set(seen).count == 10)
            #expect(seen[0] == "key-0")
            #expect(seen[1] == "key-9")
        }
    }

    @Test func range() throws {
        try withDatabase { db in
            let items = try populated(db)

            let inclusive = try items.range(
                from: .included("key-2"), to: .included("key-5")
            ).collect()
            #expect(inclusive.map(\.keyString) == ["key-2", "key-3", "key-4", "key-5"])

            let exclusive = try items.range(
                from: .excluded("key-2"), to: .excluded("key-5")
            ).collect()
            #expect(exclusive.map(\.keyString) == ["key-3", "key-4"])

            let openEnded = try items.range(from: .included("key-8")).collect()
            #expect(openEnded.map(\.keyString) == ["key-8", "key-9"])

            let all = try items.range().collect()
            #expect(all.count == 10)
        }
    }

    @Test func prefix() throws {
        try withDatabase { db in
            let items = try db.keyspace("items")
            try items.insert("fruit:apple", "1")
            try items.insert("fruit:banana", "2")
            try items.insert("veg:carrot", "3")

            let fruit = try items.prefix("fruit:").collect()
            #expect(fruit.map(\.keyString) == ["fruit:apple", "fruit:banana"])

            var count = 0
            try items.prefix("veg:").forEach { _ in count += 1 }
            #expect(count == 1)
        }
    }

    @Test func iterationIsSnapshotted() throws {
        try withDatabase { db in
            let items = try db.keyspace("items")
            try items.insert("a", "1")
            let iter = items.iter(batchSize: 1)
            try items.insert("b", "2")
            // The iterator was created before "b" was inserted.
            let pairs = try iter.collect()
            #expect(pairs.map(\.keyString) == ["a"])
        }
    }
}

@Suite struct Batches {
    @Test func atomicCommit() throws {
        try withDatabase { db in
            let items = try db.keyspace("items")
            let other = try db.keyspace("other")

            let batch = db.batch()
            try batch.insert("a", "1", into: items)
            try batch.insert("b", "2", into: other)
            #expect(try batch.count == 2)
            #expect(try items.isEmpty)  // nothing visible before commit

            try batch.commit()
            #expect(try items.getString("a") == "1")
            #expect(try other.getString("b") == "2")
        }
    }

    @Test func commitOnlyOnce() throws {
        try withDatabase { db in
            let items = try db.keyspace("items")
            let batch = db.batch()
            try batch.insert("a", "1", into: items)
            try batch.commit()

            #expect(throws: FjallError.batchConsumed) {
                try batch.commit()
            }
            #expect(throws: FjallError.batchConsumed) {
                try batch.insert("b", "2", into: items)
            }
        }
    }

    @Test func batchRemove() throws {
        try withDatabase { db in
            let items = try db.keyspace("items")
            try items.insert("a", "1")

            let batch = try db.batch().durability(.buffer)
            try batch.remove("a", from: items)
            try batch.insert("b", "2", into: items)
            try batch.commit()

            #expect(try items.getString("a") == nil)
            #expect(try items.getString("b") == "2")
        }
    }
}

@Suite struct Snapshots {
    @Test func snapshotIsolation() throws {
        try withDatabase { db in
            let items = try db.keyspace("items")
            try items.insert("before", "1")

            let snapshot = db.snapshot()
            try items.insert("after", "2")

            #expect(try snapshot.getString("before", in: items) == "1")
            #expect(try snapshot.getString("after", in: items) == nil)
            #expect(try snapshot.count(of: items) == 1)
            #expect(try !snapshot.isEmpty(items))

            // Live keyspace sees both.
            #expect(try items.count == 2)

            let pairs = try snapshot.iter(items).collect()
            #expect(pairs.map(\.keyString) == ["before"])
        }
    }

    @Test func snapshotRangeAndPrefix() throws {
        try withDatabase { db in
            let items = try db.keyspace("items")
            for i in 0..<5 {
                try items.insert("key-\(i)", "\(i)")
            }
            let snapshot = db.snapshot()
            try items.insert("key-9", "9")

            let ranged = try snapshot.range(
                in: items, from: .included("key-1"), to: .included("key-9")
            ).collect()
            #expect(ranged.map(\.keyString) == ["key-1", "key-2", "key-3", "key-4"])

            let prefixed = try snapshot.prefix("key-", in: items).collect()
            #expect(prefixed.count == 5)

            #expect(try snapshot.first(in: items)?.keyString == "key-0")
            #expect(try snapshot.last(in: items)?.keyString == "key-4")
        }
    }
}

@Suite struct KeyspaceManagement {
    @Test func createListDelete() throws {
        try withDatabase { db in
            let one = try db.keyspace("one")
            _ = try db.keyspace("two")

            #expect(db.keyspaceExists("one"))
            #expect(!db.keyspaceExists("nope"))
            #expect(db.keyspaceCount == 2)
            #expect(Set(db.keyspaceNames) == ["one", "two"])
            #expect(one.name == "one")

            try db.deleteKeyspace(one)
            #expect(!db.keyspaceExists("one"))
            #expect(db.keyspaceCount == 1)
        }
    }

    @Test func keyspaceOptions() throws {
        try withDatabase { db in
            let blobs = try db.keyspace(
                "blobs",
                options: .init(
                    maxMemtableSize: 8 * 1_024 * 1_024,
                    kvSeparation: KvSeparationOptions(separationThreshold: 1_024)
                )
            )
            let bigValue = Data(repeating: 0xAB, count: 100_000)
            try blobs.insert(Data("big".utf8), bigValue)
            #expect(try blobs.get(Data("big".utf8)) == bigValue)
        }
    }
}

@Suite struct Persistence {
    @Test func dataSurvivesReopen() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        do {
            let db = try Database(path: path)
            let items = try db.keyspace("items")
            try items.insert("persisted", "yes")
            try db.persist(.syncAll)
        }

        do {
            let db = try Database(path: path)
            #expect(db.keyspaceExists("items"))
            let items = try db.keyspace("items")
            #expect(try items.getString("persisted") == "yes")
        }
    }

    @Test func diskSpaceReporting() throws {
        try withDatabase { db in
            let items = try db.keyspace("items")
            try items.insert("a", "1")
            #expect(try db.diskSpace > 0)
            _ = items.diskSpace  // just exercise the accessor
            #expect(db.journalCount >= 1)
        }
    }
}
