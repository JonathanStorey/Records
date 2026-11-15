import Foundation
import Records

/// Scenarios that send records to iCloud and read them back as a second device would. Each one
/// works in the Lab zone with records of its own, so they can run again and again.
@MainActor
enum RoundTripScenarios {
    static var all: [Scenario] {
        [zones, everyModel, dates, assets, wholeAlbum, refresh]
    }

    // MARK: - Zones

    static let zones = Scenario(
        id: "roundTrip.zones", group: .roundTrip, title: "Zones are created", symbol: "square.stack.3d.up",
        summary: "Checks that the app's own zone exists in iCloud. Then the ghost deletes the Lab zone, and a save into it must create the zone again before it uploads."
    ) { lab in
        let context = try await lab.cloud()
        let ghost = Ghost()
        let home = try await ghost.zoneExists(.records)
        try lab.check("The app created its zone, Records, at first launch", home, expected: "the zone", actual: "none")

        try await lab.act("The ghost deletes the Lab zone") { try await ghost.deleteZone() }
        try await lab.refresh(context)
        let artist = Artist(name: "Zone Builder", founded: .now, genres: [])
        try await lab.act("Save a record into the deleted zone") {
            context.insert(artist)
            try context.save()
        }
        try await lab.waitForUploads(context, timeout: .seconds(90))
        let exists = try await ghost.zoneExists(Ghost.zone)
        try lab.check("The Lab zone exists again", exists, expected: "the zone", actual: "none")
        let uploaded = try await ghost.fetch(ghost.id(of: artist))
        try lab.check("The record is in it", uploaded != nil, expected: "the record", actual: "none")
    }

    // MARK: - Every model

    static let everyModel = Scenario(
        id: "roundTrip.models", group: .roundTrip, title: "Every model, field by field", symbol: "square.grid.3x3",
        summary: "Saves one record of every type with every field and reference filled, waits for iCloud to confirm them, then reads the server's copies as another device would and compares every field. Also checks how the server stores a renamed field, an encrypted field and an enum."
    ) { lab in
        let context = try await lab.cloud()
        let ghost = Ghost()
        let artist = Artist(name: "Halcyon", founded: Seed.year(2009), genres: ["Dream pop", "Shoegaze"])
        let first = Track(title: "Opening", number: 1, seconds: 201.5, mood: .calm)
        let second = Track(title: "Undertow", number: 2, seconds: 245.25, mood: .dark, sampledFrom: first)
        let artwork = Artwork(credit: "Studio Nine", image: Media.cover("photo", hue: 0.1, size: 96))
        let album = Album(
            title: "Tidal", year: 2021, rating: .five, notes: "Mixed in one night.",
            cover: Media.cover("waveform", hue: 0.55, size: 96), artist: artist, tracks: [first, second], artwork: artwork
        )
        let playlist = Playlist(name: "Late", preview: Media.tone(hertz: 330, seconds: 0.25), tracks: [second, first])
        let address = Address(street: "4 Glass Lane", city: "London", country: "UK")
        let place = Coordinate(latitude: 51.5072, longitude: -0.1276)
        let venue = Venue(name: "Glasshouse", address: address, place: place, artists: [artist])
        let review = Review(text: "Worth the wait.", score: 4, album: album)

        try await lab.act("Save one record of every type") {
            context.insert(album)
            context.insert(playlist)
            context.insert(venue)
            context.insert(review)
            try context.save()
        }
        try await lab.waitForUploads(context)

        // This device's copies, as saved and confirmed.
        let here = (
            artist: try lab.unwrap("Read the artist here", try context.record(id: artist.id)),
            album: try lab.unwrap("Read the album here", try context.record(id: album.id)),
            first: try lab.unwrap("Read the first track here", try context.record(id: first.id)),
            second: try lab.unwrap("Read the second track here", try context.record(id: second.id)),
            playlist: try lab.unwrap("Read the playlist here", try context.record(id: playlist.id)),
            artwork: try lab.unwrap("Read the artwork here", try context.record(id: artwork.id)),
            venue: try lab.unwrap("Read the venue here", try context.record(id: venue.id)),
            review: try lab.unwrap("Read the review here", try context.record(id: review.id))
        )
        let records: [any Record] = [here.artist, here.album, here.first, here.second, here.playlist, here.artwork, here.venue, here.review]
        let ids = Array(Set(records.flatMap { [ghost.id(of: $0)] + ghost.linkIDs(of: $0) }))

        var server: [CKRecord.ID: CKRecord] = [:]
        let fetching = try await lab.act("The ghost fetches every record and link") {
            server = try await ghost.fetch(ids)
        }
        try lab.expect("Every record and link is in iCloud", server.count, ids.count)
        lab.metric("Fetched", "\(server.count) records and links in \(fetching.label)")
        let links = server.values.filter { $0.recordType == "RecordLink" }

        /// The server's copy of `record`, decoded with every link, as another device reads it.
        func copy<R: Record>(_ record: R) throws -> R {
            let found = try lab.unwrap("iCloud has the \(R.recordType)", server[ghost.id(of: record)])
            return try ghost.decode(R.self, found, links: links)
        }

        let artistThere = try copy(here.artist)
        try lab.expect("Artist name", artistThere.name, here.artist.name)
        try lab.expect("Artist founding date", artistThere.founded, here.artist.founded)
        try lab.expect("Artist genres", artistThere.genres, here.artist.genres)
        try lab.expect("The artist lists its album", artistThere.albumIDs, here.artist.albumIDs)

        let albumThere = try copy(here.album)
        try lab.expect("Album title", albumThere.title, here.album.title)
        try lab.expect("Album year", albumThere.year, here.album.year)
        try lab.expect("Album rating", albumThere.rating, here.album.rating)
        try lab.expect("Album notes, encrypted", albumThere.notes, here.album.notes)
        try lab.expect("Album cover's asset", albumThere._cover.id, here.album._cover.id)
        try lab.expect("The album's artist", albumThere.$artist.id, here.album.$artist.id)
        try lab.expect("The album's tracks", Set(albumThere.$tracks.ids), Set(here.album.$tracks.ids))
        try lab.expect("The album's artwork", albumThere.$artwork.id, here.album.$artwork.id)

        let trackThere = try copy(here.second)
        try lab.expect("Track title", trackThere.title, here.second.title)
        try lab.expect("Track number", trackThere.number, here.second.number)
        try lab.expect("Track length", trackThere.seconds, here.second.seconds)
        try lab.expect("Track mood", trackThere.mood, here.second.mood)
        try lab.expect("The track names its album", trackThere.albumID, here.second.albumID)
        try lab.expect("The track lists its playlist", Set(trackThere.playlistIDs), Set(here.second.playlistIDs))
        try lab.expect("The track points at its sample", trackThere.$sampledFrom.id, first.id)

        let playlistThere = try copy(here.playlist)
        try lab.expect("Playlist name", playlistThere.name, here.playlist.name)
        try lab.expect("Playlist preview's asset", playlistThere._preview.id, here.playlist._preview.id)
        try lab.expect("The playlist's tracks", Set(playlistThere.$tracks.ids), Set(here.playlist.$tracks.ids))

        let artworkThere = try copy(here.artwork)
        try lab.expect("Artwork credit", artworkThere.credit, here.artwork.credit)
        try lab.expect("Artwork image's asset", artworkThere._image.id, here.artwork._image.id)
        try lab.expect("The artwork names its album", artworkThere.albumID, album.id)

        let venueThere = try copy(here.venue)
        try lab.expect("Venue name", venueThere.name, here.venue.name)
        try lab.expect("Venue address, as JSON", venueThere.address, address)
        try lab.expect("Venue location", venueThere.place, place)
        try lab.expect("The venue's artists", venueThere.$artists.ids, [artist.id])

        let reviewThere = try copy(here.review)
        try lab.expect("Review text", reviewThere.text, here.review.text)
        try lab.expect("Review score", reviewThere.score, 4)
        try lab.expect("Review creation date, the server's", reviewThere.createdAt, here.review.createdAt)
        try lab.expect("The review's album", reviewThere.$album.id, album.id)

        // How the server stores the fields, read straight from CloudKit.
        let rawReview = try lab.unwrap("iCloud has the review", server[ghost.id(of: review)])
        try lab.expect("The renamed score is stored as stars", rawReview["stars"] as? Int, 4)
        let rawAlbum = try lab.unwrap("iCloud has the album", server[ghost.id(of: album)])
        try lab.expect("The notes are stored encrypted", rawAlbum.encryptedValues["notes"] as? String, "Mixed in one night.")
        let rawTrack = try lab.unwrap("iCloud has the track", server[ghost.id(of: second)])
        try lab.expect("A mood is stored as its raw value", rawTrack["mood"] as? String, "dark")
    }

    // MARK: - Dates

    static let dates = Scenario(
        id: "roundTrip.dates", group: .roundTrip, title: "Dates arrive exactly", symbol: "calendar.badge.clock",
        summary: "Saves a date with a fraction of a millisecond. The server must store it as a Double of its seconds, and another device must read back the same instant to the last digit. CloudKit's own date type would keep only milliseconds."
    ) { lab in
        let context = try await lab.cloud()
        let ghost = Ghost()
        let founded = Date(timeIntervalSinceReferenceDate: 765_432_109.123_456_7)
        let artist = Artist(name: "Precise", founded: founded, genres: [])
        try await lab.act("Save an artist founded at a precise instant") {
            context.insert(artist)
            try context.save()
        }
        try await lab.waitForUploads(context)

        let raw = try lab.unwrap("iCloud has the artist", try await ghost.fetch(ghost.id(of: artist)))
        try lab.expect("The server stores the date as seconds", raw["founded"] as? Double, founded.timeIntervalSinceReferenceDate)
        try lab.expect("Another device reads the same instant", try ghost.decode(Artist.self, raw).founded, founded)

        try await lab.refresh(context)
        let here = try lab.unwrap("Read the artist here", try context.record(id: artist.id))
        try lab.expect("This device still has the same instant", here.founded, founded)
        try lab.expect("Nothing waits to upload after the fetch", context.pendingUploads, 0)
    }

    // MARK: - Assets

    static let assets = Scenario(
        id: "roundTrip.assets", group: .roundTrip, title: "Assets arrive byte for byte", symbol: "photo.on.rectangle",
        summary: "Saves an album cover and a playlist's audio, then downloads each asset from iCloud as another device would and compares the bytes."
    ) { lab in
        let context = try await lab.cloud()
        let ghost = Ghost()
        let cover = Media.cover("photo.artframe", hue: 0.8, size: 480)
        let preview = Media.tone(hertz: 523.25, seconds: 2)
        let album = Album(title: "Pictures", year: 2018, cover: cover)
        let playlist = Playlist(name: "Tones", preview: preview)
        try await lab.act("Save an album with a cover and a playlist with audio") {
            context.insert(album)
            context.insert(playlist)
            try context.save()
        }
        try await lab.waitForUploads(context)

        /// Downloads the asset `record` carries, straight from its link in iCloud.
        func download<R: Record>(_ record: R, _ name: String) async throws -> (data: Data, assetID: String?) {
            let id = try lab.unwrap("The \(name) has a link", ghost.assetLinkIDs(of: record).first)
            let link = try lab.unwrap("iCloud has the \(name)'s link", try await ghost.fetch(id))
            let file = try lab.unwrap("The link carries the \(name)", (link["asset"] as? CKAsset)?.fileURL)
            return (try Data(contentsOf: file), link["assetID"] as? String)
        }

        let savedAlbum = try lab.unwrap("Read the album here", try context.record(id: album.id))
        var coverThere: (data: Data, assetID: String?) = (Data(), nil)
        let coverTime = try await lab.act("The ghost downloads the cover") {
            coverThere = try await download(savedAlbum, "cover")
        }
        try lab.expect("The cover's bytes match", coverThere.data, cover)
        try lab.expect("The link names the cover's asset", coverThere.assetID, savedAlbum._cover.id?.uuidString)
        lab.metric("Cover", "\(Int64(cover.count).formatted(.byteCount(style: .file))) in \(coverTime.label)")

        let savedPlaylist = try lab.unwrap("Read the playlist here", try context.record(id: playlist.id))
        var previewThere: (data: Data, assetID: String?) = (Data(), nil)
        let previewTime = try await lab.act("The ghost downloads the audio") {
            previewThere = try await download(savedPlaylist, "audio")
        }
        try lab.expect("The audio's bytes match", previewThere.data, preview)
        lab.metric("Audio", "\(Int64(preview.count).formatted(.byteCount(style: .file))) in \(previewTime.label)")
    }

    // MARK: - A whole album

    static let wholeAlbum = Scenario(
        id: "roundTrip.wholeAlbum", group: .roundTrip, title: "A whole album arrives", symbol: "square.stack.3d.down.right",
        summary: "Saves an album with its artist, ten tracks and artwork by inserting the album alone. Then fetches every record and link as another device would, and rebuilds the album from them."
    ) { lab in
        let context = try await lab.cloud()
        let ghost = Ghost()
        let artist = Artist(name: "Marrow", founded: Seed.year(1990), genres: ["Rock"])
        let tracks = (1...10).map { Track(title: "Side \($0)", number: $0, seconds: Double(180 + $0), mood: .bright) }
        let artwork = Artwork(credit: "Darkroom", image: nil)
        let album = Album(title: "Whole", year: 2015, cover: nil, artist: artist, tracks: tracks, artwork: artwork)
        try await lab.act("Insert the album alone and save") {
            context.insert(album)
            try context.save()
        }
        try await lab.waitForUploads(context)

        let saved = try lab.unwrap("Read the album here", try context.record(id: album.id))
        let recordIDs = [ghost.id(of: album), ghost.id(of: artist), ghost.id(of: artwork)] + tracks.map { ghost.id(of: $0) }
        let linkIDs = ghost.linkIDs(of: saved)
        try lab.expect("The album writes a link per target", linkIDs.count, 12)

        var server: [CKRecord.ID: CKRecord] = [:]
        let fetching = try await lab.act("The ghost fetches the records and links") {
            server = try await ghost.fetch(recordIDs + linkIDs)
        }
        try lab.expect("All 13 records are in iCloud", recordIDs.filter { server[$0] != nil }.count, 13)
        try lab.expect("All 12 links are in iCloud", linkIDs.filter { server[$0] != nil }.count, 12)
        lab.metric("Fetched", "\(server.count) records and links in \(fetching.label)")

        let rebuilt = try ghost.decode(
            Album.self, try lab.unwrap("iCloud has the album", server[ghost.id(of: album)]),
            links: linkIDs.compactMap { server[$0] },
            targets: recordIDs.dropFirst().compactMap { server[$0] }
        )
        try lab.expect("The artist came along", rebuilt.artist?.name, "Marrow")
        try lab.expect("All ten tracks, in order", rebuilt.tracks.map(\.title), (1...10).map { "Side \($0)" })
        try lab.expect("The artwork came along", rebuilt.artwork?.credit, "Darkroom")
    }

    // MARK: - Refresh

    static let refresh = Scenario(
        id: "roundTrip.refresh", group: .roundTrip, title: "Refresh sends a waiting save", symbol: "arrow.clockwise.icloud",
        summary: "Saves a record and pulls to refresh straight away. Refresh returns only after it has fetched and sent what was waiting, so iCloud has the record as soon as it returns."
    ) { lab in
        let context = try await lab.cloud()
        let ghost = Ghost()
        let review = Review(text: "Sent by refresh.", score: 3)
        try await lab.act("Save a review") {
            context.insert(review)
            try context.save()
        }
        let refreshing = try await lab.refresh(context)
        let uploaded = try await ghost.fetch(ghost.id(of: review))
        try lab.check("iCloud has the review once refresh returns", uploaded != nil, expected: "the review", actual: "none")
        try await lab.wait("Nothing waits to upload", timeout: .seconds(5)) { context.pendingUploads == 0 }
        lab.metric("Refresh", refreshing.label)
    }
}
