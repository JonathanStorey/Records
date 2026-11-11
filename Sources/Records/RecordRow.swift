import CloudKit
import Foundation

/// A record as its database row holds it: each field's column value by field key, with the
/// record's name and dates.
///
/// `@Record` reads one in `init(from:)` and writes one in `encodeFields(into:)`, so the database
/// builds records without going through a `CKRecord`. Only Records makes rows.
public struct RecordRow: Equatable {
    /// Every column's value, by column name.
    var values: [String: SQLValue]

    init(_ values: [String: SQLValue] = [:]) {
        self.values = values
    }

    /// The record's `id`, from its name. Used by the code `@Record` generates.
    public var id: UUID {
        get throws {
            guard case .text(let name) = values["_name"], let id = UUID(uuidString: name) else {
                throw CKRecordDecodingError.invalidRecordName(values["_name"].map { "\($0)" } ?? "")
            }
            return id
        }
    }

    /// When the record was first saved, for `@Timestamped(.created)`.
    public var createdAt: Date? { date("_createdAt") }

    /// When the record was last saved, for `@Timestamped(.modified)`.
    public var modifiedAt: Date? { date("_modifiedAt") }

    private func date(_ column: String) -> Date? {
        guard case .real(let seconds) = values[column] else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// The record the server last returned, rebuilt from the archived system fields, so it
    /// carries the server's dates and change tag. `nil` before the record first syncs, or when
    /// the system fields name another record.
    func serverRecord(recordType: CKRecord.RecordType, name: String, zone: Zone) -> CKRecord? {
        guard case .blob(let data) = values["_systemFields"],
              let coder = try? NSKeyedUnarchiver(forReadingFrom: data)
        else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        guard let record = CKRecord(coder: coder), record.recordType == recordType,
              record.recordID.recordName == name, record.recordID.zoneID == zone.zoneID
        else { return nil }
        return record
    }

    /// `record`'s system fields, archived as `_systemFields` holds them.
    static func systemFields(of record: CKRecord) -> SQLValue {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return .blob(archiver.encodedData)
    }
}
