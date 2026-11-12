import CloudKit
import CoreLocation
import Foundation
import Testing
@testable import Records

// MARK: - Every route to CloudKit matches

@Test func plainFieldsMatch() throws {
    try expectMatch(Note(id: UUID(), title: "Hello", isPinned: true, rating: 4, tags: ["a", "b"], created: Date(timeIntervalSince1970: 1000)))
    try expectMatch(Note(id: UUID(), title: "Empty", isPinned: false, rating: nil, tags: [], created: Date(timeIntervalSince1970: 0)))
    try expectMatch(LegacyFolder(id: UUID(), name: "Inbox"))
    try expectMatch(Box(id: UUID(), value: 3))
    try expectMatch(Box(id: UUID(), value: ["x", "y"]))
}

@Test func mappedFieldsMatch() throws {
    try expectMatch(Venue(
        id: UUID(), name: "Hall", mood: .energetic, rating: .three,
        address: Address(street: "1 Main", city: "Springfield"), previous: nil, moods: [.calm, .energetic]
    ))
}

@Test func encryptedFieldsMatch() throws {
    try expectMatch(Vault(id: UUID(), name: "Home", secret: "s3cret", pin: 1234, codes: ["a", "b"]))
    try expectMatch(Vault(id: UUID(), name: "Empty", secret: "", pin: nil, codes: []))
}

@Test func locationsMatchInEveryDetail() throws {
    var gig = Gig(id: UUID(), title: "Proms", venue: nil, home: Coordinate(latitude: 40.7, longitude: -74))
    gig.$venue = CLLocation(
        coordinate: CLLocationCoordinate2D(latitude: 51.5009, longitude: -0.1773), altitude: 30,
        horizontalAccuracy: 5, verticalAccuracy: 3, course: 90, courseAccuracy: 1,
        speed: 2, speedAccuracy: 0.5, timestamp: Date(timeIntervalSince1970: 1000)
    )
    try expectMatch(gig)
    try expectMatch(Gig(id: UUID(), title: "Nowhere", venue: nil, home: nil))
}

@Test func assetsMatch() throws {
    try expectMatch(Poster(id: UUID(), title: "Tour", image: Data("not really a png".utf8)))
    try expectMatch(Poster(id: UUID(), title: "Blank", image: nil))
}

@Test func referencesAndTimestampsMatch() throws {
    try expectMatch(Employee(id: UUID(), name: "Ada", manager: Employee(id: UUID(), name: "Grace", manager: nil)))
    try expectMatch(Writer(id: UUID(), name: "Grace", bookIDs: [UUID(), UUID()]))
    try expectMatch(Memo(id: UUID(), text: "Call back"))
}

@Test func everyKindMatchesInOneRecord() throws {
    var novel = Novel(
        id: UUID(), title: "Notes", subtitle: nil, tags: ["math", "machines"], year: 1843,
        note: "draft", cover: Data("cover".utf8), shop: nil,
        sequel: nil, writers: [Writer(id: UUID(), name: "Ada", bookIDs: []), Writer(id: UUID(), name: "Grace", bookIDs: [])],
        editor: Writer(id: UUID(), name: "Charles", bookIDs: [])
    )
    novel.$shop = CLLocation(
        coordinate: CLLocationCoordinate2D(latitude: 51.5, longitude: -0.12), altitude: 12,
        horizontalAccuracy: 4, verticalAccuracy: 2, course: 180, courseAccuracy: 3,
        speed: 1.5, speedAccuracy: 0.25, timestamp: Date(timeIntervalSince1970: 2000)
    )
    try expectMatch(novel)
}

// MARK: - The check

/// Checks that `record` reaches CloudKit the same way by every route.
///
/// The record is encoded directly, from its database row, and from that row once it has synced and
/// carries the server's system fields. Each `CKRecord` must have the same record ID and type, the
/// same plain and encrypted fields with the same values, and every detail of each location. Each
/// asset must reach its link with its data, and the record read back from its row must find it
/// there. Every `CKRecord` must read back as the same record.
func expectMatch<R: Record>(_ record: R, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let encoder = CKRecordEncoder(), decoder = CKRecordDecoder()
    let expected = row(of: record)

    let direct = encoder.encode(record, in: .records)
    let local = encoder.encode(expected, of: R.self, in: .records)
    let synced = encoder.encode(try decoder.decode(direct, of: R.self), of: R.self, in: .records)
    expectSame(direct, local, route: "row", sourceLocation)
    expectSame(direct, synced, route: "synced row", sourceLocation)
    #expect(synced.recordChangeTag == direct.recordChangeTag, sourceLocation: sourceLocation)

    for (route, ckRecord) in [("direct", direct), ("row", local), ("synced row", synced)] {
        expectSame(row(of: try decoder.decode(R.self, from: ckRecord)), expected, of: R.self, route: "\(route), read back", sourceLocation)
        expectSame(fields(try decoder.decode(ckRecord, of: R.self)), expected, of: R.self, route: "\(route), decoded", sourceLocation)
    }

    // An asset is stored on its link, never as a field.
    let links = encoder.links(for: record, in: .records)
    for state in record.assetStates {
        #expect(direct[state.property] == nil, sourceLocation: sourceLocation)
        #expect(direct.encryptedValues[state.property] == nil, sourceLocation: sourceLocation)
        guard let id = state.id else { continue }
        let link = links.first { (try? decoder.decode(RecordLink.self, from: $0))?.assetID == id.uuidString }
        let asset = try #require(link?[RecordLink.assetKey] as? CKAsset, sourceLocation: sourceLocation)
        let sent = try Data(contentsOf: try #require(asset.fileURL, sourceLocation: sourceLocation))
        let held = try Data(contentsOf: try #require(state.fileURL, sourceLocation: sourceLocation))
        #expect(sent == held, sourceLocation: sourceLocation)
    }
    var fromRow = try R(from: expected)
    try RecordGraph(records: [], links: links, reachableFrom: R.self).load(&fromRow, depth: 0)
    #expect(fromRow.assetStates == record.assetStates, sourceLocation: sourceLocation)

    // Each link is a record too, and reaches CloudKit the same way.
    for link in record.links() {
        try expectMatch(link, sourceLocation: sourceLocation)
    }
}

/// `row` without the system fields, which only a `CKRecord` from the server has.
func fields(_ row: RecordRow) -> RecordRow {
    var row = row
    row.values["_systemFields"] = nil
    return row
}

/// Checks that `actual` names the same record as `expected` and holds the same fields.
private func expectSame(_ expected: CKRecord, _ actual: CKRecord, route: String, _ sourceLocation: SourceLocation) {
    #expect(actual.recordID == expected.recordID, "\(route): record ID", sourceLocation: sourceLocation)
    #expect(actual.recordType == expected.recordType, "\(route): record type", sourceLocation: sourceLocation)

    let encrypted = Set(expected.encryptedValues.allKeys())
    #expect(Set(actual.encryptedValues.allKeys()) == encrypted, "\(route): encrypted keys", sourceLocation: sourceLocation)
    for key in encrypted {
        #expect(expected[key] == nil && actual[key] == nil, "\(route): \(key) is only encrypted", sourceLocation: sourceLocation)
        #expect(
            same(expected.encryptedValues[key], actual.encryptedValues[key]),
            "\(route): encrypted \(key)", sourceLocation: sourceLocation
        )
    }

    let plain = Set(expected.allKeys()).subtracting(encrypted)
    #expect(Set(actual.allKeys()).subtracting(encrypted) == plain, "\(route): keys", sourceLocation: sourceLocation)
    for key in plain {
        #expect(same(expected[key], actual[key]), "\(route): \(key)", sourceLocation: sourceLocation)
    }
}

/// Checks that `actual` holds the same columns as `expected`. An archived column is compared by
/// the value it holds, since archiving the same value twice can give different bytes.
private func expectSame<R: Record>(
    _ actual: RecordRow, _ expected: RecordRow, of type: R.Type, route: String, _ sourceLocation: SourceLocation
) {
    #expect(Set(actual.values.keys) == Set(expected.values.keys), "\(route): columns", sourceLocation: sourceLocation)
    for (key, value) in expected.values {
        let other = actual.values[key] ?? .null
        guard other != value else { continue }
        let kind = R.schema.fields.first { $0.key == key }?.kind
        #expect(
            kind.map { same($0.recordValue(other), $0.recordValue(value)) } == true,
            "\(route): column \(key) holds \(other), expected \(value)", sourceLocation: sourceLocation
        )
    }
}

/// Whether two field values are the same, comparing a location by every detail it stores and an
/// asset by its file's contents.
private func same(_ lhs: Any?, _ rhs: Any?) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none):
        return true
    case let (lhs as CLLocation, rhs as CLLocation):
        return lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.altitude == rhs.altitude
            && lhs.horizontalAccuracy == rhs.horizontalAccuracy
            && lhs.verticalAccuracy == rhs.verticalAccuracy
            && lhs.course == rhs.course
            && lhs.courseAccuracy == rhs.courseAccuracy
            && lhs.speed == rhs.speed
            && lhs.speedAccuracy == rhs.speedAccuracy
            && lhs.timestamp == rhs.timestamp
    case let (lhs as CKAsset, rhs as CKAsset):
        let lhsData = lhs.fileURL.flatMap { try? Data(contentsOf: $0) }
        return lhsData != nil && lhsData == rhs.fileURL.flatMap { try? Data(contentsOf: $0) }
    case let (lhs as [Any], rhs as [Any]):
        return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { same($0, $1) }
    case let (lhs as NSObject, rhs as NSObject):
        return lhs.isEqual(rhs)
    default:
        return false
    }
}
