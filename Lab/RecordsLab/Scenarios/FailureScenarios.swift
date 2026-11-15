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
        summary: "Saves a review whose text is 1.2 MB, over iCloud's limit for a record, beside a small one. The save must throw, naming the large review, and write neither. Then the small one saves alone and uploads, leaving nothing waiting."
    ) { lab in
        let context = try await lab.cloud()
        let ghost = Ghost()
        let small = Review(text: "Fits.", score: 3)
        let large = Review(text: String(repeating: "x", count: 1_200_000), score: 1)
        var thrown: (any Error)?
        try await lab.act("Save a 1.2 MB review and a small one") {
            context.insert(small)
            context.insert(large)
            do { try context.save() } catch { thrown = error }
        }
        let kept = context.hasChanges
        let saved = try context.record(id: small.id) != nil
        try await lab.act("Drop the large review and save the small one") {
            context.rollback(id: large.id)
            try context.save()
        }
        try await lab.waitForUploads(context)
        let uploaded = try await ghost.fetch(ghost.id(of: small)) != nil

        var named = false
        if case .recordTooLarge(_, let id, _) = thrown as? RecordContextError { named = id == large.id.rawValue }
        try lab.check("The save threw for the large review", named, expected: "recordTooLarge", actual: thrown.map { "\($0)" } ?? "no error")
        if let thrown { lab.metric("Error", "\(thrown)") }
        try lab.check("Nothing was written", !saved, expected: "nothing", actual: "the small review")
        try lab.check("The changes stayed in the context", kept, expected: "kept", actual: "dropped")
        try lab.check("The small review reached iCloud alone", uploaded, expected: "uploaded", actual: "missing")
        lab.metric("Waiting to upload", context.pendingUploads == 0 ? "nothing" : "\(context.pendingUploads)")
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
