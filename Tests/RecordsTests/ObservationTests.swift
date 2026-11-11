import Foundation
import Observation
import Testing
@testable import Records

// Views redraw from three observed properties of the context: `lastSaved`, which every read of
// a record reads, and `changes` and `hasChanges`, which a read of a draft reads too.

/// A flag an observation's change handler can set from any thread.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// Whether `change` makes anything `read` observes change.
@MainActor
private func observes(_ read: () -> Void, change: () throws -> Void) rethrows -> Bool {
    let flag = Flag()
    withObservationTracking(read) { flag.set() }
    try change()
    return flag.isSet
}

@MainActor
private func savedNovel() throws -> (RecordContext, Novel) {
    let context = try RecordContainer(for: [Novel.self, Page.self], url: nil).mainContext
    let novel = Novel(
        id: UUID(), title: "Blue", subtitle: nil, tags: [], year: 1971, note: nil,
        cover: nil, shop: nil, sequel: nil, writers: [], editorID: nil
    )
    context.insert(novel)
    try context.save()
    return (context, novel)
}

/// A draft redraws when an edit begins, on save, on rollback, and on `rollback(id:)`, and not
/// while an edit is typed into.
@MainActor
@Test func draftsRedrawWhenEditsBeginOrEnd() throws {
    let (context, novel) = try savedNovel()
    let read = { _ = context.draft(id: novel.id, for: Novel.self, in: .records) }
    let id = UUID()
    var edited = novel

    edited.year = 1972
    #expect(observes(read) { context.edit(id: id, of: novel, in: .records, with: edited) })
    edited.year = 1973
    #expect(!observes(read) { context.edit(id: id, of: novel, in: .records, with: edited) })
    #expect(try observes(read) { try context.save() })

    context.edit(id: UUID(), of: novel, in: .records, with: edited)
    #expect(observes(read) { context.rollback() })

    // One record's edits discarded while another's stay.
    let other = Novel(
        id: UUID(), title: "Court and Spark", subtitle: nil, tags: [], year: 1974, note: nil,
        cover: nil, shop: nil, sequel: nil, writers: [], editorID: nil
    )
    context.insert(other)
    context.edit(id: UUID(), of: novel, in: .records, with: edited)
    #expect(observes(read) { context.rollback(id: novel.id) })
    #expect(context.hasChanges)
}

/// A rollback of edits in another zone redraws, though `changes` shows only the current zone.
@MainActor
@Test func rollingBackAnotherZoneRedraws() throws {
    let (context, novel) = try savedNovel()
    context.zone = "Work"
    context.edit(id: UUID(), of: novel, in: .records, with: novel)
    #expect(context.changes.isEmpty)
    #expect(observes({ _ = context.draft(id: novel.id, for: Novel.self, in: .records) }) { context.rollback() })
}

/// `save()` sets `lastSaved`, and a save with nothing pending leaves it.
@MainActor
@Test func saveSetsLastSaved() throws {
    let (context, novel) = try savedNovel()
    let saved = try #require(context.lastSaved)
    #expect(try !observes({ _ = context.lastSaved }) { try context.save() })
    #expect(context.lastSaved == saved)

    context.insert(novel)
    try context.save()
    #expect(try #require(context.lastSaved) >= saved)
}

/// `hasChanges` changes only when the first edit begins or the last one ends.
@MainActor
@Test func hasChangesRedrawsOnlyWhenItFlips() throws {
    let (context, novel) = try savedNovel()
    let read = { _ = context.hasChanges }
    #expect(observes(read) { context.edit(id: UUID(), of: novel, in: .records, with: novel) })
    #expect(!observes(read) { context.edit(id: UUID(), of: novel, in: .records, with: novel) })
    #expect(observes(read) { context.rollback() })
    #expect(!context.hasChanges)
}

/// Fetches and `record(id:)` read `lastSaved`, so a list redraws when a save changes it.
@MainActor
@Test func fetchesRedrawOnSave() throws {
    let (context, novel) = try savedNovel()
    var edited = novel
    edited.year = 1972
    context.insert(edited)
    #expect(try observes({ _ = try? context.fetch(RecordDescriptor<Novel>()) }) { try context.save() })

    context.insert(novel)
    #expect(try observes({ _ = try? context.record(id: novel.id, for: Novel.self) }) { try context.save() })
}

/// `changes` changes when an edit begins, changes kind or ends, and not while it is typed into.
@MainActor
@Test func changesRedrawOnlyWhenTheyChange() throws {
    let (context, novel) = try savedNovel()
    let read = { _ = context.changes }
    let id = UUID()
    var edited = novel

    edited.year = 1972
    #expect(observes(read) { context.edit(id: id, of: novel, in: .records, with: edited) })
    edited.year = 1973
    #expect(!observes(read) { context.edit(id: id, of: novel, in: .records, with: edited) })
    #expect(observes(read) { context.edit(id: id, of: novel, in: .records, with: nil) })
    #expect(context.changes == [.delete(novel.id)])
    #expect(try observes(read) { try context.save() })
    #expect(context.changes.isEmpty)
}

/// `changes` lists one entry per edit, in the order the edits began, in the current zone.
@MainActor
@Test func changesKeepTheOrderEditsBegan() throws {
    let (context, novel) = try savedNovel()
    let fresh = Novel(
        id: UUID(), title: "New", subtitle: nil, tags: [], year: 2024, note: nil,
        cover: nil, shop: nil, sequel: nil, writers: [], editorID: nil
    )
    let first = UUID()
    let start = Date(timeIntervalSince1970: 1_000)
    context.edit(id: first, of: novel, in: .records, with: novel, on: start)
    context.insert(fresh)
    context.edit(id: UUID(), of: novel, in: .records, with: novel, on: start)
    // A later edit to the first doesn't move it.
    context.edit(id: first, of: novel, in: .records, with: novel, on: start.addingTimeInterval(5))
    #expect(context.changes == [.update(novel.id), .insert(fresh.id), .update(novel.id)])

    context.zone = "Work"
    #expect(context.changes.isEmpty)
    context.zone = .records
    #expect(context.changes.count == 3)
}

/// Expanding a record in another zone reads it there without touching anything observed.
@MainActor
@Test func expandingInAnotherZoneChangesNothingObserved() throws {
    let (context, novel) = try savedNovel()
    context.zone = "Work"
    context.insert(novel)
    context.zone = .records
    #expect(!observes({ _ = context.changes; _ = context.hasChanges; _ = context.lastSaved }) {
        _ = context.expanded(novel, [\Novel.writers], in: "Work")
    })
    #expect(context.zone == .records)
}
