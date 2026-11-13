import CloudKit
import Foundation
import Testing
@testable import Records

/// The record to upload for `record` once `server` is its synced copy: its row, holding the
/// server's system fields, with `record`'s fields written over them.
func upload<R: Record>(_ record: R, onto server: CKRecord) throws -> CKRecord {
    var row = try CKRecordDecoder().decode(server, of: R.self)
    record.encodeFields(into: &row)
    return CKRecordEncoder().encode(row, of: R.self, in: .records)
}

/// `record`'s database row, as saving writes it, without dates.
func row<R: Record>(of record: R) -> RecordRow {
    var row = RecordRow(["_name": .text(record.id.uuidString), "_createdAt": .null, "_modifiedAt": .null])
    record.encodeFields(into: &row)
    return row
}

private let venue = Venue(
    name: "Hall", mood: .energetic, rating: .three,
    address: Address(street: "1 Main", city: "Springfield"), previous: nil, moods: [.calm, .energetic]
)

private let novel = Novel(
    title: "Notes", subtitle: nil, tags: ["math", "machines"], year: 1843,
    note: "draft", cover: nil, shop: Coordinate(latitude: 51.5, longitude: -0.12),
    sequel: nil, writers: [], editor: nil
)

@Test func aRecordReadsBackFromItsRow() throws {
    #expect(try Venue(from: row(of: venue)) == venue)

    let read = try Novel(from: row(of: novel))
    #expect(read.title == novel.title && read.subtitle == nil && read.tags == novel.tags && read.year == 1843)
    #expect(read.note == "draft")
    #expect(read.shop == novel.shop)
}

@Test func timestampsReadTheirColumns() throws {
    var row = row(of: Memo(text: "Call back"))
    row.values["_createdAt"] = .real(100)
    row.values["_modifiedAt"] = .real(200)
    let memo = try Memo(from: row)
    #expect(memo.createdAt == Date(timeIntervalSinceReferenceDate: 100))
    #expect(memo.modifiedAt == Date(timeIntervalSinceReferenceDate: 200))
}

@MainActor
@Test func savingFillsTheDates() throws {
    let context = try RecordContainer(for: [Memo.self], url: nil).mainContext
    let memo = Memo(text: "Call back")
    context.insert(memo)
    try context.save()
    let saved = try #require(try context.record(id: memo.id, for: Memo.self))
    #expect(saved.createdAt != nil)
    #expect(saved.createdAt == saved.modifiedAt)
}

@Test func aSyncedRowEncodesOntoTheServersRecord() throws {
    let server = CKRecordEncoder().encode(venue, in: .records)
    var row = try CKRecordDecoder().decode(server, of: Venue.self)
    guard case .blob = row.values["_systemFields"] else {
        Issue.record("The row keeps the server's system fields")
        return
    }

    // A field cleared locally is set on the upload, so the server clears it too.
    row.values["rating"] = .null
    let upload = CKRecordEncoder().encode(row, of: Venue.self, in: .records)
    #expect(upload.recordID == server.recordID)
    #expect(upload.recordChangeTag == server.recordChangeTag)
    #expect(upload["rating"] == nil)
    #expect(upload["title"] as? String == "Hall")
    #expect(try CKRecordDecoder().decode(Venue.self, from: upload).rating == nil)

    // System fields for another record are ignored.
    var other = row
    other.values["_name"] = .text(UUID().uuidString)
    #expect(CKRecordEncoder().encode(other, of: Venue.self, in: .records).recordID.recordName != server.recordID.recordName)
}
