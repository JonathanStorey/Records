import CloudKit
import CryptoKit
import Foundation
import Testing
@testable import Records

// A music library that uses every kind of reference, saved to CKRecords and read back.
//
//   Artist  ◀── Album.artist ──── Album ──── Album.tracks (ordered) ───▶ Track
//     ▲                            │  │                                    │ │ │
//     └── Track.featuring ─────────┼──┼────────────────────────────────────┘ │ │
//                                  │  └─ Album.cover ─▶ Artwork             │ │
//          Genre ◀── Album.genreID ┘                    Tag ◀── Track.tags ─┘ │
//          (Genre.parentID)                             Track.remixOf ────────┘
//
//   Listener ◀── Playlist.curator ── Playlist ── Playlist.tracks (ordered) ──▶ Track
//   (Listener.favorite, followingIDs)  (Playlist.folderID)

// MARK: - Model

@Record
struct Artist: Equatable {
    var id: UUID
    var name: String
    /// Two-way one-to-many, read side: the albums whose `artist` is this artist.
    @Reference(from: \Album.artist) var albumIDs: [UUID]
}

@Record
struct Album: Equatable {
    var id: UUID
    var title: String
    var year: Int
    /// Two-way, owned by the many side: each album writes one link.
    @Reference var artist: Artist?
    /// Two-way one-to-many, owned by the one side: ordered, and tracks are deleted with the album.
    @Reference var tracks: [Track]
    /// Two-way one-to-one: the artwork is deleted with the album.
    @Reference var cover: Artwork?
    /// One-way, holding only the ID.
    @Reference(Genre.self) var genreID: UUID?
}

@Record
struct Artwork: Equatable {
    var id: UUID
    var url: String
    @Reference(from: \Album.cover, deleteSelf: true) var albumID: UUID?
}

@Record
struct Track: Equatable {
    var id: UUID
    var title: String
    var seconds: Int
    @Reference(from: \Album.tracks, deleteSelf: true) var albumID: UUID?
    /// One-way many-to-many, ordered.
    @Reference var tags: [Tag]
    /// One-way many-to-many to a type that has its own two-way relationship with `Album`.
    @Reference var featuring: [Artist]
    /// One-way to-one pointing at its own type.
    @Reference var remixOf: Track?
    /// Two-way many-to-many, read side: the playlists that hold this track.
    @Reference(from: \Playlist.tracks) var playlistIDs: [UUID]
}

@Record
struct Tag: Equatable {
    var id: UUID
    var name: String
}

@Record
struct Genre: Equatable {
    var id: UUID
    var name: String
    /// One-way to-one pointing at its own type, holding only the ID.
    @Reference(Genre.self) var parentID: UUID?
}

@Record
struct Playlist: Equatable {
    var id: UUID
    var name: String
    @Reference var curator: Listener?
    /// Two-way many-to-many, owning side: ordered by hand.
    @Reference var tracks: [Track]
    @Reference(Playlist.self) var folderID: UUID?
}

@Record
struct Listener: Equatable {
    var id: UUID
    var name: String
    @Reference(from: \Playlist.curator) var playlistIDs: [UUID]
    @Reference var favorite: Track?
    /// One-way many-to-many pointing at its own type, holding only IDs.
    @Reference(Listener.self) var followingIDs: [UUID]
}

// MARK: - Library

/// A stable ID per name, so records can name each other before they exist.
private func uid(_ name: String) -> UUID {
    let b = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
    return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
}

/// CKRecords saved by `CKRecordEncoder`, standing in for a zone.
private struct Saved {
    var records: [CKRecord.ID: CKRecord] = [:]

    var links: [CKRecord] { records.values.filter { $0.recordType == RecordLink.recordType } }
    var count: Int { records.count - links.count }

    mutating func save<R: Record>(_ record: inout R) {
        let encoder = CKRecordEncoder()
        let ckRecord = encoder.encode(record, in: .records)
        records[ckRecord.recordID] = ckRecord
        for link in encoder.linksToSave(for: record, in: .records) { records[link.recordID] = link }
        for id in encoder.linkIDsToDelete(for: record, in: .records) { records[id] = nil }
        record.markReferencesSaved()
    }

    func load<R: Record>(_ type: R.Type, _ id: UUID, depth: Int = 1) throws -> R {
        let record = try #require(records[CKRecord.ID(recordName: id.uuidString, zoneID: Zone.records.zoneID)])
        return try CKRecordDecoder().decode(type, from: record, links: links, targets: Array(records.values), depth: depth)
    }
}

private struct Library {
    let energetic = Tag(id: uid("energetic"), name: "energetic")
    let mellow = Tag(id: uid("mellow"), name: "mellow")
    let live = Tag(id: uid("live"), name: "live")
    let acoustic = Tag(id: uid("acoustic"), name: "acoustic")

    let rock = Genre(id: uid("rock"), name: "Rock", parentID: nil)
    let indie = Genre(id: uid("indie"), name: "Indie Rock", parentID: uid("rock"))
    let folk = Genre(id: uid("folk"), name: "Folk", parentID: nil)

    let nova = Artist(id: uid("nova"), name: "Nova Static", albumIDs: [uid("signal"), uid("orbit")])
    let paper = Artist(id: uid("paper"), name: "Paper Lanterns", albumIDs: [uid("harbor")])
    let juno = Artist(id: uid("juno"), name: "Juno Vale", albumIDs: [])

    let signalArt = Artwork(id: uid("signal-art"), url: "https://example.com/signal.jpg", albumID: uid("signal"))
    let harborArt = Artwork(id: uid("harbor-art"), url: "https://example.com/harbor.jpg", albumID: uid("harbor"))

    let ignition: Track
    let bloom: Track
    let afterglow: Track
    let lowOrbit: Track
    let orbitMix: Track
    let harborLights: Track

    let signal: Album
    let orbit: Album
    let harbor: Album

    let sam = Listener(id: uid("sam"), name: "Sam", playlistIDs: [uid("road"), uid("evening")], favorite: nil, followingIDs: [])
    let riley: Listener

    let road: Playlist
    let evening: Playlist

    init() {
        ignition = Track(
            id: uid("ignition"), title: "Ignition", seconds: 201, albumID: uid("signal"),
            tags: [energetic, live], featuring: [], remixOf: nil, playlistIDs: [uid("road")]
        )
        bloom = Track(
            id: uid("bloom"), title: "Static Bloom", seconds: 245, albumID: uid("signal"),
            tags: [mellow], featuring: [juno], remixOf: nil, playlistIDs: [uid("evening")]
        )
        afterglow = Track(
            id: uid("afterglow"), title: "Afterglow", seconds: 312, albumID: uid("signal"),
            tags: [], featuring: [], remixOf: nil, playlistIDs: []
        )
        lowOrbit = Track(
            id: uid("low-orbit"), title: "Low Orbit", seconds: 188, albumID: uid("orbit"),
            tags: [energetic], featuring: [], remixOf: nil, playlistIDs: [uid("road")]
        )
        orbitMix = Track(
            id: uid("orbit-mix"), title: "Ignition (Orbit Mix)", seconds: 276, albumID: uid("orbit"),
            tags: [], featuring: [], remixOf: ignition, playlistIDs: []
        )
        harborLights = Track(
            id: uid("harbor-lights"), title: "Harbor Lights", seconds: 230, albumID: uid("harbor"),
            tags: [mellow, acoustic], featuring: [juno, nova], remixOf: nil, playlistIDs: [uid("road"), uid("evening")]
        )

        signal = Album(
            id: uid("signal"), title: "Signal Fires", year: 2019, artist: nova,
            tracks: [ignition, bloom, afterglow], cover: signalArt, genreID: indie.id
        )
        orbit = Album(
            id: uid("orbit"), title: "Low Orbit", year: 2022, artist: nova,
            tracks: [lowOrbit, orbitMix], cover: nil, genreID: rock.id
        )
        harbor = Album(
            id: uid("harbor"), title: "Harbor Lights", year: 2021, artist: paper,
            tracks: [harborLights], cover: harborArt, genreID: folk.id
        )

        riley = Listener(id: uid("riley"), name: "Riley", playlistIDs: [], favorite: afterglow, followingIDs: [sam.id])

        road = Playlist(id: uid("road"), name: "Road Trip", curator: sam, tracks: [lowOrbit, ignition, harborLights], folderID: nil)
        evening = Playlist(id: uid("evening"), name: "Evening", curator: sam, tracks: [bloom, harborLights], folderID: road.id)
    }

    var tags: [Tag] { [energetic, mellow, live, acoustic] }
    var genres: [Genre] { [rock, indie, folk] }
    var artists: [Artist] { [nova, paper, juno] }
    var artworks: [Artwork] { [signalArt, harborArt] }
    var tracks: [Track] { [ignition, bloom, afterglow, lowOrbit, orbitMix, harborLights] }
    var albums: [Album] { [signal, orbit, harbor] }
    var listeners: [Listener] { [sam, riley] }
    var playlists: [Playlist] { [road, evening] }

    /// Every record and every link, saved.
    func saved() -> Saved {
        var saved = Saved()
        func save<R: Record>(_ records: [R]) {
            for var record in records { saved.save(&record) }
        }
        save(tags); save(genres); save(artists); save(artworks)
        save(tracks); save(albums); save(listeners); save(playlists)
        return saved
    }
}

// MARK: - Checks

/// The same IDs, ignoring order. A `from:` side lists its owners by when their links were created.
private func sameIDs(_ lhs: [UUID], _ rhs: [UUID]) -> Bool {
    lhs.count == rhs.count && Set(lhs) == Set(rhs)
}

private func hasNoChanges(_ record: some Record) -> Bool {
    let encoder = CKRecordEncoder()
    return encoder.linksToSave(for: record, in: .records).isEmpty
        && encoder.linkIDsToDelete(for: record, in: .records).isEmpty
}

private func expectSame(_ decoded: Artist, _ original: Artist) {
    #expect(decoded.id == original.id && decoded.name == original.name)
    #expect(sameIDs(decoded.albumIDs, original.albumIDs))
}

private func expectSame(_ decoded: Track, _ original: Track) {
    #expect(decoded.id == original.id && decoded.title == original.title && decoded.seconds == original.seconds)
    #expect(decoded.albumID == original.albumID)
    #expect(decoded._tags == original._tags)
    #expect(decoded._featuring == original._featuring)
    #expect(decoded._remixOf == original._remixOf)
    #expect(sameIDs(decoded.playlistIDs, original.playlistIDs))
}

private func expectSame(_ decoded: Listener, _ original: Listener) {
    #expect(decoded.id == original.id && decoded.name == original.name)
    #expect(decoded._favorite == original._favorite)
    #expect(decoded.followingIDs == original.followingIDs)
    #expect(sameIDs(decoded.playlistIDs, original.playlistIDs))
}

// MARK: - Links

@Test func everyRelationshipWritesItsLinks() throws {
    let saved = Library().saved()
    let links = try saved.links.map { try CKRecordDecoder().decode(RecordLink.self, from: $0) }

    var counts: [String: Int] = [:]
    for link in links { counts[link.relationship, default: 0] += 1 }
    #expect(counts == [
        "Album.artist:Artist <-> Artist.albumIDs:[Album]": 3,
        "Album.tracks:[Track] <-> Track.albumID:Album": 6,
        "Album.cover:Artwork <-> Artwork.albumID:Album": 2,
        "Album.genreID:Genre": 3,
        "Track.tags:[Tag]": 6,
        "Track.featuring:[Artist]": 3,
        "Track.remixOf:Track": 1,
        "Genre.parentID:Genre": 1,
        "Playlist.curator:Listener <-> Listener.playlistIDs:[Playlist]": 2,
        "Playlist.tracks:[Track] <-> Track.playlistIDs:[Playlist]": 5,
        "Playlist.folderID:Playlist": 1,
        "Listener.favorite:Track": 1,
        "Listener.followingIDs:[Listener]": 1,
    ])

    var kinds: [Relationship: Int] = [:]
    for link in links {
        let kind = try link.kind
        kinds[kind, default: 0] += 1
    }
    #expect(kinds == [.oneToOne: 2, .oneToMany: 6, .manyToOne: 12, .manyToMany: 15])
    let deleting = links.filter { $0.deleteSelf }.count
    #expect(deleting == 8) // tracks and artwork
    #expect(saved.count == 25)
}

// MARK: - Round trip

@Test func everyRecordRoundTrips() throws {
    let library = Library()
    let saved = library.saved()

    for tag in library.tags { #expect(try saved.load(Tag.self, tag.id) == tag) }
    for genre in library.genres { #expect(try saved.load(Genre.self, genre.id) == genre) }
    for artwork in library.artworks { #expect(try saved.load(Artwork.self, artwork.id) == artwork) }
    for album in library.albums { #expect(try saved.load(Album.self, album.id) == album) }
    for playlist in library.playlists { #expect(try saved.load(Playlist.self, playlist.id) == playlist) }
    for artist in library.artists { try expectSame(saved.load(Artist.self, artist.id), artist) }
    for track in library.tracks { try expectSame(saved.load(Track.self, track.id), track) }
    for listener in library.listeners { try expectSame(saved.load(Listener.self, listener.id), listener) }
}

@Test func decodedRecordsStartUnchanged() throws {
    let library = Library()
    let saved = library.saved()
    for album in library.albums { #expect(try hasNoChanges(saved.load(Album.self, album.id))) }
    for track in library.tracks { #expect(try hasNoChanges(saved.load(Track.self, track.id))) }
    for playlist in library.playlists { #expect(try hasNoChanges(saved.load(Playlist.self, playlist.id))) }
    for listener in library.listeners { #expect(try hasNoChanges(saved.load(Listener.self, listener.id))) }
}

@Test func recordsLoadOneLevelDeep() throws {
    let library = Library()
    let saved = library.saved()

    // Level one: the album's records.
    let album = try saved.load(Album.self, library.signal.id)
    #expect(album.artist?.name == "Nova Static")
    #expect(album.tracks.map(\.title) == ["Ignition", "Static Bloom", "Afterglow"])
    #expect(album.cover?.url == "https://example.com/signal.jpg")
    #expect(album.genreID == library.indie.id)

    // Level two: the tracks' own references hold IDs, but not records.
    let ignition = album.tracks[0]
    #expect(ignition.albumID == album.id)
    #expect(ignition.tags.isEmpty)
    #expect(ignition.$tags == [library.energetic.id, library.live.id])
    #expect(ignition.playlistIDs == [library.road.id])
    #expect(album.tracks[1].featuring.isEmpty)
    #expect(album.tracks[1].$featuring == [library.juno.id])
    #expect(album.artist.map { sameIDs($0.albumIDs, [library.signal.id, library.orbit.id]) } == true)
    #expect(album.cover?.albumID == album.id)

    // A record pointing at its own type loads the same way.
    let mix = try saved.load(Track.self, library.orbitMix.id)
    #expect(mix.remixOf?.title == "Ignition")
    #expect(mix.remixOf?.$tags == [library.energetic.id, library.live.id])

    let road = try saved.load(Playlist.self, library.road.id)
    #expect(road.tracks.map(\.title) == ["Low Orbit", "Ignition", "Harbor Lights"])
    #expect(road.curator?.name == "Sam")
    #expect(road.curator.map { sameIDs($0.playlistIDs, [library.road.id, library.evening.id]) } == true)
}

@Test func depthControlsHowFarRecordsLoad() throws {
    let library = Library()
    let saved = library.saved()

    // Depth 0: every reference holds only IDs.
    let flat = try saved.load(Album.self, library.signal.id, depth: 0)
    #expect(flat.tracks.isEmpty && flat.artist == nil && flat.cover == nil)
    #expect(flat.$tracks == [library.ignition.id, library.bloom.id, library.afterglow.id])
    #expect(flat.$artist == library.nova.id)
    #expect(flat == library.signal)
    #expect(hasNoChanges(flat))

    // Depth 2: the tracks' own references hold records too.
    let deep = try saved.load(Album.self, library.signal.id, depth: 2)
    #expect(deep.tracks[0].tags.map(\.name) == ["energetic", "live"])
    #expect(deep.tracks[1].featuring.map(\.name) == ["Juno Vale"])
    #expect(deep.tracks[1].featuring.first.map { sameIDs($0.albumIDs, []) } == true)
    #expect(deep == library.signal)
    #expect(hasNoChanges(deep))

    // Deeper still, and through a reference to the same type.
    let riley = try saved.load(Listener.self, library.riley.id, depth: 3)
    #expect(riley.favorite?.title == "Afterglow")
    let remix = try saved.load(Track.self, library.orbitMix.id, depth: 2)
    #expect(remix.remixOf?.tags.map(\.name) == ["energetic", "live"])

    // Saving an edit made at depth 2 writes only that edit.
    var edited = deep
    edited.tracks = [library.bloom, library.ignition, library.afterglow]
    #expect(CKRecordEncoder().linksToSave(for: edited, in: .records).count == 1)
}

@Test func projectionsTellLoadedFromEmpty() throws {
    let library = Library()
    let saved = library.saved()

    // Not loaded: the record form is empty, but `$` holds the IDs.
    let flat = try saved.load(Album.self, library.signal.id, depth: 0)
    #expect(flat.tracks.isEmpty)
    #expect(flat.$tracks == [library.ignition.id, library.bloom.id, library.afterglow.id])
    #expect(flat.artist == nil && flat.$artist == library.nova.id)
    #expect(flat.cover == nil && flat.$cover == library.signalArt.id)

    // Loaded: the counts match.
    let album = try saved.load(Album.self, library.signal.id)
    #expect(album.$tracks == album.tracks.map(\.id))
    #expect(album.$artist == album.artist?.id)

    // The next level holds only IDs.
    #expect(album.tracks[0].tags.count == 0)
    #expect(album.tracks[0].$tags.count == 2)

    // Truly empty: no record and no ID.
    let orbit = try saved.load(Album.self, library.orbit.id)
    #expect(orbit.cover == nil && orbit.$cover == nil)
}

/// Walks the whole library from one listener by following IDs, as an app would, one fetch at a time.
@Test func walkingFromOneListenerReachesEveryRecord() throws {
    let library = Library()
    let saved = library.saved()

    enum Node: Hashable {
        case artist(UUID), album(UUID), artwork(UUID), track(UUID), tag(UUID)
        case genre(UUID), playlist(UUID), listener(UUID)
    }
    var visited: Set<Node> = []
    var queue: [Node] = [.listener(library.riley.id)]

    while let node = queue.popLast() {
        guard visited.insert(node).inserted else { continue }
        switch node {
        case .artist(let id):
            let artist = try saved.load(Artist.self, id)
            queue += artist.albumIDs.map(Node.album)
        case .album(let id):
            let album = try saved.load(Album.self, id)
            queue += album.$artist.map(Node.artist).map { [$0] } ?? []
            queue += album.$tracks.map(Node.track)
            queue += album.$cover.map(Node.artwork).map { [$0] } ?? []
            queue += album.genreID.map(Node.genre).map { [$0] } ?? []
        case .artwork(let id):
            let artwork = try saved.load(Artwork.self, id)
            queue += artwork.albumID.map(Node.album).map { [$0] } ?? []
        case .track(let id):
            let track = try saved.load(Track.self, id)
            queue += track.albumID.map(Node.album).map { [$0] } ?? []
            queue += track.$tags.map(Node.tag)
            queue += track.$featuring.map(Node.artist)
            queue += track.$remixOf.map(Node.track).map { [$0] } ?? []
            queue += track.playlistIDs.map(Node.playlist)
        case .tag(let id):
            _ = try saved.load(Tag.self, id)
        case .genre(let id):
            let genre = try saved.load(Genre.self, id)
            queue += genre.parentID.map(Node.genre).map { [$0] } ?? []
        case .playlist(let id):
            let playlist = try saved.load(Playlist.self, id)
            queue += playlist.$curator.map(Node.listener).map { [$0] } ?? []
            queue += playlist.$tracks.map(Node.track)
            queue += playlist.folderID.map(Node.playlist).map { [$0] } ?? []
        case .listener(let id):
            let listener = try saved.load(Listener.self, id)
            queue += listener.playlistIDs.map(Node.playlist)
            queue += listener.$favorite.map(Node.track).map { [$0] } ?? []
            queue += listener.followingIDs.map(Node.listener)
        }
    }

    #expect(visited.count == saved.count)
    #expect(visited.count == 25)
}

// MARK: - Edits

@Test func libraryEditsRoundTrip() throws {
    let library = Library()
    var saved = library.saved()
    let linkCount = saved.links.count

    // Reorder an album: only the moved track's link is rewritten.
    var signal = try saved.load(Album.self, library.signal.id)
    signal.tracks = [library.afterglow, library.ignition, library.bloom]
    #expect(CKRecordEncoder().linksToSave(for: signal, in: .records).count == 1)

    // Drop the cover: its one-to-one link is deleted.
    signal.cover = nil
    #expect(CKRecordEncoder().linkIDsToDelete(for: signal, in: .records).count == 1)
    saved.save(&signal)
    #expect(hasNoChanges(signal))

    // Swap a playlist track: one link out, one in.
    var evening = try saved.load(Playlist.self, library.evening.id)
    evening.tracks = [library.lowOrbit, library.harborLights]
    saved.save(&evening)

    // Move an album to another artist: the same link record is overwritten.
    var harbor = try saved.load(Album.self, library.harbor.id)
    harbor.artist = library.nova
    saved.save(&harbor)

    // Unfollow, and pick a new favorite.
    var riley = try saved.load(Listener.self, library.riley.id)
    riley.followingIDs = []
    riley.favorite = library.harborLights
    saved.save(&riley)

    #expect(saved.links.count == linkCount - 2) // the cover and the follow

    let signalAgain = try saved.load(Album.self, library.signal.id)
    #expect(signalAgain.tracks.map(\.title) == ["Afterglow", "Ignition", "Static Bloom"])
    #expect(signalAgain.cover == nil)
    #expect(try saved.load(Artwork.self, library.signalArt.id).albumID == nil)

    #expect(try saved.load(Playlist.self, library.evening.id).tracks.map(\.title) == ["Low Orbit", "Harbor Lights"])
    #expect(try saved.load(Track.self, library.bloom.id).playlistIDs.isEmpty)
    #expect(try sameIDs(saved.load(Track.self, library.lowOrbit.id).playlistIDs, [library.road.id, library.evening.id]))

    #expect(try sameIDs(saved.load(Artist.self, library.nova.id).albumIDs, [library.signal.id, library.orbit.id, library.harbor.id]))
    #expect(try saved.load(Artist.self, library.paper.id).albumIDs.isEmpty)

    let rileyAgain = try saved.load(Listener.self, library.riley.id)
    #expect(rileyAgain.followingIDs.isEmpty)
    #expect(rileyAgain.favorite?.title == "Harbor Lights")
}

@Test func editingANestedRecordChangesOnlyThatRecord() throws {
    let library = Library()
    var saved = library.saved()
    var album = try saved.load(Album.self, library.signal.id)

    // Editing a track leaves the album's links alone.
    album.tracks[0].title = "Ignition (Live)"
    #expect(CKRecordEncoder().linksToSave(for: album, in: .records).isEmpty)
    #expect(CKRecordEncoder().linkIDsToDelete(for: album, in: .records).isEmpty)

    // The album's save doesn't cover its tracks, so the track is saved on its own.
    var track = album.tracks[0]
    saved.save(&track)
    #expect(try saved.load(Track.self, track.id).title == "Ignition (Live)")
}
