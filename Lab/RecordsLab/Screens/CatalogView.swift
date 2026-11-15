import AVFoundation
import Records
import SwiftUI

/// The app's own records, read from the iCloud container.
struct CatalogView: View {
    @Environment(\.recordContext) private var context

    var body: some View {
        NavigationStack {
            List {
                let albums = fetch(albumsDescriptor)
                if albums.isEmpty {
                    ContentUnavailableView(
                        "No records yet", systemImage: "music.note.house",
                        description: Text("Seed the catalog from the Dashboard, or pull to fetch from iCloud.")
                    )
                }
                Section {
                    ForEach(albums) { album in
                        NavigationLink {
                            AlbumDetail(album: album)
                        } label: {
                            AlbumRow(album: album)
                        }
                    }
                } header: {
                    CountHeader(title: "Albums", symbol: "square.stack", count: albums.count)
                }
                let artists = fetch(RecordDescriptor<Artist>(sortBy: [SortDescriptor(\.name)]))
                Section {
                    ForEach(artists) { ArtistRow(artist: $0) }
                } header: {
                    CountHeader(title: "Artists", symbol: "music.mic", count: artists.count)
                }
                let playlists = fetch(RecordDescriptor<Playlist>(sortBy: [SortDescriptor(\.name)]))
                Section {
                    ForEach(playlists) { PlaylistRow(playlist: $0) }
                } header: {
                    CountHeader(title: "Playlists", symbol: "music.note.list", count: playlists.count)
                }
                let venues = fetch(RecordDescriptor<Venue>(sortBy: [SortDescriptor(\.name)]))
                Section {
                    ForEach(venues) { VenueRow(venue: $0) }
                } header: {
                    CountHeader(title: "Venues", symbol: "mappin.and.ellipse", count: venues.count)
                }
                let reviews = fetch(reviewsDescriptor)
                Section {
                    ForEach(reviews) { ReviewRow(review: $0) }
                } header: {
                    CountHeader(title: "Reviews", symbol: "text.quote", count: reviews.count)
                }
            }
            .navigationTitle("Catalog")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { SaveControls() }
            }
            .refreshable { await context.refresh() }
        }
    }

    private var albumsDescriptor: RecordDescriptor<Album> {
        var descriptor = RecordDescriptor<Album>(sortBy: [SortDescriptor(\.title)])
        descriptor.relationshipKeyPathsForPrefetching = [\Album.artist]
        return descriptor
    }

    private var reviewsDescriptor: RecordDescriptor<Review> {
        var descriptor = RecordDescriptor<Review>()
        descriptor.relationshipKeyPathsForPrefetching = [\Review.album]
        return descriptor
    }

    /// The records, or none with the error printed.
    private func fetch<R: Record>(_ descriptor: RecordDescriptor<R>) -> [R] {
        do {
            return try context.fetch(descriptor)
        } catch {
            print("LAB FAIL catalog fetch of \(R.recordType): \(error)")
            return []
        }
    }
}

struct CountHeader: View {
    let title: String
    let symbol: String
    let count: Int

    var body: some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Text(count, format: .number)
                .monospacedDigit()
        }
    }
}

struct AlbumRow: View {
    let album: Album

    var body: some View {
        HStack(spacing: 12) {
            CoverImage(url: album.$cover)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title).font(.headline)
                Text("\(album.artist?.name ?? "No artist") · \(String(album.year))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Label("\(album.$tracks.count)", systemImage: "music.note")
                    if album.$artwork.id != nil {
                        Label("Art", systemImage: "photo.artframe")
                    }
                    if album.notes != nil {
                        Label("Notes", systemImage: "lock.fill")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }
            Spacer()
            Stars(count: album.rating?.rawValue ?? 0)
                .font(.caption2)
        }
    }
}

/// An album edited through an optional `@Recordable`, which reads `nil` once it is deleted.
struct AlbumDetail: View {
    @Recordable var album: Album?
    @Environment(\.recordContext) private var context
    @State private var showsSideBySide = false
    private let original: Album

    init(album: Album) {
        _album = Recordable(album, expand: \Album.artist, \Album.tracks, \Album.artwork)
        original = album
    }

    var body: some View {
        Group {
            if let album = Binding($album) {
                form(album)
            } else {
                ContentUnavailableView(
                    "Album deleted", systemImage: "trash",
                    description: Text("Saving removes it with its tracks and artwork.")
                )
            }
        }
        .navigationTitle(original.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { SaveControls() }
            ToolbarItem(placement: .bottomBar) {
                Button("Side by side", systemImage: "rectangle.split.1x2") { showsSideBySide = true }
            }
        }
        .sheet(isPresented: $showsSideBySide) {
            NavigationStack {
                SplitAlbumEditor(album: original)
                    .navigationTitle("Side by side")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Close") { showsSideBySide = false }
                        }
                    }
            }
        }
    }

    private func form(_ album: Binding<Album>) -> some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    CoverImage(url: album.wrappedValue.$cover, size: 96)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(album.wrappedValue.title).font(.title3.bold())
                        Text(album.wrappedValue.artist?.name ?? "No artist").foregroundStyle(.secondary)
                        Stars(count: album.wrappedValue.rating?.rawValue ?? 0).font(.caption)
                    }
                }
            }
            AlbumFieldsSection(album: album, title: "Fields")
            Section {
                let tracks = Dictionary(album.wrappedValue.tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                ForEach(album.wrappedValue.$tracks, id: \.self) { id in
                    if let track = tracks[id] {
                        NavigationLink {
                            TrackEditor(track: track)
                        } label: {
                            TrackRow(track: track)
                        }
                    } else {
                        Text(id.description).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    album.wrappedValue.$tracks.remove(atOffsets: offsets, in: context)
                }
            } header: {
                CountHeader(title: "Tracks", symbol: "music.note", count: album.wrappedValue.$tracks.count)
            } footer: {
                Text("Swipe to remove a track from the album. Only the link changes, so the album's fields never conflict with it.")
            }
            if let artwork = album.wrappedValue.artwork {
                Section("Artwork") {
                    HStack(spacing: 16) {
                        CoverImage(url: artwork.$image, size: 72, symbol: "photo.artframe")
                        Text(artwork.credit)
                    }
                }
            }
            Section {
                Button("Delete album", systemImage: "trash", role: .destructive) {
                    self.album = nil
                }
            } footer: {
                Text("Deleting the album deletes its tracks and artwork when you save.")
            }
        }
    }
}

struct TrackRow: View {
    let track: Track

    var body: some View {
        HStack {
            Text(track.number, format: .number)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading) {
                Text(track.title)
                if track.$sampledFrom.id != nil {
                    Label("Samples another track", systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.purple)
                }
            }
            Spacer()
            Text(track.mood.rawValue.capitalized)
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.tint.opacity(0.15), in: Capsule())
            Text(Duration.seconds(track.seconds).formatted(.time(pattern: .minuteSecond)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

/// A track with its own `@Recordable`.
struct TrackEditor: View {
    @Recordable var track: Track

    init(track: Track) {
        _track = Recordable(track)
    }

    var body: some View {
        Form {
            Section("Track") {
                TextField("Title", text: $track.title)
                Stepper(value: $track.number, in: 1...999) {
                    LabeledContent("Number", value: String(track.number))
                }
                LabeledContent("Length", value: Duration.seconds(track.seconds).formatted(.time(pattern: .minuteSecond)))
                Slider(value: $track.seconds, in: 30...600, step: 1)
                Picker("Mood", selection: $track.mood) {
                    ForEach(Mood.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
            }
            Section("References") {
                LabeledContent("Album", value: track.albumID.map { String($0.description.prefix(8)) } ?? "None")
                LabeledContent("Playlists", value: String(track.playlistIDs.count))
                LabeledContent("Samples", value: track.$sampledFrom.id.map { String($0.description.prefix(8)) } ?? "None")
            }
        }
        .navigationTitle(track.title)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { SaveControls() }
        }
    }
}

struct ArtistRow: View {
    let artist: Artist

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(artist.name).font(.headline)
                Spacer()
                Label("\(artist.albumIDs.count)", systemImage: "square.stack")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Since \(artist.founded.formatted(.dateTime.year())) · \(artist.genres.joined(separator: ", "))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

struct PlaylistRow: View {
    let playlist: Playlist
    @State private var player: AVAudioPlayer?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name).font(.headline)
                Label("\(playlist.$tracks.count) tracks", systemImage: "music.note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let url = playlist.$preview {
                Button {
                    player = try? AVAudioPlayer(contentsOf: url)
                    player?.play()
                } label: {
                    Image(systemName: "play.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

struct VenueRow: View {
    let venue: Venue

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(venue.name).font(.headline)
                Spacer()
                Label("\(venue.$artists.count)", systemImage: "music.mic")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(venue.address.street), \(venue.address.city), \(venue.address.country)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let place = venue.place {
                Label(
                    "\(place.latitude.formatted(.number.precision(.fractionLength(3)))), \(place.longitude.formatted(.number.precision(.fractionLength(3))))",
                    systemImage: "location.fill"
                )
                .font(.caption)
                .foregroundStyle(.blue)
            }
        }
    }
}

struct ReviewRow: View {
    let review: Review

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(review.album?.title ?? "No album").font(.headline)
                Spacer()
                Stars(count: review.score).font(.caption2)
            }
            Text(review.text).font(.subheadline)
            if let created = review.createdAt {
                Text(created, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
