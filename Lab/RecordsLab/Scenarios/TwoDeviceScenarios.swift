import Foundation
import Records
import SwiftUI

/// Scenarios that need a second device running the Lab, signed in to the same iCloud account.
/// They work on the catalog in the app's own zone, so seed it on one device only and let the
/// other fetch it, or each device holds its own copy.
@MainActor
enum TwoDeviceScenarios {
    static var all: [Scenario] {
        [push, bothEdit, deleteArrives]
    }

    /// The first album in the catalog, or a failure saying to seed it.
    private static func firstAlbum(in context: RecordContext, _ lab: Lab) throws -> Album {
        let albums = try context.fetch(RecordDescriptor<Album>(sortBy: [SortDescriptor(\.title)]))
        return try lab.unwrap("The catalog has an album. Seed it on one device and fetch on the other", albums.first)
    }

    /// Waits for a fetch from iCloud that started after `date`, without refreshing.
    private static func waitForFetch(after date: Date?, in context: RecordContext, _ lab: Lab) async throws {
        try await lab.wait("A change arrives here without a refresh", timeout: .seconds(90)) {
            context.events.lastSynced.map { $0 > (date ?? .distantPast) } ?? false
        }
    }

    static let push = Scenario(
        id: "twoDevices.push", group: .twoDevices, title: "A change arrives on its own", symbol: "bell.badge",
        summary: "You rename an album on the other device. iCloud tells this device, which fetches the change without a pull to refresh."
    ) { lab in
        let context = try await lab.cloud()
        context.zone = .records
        let album = try firstAlbum(in: context, lab)
        let before = context.events.lastSynced
        _ = await lab.ask(
            "Rename an album on the other device",
            detail: "On the other device, open Catalog, open \"\(album.title)\", change its title, and save. Then tap Done here. Don't pull to refresh on this device.",
            answers: .done
        ) { EmptyView() }
        try await waitForFetch(after: before, in: context, lab)
        let here = try lab.unwrap("Read the album here", try context.record(id: album.id))
        try lab.check("The new title is here", here.title != album.title, expected: "a new title", actual: here.title)
        lab.metric("New title", here.title)
    }

    static let bothEdit = Scenario(
        id: "twoDevices.bothEdit", group: .twoDevices, title: "Both devices edit one album", symbol: "arrow.triangle.merge",
        summary: "This device changes an album's year while you change its rating on the other device. Both changes end up on both devices."
    ) { lab in
        let context = try await lab.cloud()
        context.zone = .records
        var album = try firstAlbum(in: context, lab)
        let year = album.year == 1999 ? 2001 : 1999
        let rating: Rating = album.rating == .one ? .five : .one
        try await lab.act("Change its year here to \(year)") {
            album.year = year
            context.insert(album)
            try context.save()
        }
        let before = context.events.lastSynced
        _ = await lab.ask(
            "Change its rating on the other device",
            detail: "On the other device, open \"\(album.title)\" and set its rating to \(rating.rawValue) stars, then save. Tap Done here.",
            answers: .done
        ) { EmptyView() }
        try await waitForFetch(after: before, in: context, lab)
        let here = try lab.unwrap("Read the album here", try context.record(id: album.id))
        try lab.expect("This device kept its year", here.year, year)
        try lab.expect("The other device's rating arrived", here.rating, rating)
        let other = await lab.ask(
            "Check the other device",
            detail: "On the other device, does \"\(album.title)\" show the year \(year) and \(rating.rawValue) stars?"
        ) { EmptyView() }
        try lab.check("The other device has both changes", other, expected: "Yes", actual: "No")
    }

    static let deleteArrives = Scenario(
        id: "twoDevices.deleteArrives", group: .twoDevices, title: "A delete arrives with what it owns", symbol: "trash",
        summary: "You delete an album on the other device. It disappears here, with its tracks and artwork."
    ) { lab in
        let context = try await lab.cloud()
        context.zone = .records
        let album = try firstAlbum(in: context, lab)
        let before = context.events.lastSynced
        _ = await lab.ask(
            "Delete an album on the other device",
            detail: "On the other device, open \"\(album.title)\", tap Delete album, and save. Tap Done here.",
            answers: .done
        ) { EmptyView() }
        try await waitForFetch(after: before, in: context, lab)
        try lab.check("The album is gone here", try context.record(id: album.id) == nil, expected: "gone", actual: "still here")
        let tracks = try album.$tracks.ids.filter { try context.record(id: $0) != nil }.count
        try lab.expect("Its tracks are gone here", tracks, 0)
        if let artwork = album.$artwork.id {
            try lab.check("Its artwork is gone here", try context.record(id: artwork) == nil, expected: "gone", actual: "still here")
        }
    }
}
