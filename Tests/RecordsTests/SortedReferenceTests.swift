import CloudKit
import Foundation
@testable import Records
import Testing

@Record
struct Crate {
    var id: UUID
    var name: String
    @Reference(sort: \Disc.title) var discs: [Disc]
    @Reference(sort: [SortDescriptor(\Disc.year, order: .reverse)]) var newest: [Disc]
    @Reference(sort: \Disc.rating, order: .reverse) var rated: [Disc]
    @Reference(sort: SortDescriptor(\Disc.year)) var oldest: [Disc]
}

@Record
struct Disc: Equatable {
    var id: UUID
    var title: String
    var year: Int
    var rating: Int?
    /// A `from:` side that names a sorted property, so the two macros refer to each other.
    @Reference(from: \Crate.discs) var crateIDs: [UUID]
}

private func disc(_ title: String, _ year: Int, _ rating: Int? = nil) -> Disc {
    Disc(id: UUID(), title: title, year: year, rating: rating, crateIDs: [])
}

private let blue = disc("Blue", 1971, 5)
private let abbey = disc("Abbey Road", 1969)
private let kid = disc("Kid A", 2000, 4)

@Test func sortedReferencesReadInSortOrder() {
    let crate = Crate(id: UUID(), name: "Vinyl", discs: [blue, kid, abbey], newest: [blue, abbey, kid], rated: [abbey, kid, blue], oldest: [kid, abbey, blue])
    #expect(crate.discs.map(\.title) == ["Abbey Road", "Blue", "Kid A"])
    #expect(crate.newest.map(\.title) == ["Kid A", "Blue", "Abbey Road"])
    #expect(crate.rated.map(\.title).prefix(2) == ["Blue", "Kid A"])
    #expect(crate.oldest.map(\.title) == ["Abbey Road", "Blue", "Kid A"])
    #expect(crate.$discs.ids == [blue.id, kid.id, abbey.id]) // IDs aren't sorted
}

@Test func sortedReferencesWriteNoOrderKeys() {
    let crate = Crate(id: UUID(), name: "Vinyl", discs: [blue, kid], newest: [], rated: [], oldest: [])
    let links = CKRecordEncoder().links(for: crate, in: .records)
    #expect(links.count == 2)
    #expect(links.allSatisfy { $0["order"] == nil })
}

@Test func reorderingASortedReferenceChangesNothing() {
    var crate = Crate(id: UUID(), name: "Vinyl", discs: [blue, kid], newest: [], rated: [], oldest: [])
    let links = CKRecordEncoder().links(for: crate, in: .records)
    crate._discs.values = [kid, blue]
    #expect(CKRecordEncoder().changes(for: crate, from: links).isEmpty)
}

@Test func sortedReferencesRoundTrip() throws {
    let crate = Crate(id: UUID(), name: "Vinyl", discs: [kid, blue, abbey], newest: [], rated: [], oldest: [])
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
