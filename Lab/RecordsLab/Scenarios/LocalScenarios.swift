import Foundation
import Records
import SwiftUI

/// Every scenario, in the order the Scenarios tab lists them.
@MainActor
enum Scenarios {
    static var all: [Scenario] {
        LocalScenarios.all + RoundTripScenarios.all + GhostScenarios.all + RelaunchScenarios.all + FailureScenarios.all
            + TwoDeviceScenarios.all
    }
}

/// Scenarios that never touch iCloud. Each opens its own in-memory container, so they leave the
/// app's records alone. Most mirror tests in the package's suite.
@MainActor
enum LocalScenarios {
    static var all: [Scenario] {
        [fields, nesting, shapes, cascade, pending, liveUpdates, twoEditors, fetching, assets, bulk]
    }

    // MARK: - Every kind of field

    static let fields = Scenario(
        id: "local.fields", group: .local, title: "Every kind of field", symbol: "list.bullet.rectangle.portrait",
        summary: "Saves one record of each type and reads every field back: text, numbers, dates, arrays, enums, JSON, encrypted text, a location, an asset, a renamed field and a creation date. Then sends two records through JSON."
    ) { lab in
        let container = try Catalog.scratch()
        let context = container.mainContext
        let cover = Media.cover("music.note", hue: 0.6)
        let founded = Seed.year(1994)
        let artist = Artist(name: "Nova", founded: founded, genres: ["Ambient", "Electronic"])
        let album = Album(
            title: "Blue Hour", year: 1997, rating: .four, notes: "One take, no edits.", cover: cover,
            artist: artist
        )
        let place = Coordinate(latitude: 47.6062, longitude: -122.3321)
        let address = Address(street: "1 Pier Road", city: "Seattle", country: "USA")
        let venue = Venue(name: "Harbor Hall", address: address, place: place, artists: [artist])
        let review = Review(text: "A quiet classic.", score: 5, album: album)

        try await lab.act("Insert four records and save") {
            context.insert(artist)
            context.insert(album)
            context.insert(venue)
            context.insert(review)
            try context.save()
        }

        let savedArtist = try lab.unwrap("Read the artist back", try context.record(id: artist.id))
        try lab.expect("Text", savedArtist.name, "Nova")
        try lab.expect("Date", savedArtist.founded, founded)
        try lab.expect("Array of text", savedArtist.genres, ["Ambient", "Electronic"])
        try lab.expect("The artist lists its album by ID", savedArtist.albumIDs, [album.id])

        let savedAlbum = try lab.unwrap("Read the album back", try context.record(id: album.id))
        try lab.expect("Number", savedAlbum.year, 1997)
        try lab.expect("Optional enum", savedAlbum.rating, .four)
        try lab.expect("Encrypted text", savedAlbum.notes, "One take, no edits.")
        try lab.expect("Asset data", savedAlbum.cover, cover)
        let file = savedAlbum.$cover.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        try lab.check("The asset has its own file", file, expected: "a file", actual: "none")
        try lab.expect("To-one reference", savedAlbum.$artist.id, artist.id)
        lab.metric("Cover size", Int64(cover.count).formatted(.byteCount(style: .file)))

        let savedVenue = try lab.unwrap("Read the venue back", try context.record(id: venue.id))
        try lab.expect("JSON field", savedVenue.address, address)
        try lab.expect("Location", savedVenue.place, place)
        try lab.expect("One-way to-many reference", savedVenue.$artists.ids, [artist.id])

        let savedReview = try lab.unwrap("Read the review back", try context.record(id: review.id))
        try lab.expect("Renamed field", savedReview.score, 5)
        try lab.check("Creation date set by the save", savedReview.createdAt != nil, expected: "a date", actual: "nil")
        try lab.expect("One-way to-one reference", savedReview.$album.id, album.id)

        var decodedVenue: Venue?
        var decodedReview: Review?
        try await lab.act("Encode the venue and review as JSON and decode them") {
            decodedVenue = try JSONDecoder().decode(Venue.self, from: JSONEncoder().encode(savedVenue))
            decodedReview = try JSONDecoder().decode(Review.self, from: JSONEncoder().encode(savedReview))
        }
        try lab.expect("JSON keeps the ID", decodedVenue?.id, venue.id)
        try lab.expect("JSON keeps the location", decodedVenue?.place, place)
        try lab.expect("JSON keeps reference IDs", decodedVenue?.$artists.ids, [artist.id])
        try lab.expect("JSON keeps the renamed field", decodedReview?.score, 5)
        try lab.check("JSON leaves out the creation date", decodedReview?.createdAt == nil, expected: "nil", actual: "a date")
    }

    // MARK: - Nesting

    static let nesting = Scenario(
        id: "local.nesting", group: .local, title: "Nested references", symbol: "square.stack.3d.down.right",
        summary: "Builds three albums whose tracks sample tracks on the album before, and saves them through the albums alone. A read loads one level: the album holds its tracks, and each track's sample is an ID."
    ) { lab in
        let container = try Catalog.scratch()
        let context = container.mainContext
        let artist = Artist(name: "Marrow", founded: Seed.year(1988), genres: ["Rock"])
        var albums: [Album] = []
        var previous: [Track] = []
        for index in 0..<3 {
            let tracks = (1...10).map { number in
                Track(
                    title: "Part \(index + 1).\(number)", number: number, seconds: Double(120 + number * 10),
                    mood: .dark, sampledFrom: previous.isEmpty ? nil : previous[number - 1]
                )
            }
            albums.append(Album(
                title: "Volume \(index + 1)", year: 2000 + index, cover: nil,
                artist: artist, tracks: tracks
            ))
            previous = tracks
        }

        try await lab.act("Insert only the albums and save") {
            for album in albums { context.insert(album) }
            try context.save()
        }
        try lab.expect("The artist was saved through the albums", try context.fetchCount(RecordDescriptor<Artist>()), 1)
        try lab.expect("Every track was saved through its album", try context.fetchCount(RecordDescriptor<Track>()), 30)

        var loaded: Album?
        let fetching = try await lab.act("Fetch the last album") {
            loaded = try context.fetch(RecordDescriptor<Album>(predicate: #Predicate { $0.title == "Volume 3" })).first
        }
        let album = try lab.unwrap("Found the album", loaded)
        try lab.expect("Level 1: the artist is loaded", album.artist?.name, "Marrow")
        try lab.expect("Level 1: all ten tracks are loaded", album.tracks.count, 10)
        try lab.expect("Tracks sort by number", album.tracks.map(\.number), Array(1...10))
        try lab.expect("The $tracks handle lists IDs in the same order", album.$tracks.ids, album.tracks.map(\.id))
        try lab.expect("Level 2: no sample records are loaded", album.tracks.compactMap(\.sampledFrom).count, 0)
        try lab.expect("Level 2: every sample ID is there", album.tracks.compactMap(\.$sampledFrom.id).count, 10)
        lab.metric("One-level fetch", fetching.label)

        let firstTrack = try lab.unwrap("The first track", album.tracks.first)
        let sampleID = try lab.unwrap("The first track's sample ID", firstTrack.$sampledFrom.id)
        let sample = try lab.unwrap("Read the sample by ID", try context.record(id: sampleID))
        try lab.expect("The sample is the right track", sample.title, "Part 2.1")
        try lab.expect("A read by ID loads one level too", sample.sampledFrom?.title, "Part 1.1")
    }

    // MARK: - Relationship shapes

    static let shapes = Scenario(
        id: "local.shapes", group: .local, title: "Every relationship shape", symbol: "point.3.connected.trianglepath.dotted",
        summary: "One-to-one, one-to-many from either side, many-to-many, one-way and self references. Checks that each read side lists its owners, then moves a track to another album and clears an artist."
    ) { lab in
        let container = try Catalog.scratch()
        let context = container.mainContext
        let artist = Artist(name: "Kite Theory", founded: Seed.year(2011), genres: ["Pop"])
        let tracks = (1...3).map {
            Track(title: "Song \($0)", number: $0, seconds: 200, mood: .bright)
        }
        let remix = Track(title: "Song 1 (Remix)", number: 1, seconds: 260, mood: .energetic, sampledFrom: tracks[0])
        let artwork = Artwork(credit: "Studio Atlas", image: nil)
        let first = Album(title: "First", year: 2012, cover: nil, artist: artist, tracks: tracks, artwork: artwork)
        let second = Album(title: "Second", year: 2014, cover: nil, tracks: [remix])
        let morning = Playlist(name: "Morning", preview: nil, tracks: [tracks[0], tracks[1]])
        let focus = Playlist(name: "Focus", preview: nil, tracks: [tracks[0], remix])
        let venue = Venue(name: "Sala Norte", address: Address(street: "Calle Mayor 8", city: "Madrid", country: "Spain"), place: nil, artists: [artist])
        let review = Review(text: "Bright and quick.", score: 4, album: first)

        try await lab.act("Insert two albums, two playlists, a venue and a review") {
            for album in [first, second] { context.insert(album) }
            for playlist in [morning, focus] { context.insert(playlist) }
            context.insert(venue)
            context.insert(review)
            try context.save()
        }

        let savedArtwork = try lab.unwrap("Read the artwork", try context.record(id: artwork.id))
        try lab.expect("One-to-one: the artwork names its album", savedArtwork.albumID, first.id)
        let savedArtist = try lab.unwrap("Read the artist", try context.record(id: artist.id))
        try lab.expect("One-to-many, owned by the many side: the artist lists its album", savedArtist.albumIDs, [first.id])
        let firstTrack = try lab.unwrap("Read the first track", try context.record(id: tracks[0].id))
        try lab.expect("One-to-many, owned by the one side: the track names its album", firstTrack.albumID, first.id)
        try lab.expect("Many-to-many: the track lists both playlists", Set(firstTrack.playlistIDs), [morning.id, focus.id])
        let savedRemix = try lab.unwrap("Read the remix", try context.record(id: remix.id))
        try lab.expect("Self reference: the remix points at its original", savedRemix.$sampledFrom.id, tracks[0].id)
        let savedVenue = try lab.unwrap("Read the venue", try context.record(id: venue.id))
        try lab.expect("One-way to-many: the venue holds the artist", savedVenue.$artists.ids, [artist.id])
        let savedReview = try lab.unwrap("Read the review", try context.record(id: review.id))
        try lab.expect("One-way to-one: the review holds the album", savedReview.$album.id, first.id)

        try await lab.act("Move Song 2 to the second album by key path") {
            context.insert(tracks[1], into: \Album.tracks, of: second.id)
            try context.save()
        }
        let moved = try lab.unwrap("Read Song 2", try context.record(id: tracks[1].id))
        try lab.expect("Song 2 now names the second album", moved.albumID, second.id)
        let oldAlbum = try lab.unwrap("Read the first album", try context.record(id: first.id))
        try lab.expect("The first album kept two tracks", oldAlbum.$tracks.count, 2)

        try await lab.act("Clear the first album's artist through its handle") {
            var album = oldAlbum
            album.$artist.clear(in: context)
            try context.save()
        }
        let cleared = try lab.unwrap("Read the artist again", try context.record(id: artist.id))
        try lab.expect("The artist lists no albums", cleared.albumIDs, [])
    }

    // MARK: - Cascading deletes

    static let cascade = Scenario(
        id: "local.cascade", group: .local, title: "Deletes that cascade", symbol: "trash.square",
        summary: "Deleting an album deletes its tracks and artwork and removes the links others hold to it. A track moved to another album in the same save survives. Then deletes reviews by predicate."
    ) { lab in
        let container = try Catalog.scratch()
        let context = container.mainContext
        let tracks = (1...5).map {
            Track(title: "Cut \($0)", number: $0, seconds: 180, mood: .calm)
        }
        let artwork = Artwork(credit: "Studio Prism", image: nil)
        let album = Album(title: "Doomed", year: 2020, cover: nil, tracks: tracks, artwork: artwork)
        let playlist = Playlist(name: "Keepers", preview: nil, tracks: [tracks[0], tracks[1]])
        let review = Review(text: "Gone too soon.", score: 3, album: album)
        try await lab.act("Insert an album with five tracks, artwork, a playlist and a review") {
            context.insert(album)
            context.insert(playlist)
            context.insert(review)
            try context.save()
        }
        try lab.expect("Five tracks saved", try context.fetchCount(RecordDescriptor<Track>()), 5)

        try await lab.act("Delete the album") {
            context.delete(album)
            try context.save()
        }
        try lab.expect("Its tracks are gone", try context.fetchCount(RecordDescriptor<Track>()), 0)
        try lab.expect("Its artwork is gone", try context.fetchCount(RecordDescriptor<Artwork>()), 0)
        let savedPlaylist = try lab.unwrap("The playlist remains", try context.record(id: playlist.id))
        try lab.expect("The playlist dropped the deleted tracks", savedPlaylist.$tracks.count, 0)
        let savedReview = try lab.unwrap("The review remains", try context.record(id: review.id))
        try lab.check("The review dropped the album", savedReview.$album.id == nil, expected: "nil", actual: "an ID")

        let keeper = Track(title: "Keeper", number: 1, seconds: 200, mood: .bright)
        let leaving = Album(title: "Leaving", year: 2021, cover: nil, tracks: [keeper])
        let staying = Album(title: "Staying", year: 2022, cover: nil)
        try await lab.act("Save two albums, then move a track and delete its old album in one save") {
            context.insert(leaving)
            context.insert(staying)
            try context.save()
            context.insert(keeper, into: \Album.tracks, of: staying.id)
            context.delete(leaving)
            try context.save()
        }
        let survivor = try lab.unwrap("The moved track survives", try context.record(id: keeper.id))
        try lab.expect("It belongs to its new album", survivor.albumID, staying.id)

        var deleted = 0
        try await lab.act("Save five reviews, then delete the ones scored under 3 by predicate") {
            for score in 1...5 {
                context.insert(Review(text: "Scored \(score)", score: score))
            }
            try context.save()
            deleted = try context.delete(Review.self, where: #Predicate { $0.score < 3 })
            try context.save()
        }
        try lab.expect("Two reviews matched", deleted, 2)
        let left = try context.fetch(RecordDescriptor<Review>(sortBy: [SortDescriptor(\.score)])).map(\.score)
        try lab.expect("The rest remain", left, [3, 3, 4, 5])
    }

    // MARK: - Pending changes

    static let pending = Scenario(
        id: "local.pending", group: .local, title: "Pending changes and rollback", symbol: "arrow.uturn.backward.circle",
        summary: "Lists an insert, an update and a delete before saving, shows that reads see saved records only, and rolls back one record and then everything."
    ) { lab in
        let container = try Catalog.scratch()
        let context = container.mainContext
        let album = Album(title: "Draft", year: 2019, cover: nil)
        let review = Review(text: "Fine.", score: 3)
        try await lab.act("Save an album and a review") {
            context.insert(album)
            context.insert(review)
            try context.save()
        }
        try lab.check("Nothing pending after a save", !context.hasChanges, expected: "false", actual: "true")

        let artist = Artist(name: "Quiet Engines", founded: Seed.year(1999), genres: ["Jazz"])
        try await lab.act("Insert an artist, rename the album and delete the review") {
            context.insert(artist)
            var renamed = album
            renamed.title = "Final"
            context.insert(renamed)
            context.delete(review)
        }
        try lab.check("Changes are pending", context.hasChanges, expected: "true", actual: "false")
        try lab.expect(
            "Changes list each edit in order", context.changes,
            [.insert(artist.id.rawValue), .update(album.id.rawValue), .delete(review.id.rawValue)]
        )
        try lab.check("Reads show saved records only", try context.record(id: artist.id) == nil, expected: "nil", actual: "the unsaved artist")
        try lab.expect("The saved title is unchanged", try context.record(id: album.id)?.title, "Draft")

        try await lab.act("Roll back the album alone") {
            context.rollback(id: album.id)
        }
        try lab.expect("Two changes remain", context.changes, [.insert(artist.id.rawValue), .delete(review.id.rawValue)])

        try await lab.act("Roll back everything") {
            context.rollback()
        }
        try lab.check("Nothing pending", !context.hasChanges, expected: "false", actual: "true")
        try lab.expect("The artist was never saved", try context.fetchCount(RecordDescriptor<Artist>()), 0)
        try lab.check("The review is still there", try context.record(id: review.id) != nil, expected: "the review", actual: "nil")
    }

    // MARK: - Live updates

    static let liveUpdates = Scenario(
        id: "local.live", group: .local, title: "@Recordable live updates", symbol: "dot.radiowaves.left.and.right",
        summary: "Shows an album in a view with @Recordable while the Lab saves five changes to it behind the scenes. You confirm the card followed each save."
    ) { lab in
        let container = try Catalog.scratch()
        let context = container.mainContext
        let album = Album(
            title: "Take 0", year: 2024, rating: .one, cover: Media.cover("waveform", hue: 0.8)
        )
        try await lab.act("Save an album") {
            context.insert(album)
            try context.save()
        }
        let id = album.id
        let edits = Task { @MainActor in
            for take in 1...5 {
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled, var edited = try? context.record(id: id) else { return }
                edited.title = "Take \(take)"
                edited.rating = Rating(rawValue: take)
                context.insert(edited)
                try? context.save()
            }
        }
        let saw = await lab.ask(
            "Did the card change five times?",
            detail: "The Lab saves a new title and rating every second or so. The card reads the album with @Recordable, so it should follow each save without being told. Wait for “Take 5” with five stars before you answer."
        ) {
            LiveAlbumCard(album: album).recordContext(context)
        }
        await edits.value
        try lab.check("You saw the card follow the saves", saw, expected: "Yes", actual: "No")
        let saved = try lab.unwrap("Read the album", try context.record(id: id))
        try lab.expect("The last save landed", saved.title, "Take 5")
    }

    // MARK: - Two editors

    static let twoEditors = Scenario(
        id: "local.editors", group: .local, title: "Two editors, one record", symbol: "rectangle.split.1x2",
        summary: "Two @Recordable editors on the same album. You change the title in one and the year in the other, and one save keeps both, because each editor saves only the fields it changed."
    ) { lab in
        let container = try Catalog.scratch()
        let context = container.mainContext
        let album = Album(title: "Paper Moons", year: 2001, rating: .three, cover: nil)
        try await lab.act("Save an album") {
            context.insert(album)
            try context.save()
        }
        _ = await lab.ask(
            "Edit a different field in each editor",
            detail: "Change the title in the top editor and the year in the bottom one, then tap Done. Each editor shows the other's edit as you type, because both read the same pending changes.",
            answers: .done
        ) {
            SplitAlbumEditor(album: album).recordContext(context)
        }
        try lab.expect("Two edits are pending, one per editor", context.changes, [.update(album.id.rawValue), .update(album.id.rawValue)])
        try await lab.act("Save once") {
            try context.save()
        }
        let saved = try lab.unwrap("Read the album", try context.record(id: album.id))
        try lab.check("The top editor's title landed", saved.title != "Paper Moons", expected: "a new title", actual: saved.title)
        try lab.check("The bottom editor's year landed", saved.year != 2001, expected: "a new year", actual: String(saved.year))
        try lab.expect("The untouched rating kept its value", saved.rating, .three)
    }

    // MARK: - Fetching

    static let fetching = Scenario(
        id: "local.fetching", group: .local, title: "Fetching and predicates", symbol: "line.3.horizontal.decrease.circle",
        summary: "Seeds the full catalog, then fetches with predicates the database runs, predicates that read through references, sorting with limits, and counts. Each result is checked against the same filter run in Swift."
    ) { lab in
        let container = try Catalog.scratch()
        let context = container.mainContext
        var inserted = 0
        let seeding = try await lab.act("Seed the catalog") {
            inserted = Seed.insertCatalog(into: context)
            try context.save()
        }
        lab.metric("Seeded", "\(inserted) records in \(seeding.label)")

        var everything: [Album] = []
        try await lab.act("Fetch every album with its tracks and artist") {
            everything = try context.fetch(RecordDescriptor<Album>())
        }
        try lab.expect("Twelve albums", everything.count, Seed.albums.count)

        var recent: [Album] = []
        let byYear = try await lab.act("Albums after 2000, by year") {
            recent = try context.fetch(RecordDescriptor<Album>(predicate: #Predicate { $0.year > 2000 }, sortBy: [SortDescriptor(\.year)]))
        }
        try lab.expect("Same albums as Swift finds", recent.map(\.id), everything.filter { $0.year > 2000 }.sorted { $0.year < $1.year }.map(\.id))
        lab.metric("Year predicate", byYear.label)

        var novaReviews: [Review] = []
        let throughTwo = try await lab.act("Reviews of albums by Nova, through two references") {
            novaReviews = try context.fetch(RecordDescriptor<Review>(predicate: #Predicate { $0.album?.artist?.name == "Nova" }))
        }
        let novaAlbums = Set(everything.filter { $0.artist?.name == "Nova" }.map(\.id))
        try lab.expect("One review per Nova album", novaReviews.count, novaAlbums.count)
        try lab.check("Every review is of a Nova album", novaReviews.allSatisfy { $0.$album.id.map { novaAlbums.contains($0) } ?? false })
        lab.metric("Two-reference predicate", throughTwo.label)

        var long: [Album] = []
        let throughMany = try await lab.act("Albums with a track over 380 seconds") {
            long = try context.fetch(RecordDescriptor<Album>(predicate: #Predicate { $0.tracks.contains { $0.seconds > 380 } }))
        }
        let expected = Set(everything.filter { $0.tracks.contains { $0.seconds > 380 } }.map(\.id))
        try lab.expect("Same albums as Swift finds", Set(long.map(\.id)), expected)
        lab.metric("To-many predicate", throughMany.label)

        var longest: [Track] = []
        let sorted = try await lab.act("The five longest tracks") {
            longest = try context.fetch(RecordDescriptor<Track>(sortBy: [SortDescriptor(\.seconds, order: .reverse)], fetchLimit: 5))
        }
        let allSeconds = everything.flatMap(\.tracks).map(\.seconds).sorted(by: >)
        try lab.expect("Five tracks", longest.count, 5)
        try lab.expect("The longest come first", longest.map(\.seconds), Array(allSeconds.prefix(5)))
        lab.metric("Sorted, limited fetch", sorted.label)

        var count = 0
        let counting = try await lab.act("Count the tracks") {
            count = try context.fetchCount(RecordDescriptor<Track>())
        }
        try lab.expect("120 tracks", count, 120)
        lab.metric("Count", counting.label)
    }

    // MARK: - Assets

    static let assets = Scenario(
        id: "local.assets", group: .local, title: "Assets: data, files and IDs", symbol: "photo.on.rectangle.angled",
        summary: "Saves a cover as data and a 4 MB file by URL, checks each lands in its own file, and shows that editing other fields keeps the asset's ID, so it never uploads again."
    ) { lab in
        let container = try Catalog.scratch()
        let context = container.mainContext
        let cover = Media.cover("photo", hue: 0.33)
        let album = Album(title: "Glass Garden", year: 2005, cover: cover)
        let playlist = Playlist(name: "Tones", preview: Media.tone(hertz: 440))
        try await lab.act("Save an album with a cover and a playlist with audio") {
            context.insert(album)
            context.insert(playlist)
            try context.save()
        }
        var saved = try lab.unwrap("Read the album", try context.record(id: album.id))
        try lab.expect("The cover reads back", saved.cover, cover)
        let firstID = try lab.unwrap("The cover has an ID", saved.assetStates.first?.id)
        let inAppFolder = FileManager.default.fileExists(atPath: Inspector.assetsURL.appending(path: "\(firstID.uuidString).asset").path)
        try lab.check("A scratch container keeps its files out of the app's folder", !inAppFolder, expected: "no file there", actual: "a file there")
        let savedPlaylist = try lab.unwrap("Read the playlist", try context.record(id: playlist.id))
        try lab.expect("The audio reads back", savedPlaylist.preview?.count, Media.tone(hertz: 440).count)

        try await lab.act("Rename the album") {
            saved.title = "Glass Garden (Deluxe)"
            context.insert(saved)
            try context.save()
        }
        saved = try lab.unwrap("Read it again", try context.record(id: album.id))
        try lab.expect("Editing a field keeps the asset's ID", saved.assetStates.first?.id, firstID)

        let newCover = Media.cover("photo.fill", hue: 0.9)
        try await lab.act("Replace the cover") {
            saved.cover = newCover
            context.insert(saved)
            try context.save()
        }
        saved = try lab.unwrap("Read it again", try context.record(id: album.id))
        try lab.check("A new cover gets a new ID", saved.assetStates.first?.id != firstID, expected: "a new ID", actual: "the old one")
        try lab.expect("The new cover reads back", saved.cover, newCover)

        let large = Media.filler(megabytes: 4)
        let url = URL.temporaryDirectory.appending(path: "lab-large-\(UUID().uuidString).bin")
        try large.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let copy = try await lab.act("Set the cover to a 4 MB file by URL") {
            saved.$cover = url
            context.insert(saved)
            try context.save()
        }
        lab.metric("Copied 4 MB", copy.label)
        saved = try lab.unwrap("Read it again", try context.record(id: album.id))
        try lab.check("The file was copied in, not used in place", saved.$cover != url, expected: "a copy", actual: "the original file")
        try lab.expect("The large asset reads back", saved.cover, large)

        try await lab.act("Clear the cover") {
            saved.cover = nil
            context.insert(saved)
            try context.save()
        }
        saved = try lab.unwrap("Read it again", try context.record(id: album.id))
        try lab.check("The cover is gone", saved.cover == nil, expected: "nil", actual: "data")
    }

    // MARK: - Bulk

    static let bulk = Scenario(
        id: "local.bulk", group: .local, title: "5,000 tracks in one save", symbol: "speedometer",
        summary: "Times saving, counting, sorting and loading an album of 5,000 tracks, then deleting it, which deletes every track with it."
    ) { lab in
        let container = try Catalog.scratch()
        let context = container.mainContext
        let total = 5_000
        var album: Album?
        let building = try await lab.act("Build 5,000 tracks") {
            album = Seed.bulkAlbum(tracks: total)
        }
        lab.metric("Built", building.label)
        let bulk = try lab.unwrap("Have the album", album)

        let saving = try await lab.act("Save them in one transaction") {
            context.insert(bulk)
            try context.save()
        }
        lab.metric("Saved", "\(Int(Double(total) / max(saving.seconds, 0.001)).formatted()) tracks a second")

        var count = 0
        let counting = try await lab.act("Count them") {
            count = try context.fetchCount(RecordDescriptor<Track>())
        }
        try lab.expect("All 5,000 saved", count, total)
        lab.metric("Counted", counting.label)

        var top: [Track] = []
        let sorting = try await lab.act("Fetch the 20 longest") {
            top = try context.fetch(RecordDescriptor<Track>(sortBy: [SortDescriptor(\.seconds, order: .reverse)], fetchLimit: 20))
        }
        try lab.expect("Twenty tracks", top.count, 20)
        try lab.check("Sorted longest first", zip(top, top.dropFirst()).allSatisfy { $0.seconds >= $1.seconds })
        lab.metric("Sorted and limited", sorting.label)

        var loaded: [Album] = []
        let loading = try await lab.act("Load the album with every track") {
            loaded = try context.fetch(RecordDescriptor<Album>())
        }
        try lab.expect("Every track loaded", loaded.first?.tracks.count, total)
        lab.metric("Loaded", loading.label)

        let deleting = try await lab.act("Delete the album") {
            context.delete(bulk)
            try context.save()
        }
        try lab.expect("Every track went with it", try context.fetchCount(RecordDescriptor<Track>()), 0)
        lab.metric("Deleted", deleting.label)
    }
}
