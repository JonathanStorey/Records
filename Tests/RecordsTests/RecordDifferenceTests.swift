import Foundation
import Testing
@testable import Records

// An edit is saved as its difference from the saved record it started from, so changes made
// elsewhere in the meantime to anything it didn't touch survive.

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
@Test func insertingAgainKeepsTheFirstBase() throws {
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
@Test func changesListThePendingEdits() throws {
    let (here, _) = try twoContexts()
    let kept = novel("Kept", year: 2000)
    let gone = novel("Gone", year: 2001)
    here.insert(kept)
    here.insert(gone)
    try here.save()

    let added = novel("Added", year: 2002)
    here.insert(kept)
    here.delete(gone)
    here.insert(added)
    #expect(here.changes == [.update(kept.id), .delete(gone.id), .insert(added.id)])
}

/// Inserting a record again replaces the same edit, which keeps the base it started from.
@MainActor
@Test func insertingAgainReplacesTheSameEdit() throws {
    let (here, _) = try twoContexts()
    let saved = novel("Blue", year: 1971)
    here.insert(saved)
    try here.save()

    var draft = saved
    draft.year = 1972
    here.insert(draft)
    draft.year = 1973
    here.insert(draft)

    let difference = try #require(here.differences.values.first)
    #expect(here.differences.count == 1)
    #expect((difference.edit as? Novel)?.year == 1973)
    #expect((difference.base as? Novel)?.year == 1971)
    #expect(difference.change == .update(saved.id))

    here.delete(draft)
    #expect(here.differences.count == 1)
    #expect(here.changes == [.delete(saved.id)])
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

// MARK: - Reading saved records

/// Reads show the latest saved record until the draft is saved, and the save lays the
/// draft's edits over it.
@MainActor
@Test func aStaleDraftReadsAsSavedUntilItSaves() throws {
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
    #expect(read.year == 1971)
    #expect(try here.fetchCount(RecordDescriptor<Novel>(predicate: #Predicate { $0.year == 1972 })) == 0)

    try here.save()
    let merged = try #require(try here.record(id: saved.id, for: Novel.self))
    #expect(merged.title == "Blue (Remastered)")
    #expect(merged.year == 1972)
    let fetched = try here.fetch(RecordDescriptor<Novel>(predicate: #Predicate { $0.year == 1972 }))
    #expect(fetched.map(\.title) == ["Blue (Remastered)"])
}

/// Reading with changes pending writes nothing: they stay pending and the database stays as it was.
@MainActor
@Test func readingWithPendingChangesWritesNothing() throws {
    let (here, elsewhere) = try twoContexts()
    let saved = novel("Blue", year: 1971)
    here.insert(saved)
    try here.save()

    var draft = saved
    draft.year = 1972
    here.insert(draft)
    here.insert(novel("Court and Spark", year: 1974))
    #expect(try here.fetch(RecordDescriptor<Novel>()).count == 1)
    #expect(try here.record(id: saved.id, for: Novel.self)?.year == 1971)

    #expect(here.changes.count == 2)
    #expect(try elsewhere.fetch(RecordDescriptor<Novel>()).map(\.year) == [1971])
    try here.save()
    #expect(try here.record(id: saved.id, for: Novel.self)?.year == 1972)
}

/// A stale draft's links read as saved until it saves, then merge with the links changed elsewhere.
@MainActor
@Test func aStaleDraftSavesWithLinksChangedElsewhere() throws {
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

    func labelIDs() throws -> Set<UUID> {
        let page = try #require(try here.record(id: saved.id, for: Page.self))
        return Set(page.referenceStates.first { $0.property == "labels" }?.ids ?? [])
    }
    #expect(try labelIDs() == [labels[0].id, labels[3].id])
    #expect(here.hasChanges)

    try here.save()
    #expect(try labelIDs() == [labels[0].id, labels[2].id, labels[3].id])
}

/// An edit laid over a record keeps that record's other fields and its `from:` sides.
@Test func anEditLaysOverTheSavedRecord() throws {
    let original = novel("Blue", year: 1971)
    var edit = original
    edit.year = 1972
    let difference = RecordDifference(id: UUID(), zone: .records, base: original, edit: edit, modified: .now)
    #expect((difference.laid(over: nil) as? Novel)?.year == 1972)

    var saved = original
    saved.title = "Blue (Remastered)"
    let value = try #require(difference.laid(over: saved) as? Novel)
    #expect(value.title == "Blue (Remastered)")
    #expect(value.year == 1972)

    let writer = Writer(id: UUID(), name: "Ada", bookIDs: [])
    let savedWriter = Writer(id: writer.id, name: "Ada", bookIDs: [original.id])
    var editedWriter = writer
    editedWriter.name = "Ada L."
    let writerDifference = RecordDifference(id: UUID(), zone: .records, base: writer, edit: editedWriter, modified: .now)
    let writerValue = try #require(writerDifference.laid(over: savedWriter) as? Writer)
    #expect(writerValue.name == "Ada L.")
    #expect(writerValue.bookIDs == [original.id])
}

/// A difference's change follows its base and edit.
@Test func theChangeFollowsTheBaseAndEdit() {
    let record = novel("Blue", year: 1971)
    var difference = RecordDifference(id: UUID(), zone: .records, base: nil, edit: record, modified: .now)
    #expect(difference.change == .insert(record.id))
    difference.base = record
    #expect(difference.change == .update(record.id))
    difference.edit = nil
    #expect(difference.change == .delete(record.id))
    #expect(difference.change.id == record.id)
}

/// Rebasing keeps the fields the edit changed and takes the rest from the new base. A base
/// deleted elsewhere turns the edit into an insert.
@Test func rebasingMovesTheEditOntoTheNewBase() throws {
    let original = novel("Blue", year: 1971)
    var edit = original
    edit.year = 1972
    var difference = RecordDifference(id: UUID(), zone: .records, base: original, edit: edit, modified: .now)

    var remote = original
    remote.title = "Blue (Remastered)"
    difference.rebase(onto: remote)
    let rebased = try #require(difference.edit as? Novel)
    #expect(rebased.title == "Blue (Remastered)")
    #expect(rebased.year == 1972)
    #expect((difference.base as? Novel)?.title == "Blue (Remastered)")

    difference.rebase(onto: nil)
    #expect(difference.change == .insert(original.id))
    #expect((difference.edit as? Novel)?.year == 1972)
}

/// Saving writes the edits oldest first, so the newer edit of a field wins.
@MainActor
@Test func savingWritesTheOldestEditFirst() throws {
    let (here, _) = try twoContexts()
    let saved = novel("Blue", year: 1971)
    here.insert(saved)
    try here.save()

    var older = saved
    older.year = 1980
    var newer = saved
    newer.year = 1990
    let start = Date(timeIntervalSince1970: 1_000)
    here.edit(id: UUID(), of: saved, in: .records, with: newer, on: start.addingTimeInterval(1))
    here.edit(id: UUID(), of: saved, in: .records, with: older, on: start)
    #expect(here.draft(id: saved.id, for: Novel.self, in: .records)?.year == 1990)

    try here.save()
    #expect(try here.record(id: saved.id, for: Novel.self)?.year == 1990)
    #expect(!here.hasChanges)
}

/// Rolling back discards every edit, and the record reads as saved.
@MainActor
@Test func rollingBackDiscardsEveryEdit() throws {
    let (here, _) = try twoContexts()
    let saved = novel("Blue", year: 1971)
    here.insert(saved)
    try here.save()

    var draft = saved
    draft.year = 1972
    here.insert(draft)
    here.edit(id: UUID(), of: saved, in: .records, with: draft)
    here.rollback()
    #expect(!here.hasChanges)
    #expect(here.draft(id: saved.id, for: Novel.self, in: .records)?.year == 1971)
}
