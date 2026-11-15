import Foundation
import Records
import UIKit

/// Images, audio and filler bytes made in code, so the Lab ships no media files.
enum Media {
    /// A square PNG of an SF Symbol on a gradient.
    @MainActor
    static func cover(_ symbol: String, hue: Double, size: CGFloat = 240) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
        let image = renderer.image { context in
            let top = UIColor(hue: hue, saturation: 0.65, brightness: 0.95, alpha: 1)
            let bottom = UIColor(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.85, brightness: 0.45, alpha: 1)
            let colors = [top.cgColor, bottom.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])
            }
            let configuration = UIImage.SymbolConfiguration(pointSize: size * 0.38, weight: .semibold)
            if let glyph = UIImage(systemName: symbol, withConfiguration: configuration)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) {
                glyph.draw(at: CGPoint(x: (size - glyph.size.width) / 2, y: (size - glyph.size.height) / 2))
            }
        }
        return image.pngData() ?? Data()
    }

    /// A mono 16-bit WAV of a sine tone.
    static func tone(hertz: Double, seconds: Double = 1) -> Data {
        let rate = 22_050
        let count = Int(Double(rate) * seconds)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(rate))
        append(UInt32(rate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(count * 2))
        for index in 0..<count {
            let sample = sin(2 * Double.pi * hertz * Double(index) / Double(rate))
            append(Int16(sample * 12_000))
        }
        return data
    }

    /// `megabytes` of random bytes, for an asset too large to fit in a record.
    static func filler(megabytes: Int) -> Data {
        let count = megabytes * 1_048_576
        var generator = SystemRandomNumberGenerator()
        var data = Data(count: count)
        data.withUnsafeMutableBytes { buffer in
            for offset in stride(from: 0, to: count - 7, by: 8) {
                buffer.storeBytes(of: generator.next() as UInt64, toByteOffset: offset, as: UInt64.self)
            }
        }
        return data
    }
}

/// Fills a context with the Lab's catalog, adds bulk tracks, or erases everything.
@MainActor
enum Seed {
    static let artists: [(name: String, founded: Int, genres: [String], symbol: String)] = [
        ("Nova", 1994, ["Ambient", "Electronic"], "sparkles"),
        ("The Lanterns", 2003, ["Indie", "Folk"], "flame"),
        ("Marrow", 1988, ["Rock"], "bolt"),
        ("Kite Theory", 2011, ["Pop", "Synth"], "wind"),
        ("Quiet Engines", 1999, ["Jazz", "Ambient"], "gearshape.2"),
    ]

    static let albums = [
        "Blue Hour", "Paper Moons", "Signal Fires", "Low Tide", "Glass Garden", "North of Noon",
        "Static Bloom", "Long Division", "Velvet Map", "Cold Open", "Harbor Lights", "Afterimage",
    ]

    static let words = [
        "Echo", "Drift", "Ember", "Hollow", "Silver", "Orbit", "Lantern", "Meridian", "Rain",
        "Copper", "Fable", "Neon", "Quartz", "Willow", "Atlas", "Cinder", "Tidal", "Prism",
    ]

    static let playlists = ["Morning", "Focus", "Late Drive", "Rainy Day", "Workout", "Sunday"]

    static let venues: [(name: String, street: String, city: String, country: String, latitude: Double, longitude: Double)] = [
        ("Harbor Hall", "1 Pier Road", "Seattle", "USA", 47.6062, -122.3321),
        ("The Lantern Room", "22 Mill Lane", "Manchester", "UK", 53.4808, -2.2426),
        ("Sala Norte", "Calle Mayor 8", "Madrid", "Spain", 40.4168, -3.7038),
        ("Kettle Works", "90 Foundry St", "Melbourne", "Australia", -37.8136, 144.9631),
    ]

    static func year(_ year: Int) -> Date {
        DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .gmt, year: year, month: 6, day: 1).date ?? .distantPast
    }

    /// 5 artists, 12 albums of 10 tracks, artwork on every other album, 6 playlists, 4 venues
    /// and a review per album. Some tracks sample a track on an earlier album. Returns the
    /// number of records inserted.
    @discardableResult
    static func insertCatalog(into context: RecordContext) -> Int {
        let artists = Self.artists.map {
            Artist(name: $0.name, founded: year($0.founded), genres: $0.genres)
        }
        var count = artists.count
        var allTracks: [Track] = []
        var previous: [Track] = []
        var albums: [Album] = []
        for (index, title) in Self.albums.enumerated() {
            let artist = artists[index % artists.count]
            let symbol = Self.artists[index % artists.count].symbol
            let hue = Double(index) / Double(Self.albums.count)
            var tracks: [Track] = []
            for number in 1...10 {
                let sample = number % 4 == 0 && previous.count >= number ? previous[number - 1] : nil
                tracks.append(Track(
                    title: "\(words[(index * 3 + number) % words.count]) \(words[(index + number * 5) % words.count])",
                    number: number,
                    seconds: Double(150 + (index * 37 + number * 23) % 240),
                    mood: Mood.allCases[(index + number) % Mood.allCases.count], sampledFrom: sample
                ))
            }
            let artwork = index.isMultiple(of: 2)
                ? Artwork(credit: "Studio \(words[index % words.count])", image: Media.cover("photo.artframe", hue: hue))
                : nil
            let album = Album(
                title: title, year: 1990 + index * 3, rating: Rating(rawValue: index % 5 + 1),
                notes: "Recorded in \(2 + index % 4) weeks.", cover: Media.cover(symbol, hue: hue),
                artist: artist, tracks: tracks, artwork: artwork
            )
            albums.append(album)
            allTracks += tracks
            previous = tracks
            count += 1 + tracks.count + (artwork == nil ? 0 : 1)
        }
        for artist in artists { context.insert(artist) }
        for album in albums { context.insert(album) }
        for (index, name) in Self.playlists.enumerated() {
            let tracks = stride(from: index, to: allTracks.count, by: 7).map { allTracks[$0] }
            context.insert(Playlist(name: name, preview: Media.tone(hertz: 220 + Double(index) * 55), tracks: Array(tracks.prefix(15))))
            count += 1
        }
        for (index, venue) in Self.venues.enumerated() {
            context.insert(Venue(
                name: venue.name,
                address: Address(street: venue.street, city: venue.city, country: venue.country),
                place: Coordinate(latitude: venue.latitude, longitude: venue.longitude),
                artists: [artists[index], artists[(index + 2) % artists.count]]
            ))
            count += 1
        }
        for album in albums {
            context.insert(Review(text: "\(album.title) rewards a second listen.", score: (album.rating?.rawValue ?? 3), album: album))
            count += 1
        }
        return count
    }

    /// A new album holding `count` tracks, saved in one go. Returns the album.
    static func bulkAlbum(tracks count: Int) -> Album {
        let tracks = (1...count).map { number in
            Track(
                title: "Take \(number)", number: number, seconds: Double(60 + number % 300),
                mood: Mood.allCases[number % Mood.allCases.count]
            )
        }
        return Album(
            title: "Bulk Session \(Date.now.formatted(date: .omitted, time: .shortened))", year: 2026,
            cover: nil, tracks: tracks
        )
    }

    /// Deletes every record in the context's zone, one type at a time, and returns how many.
    /// Deleting an album would delete its tracks and artwork anyway, but any left on their own
    /// go too.
    @discardableResult
    static func eraseAll(in context: RecordContext) throws -> Int {
        try context.delete(Review.self) + context.delete(Venue.self) + context.delete(Playlist.self)
            + context.delete(Album.self) + context.delete(Artist.self) + context.delete(Track.self)
            + context.delete(Artwork.self)
    }
}
