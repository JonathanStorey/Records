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
