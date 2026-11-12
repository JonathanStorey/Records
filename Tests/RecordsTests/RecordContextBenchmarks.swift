import Foundation
import Testing
@testable import Records

/// Rough timings for the context's synchronous operations, on an in-memory database. Each test
/// prints its time and fails only far above what the work should take, so slow CI machines
/// and debug builds don't make them flaky. They catch a change that makes an operation
/// dramatically slower, such as a lost index or a query per field.
@Suite(.serialized)
@MainActor
struct RecordContextBenchmarks {
    static let count = 1_000

    /// Runs `body` once and returns its time in milliseconds, printing it under `name`.
    @discardableResult
    func measure(_ name: String, _ body: () throws -> Void) rethrows -> Double {
        let clock = ContinuousClock()
        let elapsed = try clock.measure(body)
        let milliseconds = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3
        print("Benchmark \(name): \(String(format: "%.1f", milliseconds)) ms")
        return milliseconds
    }

    func venues() -> [Venue] {
        (0..<Self.count).map { index in
            Venue(
                id: UUID(), name: "Venue \(index)", mood: .calm, rating: .three,
                address: Address(street: "\(index) Main", city: "Springfield"), previous: nil, moods: [.calm]
            )
        }
    }

    @Test func insertAndSaveManyRecords() throws {
        let context = try RecordContainer(for: [Venue.self], url: nil).mainContext
        let venues = venues()
        let time = try measure("insert and save \(Self.count) records") {
            for venue in venues { context.insert(venue) }
            try context.save()
        }
        #expect(time < 5_000)
    }

    @Test func saveUnchangedRecords() throws {
        let context = try RecordContainer(for: [Venue.self], url: nil).mainContext
        let venues = venues()
        for venue in venues { context.insert(venue) }
        try context.save()
        let time = try measure("save \(Self.count) unchanged records") {
            for venue in venues { context.insert(venue) }
            try context.save()
        }
        #expect(time < 5_000)
    }

    @Test func saveEditedRecords() throws {
        let context = try RecordContainer(for: [Venue.self], url: nil).mainContext
        var venues = venues()
        for venue in venues { context.insert(venue) }
        try context.save()
        try context.database.run("UPDATE \"Venue\" SET \"_systemFields\" = x'00'", [])
        for index in venues.indices { venues[index].name += " edited" }
        let time = try measure("save \(Self.count) edited synced records") {
            for venue in venues { context.insert(venue) }
            try context.save()
        }
        #expect(time < 5_000)
    }

    @Test func lookUpByIDWithType() throws {
        let context = try RecordContainer(for: [Venue.self], url: nil).mainContext
        let venues = venues()
        for venue in venues { context.insert(venue) }
        try context.save()
        let time = try measure("look up \(Self.count) records with a type") {
            for venue in venues { _ = try context.record(id: venue.id, for: Venue.self) }
        }
        #expect(time < 5_000)
    }

    @Test func lookUpByIDWithoutType() throws {
        let context = try RecordContainer(for: [Venue.self, Page.self, Novel.self], url: nil).mainContext
        let venues = venues()
        for venue in venues { context.insert(venue) }
        try context.save()
        let time = try measure("look up \(Self.count) records without a type") {
            for venue in venues { _ = try context.record(id: venue.id) }
        }
        #expect(time < 5_000)
    }

    @Test func saveARecordWithManyLinks() throws {
        let context = try RecordContainer(for: [Page.self], url: nil).mainContext
        let labels = (0..<Self.count).map { Label(id: UUID(), name: "\($0)") }
        var page = Page(id: UUID(), title: "Notes", labels: labels)
        let time = try measure("save a record with \(Self.count) new linked records") {
            context.insert(page)
            try context.save()
        }
        #expect(time < 5_000)

        page._labels.values = Array(labels.reversed())
        let reorder = try measure("save a reversed list of \(Self.count) links") {
            context.insert(page)
            try context.save()
        }
        #expect(reorder < 5_000)
    }

    @Test func fetchEveryRecord() throws {
        let context = try RecordContainer(for: [Venue.self], url: nil).mainContext
        for venue in venues() { context.insert(venue) }
        try context.save()
        let time = try measure("fetch \(Self.count) records") {
            let count = try context.fetch(RecordDescriptor<Venue>()).count
            #expect(count == Self.count)
        }
        #expect(time < 5_000)
    }

    @Test func fetchWithPredicateAndSort() throws {
        let context = try RecordContainer(for: [Venue.self], url: nil).mainContext
        for venue in venues() { context.insert(venue) }
        try context.save()
        let descriptor = RecordDescriptor<Venue>(
            predicate: #Predicate { $0.name.contains("9") },
            sortBy: [SortDescriptor(\.name)],
            fetchLimit: 50
        )
        let time = try measure("fetch \(Self.count) records with a predicate, sort, and limit") {
            let count = try context.fetch(descriptor).count
            #expect(count == 50)
        }
        #expect(time < 5_000)
    }

    @Test func fetchOneRecordByAPredicateTheDatabaseChecks() throws {
        let context = try RecordContainer(for: [Venue.self], url: nil).mainContext
        for venue in venues() { context.insert(venue) }
        try context.save()
        let descriptor = RecordDescriptor<Venue>(predicate: #Predicate { $0.name == "Venue 500" })
        let time = try measure("fetch 1 of \(Self.count) records by a predicate the database checks") {
            let count = try context.fetch(descriptor).count
            #expect(count == 1)
        }
        #expect(time < 5_000)
    }

    @Test func fetchTheFirstRecordsSortedByTheDatabase() throws {
        let context = try RecordContainer(for: [Gauge.self], url: nil).mainContext
        for index in 0..<Self.count {
            context.insert(Gauge(
                id: UUID(), name: "\(index)", level: Double(index), steps: (index * 7919) % Self.count, limit: 0,
                checkedAt: .now, isOn: index.isMultiple(of: 2), mood: .calm, rating: nil, nickname: nil
            ))
        }
        try context.save()
        let descriptor = RecordDescriptor<Gauge>(
            predicate: #Predicate { $0.isOn }, sortBy: [SortDescriptor(\.steps)], fetchLimit: 50
        )
        let fetchTime = try measure("fetch the first 50 of \(Self.count) records sorted by the database") {
            let count = try context.fetch(descriptor).count
            #expect(count == 50)
        }
        let countTime = try measure("count \(Self.count / 2) of \(Self.count) records in the database") {
            let count = try context.fetchCount(RecordDescriptor<Gauge>(predicate: #Predicate { $0.isOn }))
            #expect(count == Self.count / 2)
        }
        #expect(fetchTime < 5_000)
        #expect(countTime < 5_000)
    }

    @Test func fetchThroughAReference() throws {
        let context = try RecordContainer(for: [LP.self], url: nil).mainContext
        let musicians = (0..<10).map { Musician(id: UUID(), name: "Musician \($0)", isActive: true) }
        for index in 0..<Self.count {
            context.insert(LP(id: UUID(), title: "\(index)", year: 2000, musician: musicians[index % 10], cuts: []))
        }
        try context.save()

        let exact = RecordDescriptor<LP>(predicate: #Predicate { $0.musician?.isActive == true && $0.year == 2000 })
        let inDatabase = try measure("fetch \(Self.count) records through a reference, checked in the database") {
            let count = try context.fetch(exact).count
            #expect(count == Self.count)
        }
        let loose = RecordDescriptor<LP>(predicate: #Predicate { $0.musician?.name.contains("3") == true })
        let inSwift = try measure("fetch 100 of \(Self.count) records through a reference, checked in Swift") {
            let count = try context.fetch(loose).count
            #expect(count == Self.count / 10)
        }
        #expect(inDatabase < 5_000)
        #expect(inSwift < 5_000)
    }

    @Test func fetchRecordsWithLinks() throws {
        let context = try RecordContainer(for: [Page.self], url: nil).mainContext
        let labels = (0..<10).map { Label(id: UUID(), name: "\($0)") }
        for index in 0..<Self.count {
            context.insert(Page(id: UUID(), title: "\(index)", labels: labels))
        }
        try context.save()
        let time = try measure("fetch \(Self.count) records with 10 links each") {
            let count = try context.fetch(RecordDescriptor<Page>()).count
            #expect(count == Self.count)
        }
        #expect(time < 5_000)
    }
}
