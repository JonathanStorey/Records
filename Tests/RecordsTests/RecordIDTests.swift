import Foundation
import Testing
@testable import Records

/// A 2025 date with precision below one microsecond.
private let sampleDate = Date(timeIntervalSinceReferenceDate: 783_000_000.123_456_789)

@Test func aNewIDIsAVersion7UUID() {
    let bytes = Memo.ID().rawValue.uuid
    #expect(bytes.6 >> 4 == 7)
    #expect(bytes.8 >> 6 == 0b10)
}

@Test func anIDLeadsWithUnixMilliseconds() {
    // 783,000,000.123… s after 2001 is 1,761,307,200,123 ms after 1970.
    let id = TimestampClock().next(sampleDate)
    let hex = id.uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
    #expect(UInt64(hex, radix: 16) == 1_761_307_200_123)
}

@Test(arguments: [
    sampleDate,
    Date(timeIntervalSinceReferenceDate: 536_870_912),      // 2018, where 2⁻²³ s spacing starts
    Date(timeIntervalSinceReferenceDate: 1_073_741_824.5),  // 2035, coarser spacing
])
func anIDHoldsItsExactDate(_ date: Date) {
    #expect(TimestampClock.date(of: TimestampClock().next(date)) == date)
}

@Test func anIDHoldsTheExactDateOfNow() {
    let now = Date.now
    #expect(TimestampClock.date(of: TimestampClock().next(now)) == now)
}

@Test func aRepeatedDateAdvancesByOneTick() {
    let clock = TimestampClock()
    let first = TimestampClock.date(of: clock.next(sampleDate))
    let second = TimestampClock.date(of: clock.next(sampleDate))
    #expect(first == sampleDate)
    #expect(second == sampleDate.addingTimeInterval(0x1p-23))
}

@Test func aClockSteppingBackStillSortsInOrder() {
    let clock = TimestampClock()
    let first = clock.next(sampleDate)
    let second = clock.next(sampleDate.addingTimeInterval(-60))
    #expect(first.uuidString < second.uuidString)
}

@Test func newIDsSortInTheOrderTheyWereMade() {
    let ids = (0..<10_000).map { _ in Memo.ID() }
    #expect(ids == ids.sorted())
    #expect(Set(ids).count == ids.count)
}

@Test func anIDFromElsewhereHoldsNoDate() {
    #expect(TimestampClock.date(of: UUID()) == nil)
}

@Test func anIDEncodesAsItsUUID() throws {
    let id = Memo.ID()
    let data = try JSONEncoder().encode(id)
    #expect(try JSONDecoder().decode(UUID.self, from: data) == id.rawValue)
    #expect(try JSONDecoder().decode(Memo.ID.self, from: data) == id)
}

@Test func aRecordWithoutAnIDGetsANewOneEachTime() {
    let first = Memo(text: "a"), second = Memo(text: "b")
    #expect(first.id != second.id)
    #expect(first.id < second.id)
}
