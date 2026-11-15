import Foundation
import Records

/// Scenarios that push iCloud past its limits. Each works in the Lab zone and cleans up after
/// itself.
@MainActor
enum FailureScenarios {
    static var all: [Scenario] {
        [tooLarge, largeBatch]
    }

    static let tooLarge = Scenario(
        id: "failures.tooLarge", group: .failures, title: "A record over 1 MB", symbol: "externaldrive.badge.xmark",
        summary: "Saves a review whose text is 1.2 MB, over CloudKit's limit for a record, beside a small one. The small one uploads, the large one doesn't, and the log names it. The result says whether the large one keeps waiting to upload. Deleting it afterwards must clear it."
    ) { lab in
        let context = try await lab.cloud()
        let ghost = Ghost()
        let small = Review(text: "Fits.", score: 3)
        let large = Review(text: String(repeating: "x", count: 1_200_000), score: 1)
        let start = Date.now
        try await lab.act("Save a 1.2 MB review and a small one") {
            context.insert(small)
            context.insert(large)
            try context.save()
        }
        try await lab.poll("The small review reaches iCloud") { try await ghost.fetch(ghost.id(of: small)) != nil }
        try await lab.act("Give sync 10 more seconds") { try await Task.sleep(for: .seconds(10)) }

        // Read everything first, so the large review is deleted even when a check fails.
        let uploaded = try await ghost.fetch(ghost.id(of: large)) != nil
        let lines = (try? LogLine.read()) ?? []
        let logged = lines.first { $0.date >= start && $0.message.contains(large.id.rawValue.uuidString) }
        let waiting = context.pendingUploads
        try await lab.act("Delete the large review") {
            context.delete(large)
            try context.save()
        }

        try lab.check("iCloud refused the large review", !uploaded, expected: "refused", actual: "uploaded")
        try lab.check("The log names it", logged != nil, expected: "a log line", actual: "none")
        if let logged { lab.metric("Logged", logged.message) }
        lab.metric("Waiting to upload after the failure", waiting == 0 ? "nothing" : "\(waiting), retried at every save, refresh and launch")
        try await lab.waitForUploads(context)
    }

    static let largeBatch = Scenario(
        id: "failures.largeBatch", group: .failures, title: "5,000 tracks in one save", symbol: "square.stack.3d.up.badge.automatic",
        summary: "Saves an album of 5,000 tracks in one go and times the upload, about 10,000 CloudKit records with the links. Watches the log for the server refusing a batch as too large. Deletes the Lab zone afterwards."
    ) { lab in
        let context = try await lab.cloud()
        let ghost = Ghost()
        let album = Seed.bulkAlbum(tracks: 5_000)
        let start = Date.now
        let saving = try await lab.act("Save an album of 5,000 tracks") {
            context.insert(album)
            try context.save()
        }
        lab.metric("Save", saving.label)
        let uploading = ContinuousClock.now
        try await lab.waitForUploads(context, timeout: .seconds(600))
        let elapsed = ContinuousClock.now - uploading
        lab.metric("Upload", "\(elapsed.label), \(Int(10_001 / max(elapsed.seconds, 0.001))) CloudKit records a second")

        let uploaded = try await ghost.fetch(ghost.id(of: album)) != nil
        let refused = ((try? LogLine.read()) ?? []).filter {
            $0.date >= start && $0.subsystem == "Records" && $0.message.localizedCaseInsensitiveContains("limit")
        }
        try await lab.act("Delete the Lab zone") { try await ghost.deleteZone() }
        try await lab.refresh(context)

        try lab.check("iCloud has the album", uploaded, expected: "the album", actual: "none")
        lab.metric("Batches refused as too large", refused.isEmpty ? "none" : "\(refused.count): \(refused[0].message)")
    }
}
