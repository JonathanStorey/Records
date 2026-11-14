import Foundation
import Observation
import Testing
@testable import Records

// Views redraw from three observed properties of the context: `events`, which every read of a
// record reads, and `changes` and `hasChanges`, which a read of a draft reads too.

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
        title: "Blue", subtitle: nil, tags: [], year: 1971, note: nil,
        cover: nil, shop: nil, sequel: nil, writers: [], editor: nil
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
        title: "Court and Spark", subtitle: nil, tags: [], year: 1974, note: nil,
        cover: nil, shop: nil, sequel: nil, writers: [], editor: nil
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

/// `save()` appends `.saved`, and a save with nothing pending appends nothing.
@MainActor
@Test func saveAppendsSaved() throws {
    let (context, novel) = try savedNovel()
    let saved = try #require(context.events.lastSaved)
    #expect(context.events == [.saved(saved)])
    #expect(try !observes({ _ = context.events }) { try context.save() })
    #expect(context.events == [.saved(saved)])

    context.insert(novel)
    try context.save()
    #expect(try #require(context.events.lastSaved) >= saved)
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

/// Fetches and `record(id:)` read `events`, so a list redraws when a save changes it.
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
    #expect(context.changes == [.delete(novel.uuid)])
    #expect(try observes(read) { try context.save() })
    #expect(context.changes.isEmpty)
}

/// `changes` lists one entry per edit, in the order the edits began, in the current zone.
@MainActor
@Test func changesKeepTheOrderEditsBegan() throws {
    let (context, novel) = try savedNovel()
    let fresh = Novel(
        title: "New", subtitle: nil, tags: [], year: 2024, note: nil,
        cover: nil, shop: nil, sequel: nil, writers: [], editor: nil
    )
    let first = UUID()
    let start = Date(timeIntervalSince1970: 1_000)
    context.edit(id: first, of: novel, in: .records, with: novel, on: start)
    context.insert(fresh)
    context.edit(id: UUID(), of: novel, in: .records, with: novel, on: start)
    // A later edit to the first doesn't move it.
    context.edit(id: first, of: novel, in: .records, with: novel, on: start.addingTimeInterval(5))
    #expect(context.changes == [.update(novel.uuid), .insert(fresh.uuid), .update(novel.uuid)])

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
    #expect(!observes({ _ = context.changes; _ = context.hasChanges; _ = context.events }) {
        _ = context.expanded(novel, [\Novel.writers], in: "Work")
    })
    #expect(context.zone == .records)
}

// MARK: - Changes from another context

@MainActor
private func twoContexts() throws -> (RecordContainer, RecordContext, RecordContext, Novel) {
    let container = try RecordContainer(for: [Novel.self, Page.self], url: nil)
    let here = container.mainContext
    let novel = Novel(
        title: "Blue", subtitle: nil, tags: [], year: 1971, note: nil,
        cover: nil, shop: nil, sequel: nil, writers: [], editor: nil
    )
    here.insert(novel)
    try here.save()
    return (container, here, RecordContext(container: container), novel)
}

/// A save in one context appends `.saved` to the other, so its views redraw.
@MainActor
@Test func aSaveRedrawsTheOtherContexts() throws {
    // The container must stay alive for its contexts to hear each other's saves.
    let (container, here, elsewhere, novel) = try twoContexts()
    defer { withExtendedLifetime(container) {} }
    var remote = novel
    remote.title = "Blue (Remastered)"
    elsewhere.insert(remote)
    #expect(try observes({ _ = here.draft(id: novel.id, for: Novel.self, in: .records) }) { try elsewhere.save() })
    #expect(here.draft(id: novel.id, for: Novel.self, in: .records)?.title == "Blue (Remastered)")
}

/// The other context's log gets the save too, and its own unsaved edits don't block it.
@MainActor
@Test func aSaveAppendsSavedToTheOtherContexts() throws {
    let (container, here, elsewhere, novel) = try twoContexts()
    defer { withExtendedLifetime(container) {} }
    #expect(elsewhere.events.isEmpty)
    var remote = novel
    remote.year = 1972
    elsewhere.insert(remote)
    #expect(try observes({ _ = here.events }) { try elsewhere.save() })
    #expect(here.events.count == 1 && here.events.lastSaved != nil)
    #expect(elsewhere.events.count == 1 && elsewhere.events.lastSaved != nil)
}

/// Rebasing moves an edit onto the record as saved now, so a field changed again elsewhere
/// after the edit began isn't overwritten by the value the edit started from.
@MainActor
@Test func rebasingKeepsLaterChangesMadeElsewhere() throws {
    // The container must stay alive for its contexts to hear each other's saves.
    let (container, here, elsewhere, novel) = try twoContexts()
    defer { withExtendedLifetime(container) {} }
    func remoteTitle(_ title: String) throws {
        var remote = try #require(try elsewhere.record(id: novel.id, for: Novel.self))
        remote.title = title
        elsewhere.insert(remote)
        try elsewhere.save()
    }

    try remoteTitle("Blue (Remastered)")
    // An editor's edit starts from the draft, which shows the first remote title.
    let id = UUID()
    var edited = try #require(here.draft(id: novel.id, for: Novel.self, in: .records))
    edited.year = 1972
    here.edit(id: id, of: novel, in: .records, with: edited)
    try remoteTitle("Blue (Final)")
    #expect((here.differences[id]?.base as? Novel)?.title == "Blue (Final)")

    try here.save()
    let read = try #require(try here.record(id: novel.id, for: Novel.self))
    #expect(read.title == "Blue (Final)")
    #expect(read.year == 1972)
}

/// An edit to a record deleted elsewhere becomes an insert, and a delete of it is dropped.
@MainActor
@Test func rebasingOntoADeleteRevivesEditsAndDropsDeletes() throws {
    // The container must stay alive for its contexts to hear each other's saves.
    let (container, here, elsewhere, novel) = try twoContexts()
    defer { withExtendedLifetime(container) {} }
    var edited = novel
    edited.year = 1972
    let editID = UUID()
    let deleteID = UUID()
    here.edit(id: editID, of: novel, in: .records, with: edited)
    here.edit(id: deleteID, of: novel, in: .records, with: nil)
    #expect(here.changes == [.update(novel.uuid), .delete(novel.uuid)])

    elsewhere.delete(novel)
    try elsewhere.save()
    #expect(here.changes == [.insert(novel.uuid)])
    #expect(here.differences[deleteID] == nil)

    try here.save()
    #expect(try here.record(id: novel.id, for: Novel.self)?.year == 1972)
}

/// A context the app no longer holds is released, and the next save goes on without it.
@MainActor
@Test func aReleasedContextIsLeftOut() throws {
    let container = try RecordContainer(for: [Novel.self, Page.self], url: nil)
    weak var released: RecordContext?
    do {
        let context = RecordContext(container: container)
        released = context
    }
    #expect(released == nil)
    container.mainContext.insert(Novel(
        title: "Blue", subtitle: nil, tags: [], year: 1971, note: nil,
        cover: nil, shop: nil, sequel: nil, writers: [], editor: nil
    ))
    try container.mainContext.save()
}


// MARK: - Events

/// An event that repeats the newest entry replaces its date and adds no entry. The replacement
/// still redraws.
@MainActor
@Test func aRepeatedEventReplacesTheNewestEntry() throws {
    let context = try RecordContainer(for: [Novel.self], url: nil).mainContext
    let first = Date(timeIntervalSinceReferenceDate: 1)
    let second = Date(timeIntervalSinceReferenceDate: 2)
    context.append(.synced(first))
    #expect(observes({ _ = context.events }) { context.append(.synced(second)) })
    #expect(context.events == [.synced(second)])

    context.append(.saved(first))
    context.append(.saved(second))
    #expect(context.events == [.synced(second), .saved(second)])
}

/// Only the same kind with the same status or flag repeats an entry. A new status or flag adds
/// an entry, so the newest one always tells the current state.
@MainActor
@Test func aNewStatusOrFlagAddsAnEntry() throws {
    let context = try RecordContainer(for: [Novel.self], url: nil).mainContext
    let date = Date(timeIntervalSinceReferenceDate: 1)
    let later = Date(timeIntervalSinceReferenceDate: 2)
    context.append(.account(date, .available))
    context.append(.account(later, .available))
    context.append(.account(later, .noAccount))
    context.append(.storage(date, isFull: true))
    context.append(.storage(later, isFull: true))
    context.append(.storage(later, isFull: false))
    #expect(context.events == [
        .account(later, .available), .account(later, .noAccount),
        .storage(later, isFull: true), .storage(later, isFull: false),
    ])
}

/// `lastSaved` and `lastSynced` read the newest matching event, past any other kind.
@Test func lastSavedAndLastSyncedReadTheNewestMatch() {
    let one = Date(timeIntervalSinceReferenceDate: 1)
    let two = Date(timeIntervalSinceReferenceDate: 2)
    let three = Date(timeIntervalSinceReferenceDate: 3)
    let events: [RecordEvent] = [.saved(one), .synced(two), .saved(three), .account(three, .available)]
    #expect(events.lastSaved == three)
    #expect(events.lastSynced == two)
    #expect([RecordEvent]().lastSaved == nil)
    #expect([RecordEvent.saved(one)].lastSynced == nil)
}

/// Appending any event redraws a view showing a record, and so does each record read.
@MainActor
@Test func appendingRedrawsRecordReads() throws {
    let (context, novel) = try savedNovel()
    let date = Date(timeIntervalSinceReferenceDate: 1)
    #expect(observes({ _ = try? context.record(id: novel.id, for: Novel.self) }) { context.append(.synced(date)) })
    #expect(observes({ _ = context.draft(id: novel.id, for: Novel.self, in: .records) }) {
        context.append(.account(date, .available))
    })
}

/// Rebasing alone appends nothing. The caller appends the event that redraws.
@MainActor
@Test func rebasingAppendsNothing() throws {
    let (context, _) = try savedNovel()
    let events = context.events
    #expect(!observes({ _ = context.events }) { context.rebase() })
    #expect(context.events == events)
}
