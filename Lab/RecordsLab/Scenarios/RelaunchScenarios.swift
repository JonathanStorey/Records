import Foundation
import Records

/// Scenarios that quit the app and open it again. Each saves what it needs, asks you to quit,
/// and finishes on its own at the next launch.
@MainActor
enum RelaunchScenarios {
    static var all: [Scenario] {
        [offline, resumes, assets, schema, signedOut]
    }

    /// The text the schema scenario saves in place of the real schema.
    private static let changedSchema = "Changed(by:lab)"

    /// Runs before the container opens. The schema scenario changes the saved schema here, as
    /// an app update that adds a field would, so the container sees it at open.
    static func beforeOpening() {
        guard var resume = Resume.saved, resume.scenario == schema.id, resume.values["phase"] == "change" else { return }
        let changed = Inspector.change("UPDATE \"_SyncState\" SET state = '\(changedSchema)' WHERE scope = 'schema'")
        resume.values["phase"] = changed == 1 ? "changed" : "unchanged"
        resume.save()
    }

    /// How many records and deletions sync has fetched since launch, from its log.
    static func fetchedSinceLaunch() -> Int {
        let lines = (try? LogLine.read()) ?? []
        return lines.filter { $0.subsystem == "Records" }.reduce(0) { total, line in
            guard let match = line.message.firstMatch(of: /Fetched (\d+) records and (\d+) deletions/) else { return total }
            return total + (Int(match.1) ?? 0) + (Int(match.2) ?? 0)
        }
    }

    /// Records this device has that iCloud has confirmed, in every table.
    static func syncedRecords() -> Int {
        Inspector.tables().reduce(0) { $0 + $1.synced }
    }

    // MARK: - Offline

    static let offline = Scenario(
        id: "relaunch.offline", group: .relaunch, title: "A save made offline uploads later", symbol: "airplane",
        summary: "Saves a record in airplane mode. It waits to upload and nothing arrives from iCloud. Then you quit, turn airplane mode off, and open the Lab, and the record uploads."
    ) { lab in
        let context = try await lab.cloud()
        if let kept = lab.resumed {
            let id = try lab.unwrap("The saved artist's ID", kept["artist"].flatMap(UUID.init(uuidString:)))
            let artist = try lab.unwrap("The artist is still here", try context.record(id: Artist.ID(rawValue: id)))
            try await lab.waitForUploads(context, timeout: .seconds(120))
            let ghost = Ghost()
            try await lab.poll("iCloud has the artist") { try await ghost.fetch(ghost.id(of: artist)) != nil }
            return
        }
        _ = await lab.ask("Turn on airplane mode", detail: "Open Control Center, turn on airplane mode, and come back.", answers: .done) {
            EmptyView()
        }
        let lastSynced = context.events.lastSynced
        let artist = Artist(name: "Offline", founded: .now, genres: [])
        try await lab.act("Save an artist") {
            context.insert(artist)
            try context.save()
        }
        try await lab.act("Give sync 5 seconds to try") { try await Task.sleep(for: .seconds(5)) }
        try lab.check("It waits to upload", context.pendingUploads > 0, expected: "1 or more", actual: "0")
        try lab.check("Nothing arrived from iCloud", context.events.lastSynced == lastSynced, expected: "no fetch", actual: "a fetch")
        try await lab.relaunch(
            "Tap Quit now, turn airplane mode off, then open the Lab again. The scenario finishes on its own.",
            keeping: ["artist": artist.id.uuidString]
        )
    }

    // MARK: - Resuming

    static let resumes = Scenario(
        id: "relaunch.resumes", group: .relaunch, title: "Sync resumes where it left off", symbol: "arrow.uturn.forward",
        summary: "Syncs, quits, and opens again. Sync starts from its saved state, so it fetches only what changed since, not every record again."
    ) { lab in
        let context = try await lab.cloud()
        if lab.resumed != nil {
            try await lab.refresh(context)
            let fetched = fetchedSinceLaunch()
            let synced = syncedRecords()
            lab.metric("Fetched since launch", "\(fetched) of \(synced) synced records")
            try lab.check("Only what changed was fetched", fetched < synced, expected: "fewer than \(synced)", actual: "\(fetched)")
            return
        }
        try await lab.act("Save an artist") {
            context.insert(Artist(name: "Resumer", founded: .now, genres: []))
            try context.save()
        }
        try await lab.waitForUploads(context)
        try await lab.refresh(context)
        try lab.check("Sync saved its state", Inspector.syncState().contains("private"), expected: "saved", actual: "none")
        try await lab.relaunch("Tap Quit now, then open the Lab again. The scenario finishes on its own.")
    }

    // MARK: - Asset files

    static let assets = Scenario(
        id: "relaunch.assets", group: .relaunch, title: "Unused asset files go at launch", symbol: "doc.badge.clock",
        summary: "Leaves a stray asset file that no record uses beside one a saved album uses. At the next launch, the stray file is removed and the used one stays."
    ) { lab in
        let context = try await lab.cloud()
        if let kept = lab.resumed {
            let stray = Inspector.assetsURL.appending(path: "\(kept["stray"] ?? "").asset")
            let used = Inspector.assetsURL.appending(path: "\(kept["used"] ?? "").asset")
            try lab.check("The stray file is gone", !FileManager.default.fileExists(atPath: stray.path), expected: "removed", actual: "still there")
            try lab.check("The album's cover is still there", FileManager.default.fileExists(atPath: used.path), expected: "kept", actual: "removed")
            return
        }
        let album = Album(title: "Keeper", year: 2020, cover: Media.cover("photo", hue: 0.3, size: 64))
        try await lab.act("Save an album with a cover") {
            context.insert(album)
            try context.save()
        }
        let saved = try lab.unwrap("Read the album here", try context.record(id: album.id))
        let used = try lab.unwrap("The cover has an ID", saved._cover.id)
        try lab.check(
            "The cover's file is in the asset folder",
            FileManager.default.fileExists(atPath: Inspector.assetsURL.appending(path: "\(used.uuidString).asset").path),
            expected: "the file", actual: "none"
        )
        let stray = UUID()
        try await lab.act("Leave a stray asset file") {
            try Data("unused".utf8).write(to: Inspector.assetsURL.appending(path: "\(stray.uuidString).asset"))
        }
        try await lab.relaunch(
            "Tap Quit now, then open the Lab again. The scenario finishes on its own.",
            keeping: ["stray": stray.uuidString, "used": used.uuidString]
        )
    }

    // MARK: - Schema

    static let schema = Scenario(
        id: "relaunch.schema", group: .relaunch, title: "A changed schema fetches everything", symbol: "tablecells.badge.ellipsis",
        summary: "Changes the saved schema before the container opens, as an app update that adds a field would. Sync then drops its saved state and fetches every record again."
    ) { lab in
        let context = try await lab.cloud()
        if let kept = lab.resumed {
            try lab.expect("The saved schema was changed before the container opened", kept["phase"], "changed")
            try lab.check("The container saved the real schema again", Inspector.syncValue("schema") != changedSchema, expected: "the real schema", actual: changedSchema)
            try await lab.refresh(context)
            let synced = syncedRecords()
            try await lab.poll("Sync fetches every record again", timeout: .seconds(120)) { fetchedSinceLaunch() >= synced }
            lab.metric("Fetched since launch", "\(fetchedSinceLaunch()) for \(synced) synced records")
            return
        }
        try await lab.act("Save an artist") {
            context.insert(Artist(name: "Schema", founded: .now, genres: []))
            try context.save()
        }
        try await lab.waitForUploads(context)
        try await lab.relaunch(
            "Tap Quit now, then open the Lab again. The Lab changes the saved schema before the container opens.",
            keeping: ["phase": "change"]
        )
    }

    // MARK: - Signed out

    static let signedOut = Scenario(
        id: "relaunch.signedOut", group: .relaunch, title: "Records stay without iCloud", symbol: "icloud.slash",
        summary: "On a device that isn't signed in to iCloud, saves a record, quits and opens again. The record is still there, waiting to upload once someone signs in. Skipped on a signed-in device."
    ) { lab in
        let container = try lab.container()
        let status = try await CKContainer.default().accountStatus()
        guard status == .noAccount else {
            try lab.skip("Runs only on a device that isn't signed in to iCloud")
        }
        let context = container.mainContext
        context.zone = Ghost.zone
        if let kept = lab.resumed {
            let id = try lab.unwrap("The saved artist's ID", kept["artist"].flatMap(UUID.init(uuidString:)))
            _ = try lab.unwrap("The artist is still here", try context.record(id: Artist.ID(rawValue: id)))
            lab.metric("Waiting to upload", "\(context.pendingUploads)")
            return
        }
        let artist = Artist(name: "Signed out", founded: .now, genres: [])
        try await lab.act("Save an artist") {
            context.insert(artist)
            try context.save()
        }
        try await lab.relaunch(
            "Tap Quit now, then open the Lab again. The scenario finishes on its own.",
            keeping: ["artist": artist.id.uuidString]
        )
    }
}
