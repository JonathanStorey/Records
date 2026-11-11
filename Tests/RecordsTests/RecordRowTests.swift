import CloudKit
import Foundation
import Testing
@testable import Records

/// `record`'s database row, as saving writes it, without dates.
private func row<R: Record>(of record: R) -> RecordRow {
    var row = RecordRow(["_name": .text(record.id.uuidString), "_createdAt": .null, "_modifiedAt": .null])
    record.encodeFields(into: &row)
    return row
}

private let venue = Venue(
    id: UUID(), name: "Hall", mood: .energetic, rating: .three,
    address: Address(street: "1 Main", city: "Springfield"), previous: nil, moods: [.calm, .energetic]
)

private let novel = Novel(
    id: UUID(), title: "Notes", subtitle: nil, tags: ["math", "machines"], year: 1843,
    note: "draft", cover: nil, shop: Coordinate(latitude: 51.5, longitude: -0.12),
    sequel: nil, writers: [], editorID: nil
)

@Test func aRecordReadsBackFromItsRow() throws {
    #expect(try Venue(from: row(of: venue)) == venue)

    let read = try Novel(from: row(of: novel))
    #expect(read.title == novel.title && read.subtitle == nil && read.tags == novel.tags && read.year == 1843)
    #expect(read.note == "draft")
    #expect(read.shop == novel.shop)
}

@Test func theRowAndTheCKRecordAgree() throws {
    let encoder = CKRecordEncoder(), decoder = CKRecordDecoder()
    for (record, type) in [(venue, Venue.self), (novel, Novel.self)] as [(any Record, any Record.Type)] {
        try agree(record, as: type, encoder: encoder, decoder: decoder)
    }
}

/// The two routes from a record to a `CKRecord`, directly and through its row, give the same
/// fields, and each reads back the same way.
private func agree<R: Record>(_ record: any Record, as type: R.Type, encoder: CKRecordEncoder, decoder: CKRecordDecoder) throws {
    let record = try #require(record as? R)
    let direct = encoder.encode(record, in: .records)
    let throughRow = encoder.encode(row(of: record), of: R.self, in: .records)
    #expect(try decoder.decode(direct, of: R.self) == row(of: record))
    #expect(try decoder.decode(throughRow, of: R.self) == row(of: record))
    #expect(row(of: try R(record: throughRow)) == row(of: record))
    #expect(row(of: try R(from: decoder.decode(direct, of: R.self))) == row(of: record))
}

@Test func timestampsReadTheirColumns() throws {
    var row = row(of: Memo(id: UUID(), text: "Call back"))
    row.values["_createdAt"] = .real(100)
    row.values["_modifiedAt"] = .real(200)
    let memo = try Memo(from: row)
    #expect(memo.createdAt == Date(timeIntervalSince1970: 100))
    #expect(memo.modifiedAt == Date(timeIntervalSince1970: 200))
}

@MainActor
@Test func savingFillsTheDates() throws {
    let context = try RecordContainer(for: [Memo.self], url: nil).mainContext
    let memo = Memo(id: UUID(), text: "Call back")
    context.insert(memo)
    try context.save()
    let saved = try #require(try context.record(id: memo.id, for: Memo.self))
    #expect(saved.createdAt != nil)
    #expect(saved.createdAt == saved.modifiedAt)
}
