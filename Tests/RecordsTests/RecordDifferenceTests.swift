import Foundation
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
    #expect(changes.map(\.id) == [kept.id, gone.id])
    guard case .insert(let inserted) = changes[0], case .delete(let deleted) = changes[1] else {
        Issue.record("expected an insert and a delete")
        return
    }
    #expect(inserted.id == kept.id)
    #expect(deleted.id == gone.id)
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
