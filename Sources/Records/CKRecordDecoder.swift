import CloudKit

/// Why a `CKRecord` could not be turned back into a `Record`.
public enum CKRecordDecodingError: Error, Equatable {
    /// The record's type is not the `Record`'s `recordType`.
    case recordTypeMismatch(expected: String, found: String)
    /// The record name is not a UUID string.
    case invalidRecordName(String)
    /// A non-optional property has no field on the record.
    case missingField(String)
    /// The field holds a value of a different type than the property.
    case typeMismatch(field: String)
}

/// Converts a `CKRecord` back into a `Record`.
///
/// The record type must match, the record name must be a UUID, and every non-optional
/// property must have a field of its type. Missing optional fields decode as `nil`.
public struct CKRecordDecoder: Sendable {
    public init() {}

    public func decode<R: Record>(_ type: R.Type, from record: CKRecord) throws -> R {
        try R(from: decode(record, of: R.self))
    }

    /// Decodes `record` and fills its `@Reference` and `@Asset` properties from `links`.
    ///
    /// `links` may hold any `RecordLink` records, such as every link in the zone. Only the ones
    /// whose source or, for `@Reference(from:)` properties, target is `record` are used, and links
    /// that can't be read are skipped. To-many targets are sorted by ID, the order they were made.
    ///
    /// A reference that holds records is filled from the matching records in `targets`. Those
    /// targets' own references hold only IDs. A reference that holds IDs is always filled.
    public func decode<R: Record>(
        _ type: R.Type,
        from record: CKRecord,
        links: [CKRecord],
        targets: [CKRecord] = []
    ) throws -> R {
        var decoded = try decode(type, from: record)
        try RecordGraph(records: targets, links: links, reachableFrom: R.self).load(&decoded, depth: 1)
        return decoded
    }

    /// `record` as `R`'s database row: each field's column value, with the record's name, the
    /// server's dates, and its archived system fields, so the next upload updates it. Sync
    /// writes it to the database.
    public func decode<R: Record>(_ record: CKRecord, of type: R.Type) throws -> RecordRow {
        guard record.recordType == R.recordType else {
            throw CKRecordDecodingError.recordTypeMismatch(expected: R.recordType, found: record.recordType)
        }
        var row = RecordRow([
            "_name": .text(record.recordID.recordName),
            "_createdAt": record.creationDate.map { .real($0.timeIntervalSinceReferenceDate) } ?? .null,
            "_modifiedAt": record.modificationDate.map { .real($0.timeIntervalSinceReferenceDate) } ?? .null,
            "_systemFields": RecordRow.systemFields(of: record),
        ])
        for field in R.schema.fields {
            let value = field.isEncrypted ? record.encryptedValues[field.key] : record[field.key]
            row.values[field.key] = field.kind.sqlValue(value)
            if value != nil, row.values[field.key] == .null {
                throw CKRecordDecodingError.typeMismatch(field: field.key)
            }
        }
        return row
    }
}
