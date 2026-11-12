import Foundation
import Testing
@testable import Records

@Test func aNewIDIsAVersion7UUID() {
    let bytes = Memo.ID().uuid.uuid
    #expect(bytes.6 >> 4 == 7)
    #expect(bytes.8 >> 6 == 0b10)
}

@Test func newIDsSortInTheOrderTheyWereMade() {
    let ids = (0..<1_000).map { _ in Memo.ID() }
    #expect(ids == ids.sorted())
    #expect(Set(ids).count == ids.count)
    #expect(ids.map(\.uuid.uuidString) == ids.map(\.uuid.uuidString).sorted())
}

@Test func anIDReadsBackTheTimeItWasMade() throws {
    let before = Date()
    let date = try #require(Memo.ID().date)
    #expect(abs(date.timeIntervalSince(before)) < 1)
}

@Test func anIDFromElsewhereHasNoDate() {
    #expect(Memo.ID(UUID()).date == nil)
}

@Test func anIDEncodesAsItsUUID() throws {
    let id = Memo.ID()
    let data = try JSONEncoder().encode(id)
    #expect(try JSONDecoder().decode(UUID.self, from: data) == id.uuid)
    #expect(try JSONDecoder().decode(Memo.ID.self, from: data) == id)
}

@Test func aRecordWithoutAnIDGetsANewOneEachTime() {
    let first = Memo(text: "a"), second = Memo(text: "b")
    #expect(first.id != second.id)
    #expect(first.id < second.id)
}
