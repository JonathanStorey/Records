import Foundation
import Observation
import Testing
@testable import Records

// A staged record is saved as its difference from the saved record it started from, so changes
// made elsewhere in the meantime to anything it didn't touch survive.

@MainActor
private func twoContexts() throws -> (RecordContext, RecordContext) {
    let container = try RecordContainer(for: [Novel.self, Page.self], url: nil)
    return (container.mainContext, RecordContext(container: container))
}

private func novel(_ title: String, year: Int) -> Novel {
    Novel(
        id: UUID(), title: title, subtitle: nil, tags: [], year: year, note: nil,
        cover: nil, shop: nil, sequel: nil, writers: [], editorID: nil
    )
}

@MainActor
@Test func savingAStaleDraftKeepsFieldsItDidNotEdit() throws {
    let (here, elsewhere) = try twoContexts()
    let saved = novel("Blue", year: 1971)
    here.insert(saved)
    try here.save()

    var draft = saved
    draft.year = 1972
    here.insert(draft)

    var remote = saved
    remote.title = "Blue (Remastered)"
    elsewhere.insert(remote)
    try elsewhere.save()

    try here.save()
    let result = try #require(try here.record(id: saved.id, for: Novel.self))
    #expect(result.title == "Blue (Remastered)")
    #expect(result.year == 1972)
}

@MainActor
@Test func stagingAgainKeepsTheFirstOriginal() throws {
    let (here, elsewhere) = try twoContexts()
    let saved = novel("Blue", year: 1971)
    here.insert(saved)
    try here.save()

    var draft = saved
    draft.year = 1972
    here.insert(draft)

    var remote = saved
    remote.title = "Blue (Remastered)"
    elsewhere.insert(remote)
    try elsewhere.save()

    // The draft still holds the old title, but it never edited it.
    draft.year = 1973
    here.insert(draft)
    try here.save()
    let result = try #require(try here.record(id: saved.id, for: Novel.self))
    #expect(result.title == "Blue (Remastered)")
    #expect(result.year == 1973)
}

@MainActor
@Test func aFieldEditedOnBothSidesTakesTheLastSave() throws {
    let (here, elsewhere) = try twoContexts()
    let saved = novel("Blue", year: 1971)
    here.insert(saved)
    try here.save()

    var draft = saved
    draft.title = "Blue (Live)"
    here.insert(draft)

    var remote = saved
    remote.title = "Blue (Remastered)"
    elsewhere.insert(remote)
    try elsewhere.save()

    try here.save()
    #expect(try here.record(id: saved.id, for: Novel.self)?.title == "Blue (Live)")
}

@MainActor
@Test func savingAStaleDraftKeepsLinksItDidNotEdit() throws {
    let (here, elsewhere) = try twoContexts()
    let labels = ["x", "y", "z", "w"].map { Label(id: UUID(), name: $0) }
    let saved = Page(id: UUID(), title: "Page", labels: [labels[0], labels[1]], pinnedIDs: [])
    here.insert(saved)
    try here.save()

    // Here adds z. Elsewhere removes y and adds w.
    var draft = saved
    draft.labels = [labels[0], labels[1], labels[2]]
    here.insert(draft)

    var remote = saved
    remote.labels = [labels[0], labels[3]]
    elsewhere.insert(remote)
    try elsewhere.save()

    try here.save()
    let page = try #require(try here.record(id: saved.id, for: Page.self))
    let ids = Set(page.referenceStates.first { $0.property == "labels" }?.ids ?? [])
    #expect(ids == [labels[0].id, labels[2].id, labels[3].id])
}

@MainActor
@Test func aDraftOfARecordDeletedElsewhereRestoresItWhole() throws {
    let (here, elsewhere) = try twoContexts()
    let saved = novel("Blue", year: 1971)
    here.insert(saved)
    try here.save()

    var draft = saved
    draft.year = 1972
    here.insert(draft)

    elsewhere.delete(saved)
    try elsewhere.save()

    try here.save()
    let result = try #require(try here.record(id: saved.id, for: Novel.self))
    #expect(result.title == "Blue")
    #expect(result.year == 1972)
}

@MainActor
@Test func changesListTheStagedDifferences() throws {
    let (here, _) = try twoContexts()
    let kept = novel("Kept", year: 2000)
    let gone = novel("Gone", year: 2001)
    here.insert(kept)
    here.insert(gone)
    try here.save()

    here.insert(kept)
    here.delete(gone)
    let changes: [RecordDifference.Change] = here.changes
    #expect(changes == [.insert(kept.id), .delete(gone.id)])
    #expect(changes.map(\.id) == [kept.id, gone.id])
    let differences = here.differences
    #expect((differences[0].original as? Novel)?.title == "Kept")
    #expect(differences[1].value == nil)
}

/// Staging a record again updates its difference in place, so anything observing it sees the
/// new change. The original stays the one first staged.
@MainActor
@Test func stagingAgainUpdatesTheSameDifference() throws {
    let (here, _) = try twoContexts()
    let saved = novel("Blue", year: 1971)
    here.insert(saved)
    try here.save()

    var draft = saved
    draft.year = 1972
    here.insert(draft)
    let difference = try #require(here.differences.first)

    let observed = Flag()
    withObservationTracking {
        _ = difference.draft
    } onChange: {
        observed.set()
    }
    draft.year = 1973
    here.insert(draft)

    #expect(observed.isSet)
    #expect(here.changes.count == 1)
    #expect(here.differences.first === difference)
    #expect((difference.draft as? Novel)?.year == 1973)
    #expect(difference.change == .insert(saved.id))
    #expect((difference.original as? Novel)?.year == 1971)
}

@MainActor
@Test func aPageDeletedElsewhereComesBackWithItsLinks() throws {
    let (here, elsewhere) = try twoContexts()
    let labels = ["x", "y"].map { Label(id: UUID(), name: $0) }
    let saved = Page(id: UUID(), title: "Page", labels: labels, pinnedIDs: [])
    here.insert(saved)
    try here.save()

    var draft = saved
    draft.title = "Renamed"
    here.insert(draft)
    elsewhere.delete(saved)
    try elsewhere.save()

    try here.save()
    let page = try #require(try here.record(id: saved.id, for: Page.self))
    #expect(page.title == "Renamed")
    #expect(page.referenceStates.first { $0.property == "labels" }?.ids == labels.map(\.id))
}

// MARK: - Reading drafts

/// Reads lay a draft's edits over the latest saved record, as saving would write it.
@MainActor
@Test func aStaleDraftReadsWithChangesMadeElsewhere() throws {
    let (here, elsewhere) = try twoContexts()
    let saved = novel("Blue", year: 1971)
    here.insert(saved)
    try here.save()

    var draft = saved
    draft.year = 1972
    here.insert(draft)

    var remote = saved
    remote.title = "Blue (Remastered)"
    elsewhere.insert(remote)
    try elsewhere.save()

    let read = try #require(try here.record(id: saved.id, for: Novel.self))
    #expect(read.title == "Blue (Remastered)")
    #expect(read.year == 1972)
    #expect((try here.record(id: saved.id) as? Novel)?.title == "Blue (Remastered)")

    let fetched = try here.fetch(RecordDescriptor<Novel>(predicate: #Predicate { $0.year == 1972 }))
    #expect(fetched.map(\.title) == ["Blue (Remastered)"])
    #expect(try here.fetchCount(RecordDescriptor<Novel>(predicate: #Predicate { $0.title == "Blue (Remastered)" })) == 1)
}

/// Reading staged changes writes nothing: they stay staged and the database stays as it was.
@MainActor
@Test func readingDraftsWritesNothing() throws {
    let (here, elsewhere) = try twoContexts()
    let saved = novel("Blue", year: 1971)
    here.insert(saved)
    try here.save()

    var draft = saved
    draft.year = 1972
    here.insert(draft)
    here.insert(novel("Court and Spark", year: 1974))
    #expect(try here.fetch(RecordDescriptor<Novel>()).count == 2)
    #expect(try here.record(id: saved.id, for: Novel.self)?.year == 1972)

    #expect(here.changes.count == 2)
    #expect(try elsewhere.fetch(RecordDescriptor<Novel>()).map(\.year) == [1971])
    here.rollback()
    #expect(try here.record(id: saved.id, for: Novel.self)?.year == 1971)
}

/// A stale draft's links read as saving would write them, before it is saved.
@MainActor
@Test func aStaleDraftReadsWithLinksChangedElsewhere() throws {
    let (here, elsewhere) = try twoContexts()
    let labels = ["x", "y", "z", "w"].map { Label(id: UUID(), name: $0) }
    let saved = Page(id: UUID(), title: "Page", labels: [labels[0], labels[1]], pinnedIDs: [])
    here.insert(saved)
    try here.save()

    var draft = saved
    draft.labels = [labels[0], labels[1], labels[2]]
    here.insert(draft)

    var remote = saved
    remote.labels = [labels[0], labels[3]]
    elsewhere.insert(remote)
    try elsewhere.save()

    let page = try #require(try here.record(id: saved.id, for: Page.self))
    let ids = Set(page.referenceStates.first { $0.property == "labels" }?.ids ?? [])
    #expect(ids == [labels[0].id, labels[2].id, labels[3].id])
    #expect(here.hasChanges)
}

/// A flag an observation's change handler can set from any thread.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// `value` lays the draft's edits over the latest saved record in memory, so an edit made
/// elsewhere to another field shows, and the `from:` sides come from the saved record.
@MainActor
@Test func valueLaysTheDraftOverTheSavedRecord() throws {
    let original = novel("Blue", year: 1971)
    var draft = original
    draft.year = 1972
    let difference = RecordDifference(id: original.id, original: original, draft: draft, change: .insert(draft.id))
    #expect((difference.value as? Novel)?.year == 1972)

    var saved = original
    saved.title = "Blue (Remastered)"
    difference.saved = saved
    let value = try #require(difference.value as? Novel)
    #expect(value.title == "Blue (Remastered)")
    #expect(value.year == 1972)

    let writer = Writer(id: UUID(), name: "Ada", bookIDs: [])
    let savedWriter = Writer(id: writer.id, name: "Ada", bookIDs: [original.id])
    var draftWriter = writer
    draftWriter.name = "Ada L."
    let writerDifference = RecordDifference(id: writer.id, original: writer, draft: draftWriter, change: .insert(writer.id))
    writerDifference.saved = savedWriter
    let writerValue = try #require(writerDifference.value as? Writer)
    #expect(writerValue.name == "Ada L.")
    #expect(writerValue.bookIDs == [original.id])
}

/// A difference that is only shown, not staged, isn't listed in `changes`, and a new record
/// reads as its draft.
@MainActor
@Test func aDifferenceWithoutAChangeReadsAsItsDraft() throws {
    let draft = novel("New", year: 2024)
    let difference = RecordDifference(id: draft.id, original: nil, draft: draft)
    #expect(difference.change == nil)
    #expect((difference.value as? Novel)?.title == "New")
}

/// `difference(id:)` finds the staged difference in the current zone, the same object each time.
@MainActor
@Test func differenceFindsTheStagedRecord() throws {
    let (here, _) = try twoContexts()
    let staged = novel("Blue", year: 1971)
    #expect(here.difference(id: staged.id) == nil)

    here.insert(staged)
    let difference = try #require(here.difference(id: staged.id))
    #expect(difference.change == .insert(staged.id))
    #expect(here.difference(id: staged.id) === difference)

    here.delete(staged)
    #expect(here.difference(id: staged.id) === difference)
    #expect(difference.change == .delete(staged.id))

    here.zone = "Work"
    #expect(here.difference(id: staged.id) == nil)
    here.zone = .records
    try here.save()
    #expect(here.difference(id: staged.id) == nil)
}

// MARK: - Differences handed out for editing

/// Asking for a record's difference twice gives the same object, and an edit through it stages
/// the record.
@MainActor
@Test func editingAHandedOutDifferenceStagesIt() throws {
    let (here, _) = try twoContexts()
    let saved = novel("Blue", year: 1971)
    here.insert(saved)
    try here.save()

    let difference = here.difference(for: saved)
    #expect(here.difference(for: saved) === difference)
    #expect(difference.change == nil)
    #expect(!here.hasChanges)
    #expect(here.changes.isEmpty)

    var draft = saved
    draft.year = 1972
    difference.draft = draft
    here.didEdit(difference)
    #expect(difference.change == .insert(saved.id))
    #expect(here.hasChanges)
    #expect(here.difference(for: saved) === difference)
    #expect(try here.record(id: saved.id, for: Novel.self)?.year == 1972)
}

/// Inserting a record that has a difference handed out stages that same difference.
@MainActor
@Test func insertingUsesTheHandedOutDifference() throws {
    let (here, _) = try twoContexts()
    let saved = novel("Blue", year: 1971)
    here.insert(saved)
    try here.save()

    let difference = here.difference(for: saved)
    var draft = saved
    draft.year = 1972
    here.insert(draft)
    #expect(difference.change == .insert(saved.id))
    #expect((difference.draft as? Novel)?.year == 1972)
}

/// Saving keeps each difference and starts it over from the record as written.
@MainActor
@Test func savingStartsTheDifferenceOverFromTheWrittenRecord() throws {
    let (here, elsewhere) = try twoContexts()
    let saved = novel("Blue", year: 1971)
    here.insert(saved)
    try here.save()

    let difference = here.difference(for: saved)
    var draft = saved
    draft.year = 1972
    difference.draft = draft
    here.didEdit(difference)

    var remote = saved
    remote.title = "Blue (Remastered)"
    elsewhere.insert(remote)
    try elsewhere.save()

    try here.save()
    #expect(difference.change == nil)
    #expect(difference.saved == nil)
    #expect((difference.original as? Novel)?.title == "Blue (Remastered)")
    #expect((difference.original as? Novel)?.year == 1972)
    #expect((difference.draft as? Novel)?.title == "Blue (Remastered)")
    #expect(!here.hasChanges)
    #expect(here.difference(for: saved) === difference)
}

/// Rolling back returns the draft to the saved record and keeps the difference.
@MainActor
@Test func rollingBackReturnsTheDraftToTheSavedRecord() throws {
    let (here, _) = try twoContexts()
    let saved = novel("Blue", year: 1971)
    here.insert(saved)
    try here.save()

    let difference = here.difference(for: saved)
    var draft = saved
    draft.year = 1972
    difference.draft = draft
    here.didEdit(difference)
    here.rollback()

    #expect(difference.change == nil)
    #expect((difference.draft as? Novel)?.year == 1971)
    #expect(!here.hasChanges)
    #expect(here.difference(for: saved) === difference)
}

/// The context doesn't keep an unstaged difference alive once nothing else holds it.
@MainActor
@Test func anUnusedDifferenceIsReleased() throws {
    let (here, _) = try twoContexts()
    let saved = novel("Blue", year: 1971)
    weak var released: RecordDifference?
    do {
        let difference = here.difference(for: saved)
        released = difference
        #expect(released != nil)
    }
    #expect(released == nil)
}
