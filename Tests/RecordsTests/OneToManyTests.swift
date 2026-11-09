import CloudKit
import Testing
@testable import Records

// Two-way one-to-many, owned by either side.

/// Owned by the many side: each book writes its own link. The `from:` side holds IDs.
@Record
struct Shelf: Equatable {
    var id: UUID
    var name: String
    @Reference(from: \Book.shelf) var bookIDs: [UUID]
}

@Record
struct Book: Equatable {
    var id: UUID
    var title: String
    @Reference var shelf: Shelf?
}

/// Owned by the one side: the album orders its tracks, and a track is deleted with its album.
@Record
struct Album: Equatable {
    var id: UUID
    @Reference var tracks: [Track]
}

@Record
struct Track: Equatable {
    var id: UUID
    var title: String
    @Reference(from: \Album.tracks, deleteSelf: true) var albumID: UUID?
}

/// Pointing at its own type, with IDs on the `from:` side.
@Record
struct Staff: Equatable {
    var id: UUID
    var name: String
    @Reference var manager: Staff?
    @Reference(from: \Staff.manager) var reportIDs: [UUID]
}

private let encoder = CKRecordEncoder()
private let decoder = CKRecordDecoder()

private func link(_ record: CKRecord) throws -> RecordLink {
    try decoder.decode(RecordLink.self, from: record)
}

private func makeShelf(_ name: String = "Fiction") -> Shelf {
    Shelf(id: UUID(), name: name, bookIDs: [])
}

// MARK: - Owned by the many side

@Test func manySideWritesTheLinks() throws {
    let shelf = makeShelf()
    let books = ["Dune", "Emma"].map { Book(id: UUID(), title: $0, shelf: shelf) }
    let links = try books.flatMap { encoder.linksToSave(for: $0, in: .records) }.map(link)

    #expect(links.count == 2)
    #expect(links.allSatisfy { $0.relationship == "Book.shelf:Shelf <-> Shelf.bookIDs:[Book]" })
    #expect(try links.allSatisfy { try $0.kind == .manyToOne })
    #expect(links.allSatisfy { !$0.deleteSelf && $0.targetName == shelf.id.uuidString })
    #expect(encoder.linksToSave(for: shelf, in: .records).isEmpty)
}

@Test func addingAToManyInverseKeepsLinkIDs() {
    let sourceID = UUID(), targetID = UUID()
    let oneWay = ReferenceState(
        property: "shelf", targetType: "Shelf", isToMany: false, inverse: nil, targets: [], loaded: []
    )
    let twoWay = ReferenceState(
        property: "shelf", targetType: "Shelf", isToMany: false,
        inverse: Inverse(many: \Book.shelf, to: Shelf.self, property: "bookIDs"), targets: [], loaded: []
    )
    #expect(
        RecordLink.id(reference: oneWay, sourceType: "Book", sourceID: sourceID, targetID: targetID)
            == RecordLink.id(reference: twoWay, sourceType: "Book", sourceID: sourceID, targetID: targetID)
    )
}

@Test func oneSideDecodesItsOwners() throws {
    let shelf = makeShelf()
    let books = ["Dune", "Emma"].map { Book(id: UUID(), title: $0, shelf: shelf) }
    let links = books.flatMap { encoder.linksToSave(for: $0, in: .records) }
    let bookRecords = books.map { encoder.encode($0, in: .records) }
    let shelfRecord = encoder.encode(shelf, in: .records)

    let shelfAgain = try decoder.decode(Shelf.self, from: shelfRecord, links: links, targets: bookRecords)
    #expect(Set(shelfAgain.bookIDs) == Set(books.map(\.id)))
    #expect(encoder.linksToSave(for: shelfAgain, in: .records).isEmpty)

    let bookAgain = try decoder.decode(Book.self, from: bookRecords[0], links: links, targets: [shelfRecord])
    #expect(bookAgain.shelf?.name == "Fiction")
    #expect(Set(bookAgain.shelf?.bookIDs ?? []) == Set(books.map(\.id)))
}

@Test func movingABookMovesItBetweenShelves() throws {
    let first = makeShelf("Fiction"), second = makeShelf("History")
    var book = Book(id: UUID(), title: "Dune", shelf: first)
    let original = encoder.linksToSave(for: book, in: .records)
    book.markReferencesSaved()

    book.shelf = second
    let moved = encoder.linksToSave(for: book, in: .records)
    #expect(moved.map(\.recordID) == original.map(\.recordID))
    #expect(encoder.linkIDsToDelete(for: book, in: .records).isEmpty)

    let firstAgain = try decoder.decode(Shelf.self, from: encoder.encode(first, in: .records), links: moved)
    let secondAgain = try decoder.decode(Shelf.self, from: encoder.encode(second, in: .records), links: moved)
    #expect(firstAgain.bookIDs.isEmpty)
    #expect(secondAgain.bookIDs == [book.id])
}

// MARK: - Owned by the one side

@Test func oneSideWritesOrderedLinks() throws {
    let tracks = ["Intro", "Song", "Outro"].map { Track(id: UUID(), title: $0, albumID: nil) }
    let album = Album(id: UUID(), tracks: tracks)
    let links = encoder.linksToSave(for: album, in: .records)
    let read = try links.map(link)

    #expect(read.count == 3)
    #expect(read.allSatisfy { $0.relationship == "Album.tracks:[Track] <-> Track.albumID:Album" })
    #expect(try read.allSatisfy { try $0.kind == .oneToMany })
    #expect(read.allSatisfy { $0.deleteSelf })
    #expect(Track.deleteSelfReferences == ["albumID"])
    #expect(tracks.allSatisfy { encoder.linksToSave(for: $0, in: .records).isEmpty })

    let trackRecords = tracks.map { encoder.encode($0, in: .records) }
    let albumRecord = encoder.encode(album, in: .records)
    let albumAgain = try decoder.decode(Album.self, from: albumRecord, links: links, targets: trackRecords)
    #expect(albumAgain.tracks.map(\.title) == ["Intro", "Song", "Outro"])
    #expect(albumAgain.tracks.allSatisfy { $0.albumID == album.id })

    let trackAgain = try decoder.decode(Track.self, from: trackRecords[1], links: links, targets: [albumRecord])
    #expect(trackAgain.albumID == album.id)
}

@Test func aTrackBelongsToOneAlbum() {
    let track = Track(id: UUID(), title: "Song", albumID: nil)
    let first = Album(id: UUID(), tracks: [track])
    let second = Album(id: UUID(), tracks: [track])

    // One-to-many links leave out the owner, so adding the track to a second album
    // overwrites its link to the first.
    #expect(
        encoder.linksToSave(for: first, in: .records).map(\.recordID)
            == encoder.linksToSave(for: second, in: .records).map(\.recordID)
    )
}

// MARK: - Self-reference

@Test func managersReadTheirReportsIDs() throws {
    let boss = Staff(id: UUID(), name: "Ada", manager: nil, reportIDs: [])
    let reports = ["Grace", "Linus"].map { Staff(id: UUID(), name: $0, manager: boss, reportIDs: []) }
    let links = reports.flatMap { encoder.linksToSave(for: $0, in: .records) }
    #expect(try links.map { try link($0).relationship } == Array(repeating: "Staff.manager:Staff <-> Staff.reportIDs:[Staff]", count: 2))

    let bossRecord = encoder.encode(boss, in: .records)
    let bossAgain = try decoder.decode(Staff.self, from: bossRecord, links: links)
    #expect(bossAgain.manager == nil)
    #expect(Set(bossAgain.reportIDs) == Set(reports.map(\.id)))

    let reportAgain = try decoder.decode(
        Staff.self, from: encoder.encode(reports[0], in: .records), links: links, targets: [bossRecord]
    )
    #expect(reportAgain.manager?.name == "Ada")
    #expect(reportAgain.reportIDs.isEmpty)
    #expect(Set(reportAgain.manager?.reportIDs ?? []) == Set(reports.map(\.id)))
}
