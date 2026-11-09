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
        guard record.recordType == R.recordType else {
            throw CKRecordDecodingError.recordTypeMismatch(expected: R.recordType, found: record.recordType)
        }
        return try R(record: record)
    }

    /// The record's `id`, parsed from its record name. Used by the code `@Record` generates.
    public static func decodeID(from record: CKRecord) throws -> UUID {
        let name = record.recordID.recordName
        guard let id = UUID(uuidString: name) else {
            throw CKRecordDecodingError.invalidRecordName(name)
        }
        return id
    }

    /// The value of `key` as `T`. Used by the code `@Record` generates for non-optional properties.
    public static func decode<T>(_ type: T.Type, forKey key: String, from record: CKRecord) throws -> T {
        guard let value = try decodeIfPresent(type, forKey: key, from: record) else {
            throw CKRecordDecodingError.missingField(key)
        }
        return value
    }

    /// The value of `key` as `T`, or `nil` when the field is missing. Used by the code `@Record`
    /// generates for optional properties.
    public static func decodeIfPresent<T>(_ type: T.Type, forKey key: String, from record: CKRecord) throws -> T? {
        guard let value = record[key] else { return nil }
        guard let typed = value as? T else {
            throw CKRecordDecodingError.typeMismatch(field: key)
        }
        return typed
    }
}
