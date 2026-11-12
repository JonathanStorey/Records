import Foundation
import Testing
@testable import Records
#if canImport(AppKit)
import AppKit
import SwiftUI
#endif

// `@Recordable` reads with `context.draft(id:for:in:)` and writes with
// `context.edit(id:of:in:with:on:)`. `Editor` does the same outside a view, so these tests
// cover the rules. One hosted test at the end covers the SwiftUI wiring.

/// One edit of a record, made the way `@Recordable` makes it.
@MainActor
private final class Editor<R: Record> {
    let id = UUID()
    let context: RecordContext
    let record: R
    let zone: Zone?
    let expand: [AnyKeyPath]

    init(_ record: R, in context: RecordContext, zone: Zone? = nil, expand: [AnyKeyPath] = []) {
        self.record = record
        self.context = context
        self.zone = zone
        self.expand = expand
    }

    /// The record with its pending edits, or `nil` when it is missing or deleted.
    var value: R? {
        get {
            let zone = self.zone ?? context.defaultZone
            guard let draft = context.draft(id: record.id, for: R.self, in: zone) else { return nil }
            return expand.isEmpty ? draft : context.expanded(draft, expand, in: zone)
        }
        set { edit(newValue) }
    }

    func edit(_ newValue: R?, on date: Date = Date()) {
        context.edit(id: id, of: record, in: zone ?? context.defaultZone, with: newValue, on: date)
    }
}

@MainActor
private func context() throws -> RecordContext {
    try RecordContainer(for: [Novel.self, Page.self], url: nil).mainContext
}

@MainActor
private func savedNovel(in context: RecordContext) throws -> Novel {
    let saved = novel("Blue", year: 1971)
    context.insert(saved)
    try context.save()
    return saved
}

private func novel(_ title: String, year: Int) -> Novel {
    Novel(
        title: title, subtitle: nil, tags: [], year: year, note: nil,
        cover: nil, shop: nil, sequel: nil, writers: [], editor: nil
    )
}

// MARK: - Editing

/// Editing records the change, and nothing is written until the context saves.
@MainActor
@Test func editingWritesNothingUntilSave() throws {
    let context = try context()
    let saved = try savedNovel(in: context)

    let editor = Editor(saved, in: context)
    editor.value?.title = "Blue (Live)"
    #expect(context.changes == [.update(saved.uuid)])
    #expect(editor.value?.title == "Blue (Live)")
    #expect(try context.record(id: saved.id, for: Novel.self)?.title == "Blue")

    try context.save()
    #expect(!context.hasChanges)
    #expect(editor.value?.title == "Blue (Live)")
    #expect(try context.record(id: saved.id, for: Novel.self)?.title == "Blue (Live)")
}

/// Each editor is its own difference. Two editors see each other's edits, and each saves only
/// the fields it changed.
@MainActor
@Test func twoEditorsEachSaveTheirOwnFields() throws {
    let context = try context()
    let saved = try savedNovel(in: context)

    let first = Editor(saved, in: context)
    let second = Editor(saved, in: context)
    first.value?.year = 1972
    #expect(second.value?.year == 1972)
    second.value?.title = "Blue (Live)"
    #expect(context.differences.count == 2)
    #expect(context.changes == [.update(saved.uuid), .update(saved.uuid)])

    try context.save()
    let read = try #require(try context.record(id: saved.id, for: Novel.self))
    #expect(read.title == "Blue (Live)")
    #expect(read.year == 1972)
}

/// When two editors change the same field, the newer edit wins.
@MainActor
@Test func theNewerEditOfAFieldWins() throws {
    let context = try context()
    let saved = try savedNovel(in: context)
    let start = Date(timeIntervalSince1970: 1_000)

    var older = saved
    older.year = 1980
    var newer = saved
    newer.year = 1990
    let first = Editor(saved, in: context)
    let second = Editor(saved, in: context)
    second.edit(newer, on: start.addingTimeInterval(1))
    first.edit(older, on: start)
    #expect(first.value?.year == 1990)

    try context.save()
    #expect(try context.record(id: saved.id, for: Novel.self)?.year == 1990)
}

/// Rolling back discards every edit and shows the saved record again.
@MainActor
@Test func rollbackRestoresTheSavedRecord() throws {
    let context = try context()
    let saved = try savedNovel(in: context)

    let editor = Editor(saved, in: context)
    editor.value?.year = 1980
    context.rollback()
    #expect(editor.value?.year == 1971)
    #expect(!context.hasChanges)
}

/// `rollback(id:)` discards the edits to one record and keeps the rest.
@MainActor
@Test func rollbackOfOneRecordKeepsTheOthers() throws {
    let context = try context()
    let blue = try savedNovel(in: context)
    let court = novel("Court and Spark", year: 1974)
    context.insert(court)
    try context.save()

    let first = Editor(blue, in: context)
    let second = Editor(blue, in: context)
    first.value?.year = 1972
    second.value?.title = "Blue (Live)"
    Editor(court, in: context).value?.year = 1975

    context.rollback(id: blue.id)
    #expect(first.value?.year == 1971)
    #expect(first.value?.title == "Blue")
    #expect(context.changes == [.update(court.uuid)])
}

/// A new record's first edit is an insert.
@MainActor
@Test func aNewRecordIsInsertedOnItsFirstEdit() throws {
    let context = try context()
    let fresh = novel("New", year: 2024)
    let editor = Editor(fresh, in: context)
    #expect(editor.value == nil)

    editor.value = fresh
    #expect(context.changes == [.insert(fresh.uuid)])
    try context.save()
    #expect(try context.record(id: fresh.id, for: Novel.self)?.title == "New")
}

/// A second edit of a new record starts from the first, so it updates only its own fields.
@MainActor
@Test func aSecondEditOfANewRecordUpdatesItsOwnFields() throws {
    let context = try context()
    let fresh = novel("New", year: 2024)
    context.insert(fresh)

    let first = Editor(fresh, in: context)
    let second = Editor(fresh, in: context)
    first.value?.title = "Newer"
    second.value?.year = 2025
    #expect(context.differences[second.id]?.change == .update(fresh.uuid))

    try context.save()
    let read = try #require(try context.record(id: fresh.id, for: Novel.self))
    #expect(read.title == "Newer")
    #expect(read.year == 2025)
}

/// An editor shows an insert already made through the context.
@MainActor
@Test func anEditorShowsAnInsertAlreadyMade() throws {
    let context = try context()
    let saved = try savedNovel(in: context)
    var edited = saved
    edited.year = 1980
    context.insert(edited)

    #expect(Editor(saved, in: context).value?.year == 1980)
}

/// After a save, an editor's next edit starts from the record as written.
@MainActor
@Test func editsAfterASaveAreChangesAgain() throws {
    let context = try context()
    let fresh = novel("New", year: 2024)
    let editor = Editor(fresh, in: context)
    editor.value = fresh
    try context.save()
    #expect(!context.hasChanges)

    editor.value?.year = 2025
    #expect(context.changes == [.update(fresh.uuid)])
    try context.save()
    #expect(try context.record(id: fresh.id, for: Novel.self)?.year == 2025)
}

/// Saving writes only the fields the editor changed, so a field another context saved since
/// is kept.
@MainActor
@Test func savingKeepsFieldsSavedElsewhere() throws {
    let container = try RecordContainer(for: [Novel.self, Page.self], url: nil)
    let context = container.mainContext
    let saved = try savedNovel(in: context)

    let editor = Editor(saved, in: context)
    editor.value?.year = 1972

    let elsewhere = RecordContext(container: container)
    var remote = saved
    remote.title = "Blue (Remastered)"
    elsewhere.insert(remote)
    try elsewhere.save()
    #expect(editor.value?.title == "Blue (Remastered)")
    #expect(editor.value?.year == 1972)

    try context.save()
    let read = try #require(try context.record(id: saved.id, for: Novel.self))
    #expect(read.title == "Blue (Remastered)")
    #expect(read.year == 1972)
}

// MARK: - Zones

/// Without a zone, an editor edits in the container's default zone, whatever the context's
/// current zone.
@MainActor
@Test func anEditorUsesTheDefaultZone() throws {
    let context = try context()
    let saved = try savedNovel(in: context)

    context.zone = "Work"
    let editor = Editor(saved, in: context)
    editor.value?.year = 1972
    #expect(context.changes.isEmpty)
    context.zone = .records
    #expect(context.changes == [.update(saved.uuid)])
}

/// A container's default zone is where its contexts start and where editors edit.
@MainActor
@Test func theContainerSetsTheDefaultZone() throws {
    let context = try RecordContainer(for: [Novel.self, Page.self], url: nil, defaultZone: "Work").mainContext
    #expect(context.zone == "Work")
    #expect(context.defaultZone == "Work")

    let fresh = novel("New", year: 2024)
    Editor(fresh, in: context).value = fresh
    context.zone = .records
    #expect(context.changes.isEmpty)
    context.zone = "Work"
    #expect(context.changes == [.insert(fresh.uuid)])
}

/// An editor given a zone edits the record there, and the same record in two zones is two
/// records.
@MainActor
@Test func editorsInDifferentZonesStayApart() throws {
    let context = try context()
    let saved = try savedNovel(in: context)
    context.zone = "Work"
    context.insert(saved)
    try context.save()
    context.zone = .records

    let home = Editor(saved, in: context)
    let work = Editor(saved, in: context, zone: "Work")
    home.value?.year = 1972
    work.value?.year = 1980
    #expect(home.value?.year == 1972)
    #expect(work.value?.year == 1980)

    try context.save()
    #expect(try context.record(id: saved.id, for: Novel.self)?.year == 1972)
    context.zone = "Work"
    #expect(try context.record(id: saved.id, for: Novel.self)?.year == 1980)
}

// MARK: - Expanding references

@MainActor
private func savedLP() throws -> (RecordContext, LP, Musician) {
    let nova = Musician(name: "Nova", isActive: true)
    let lp = LP(title: "A", year: 1999, musician: nova, cuts: [Cut(title: "Bloom", seconds: 200)])
    let context = try RecordContainer(for: [LP.self, Musician.self, Cut.self], url: nil).mainContext
    context.insert(lp)
    try context.save()
    return (context, try #require(try context.record(id: lp.id, for: LP.self)), nova)
}

/// `expand` loads the references it names, and only those.
@MainActor
@Test func expandLoadsTheNamedReferences() throws {
    let (context, lp, _) = try savedLP()
    #expect(lp.musician == nil)

    let editor = Editor(lp, in: context, expand: [\LP.musician])
    #expect(editor.value?.musician?.name == "Nova")
    #expect(editor.value?.cuts.isEmpty == true)
}

/// Expanded targets show changes to them once saved.
@MainActor
@Test func expandShowsChangesToTargets() throws {
    let (context, lp, nova) = try savedLP()
    let editor = Editor(lp, in: context, expand: [\LP.musician])

    var renamed = nova
    renamed.name = "Nova II"
    context.insert(renamed)
    #expect(editor.value?.musician?.name == "Nova")
    try context.save()
    #expect(editor.value?.musician?.name == "Nova II")
}

/// Editing an expanded record saves its own fields and keeps its targets.
@MainActor
@Test func editingAnExpandedRecordSavesOnlyItsOwnFields() throws {
    let (context, lp, nova) = try savedLP()
    let editor = Editor(lp, in: context, expand: [\LP.musician, \LP.cuts])
    var edited = try #require(editor.value)
    edited.title = "A (Live)"
    editor.value = edited
    #expect(context.changes == [.update(lp.uuid)])

    try context.save()
    #expect(try context.record(id: lp.id, for: LP.self)?.title == "A (Live)")
    #expect(try context.record(id: nova.id, for: Musician.self)?.name == "Nova")
    #expect(editor.value?.title == "A (Live)")
    #expect(editor.value?.musician?.name == "Nova")
    #expect(editor.value?.cuts.map(\.title) == ["Bloom"])
}

/// An editor expands in its own zone, whatever the context's current zone.
@MainActor
@Test func expandReadsInTheEditorsZone() throws {
    let (context, lp, _) = try savedLP()
    let editor = Editor(lp, in: context, expand: [\LP.musician])
    context.zone = "Work"
    #expect(editor.value?.musician?.name == "Nova")
    #expect(context.zone == "Work")
}

// MARK: - Deleting

/// A record reads `nil` once deleted, before and after the save.
@MainActor
@Test func aDeletedRecordReadsNil() throws {
    let context = try context()
    let saved = try savedNovel(in: context)
    let editor = Editor(saved, in: context)

    context.delete(saved)
    #expect(editor.value == nil)
    #expect(context.changes == [.delete(saved.uuid)])
    try context.save()
    #expect(editor.value == nil)
    #expect(try context.record(id: saved.id, for: Novel.self) == nil)
}

/// Setting `nil` deletes the record.
@MainActor
@Test func settingNilDeletesTheRecord() throws {
    let context = try context()
    let saved = try savedNovel(in: context)

    let editor = Editor(saved, in: context)
    editor.value = nil
    #expect(context.changes == [.delete(saved.uuid)])
    try context.save()
    #expect(try context.record(id: saved.id, for: Novel.self) == nil)
}

/// Setting a record after `nil` keeps it, and rolling back a delete restores it.
@MainActor
@Test func aDeleteCanBeUndone() throws {
    let context = try context()
    let saved = try savedNovel(in: context)

    let editor = Editor(saved, in: context)
    editor.value = nil
    editor.value = saved
    #expect(context.changes == [.update(saved.uuid)])
    #expect(editor.value?.title == "Blue")

    editor.value = nil
    context.rollback()
    #expect(editor.value?.title == "Blue")
    #expect(!context.hasChanges)
}

/// Editing a record after it was deleted elsewhere brings it back.
@MainActor
@Test func editingAfterADeleteBringsTheRecordBack() throws {
    let context = try context()
    let saved = try savedNovel(in: context)
    let editor = Editor(saved, in: context)
    editor.value?.year = 1972
    context.delete(saved)
    #expect(editor.value == nil)

    var revived = saved
    revived.year = 1980
    editor.value = revived
    try context.save()
    #expect(try context.record(id: saved.id, for: Novel.self)?.year == 1980)
}

/// Deleting a new record before it is saved drops it with its insert.
@MainActor
@Test func deletingANewRecordDropsIt() throws {
    let context = try context()
    let fresh = novel("New", year: 2024)
    let editor = Editor(fresh, in: context)
    editor.value = fresh
    editor.value?.year = 2025
    editor.value = nil
    #expect(editor.value == nil)
    #expect(!context.hasChanges)
}

// MARK: - The wrapper in a view

#if canImport(AppKit)
/// What a hosted view hands back to the test.
@MainActor
private final class Probe {
    var title: String?
    var id: UUID?
    var binding: Binding<Novel>?
}

private struct NovelEditor: View {
    @Recordable var novel: Novel
    let probe: Probe

    init(novel: Novel, probe: Probe) {
        _novel = Recordable(novel)
        self.probe = probe
    }

    var body: some View {
        probe.title = novel.title
        probe.id = _novel.id
        probe.binding = $novel
        return Text(novel.title)
    }
}

/// `@Recordable` in a hosted view reads the record, records an edit under its own `id`, and
/// reads the edit back.
@MainActor
@Test func aRecordableInAViewEditsItsRecord() throws {
    let context = try context()
    let saved = try savedNovel(in: context)
    let probe = Probe()
    let host = NSHostingView(rootView: NovelEditor(novel: saved, probe: probe).recordContext(context))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 50), styleMask: [], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    #expect(probe.title == "Blue")

    let binding = try #require(probe.binding)
    binding.wrappedValue.title = "Blue (Live)"
    let id = try #require(probe.id)
    #expect(context.differences[id]?.change == .update(saved.uuid))

    #expect(binding.wrappedValue.title == "Blue (Live)")
    try context.save()
    #expect(try context.record(id: saved.id, for: Novel.self)?.title == "Blue (Live)")
}
#endif
