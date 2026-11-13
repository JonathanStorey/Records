import CloudKit
import Testing
@testable import Records

private func label(_ name: String) -> Label {
    Label(name: name)
}

// MARK: - To many

@Test func repeatedIDsAppearOnce() {
    let (a, b, c) = (Label.ID(), Label.ID(), Label.ID())
    let many = ToMany<Label>(ids: [a, b, a, c, b])
    #expect(many.ids == [a, b, c])
}

@Test func settingValuesKeepsUnloadedTargets() {
    let loaded = label("b")
    let (a, c) = (Label.ID(), Label.ID())
    var many = ToMany<Label>(ids: [a, loaded.id, c])
    let added = label("d")
    many.values = [loaded, added]
    #expect(many.ids == [loaded.id, a, c, added.id])
    #expect(many.values == [loaded, added])
}

@Test func settingIDsRemovesUnloadedTargets() {
    let kept = label("a")
    var many = ToMany<Label>([kept])
    many.ids.append(Label.ID())
    many.ids = [kept.id]
    #expect(many.values == [kept])
}

@Test func emptyToManyHasNoValues() {
    let many = ToMany<Label>(ids: [])
    #expect(many.ids.isEmpty && many.values.isEmpty)
}

// MARK: - To one

@Test func changingTheIDDropsTheLoadedTarget() {
    var one = ToOne(label("a"))
    #expect(one.value?.name == "a")
    one.id = Label.ID()
    #expect(one.value == nil)
}

@Test func toOneCanGoNilAndBack() {
    let target = label("a")
    var one = ToOne(target)
    one.value = nil
    #expect(one.id == nil && one.value == nil)
    one.value = target
    #expect(one.id == target.id && one.value == target)
    one.id = nil
    one.id = target.id
    #expect(one.value == target) // the loaded record matches the ID again
}

// MARK: - Cycles

@Test func loadingACycleStopsAtItsDepth() throws {
    let encoder = CKRecordEncoder()
    let (aID, bID) = (Employee.ID(), Employee.ID())
    let a = Employee(name: "A", manager: Employee(name: "B", manager: nil, id: bID), id: aID)
    var b = Employee(name: "B", manager: nil, id: bID)
    b._manager.id = aID
    let links = encoder.links(for: a, in: .records) + encoder.links(for: b, in: .records)
    let records = [a, b].map { encoder.encode($0, in: .records) }

    let graph = try RecordGraph(records: records, links: links, reachableFrom: Employee.self)
    let decoded = try #require(try graph.record(Employee.self, id: aID.uuid, depth: 3))
    #expect(decoded.manager?.name == "B")
    #expect(decoded.manager?.manager?.name == "A")
    #expect(decoded.manager?.manager?.manager?.name == "B")
    #expect(decoded.manager?.manager?.manager?.manager == nil)
    #expect(decoded.manager?.manager?.manager?.$manager.id == aID)
}
