import Foundation
import Records

/// Scenarios where a second device, played by the Lab, changes the same records in iCloud. Each
/// one works in the Lab zone with records of its own. The last one deletes the zone, so a run
/// leaves iCloud as it found it.
@MainActor
enum GhostScenarios {
    static var all: [Scenario] {
        [mergeFields, sameField, deletedThere, deletedHere, assetReplaced, strangers, zoneDeleted]
    }

    // MARK: - Merging

    static let mergeFields = Scenario(
        id: "ghost.merge", group: .ghost, title: "Edits to different fields merge", symbol: "arrow.triangle.merge",
        summary: "The ghost renames an album while this device changes its year. After a fetch, both devices have the new title and the new year."
    ) { lab in
        let context = try await lab.cloud()
        let ghost = Ghost()
        let album = Album(title: "Harbor", year: 2019, cover: nil)
        try await save(album, in: context, lab)

        try await lab.act("The ghost renames it") { try await ghost.edit(album) { $0.title = "Harbor Lights" } }
        try await lab.act("Change its year here") { try edit(album, in: context) { $0.year = 2020 } }
        try await lab.refresh(context)
        try await lab.waitForUploads(context)

        let here = try lab.unwrap("Read the album here", try context.record(id: album.id))
        try lab.expect("This device has the ghost's title", here.title, "Harbor Lights")
        try lab.expect("This device kept its year", here.year, 2020)
        let there = try lab.unwrap("Read the album in iCloud", try await ghost.copy(of: album))
        try lab.expect("iCloud has the ghost's title", there.title, "Harbor Lights")
        try lab.expect("iCloud has this device's year", there.year, 2020)
    }

    static let sameField = Scenario(
        id: "ghost.sameField", group: .ghost, title: "The same field changed on both", symbol: "arrow.left.arrow.right",
        summary: "The ghost and this device both rename an album. The edit still waiting here when the ghost's arrives wins, and both devices end up with it."
    ) { lab in
        let context = try await lab.cloud()
        let ghost = Ghost()
        let album = Album(title: "Tide", year: 2010, cover: nil)
        try await save(album, in: context, lab)

        try await lab.act("The ghost renames it") { try await ghost.edit(album) { $0.title = "The Ghost's Title" } }
        try await lab.act("Rename it here too") { try edit(album, in: context) { $0.title = "This Device's Title" } }
        try await lab.refresh(context)
        try await lab.waitForUploads(context)

        let here = try lab.unwrap("Read the album here", try context.record(id: album.id))
        try lab.expect("This device kept its title", here.title, "This Device's Title")
        let there = try lab.unwrap("Read the album in iCloud", try await ghost.copy(of: album))
        try lab.expect("iCloud has this device's title", there.title, "This Device's Title")
    }

    // MARK: - Deleting

    static let deletedThere = Scenario(
        id: "ghost.deletedThere", group: .ghost, title: "Deleted there, edited here", symbol: "trash.slash",
        summary: "The ghost deletes an album and its tracks, as a device running Records would, while this device renames it. The edit wins, so the album comes back on both devices with the new title. Its tracks stay deleted, and the result says how many it came back with."
    ) { lab in
        let context = try await lab.cloud()
        let ghost = Ghost()
        let tracks = [Track(title: "One", number: 1, seconds: 100, mood: .calm), Track(title: "Two", number: 2, seconds: 120, mood: .calm)]
        let album = Album(title: "Gone", year: 2001, cover: nil, tracks: tracks)
        try await save(album, in: context, lab)

        let saved = try lab.unwrap("Read the album here", try context.record(id: album.id))
        try await lab.act("The ghost deletes the album and its tracks") {
            try await ghost.delete([saved] + saved.tracks.map { $0 as any Record })
        }
        try await lab.act("Rename it here") { try edit(album, in: context) { $0.title = "Back Again" } }
        try await lab.refresh(context)
        try await lab.waitForUploads(context)

        let here = try lab.unwrap("The album is still here", try context.record(id: album.id))
        try lab.expect("It has this device's title", here.title, "Back Again")
        try await lab.poll("iCloud has the album again") { try await ghost.fetch(ghost.id(of: album)) != nil }
        let there = try lab.unwrap("Read the album in iCloud", try await ghost.copy(of: album))
        try lab.expect("iCloud has this device's title", there.title, "Back Again")
        lab.metric("Tracks it came back with", "\(here.$tracks.count) of \(tracks.count)")
    }

    static let deletedHere = Scenario(
        id: "ghost.deletedHere", group: .ghost, title: "Deleted here, edited there", symbol: "trash",
        summary: "This device deletes an album while the ghost renames it. Records keeps the ghost's edit when the fetch arrives before the delete uploads, but CloudKit deletes without checking for changes, so the delete wins when it uploads first. Either way, both devices must end up agreeing. The result says which side won."
    ) { lab in
        let context = try await lab.cloud()
        let ghost = Ghost()
        let album = Album(title: "Fragile", year: 2005, cover: nil)
        try await save(album, in: context, lab)
        let created = try await ghost.fetch(ghost.id(of: album))?.creationDate

        try await lab.act("The ghost renames it") { try await ghost.edit(album) { $0.title = "Renamed There" } }
        try await lab.act("Delete it here") {
            context.delete(try lab.unwrap("Read the album here", try context.record(id: album.id)))
            try context.save()
        }
        try await lab.refresh(context)
        try await lab.waitForUploads(context)

        var result = ""
        try await lab.poll("Both devices agree") {
            let here = try context.record(id: album.id)
            let there = try await ghost.copy(of: album)
            switch (here, there) {
            case (nil, nil):
                result = "The delete won"
                return true
            case let (here?, there?) where here.title == there.title:
                result = here.title == "Renamed There" ? "The ghost's edit won" : "Both kept \"\(here.title)\""
                return true
            default:
                return false
            }
        }
        lab.metric("Result", result)
        if let server = try await ghost.fetch(ghost.id(of: album)) {
            lab.metric("iCloud's copy", server.creationDate == created ? "the original" : "deleted and made again")
        }
    }

    // MARK: - Assets

    static let assetReplaced = Scenario(
        id: "ghost.assetReplaced", group: .ghost, title: "An asset replaced there", symbol: "photo.badge.arrow.down",
        summary: "The ghost gives an album a new cover. After a fetch, this device has the new cover's bytes in its own asset folder. The old file stays until the next launch removes unused files, which Lab 3 checks."
    ) { lab in
        let context = try await lab.cloud()
        let ghost = Ghost()
        let oldCover = Media.cover("sun.max", hue: 0.12, size: 160)
        let newCover = Media.cover("moon.stars", hue: 0.66, size: 160)
        let album = Album(title: "Daybreak", year: 2012, cover: oldCover)
        try await save(album, in: context, lab)
        let saved = try lab.unwrap("Read the album here", try context.record(id: album.id))
        let oldID = try lab.unwrap("The old cover has an ID", saved._cover.id)

        var newID: UUID?
        try await lab.act("The ghost gives it a new cover") {
            var edited = try lab.unwrap("Read the album in iCloud", try await ghost.copy(of: album))
            edited.cover = newCover
            newID = edited._cover.id
            try await ghost.saveLinks(of: edited)
            // The ghost's own copy of the file goes, so this device has to download it.
            if let newID { try? FileManager.default.removeItem(at: AssetField.url(for: newID)) }
        }
        try await lab.refresh(context)

        let id = try lab.unwrap("The new cover has an ID", newID)
        let here = try lab.unwrap("Read the album here", try context.record(id: album.id))
        try lab.expect("This device has the new cover", here._cover.id, id)
        try lab.expect("The new cover's bytes match", here.cover, newCover)
        let newFile = Inspector.assetsURL.appending(path: "\(id.uuidString).asset", directoryHint: .notDirectory)
        try lab.check("The new cover is in the app's asset folder", FileManager.default.fileExists(atPath: newFile.path), expected: "the file", actual: "none")
        let oldFile = Inspector.assetsURL.appending(path: "\(oldID.uuidString).asset", directoryHint: .notDirectory)
        lab.metric("The old cover's file", FileManager.default.fileExists(atPath: oldFile.path) ? "kept until the next launch" : "already removed")
    }

    // MARK: - Strangers

    static let strangers = Scenario(
        id: "ghost.strangers", group: .ghost, title: "Records this app can't read", symbol: "questionmark.folder",
        summary: "The ghost saves a record of a type this app doesn't know, an album missing its year, and a normal album. Sync must skip the first two, log them, and still bring in the third. The ghost deletes the first two afterwards."
    ) { lab in
        let context = try await lab.cloud()
        let ghost = Ghost()
        try await lab.act("The ghost makes sure the Lab zone exists") { try await ghost.createZone() }

        let unknown = CKRecord(recordType: "LabUnknown", recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: Ghost.zone.zoneID))
        unknown["note"] = "A type this app doesn't register"
        let broken = CKRecord(recordType: Album.recordType, recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: Ghost.zone.zoneID))
        broken["title"] = "Missing its year"
        let normal = Album(title: "Still Arrives", year: 2002, cover: nil)
        let start = Date.now
        try await lab.act("The ghost saves all three") { try await ghost.save([unknown, broken, ghost.encode(normal)]) }
        try await lab.refresh(context)

        // Read everything first, so the two strangers are deleted even when a check fails.
        let arrived = try? context.record(id: normal.id)
        let albums = Result { try context.fetch(RecordDescriptor<Album>()) }
        let lines = (try? LogLine.read()) ?? []
        try await lab.act("The ghost deletes the two strangers") { try await ghost.delete(ids: [unknown.recordID, broken.recordID]) }
        try await lab.refresh(context)

        try lab.check("The normal album arrived", arrived != nil, expected: "the album", actual: "none")
        switch albums {
        case .success(let list):
            let read = list.contains { $0.id.rawValue.uuidString == broken.recordID.recordName }
            try lab.check("Albums still read with a broken one in iCloud", !read, expected: "the broken album left out", actual: "it was read")
        case .failure(let error):
            try lab.check("Albums still read with a broken one in iCloud", false, expected: "a list of albums", actual: String(describing: error))
        }
        let logged = lines.contains { $0.date >= start && $0.message.contains(broken.recordID.recordName) }
        try lab.check("The log names the broken album", logged, expected: "a log line", actual: "none")
        let unknownLogged = lines.contains { $0.date >= start && $0.message.contains("LabUnknown") }
        lab.metric("The unknown type", unknownLogged ? "skipped and logged" : "skipped, with no log line kept")
    }

    // MARK: - The zone

    static let zoneDeleted = Scenario(
        id: "ghost.zoneDeleted", group: .ghost, title: "The zone deleted there", symbol: "xmark.bin",
        summary: "The ghost deletes the whole Lab zone. After a fetch, every record in it is gone from this device, and the catalog in the app's own zone is untouched. Runs last, and leaves iCloud as it found it."
    ) { lab in
        let context = try await lab.cloud()
        let ghost = Ghost()
        try await save(Artist(name: "Last One", founded: .now, genres: []), in: context, lab)
        let catalog = try total(in: .records, context)

        try await lab.act("The ghost deletes the Lab zone") { try await ghost.deleteZone() }
        try await lab.refresh(context)

        try lab.expect("Nothing is left in the Lab zone here", try total(in: Ghost.zone, context), 0)
        try lab.expect("The catalog in the app's zone is untouched", try total(in: .records, context), catalog)
        let exists = try await ghost.zoneExists(Ghost.zone)
        try lab.check("iCloud no longer has the Lab zone", !exists, expected: "no zone", actual: "the zone")
    }

    // MARK: - Helpers

    /// Inserts `record`, saves, and waits for iCloud to confirm it.
    private static func save(_ record: some Record, in context: RecordContext, _ lab: Lab) async throws {
        try await lab.act("Save a \(type(of: record).recordType) and let it upload") {
            context.insert(record)
            try context.save()
        }
        try await lab.waitForUploads(context)
    }

    /// Reads `record` as saved, changes it with `change`, and saves.
    private static func edit<R: Record>(_ record: R, in context: RecordContext, _ change: (inout R) -> Void) throws {
        guard var saved = try context.record(id: record.id) else {
            throw LabFailure(step: "Edit the \(R.recordType) here", expected: "the saved record", actual: "none")
        }
        change(&saved)
        context.insert(saved)
        try context.save()
    }

    /// How many records of every type `context` holds in `zone`.
    private static func total(in zone: Zone, _ context: RecordContext) throws -> Int {
        let current = context.zone
        context.zone = zone
        defer { context.zone = current }
        return try Catalog.types.reduce(0) { sum, type in sum + (try count(type, context)) }
    }

    private static func count<R: Record>(_ type: R.Type, _ context: RecordContext) throws -> Int {
        try context.fetchCount(RecordDescriptor<R>())
    }
}
