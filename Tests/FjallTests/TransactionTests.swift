import Foundation
import Testing

@testable import Fjall

private func tempPath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("fjall-swift-tx-tests-\(UUID().uuidString)")
        .path
}

@Suite struct SingleWriterTransactions {
    private func makeDB() throws -> (TxDatabase, TxKeyspace) {
        let db = try TxDatabase(path: tempPath(), options: .init(temporary: true))
        let items = try db.keyspace("items")
        return (db, items)
    }

    @Test func directKeyspaceOperations() throws {
        let (_, items) = try makeDB()

        try items.insert("a", "1")
        #expect(try items.getString("a") == "1")
        #expect(try items.containsKey("a"))
        #expect(try items.size(of: "a") == 1)
        #expect(items.approximateCount >= 1)

        #expect(try items.take("a") == Data("1".utf8))
        #expect(try items.getString("a") == nil)
        #expect(try items.take("a") == nil)
    }

    @Test func commitMakesWritesVisibleAtomically() throws {
        let (db, items) = try makeDB()

        let tx = try db.writeTransaction()
        try tx.insert("x", "1", into: items)
        try tx.insert("y", "2", into: items)

        // Read-your-own-writes inside the transaction...
        #expect(try tx.getString("x", in: items) == "1")
        #expect(try tx.count(of: items) == 2)
        // ...but nothing visible outside yet.
        #expect(try items.getString("x") == nil)

        try tx.commit()
        #expect(try items.getString("x") == "1")
        #expect(try items.getString("y") == "2")

        // The transaction cannot be reused.
        #expect(throws: FjallError.transactionConsumed) {
            try tx.commit()
        }
        #expect(throws: FjallError.transactionConsumed) {
            try tx.insert("z", "3", into: items)
        }
    }

    @Test func rollbackDiscardsWrites() throws {
        let (db, items) = try makeDB()

        let tx = try db.writeTransaction()
        try tx.insert("x", "1", into: items)
        try tx.rollback()
        #expect(try items.getString("x") == nil)
    }

    @Test func scopedWriteCommits() throws {
        let (db, items) = try makeDB()

        let result = try db.write { tx in
            try tx.insert("counter", "41", into: items)
            let value = try tx.getString("counter", in: items)!
            try tx.insert("counter", String(Int(value)! + 1), into: items)
            return Int(value)! + 1
        }
        #expect(result == 42)
        #expect(try items.getString("counter") == "42")
    }

    @Test func scopedWriteRollsBackOnError() throws {
        let (db, items) = try makeDB()
        struct Boom: Error {}

        #expect(throws: Boom.self) {
            try db.write { tx in
                try tx.insert("x", "1", into: items)
                throw Boom()
            }
        }
        #expect(try items.getString("x") == nil)
    }

    @Test func discardedTransactionReleasesTheWriteLock() throws {
        let (db, items) = try makeDB()

        do {
            let tx = try db.writeTransaction()
            try tx.insert("dropped", "1", into: items)
            // Discarded without commit: rolls back and releases the lock.
        }

        // If the lock were still held, this would block forever.
        try db.write { tx in
            #expect(try tx.getString("dropped", in: items) == nil)
            try tx.insert("kept", "1", into: items)
        }
        #expect(try items.getString("kept") == "1")
    }

    @Test func transactionIteration() throws {
        let (db, items) = try makeDB()
        try items.insert("committed", "0")

        let tx = try db.writeTransaction()
        try tx.insert("staged-a", "1", into: items)
        try tx.insert("staged-b", "2", into: items)

        let all = try tx.iter(items, batchSize: 1).collect()
        #expect(all.map(\.keyString) == ["committed", "staged-a", "staged-b"])

        let staged = try tx.prefix("staged-", in: items).collect()
        #expect(staged.count == 2)

        let ranged = try tx.range(in: items, from: .included("staged-b")).collect()
        #expect(ranged.map(\.keyString) == ["staged-b"])

        #expect(try tx.first(in: items)?.keyString == "committed")
        #expect(try tx.last(in: items)?.keyString == "staged-b")
        try tx.rollback()
    }

    @Test func readTransactionIsASnapshot() throws {
        let (db, items) = try makeDB()
        try items.insert("before", "1")

        let read = db.readTransaction()
        try items.insert("after", "2")

        #expect(try read.getString("before", in: items) == "1")
        #expect(try read.getString("after", in: items) == nil)
        #expect(try read.count(of: items) == 1)
        #expect(try read.iter(items).collect().map(\.keyString) == ["before"])
    }
}

@Suite struct OptimisticTransactions {
    private func makeDB() throws -> (OptimisticTxDatabase, OptimisticTxKeyspace) {
        let db = try OptimisticTxDatabase(path: tempPath(), options: .init(temporary: true))
        let items = try db.keyspace("items")
        return (db, items)
    }

    @Test func commitWithoutConflict() throws {
        let (db, items) = try makeDB()

        let tx = try db.writeTransaction()
        try tx.insert("a", "1", into: items)
        #expect(try tx.getString("a", in: items) == "1")
        #expect(try items.getString("a") == nil)
        try tx.commit()
        #expect(try items.getString("a") == "1")
    }

    @Test func conflictingCommitThrows() throws {
        let (db, items) = try makeDB()
        try items.insert("counter", "0")

        // Two transactions read-modify-write the same key.
        let tx1 = try db.writeTransaction()
        let tx2 = try db.writeTransaction()
        let v1 = try tx1.getString("counter", in: items)!
        let v2 = try tx2.getString("counter", in: items)!
        try tx1.insert("counter", v1 + "+1", into: items)
        try tx2.insert("counter", v2 + "+2", into: items)

        try tx2.commit()
        #expect(throws: FjallError.conflict) {
            try tx1.commit()
        }
        #expect(try items.getString("counter") == "0+2")
    }

    @Test func scopedWriteRetriesConflicts() throws {
        let (db, items) = try makeDB()
        try items.insert("counter", "0")

        // Sabotage the first attempt by committing a competing write
        // after the body has read the key.
        var attempt = 0
        let result = try db.write(attempts: 3) { tx in
            attempt += 1
            let value = try tx.getString("counter", in: items)!
            if attempt == 1 {
                let competing = try db.writeTransaction()
                let v = try competing.getString("counter", in: items)!
                try competing.insert("counter", v + "!", into: items)
                try competing.commit()
            }
            try tx.insert("counter", value + "+1", into: items)
            return value
        }

        #expect(attempt == 2)
        #expect(result == "0!")
        #expect(try items.getString("counter") == "0!+1")
    }

    @Test func directKeyspaceOperations() throws {
        let (_, items) = try makeDB()

        try items.insert("a", "1")
        #expect(try items.getString("a") == "1")
        #expect(try items.take("a") == Data("1".utf8))
        #expect(try items.getString("a") == nil)
    }

    @Test func snapshotReadsThroughTxKeyspace() throws {
        let (db, items) = try makeDB()
        try items.insert("before", "1")

        let read = db.readTransaction()
        try items.insert("after", "2")

        #expect(try read.getString("before", in: items) == "1")
        #expect(try read.containsKey("after", in: items) == false)
    }
}
