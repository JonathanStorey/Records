import CloudKit
import Testing
@testable import Records

private func label(_ name: String) -> Label {
    Label(id: UUID(), name: name)
}

// MARK: - To many

@Test func repeatedIDsKeepTheirFirstPosition() {
    let (a, b, c) = (UUID(), UUID(), UUID())
    let many = ToMany<Label>(ids: [a, b, a, c, b])
    #expect(many.ids == [a, b, c])
}

@Test func settingValuesKeepsUnloadedTargetsInPlace() {
    let loaded = label("b")
    let (a, c) = (UUID(), UUID())
    var many = ToMany<Label>(ids: [a, loaded.id, c])
    let added = label("d")
    many.values = [loaded, added]
    #expect(many.ids == [a, loaded.id, c, added.id])
    #expect(many.values == [loaded, added])
}

@Test func settingIDsRemovesUnloadedTargets() {
    let kept = label("a")
    var many = ToMany<Label>([kept])
    many.ids.append(UUID())
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
    one.id = UUID()
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

@Test func decodingACycleStopsAtItsDepth() throws {
    let encoder = CKRecordEncoder(), decoder = CKRecordDecoder()
    let (aID, bID) = (UUID(), UUID())
    let a = Employee(id: aID, name: "A", manager: Employee(id: bID, name: "B", manager: nil))
    var b = Employee(id: bID, name: "B", manager: nil)
    b._manager.id = aID
    let links = encoder.links(for: a, in: .records) + encoder.links(for: b, in: .records)
    let records = [a, b].map { encoder.encode($0, in: .records) }

    let decoded = try decoder.decode(Employee.self, from: records[0], links: links, targets: records, depth: 3)
    #expect(decoded.manager?.name == "B")
    #expect(decoded.manager?.manager?.name == "A")
    #expect(decoded.manager?.manager?.manager?.name == "B")
    #expect(decoded.manager?.manager?.manager?.manager == nil)
    #expect(decoded.manager?.manager?.manager?.$manager.id == aID)
}
