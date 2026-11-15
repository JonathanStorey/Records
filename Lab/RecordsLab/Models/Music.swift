import Foundation
import Records

// The Lab's catalog: one music library that uses every kind of field and every shape of
// reference Records supports.

enum Rating: Int, Codable, CaseIterable {
    case one = 1, two, three, four, five
}

enum Mood: String, Codable, CaseIterable {
    case calm, bright, dark, energetic
}

/// Stored as JSON.
struct Address: Codable, Hashable {
    var street: String
    var city: String
    var country: String
}

/// Lists its albums by ID: one-to-many, owned by the albums.
@Record
struct Artist {
    var name: String
    var founded: Date
    var genres: [String]
    @Reference(from: \Album.artist) var albumIDs: [Album.ID] = []
}

/// The most complex record: plain, optional, enum, encrypted and asset fields, and three
/// references of different shapes.
@Record
struct Album {
    var title: String
    var year: Int
    var rating: Rating?
    @Encrypted var notes: String?
    @Asset var cover: Data?
    @Reference var artist: Artist? = nil
    @Reference(sort: \Track.number) var tracks: [Track] = []
    @Reference var artwork: Artwork? = nil
}

/// Deleted with its album, listed on playlists by ID, and able to point at another track.
@Record
struct Track {
    var title: String
    var number: Int
    var seconds: Double
    var mood: Mood
    @Reference(from: \Album.tracks, deleteSelf: true) var albumID: Album.ID? = nil
    @Reference(from: \Playlist.tracks) var playlistIDs: [Playlist.ID] = []
    @Reference var sampledFrom: Track? = nil
}

/// Many-to-many with tracks, with an audio asset.
@Record
struct Playlist {
    var name: String
    @Asset var preview: Data?
    @Reference var tracks: [Track] = []
}

/// One-to-one with its album, and deleted with it.
@Record
struct Artwork {
    var credit: String
    @Asset var image: Data?
    @Reference(from: \Album.artwork, deleteSelf: true) var albumID: Album.ID? = nil
}

/// A JSON field, a location, and a one-way to-many reference. Codable, so it can be sent
/// anywhere as JSON.
@Record
struct Venue: Codable {
    var name: String
    var address: Address
    @Location var place: Coordinate?
    @Reference var artists: [Artist] = []
}

/// A renamed field, a creation date, and a one-way to-one reference. Codable too.
@Record
struct Review: Codable {
    var text: String
    @Renamed("stars") var score: Int
    @Timestamped(.created) var createdAt: Date?
    @Reference var album: Album? = nil
}

enum Catalog {
    /// Every type the Lab registers. The rest would be found through references, but naming them
    /// all keeps the list honest.
    static var types: [any Record.Type] {
        [Artist.self, Album.self, Track.self, Playlist.self, Artwork.self, Venue.self, Review.self]
    }

    /// A throwaway container for a scenario that never touches iCloud.
    static func scratch() throws -> RecordContainer {
        try RecordContainer(for: types, sync: .inMemory)
    }
}
