import CloudKit
import CoreLocation
import Foundation

/// A value as SQLite stores it.
enum SQLValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

extension FieldKind {
    /// The column value for `value`, as `FieldCoding` wrote it into a `CKRecord`. A value that
    /// doesn't match the kind is stored as `NULL`.
    func sqlValue(_ value: Any?) -> SQLValue {
        guard let value else { return .null }
        switch self {
        case .text:
            return (value as? String).map(SQLValue.text) ?? .null
        case .integer:
            return (value as? NSNumber).map { .integer($0.int64Value) } ?? .null
        case .real:
            return (value as? NSNumber).map { .real($0.doubleValue) } ?? .null
        case .date:
            return (value as? Date).map { .real($0.timeIntervalSince1970) } ?? .null
        case .bytes:
            if let location = value as? CLLocation {
                // A `@Location` stored as a `CLLocation` rather than its archive.
                return LocationField.coding.value(location).flatMap { $0 as? Data }.map(SQLValue.blob) ?? .null
            }
            return (value as? Data).map(SQLValue.blob) ?? .null
        case .archived:
            let data = try? NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: true)
            return data.map(SQLValue.blob) ?? .null
        }
    }

    /// The value to put back into a `CKRecord` for `FieldCoding` to read, or `nil` for `NULL`.
    func recordValue(_ value: SQLValue) -> (any CKRecordValueProtocol)? {
        switch (self, value) {
        case (_, .null):
            return nil
        case (.text, .text(let string)):
            return string
        case (.integer, .integer(let number)):
            return NSNumber(value: number)
        case (.real, .real(let number)):
            return NSNumber(value: number)
        case (.date, .real(let seconds)):
            return Date(timeIntervalSince1970: seconds)
        case (.bytes, .blob(let data)):
            return data
        case (.archived, .blob(let data)):
            let classes: [AnyClass] = [
                NSArray.self, NSString.self, NSNumber.self, NSDate.self, NSData.self, CLLocation.self,
            ]
            return (try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data)) as? (any CKRecordValueProtocol)
        default:
            return nil
        }
    }
}

extension Record {
    /// The column value of each field, by field key, as `encodeFields(into:)` writes it.
    func columnValues() -> [String: SQLValue] {
        var row = RecordRow()
        encodeFields(into: &row)
        return row.values
    }
}

extension RecordSchema {
    /// A record named `name` in `zone`, holding the fields of `row`. It is what `encodeFields`
    /// would write, so the record's generated initializer reads it back.
    ///
    /// Starting from `base`, every field is set, `nil` included, so a field cleared since the
    /// server's copy uploads as cleared.
    func record(from row: [String: SQLValue], name: String, zone: Zone, onto base: CKRecord? = nil) -> CKRecord {
        let record = base ?? CKRecord(recordType: recordType, recordID: CKRecord.ID(recordName: name, zoneID: zone.zoneID))
        for field in fields {
            let value = field.kind.recordValue(row[field.key] ?? .null)
            guard value != nil || base != nil else { continue }
            if field.isEncrypted {
                record.encryptedValues[field.key] = value
            } else {
                record[field.key] = value
            }
        }
        return record
    }
}
