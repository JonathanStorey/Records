import CloudKit
import Foundation
@testable import Records
import Testing

@Record
struct Crate {
    var name: String
    @Reference(sort: \Disc.title) var discs: [Disc]
    @Reference(sort: [SortDescriptor(\Disc.year, order: .reverse)]) var newest: [Disc]
    @Reference(sort: \Disc.rating, order: .reverse) var rated: [Disc]
    @Reference(sort: SortDescriptor(\Disc.year)) var oldest: [Disc]
}

@Record
struct Disc: Equatable {
    var title: String
    var year: Int
    var rating: Int?
    /// A `from:` side that names a sorted property, so the two macros refer to each other.
    @Reference(from: \Crate.discs) var crateIDs: [Crate.ID]
}

private func disc(_ title: String, _ year: Int, _ rating: Int? = nil) -> Disc {
    Disc(title: title, year: year, rating: rating, crateIDs: [])
}

private let blue = disc("Blue", 1971, 5)
private let abbey = disc("Abbey Road", 1969)
private let kid = disc("Kid A", 2000, 4)

@Test func sortedReferencesReadInSortOrder() {
    let crate = Crate(name: "Vinyl", discs: [blue, kid, abbey], newest: [blue, abbey, kid], rated: [abbey, kid, blue], oldest: [kid, abbey, blue])
    #expect(crate.discs.map(\.title) == ["Abbey Road", "Blue", "Kid A"])
    #expect(crate.newest.map(\.title) == ["Kid A", "Blue", "Abbey Road"])
    #expect(crate.rated.map(\.title).prefix(2) == ["Blue", "Kid A"])
    #expect(crate.oldest.map(\.title) == ["Abbey Road", "Blue", "Kid A"])
    #expect(crate.$discs.ids == [abbey.id, blue.id, kid.id], "the handle follows the sort")
    #expect(Array(crate.$newest) == [kid.id, blue.id, abbey.id])
}

// MARK: - The handle

@Test func theHandleHoldsTheSort() {
    let crate = Crate(name: "Vinyl", discs: [], newest: [], rated: [], oldest: [])
    #expect(crate.$discs.sortBy.count == 1)
    #expect(crate.$oldest.sortBy.count == 1)
    #expect(crate.$newest.sortBy.first?.order == .reverse)
}

@MainActor
@Test func aHandleWithoutLoadedRecordsListsIDsInIDOrder() throws {
    let context = try RecordContainer(for: Crate.self, sync: .inMemory).mainContext
    let crate = Crate(name: "Vinyl", discs: [blue, kid, abbey], newest: [], rated: [], oldest: [])
    context.insert(crate)
    try context.save()

    // Read as a record loaded inside another holds it: with IDs only.
    let key = RecordKey(recordType: Crate.recordType, name: crate.id.uuidString, zone: context.zone)
    let saved = try #require(try context.database.load(Crate.self, key: key))
    #expect(saved.discs.isEmpty)
    #expect(saved.$discs.ids == [blue.id, kid.id, abbey.id].sorted())
}

@MainActor
@Test func onDeleteOffsetsFollowTheSort() throws {
    let context = try RecordContainer(for: Crate.self, sync: .inMemory).mainContext
    let crate = Crate(name: "Vinyl", discs: [blue, kid, abbey], newest: [], rated: [], oldest: [])
    context.insert(crate)
    try context.save()

    let descriptor = RecordDescriptor<Crate>()
    var loaded = try #require(try context.fetch(descriptor).first)
    #expect(loaded.$discs.ids == loaded.discs.map(\.id))
    loaded.$discs.remove(atOffsets: IndexSet(integer: 0), in: context)   // the first by title
    #expect(loaded.discs.map(\.title) == ["Blue", "Kid A"])
    try context.save()

    #expect(try context.fetch(descriptor).first?.discs.map(\.title) == ["Blue", "Kid A"])
}

@Test func reorderingASortedReferenceChangesNothing() {
    var crate = Crate(name: "Vinyl", discs: [blue, kid], newest: [], rated: [], oldest: [])
    let links = CKRecordEncoder().links(for: crate, in: .records)
    crate._discs.values = [kid, blue]
    #expect(CKRecordEncoder().changes(for: crate, from: links).isEmpty)
}

@Test func sortedReferencesRoundTrip() throws {
    let crate = Crate(name: "Vinyl", discs: [kid, blue, abbey], newest: [], rated: [], oldest: [])
    let encoder = CKRecordEncoder()
    let links = encoder.links(for: crate, in: .records)
    let targets = [kid, blue, abbey].map { encoder.encode($0, in: .records) }

    let decoded = try CKRecordDecoder().decode(
        Crate.self, from: encoder.encode(crate, in: .records), links: links, targets: targets
    )
    #expect(decoded.discs.map(\.title) == ["Abbey Road", "Blue", "Kid A"])
    #expect(encoder.changes(for: decoded, from: links).isEmpty)

    let readBack = try CKRecordDecoder().decode(Disc.self, from: targets[0], links: links)
    #expect(readBack.crateIDs == [crate.id])
}
