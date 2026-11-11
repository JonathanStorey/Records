import Foundation
import Testing
@testable import Records

// `@Recordable` is a thin SwiftUI wrapper over `RecordableStorage`, which these tests drive.

@MainActor
private func context() throws -> RecordContext {
    try RecordContainer(for: [Novel.self, Page.self], url: nil).mainContext
}

private func novel(_ title: String, year: Int) -> Novel {
    Novel(
        id: UUID(), title: title, subtitle: nil, tags: [], year: year, note: nil,
        cover: nil, shop: nil, sequel: nil, writers: [], editorID: nil
    )
}

/// Two wrappers on the same record share its difference, so an edit through one shows in the
/// other at once.
@MainActor
@Test func twoRecordablesShareEdits() throws {
    let context = try context()
    let saved = novel("Blue", year: 1971)
    context.insert(saved)
    try context.save()

    let first = RecordableStorage(saved)
    let second = RecordableStorage(saved)
    first.connect(to: context)
    second.connect(to: context)
    #expect(first.difference === second.difference)

    first.value.year = 1972
    #expect(second.value.year == 1972)
    #expect(context.changes == [.insert(saved.id)])
}

/// Editing stages the record, and nothing is written until the context saves.
@MainActor
@Test func editingWritesNothingUntilSave() throws {
    let context = try context()
    let saved = novel("Blue", year: 1971)
    context.insert(saved)
    try context.save()

    let storage = RecordableStorage(saved)
    storage.connect(to: context)
    storage.value.title = "Blue (Live)"
    #expect(context.hasChanges)

    try context.save()
    #expect(!context.hasChanges)
    #expect(storage.value.title == "Blue (Live)")
    #expect(try context.record(id: saved.id, for: Novel.self)?.title == "Blue (Live)")
}

/// Rolling back returns the wrapper to the saved record.
@MainActor
@Test func rollbackRestoresTheRecordable() throws {
    let context = try context()
    let saved = novel("Blue", year: 1971)
    context.insert(saved)
    try context.save()

    let storage = RecordableStorage(saved)
    storage.connect(to: context)
    storage.value.year = 1980
    context.rollback()
    #expect(storage.value.year == 1971)
    #expect(!context.hasChanges)
}

/// A new record shows as given, and its first edit stages it as an insert.
@MainActor
@Test func aNewRecordIsInsertedOnItsFirstEdit() throws {
    let context = try context()
    let fresh = novel("New", year: 2024)
    let storage = RecordableStorage(fresh)
    storage.connect(to: context)
    #expect(storage.value.title == "New")
    #expect(!context.hasChanges)

    storage.value.year = 2025
    #expect(context.changes == [.insert(fresh.id)])
    try context.save()
    #expect(try context.record(id: fresh.id, for: Novel.self)?.year == 2025)
}

/// Without a zone, a wrapper edits in the container's default zone, whatever the context's
/// current zone.
@MainActor
@Test func aRecordableUsesTheDefaultZone() throws {
    let context = try context()
    context.zone = "Work"
    let fresh = novel("New", year: 2024)
    let storage = RecordableStorage(fresh)
    storage.connect(to: context)
    storage.value.year = 2025

    #expect(context.changes.isEmpty)
    context.zone = .records
    #expect(context.changes == [.insert(fresh.id)])
}

/// A container's default zone is where its contexts start and where wrappers edit.
@MainActor
@Test func theContainerSetsTheDefaultZone() throws {
    let container = try RecordContainer(for: [Novel.self, Page.self], url: nil, defaultZone: "Work")
    #expect(container.defaultZone == "Work")
    let context = container.mainContext
    #expect(context.zone == "Work")

    let fresh = novel("New", year: 2024)
    let storage = RecordableStorage(fresh)
    context.zone = .records
    storage.connect(to: context)
    storage.value.year = 2025
    #expect(context.changes.isEmpty)
    context.zone = "Work"
    #expect(context.changes == [.insert(fresh.id)])
}

/// A wrapper given a zone edits the record there, whatever the context's zone.
@MainActor
@Test func aRecordableEditsInTheZoneItWasGiven() throws {
    let context = try context()
    let fresh = novel("New", year: 2024)
    let storage = RecordableStorage(fresh, zone: "Work")
    storage.connect(to: context)
    storage.value.year = 2025

    #expect(context.changes.isEmpty)
    context.zone = "Work"
    #expect(context.changes == [.insert(fresh.id)])
}

// MARK: - Edge cases

/// A wrapper on a record the context already changed shows that change.
@MainActor
@Test func aRecordableShowsAnInsertAlreadyMade() throws {
    let context = try context()
    let saved = novel("Blue", year: 1971)
    context.insert(saved)
    try context.save()

    var edited = saved
    edited.year = 1972
    context.insert(edited)

    let storage = RecordableStorage(saved)
    storage.connect(to: context)
    #expect(storage.value.year == 1972)
}

/// An insert through the context after the wrapper connected shows in the wrapper.
@MainActor
@Test func aRecordableFollowsInsertsThroughTheContext() throws {
    let context = try context()
    let saved = novel("Blue", year: 1971)
    context.insert(saved)
    try context.save()

    let storage = RecordableStorage(saved)
    storage.connect(to: context)
    var edited = saved
    edited.year = 1972
    context.insert(edited)
    #expect(storage.value.year == 1972)
}

/// After a save the wrapper keeps the same difference, and its next edit is a new change.
@MainActor
@Test func editsAfterASaveAreChangesAgain() throws {
    let context = try context()
    let saved = novel("Blue", year: 1971)
    context.insert(saved)
    try context.save()

    let storage = RecordableStorage(saved)
    storage.connect(to: context)
    let difference = storage.difference
    storage.value.year = 1972
    try context.save()
    #expect(context.changes.isEmpty)
    #expect(storage.difference === difference)
    #expect(context.difference(for: saved) === difference)

    storage.value.year = 1973
    #expect(context.changes == [.insert(saved.id)])
    try context.save()
    #expect(try context.record(id: saved.id, for: Novel.self)?.year == 1973)
}

/// An edit stays in the context after its wrapper is gone, and the next save writes it.
@MainActor
@Test func anEditOutlivesItsRecordable() throws {
    let context = try context()
    let saved = novel("Blue", year: 1971)
    context.insert(saved)
    try context.save()

    do {
        let storage = RecordableStorage(saved)
        storage.connect(to: context)
        storage.value.year = 1972
    }
    // Handing out another difference drops the unused ones.
    _ = context.difference(for: novel("Other", year: 2000))
    #expect(context.changes == [.insert(saved.id)])

    try context.save()
    #expect(try context.record(id: saved.id, for: Novel.self)?.year == 1972)
}

/// A wrapper that never edited leaves nothing behind once it is gone.
@MainActor
@Test func anUneditedRecordableLeavesNothingBehind() throws {
    let context = try context()
    let saved = novel("Blue", year: 1971)
    context.insert(saved)
    try context.save()

    do {
        let storage = RecordableStorage(saved)
        storage.connect(to: context)
        #expect(context.differences.count == 1)
    }
    let other = novel("Other", year: 2000)
    _ = context.difference(for: other)
    #expect(context.differences.keys.map(\.name) == [other.id.uuidString])
    #expect(!context.hasChanges)
}

/// The same record in two zones is two records, so wrappers in each edit apart.
@MainActor
@Test func recordablesInDifferentZonesStayApart() throws {
    let context = try context()
    let fresh = novel("New", year: 2024)
    let here = RecordableStorage(fresh)
    let work = RecordableStorage(fresh, zone: "Work")
    here.connect(to: context)
    work.connect(to: context)
    #expect(here.difference !== work.difference)

    here.value.year = 2025
    #expect(work.value.year == 2024)
    #expect(context.changes == [.insert(fresh.id)])
    context.zone = "Work"
    #expect(context.changes.isEmpty)
}

/// Saving writes only the fields the wrapper edited, so a field another context saved since
/// is kept, and the wrapper then shows both.
@MainActor
@Test func savingKeepsFieldsSavedElsewhere() throws {
    let container = try RecordContainer(for: [Novel.self, Page.self], url: nil)
    let context = container.mainContext
    let other = RecordContext(container: container)
    let saved = novel("Blue", year: 1971)
    context.insert(saved)
    try context.save()

    let storage = RecordableStorage(saved)
    storage.connect(to: context)
    storage.value.year = 1972

    var renamed = saved
    renamed.title = "Green"
    other.insert(renamed)
    try other.save()

    try context.save()
    let written = try #require(try context.record(id: saved.id, for: Novel.self))
    #expect(written.title == "Green")
    #expect(written.year == 1972)
    #expect(storage.value.title == "Green")
    #expect(storage.value.year == 1972)
}

/// Moving a wrapper to another context shows that context's copy, and leaves the first
/// context's change where it was.
@MainActor
@Test func aRecordableMovedToAnotherContextStartsFromItsCopy() throws {
    let container = try RecordContainer(for: [Novel.self, Page.self], url: nil)
    let context = container.mainContext
    let other = RecordContext(container: container)
    let saved = novel("Blue", year: 1971)
    context.insert(saved)
    try context.save()

    let storage = RecordableStorage(saved)
    storage.connect(to: context)
    storage.value.year = 1972
    storage.connect(to: other)

    #expect(storage.value.year == 1971)
    #expect(context.changes == [.insert(saved.id)])
    #expect(!other.hasChanges)
}

/// Connecting to the same context again keeps the same difference.
@MainActor
@Test func reconnectingToTheSameContextKeepsTheDifference() throws {
    let context = try context()
    let fresh = novel("New", year: 2024)
    let storage = RecordableStorage(fresh)
    storage.connect(to: context)
    let difference = storage.difference
    storage.value.year = 2025
    storage.connect(to: context)
    #expect(storage.difference === difference)
    #expect(storage.value.year == 2025)
}
