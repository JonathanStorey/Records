import CloudKit
import Testing
@testable import Records

// Two-way one-to-many, owned by either side.

/// Owned by the many side: each book writes its own link. The `from:` side holds IDs.
@Record
struct Shelf: Equatable {
    var name: String
    @Reference(from: \Book.shelf) var bookIDs: [Book.ID]
}

@Record
struct Book: Equatable {
    var title: String
    @Reference var shelf: Shelf?
}

/// Owned by the one side: the album orders its tracks, and a track is deleted with its album.
@Record
struct Release: Equatable {
    @Reference var tracks: [Song]
}

@Record
struct Song: Equatable {
    var title: String
    @Reference(from: \Release.tracks, deleteSelf: true) var albumID: Release.ID?
}

/// Pointing at its own type, with IDs on the `from:` side.
@Record
struct Staff: Equatable {
    var name: String
    @Reference var manager: Staff?
    @Reference(from: \Staff.manager) var reportIDs: [Staff.ID]
}

private let encoder = CKRecordEncoder()
private let decoder = CKRecordDecoder()

private func link(_ record: CKRecord) throws -> RecordLink {
    try decoder.decode(RecordLink.self, from: record)
}

private func makeShelf(_ name: String = "Fiction") -> Shelf {
    Shelf(name: name, bookIDs: [])
}

// MARK: - Owned by the many side

@Test func manySideWritesTheLinks() throws {
    let shelf = makeShelf()
    let books = ["Dune", "Emma"].map { Book(title: $0, shelf: shelf) }
    let links = try books.flatMap { encoder.links(for: $0, in: .records) }.map(link)

    #expect(links.count == 2)
    #expect(links.allSatisfy { $0.source == "Book.shelf" })
    #expect(signatures(of: books[0]) == ["Book.shelf:Shelf <-> Shelf.bookIDs:[Book]"])
    #expect(Relationship(books[0].referenceStates[0]) == .manyToOne)
    #expect(links.allSatisfy { $0.targetName == shelf.id.uuidString })
    #expect(encoder.links(for: shelf, in: .records).isEmpty)
}

@Test func oneSideDecodesItsOwners() throws {
    let shelf = makeShelf()
    let books = ["Dune", "Emma"].map { Book(title: $0, shelf: shelf) }
    let links = books.flatMap { encoder.links(for: $0, in: .records) }
    let bookRecords = books.map { encoder.encode($0, in: .records) }
    let shelfRecord = encoder.encode(shelf, in: .records)

    let shelfAgain = try decoder.decode(Shelf.self, from: shelfRecord, links: links, targets: bookRecords)
    #expect(Set(shelfAgain.bookIDs) == Set(books.map(\.id)))
    #expect(encoder.links(for: shelfAgain, in: .records).isEmpty)

    let bookAgain = try decoder.decode(Book.self, from: bookRecords[0], links: links, targets: [shelfRecord])
    #expect(bookAgain.shelf?.name == "Fiction")
    #expect(Set(bookAgain.shelf?.bookIDs ?? []) == Set(books.map(\.id)))
}

@Test func movingABookMovesItBetweenShelves() throws {
    let first = makeShelf("Fiction"), second = makeShelf("History")
    var book = Book(title: "Dune", shelf: first)
    let original = encoder.links(for: book, in: .records)

    book._shelf.value = second
    let changes = encoder.changes(for: book, from: original)
    let moved = changes.saves
    #expect(moved.map(\.recordID) == original.map(\.recordID))
    #expect(changes.deletes.isEmpty)

    let firstAgain = try decoder.decode(Shelf.self, from: encoder.encode(first, in: .records), links: moved)
    let secondAgain = try decoder.decode(Shelf.self, from: encoder.encode(second, in: .records), links: moved)
    #expect(firstAgain.bookIDs.isEmpty)
    #expect(secondAgain.bookIDs == [book.id])
}

// MARK: - Owned by the one side

@Test func oneSideWritesALinkPerMember() throws {
    let tracks = ["Intro", "Song", "Outro"].map { Song(title: $0, albumID: nil) }
    let album = Release(tracks: tracks)
    let links = encoder.links(for: album, in: .records)
    let read = try links.map(link)

    #expect(read.count == 3)
    #expect(read.allSatisfy { $0.source == "Release.tracks" })
    #expect(signatures(of: album) == ["Release.tracks:[Song] <-> Song.albumID:Release"])
    #expect(Relationship(album.referenceStates[0]) == .oneToMany)
    #expect(Song.schema.references.filter(\.deleteSelf).map(\.property) == ["albumID"])
    #expect(tracks.allSatisfy { encoder.links(for: $0, in: .records).isEmpty })

    let trackRecords = tracks.map { encoder.encode($0, in: .records) }
    let albumRecord = encoder.encode(album, in: .records)
    let albumAgain = try decoder.decode(Release.self, from: albumRecord, links: links, targets: trackRecords)
    #expect(albumAgain.tracks.map(\.title) == ["Intro", "Song", "Outro"])
    #expect(albumAgain.tracks.allSatisfy { $0.albumID == album.id })

    let trackAgain = try decoder.decode(Song.self, from: trackRecords[1], links: links, targets: [albumRecord])
    #expect(trackAgain.albumID == album.id)
}

@Test func aTrackBelongsToOneAlbum() {
    let track = Song(title: "Song", albumID: nil)
    let first = Release(tracks: [track])
    let second = Release(tracks: [track])

    // One-to-many links leave out the owner, so adding the track to a second album
    // overwrites its link to the first.
    #expect(
        encoder.links(for: first, in: .records).map(\.recordID)
            == encoder.links(for: second, in: .records).map(\.recordID)
    )
}

// MARK: - Self-reference

@Test func managersReadTheirReportsIDs() throws {
    let boss = Staff(name: "Ada", manager: nil, reportIDs: [])
    let reports = ["Grace", "Linus"].map { Staff(name: $0, manager: boss, reportIDs: []) }
    let links = reports.flatMap { encoder.links(for: $0, in: .records) }
    #expect(try links.map { try link($0).source } == ["Staff.manager", "Staff.manager"])
    #expect(signatures(of: reports[0]) == ["Staff.manager:Staff <-> Staff.reportIDs:[Staff]"])

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
