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

    /// Decodes `record` and fills its `@Reference` and `@Asset` properties from `links`.
    ///
    /// `links` may hold any `RecordLink` records, such as every link in the zone. Only the ones
    /// whose source or, for `@Reference(from:)` properties, target is `record` are used, and links
    /// that can't be read are skipped. To-many targets are ordered by their order keys, then by
    /// when the link was created, then by the link's name.
    ///
    /// A reference that holds records is filled from the matching records in `targets`, `depth`
    /// levels deep. With the default of 1, the targets are records and their own references
    /// hold only IDs. With 2, those references hold records too, and so on. With 0, every
    /// reference holds only IDs. A reference that holds IDs is always filled, at every level.
    public func decode<R: Record>(
        _ type: R.Type,
        from record: CKRecord,
        links: [CKRecord],
        targets: [CKRecord] = [],
        depth: Int = 1
    ) throws -> R {
        var decoded = try decode(type, from: record)
        let sourceName = record.recordID.recordName

        var byProperty: [String: [(target: ReferenceTarget, link: CKRecord)]] = [:]
        for linkRecord in links where linkRecord.recordType == RecordLink.recordType {
            // Skip a malformed link rather than fail the whole record.
            guard let link = try? decode(RecordLink.self, from: linkRecord) else { continue }
            // An `@Asset`'s link: this record is its source.
            if let assetID = link.assetID {
                if link.sourceName == sourceName, let source = link.source, source.type == R.recordType {
                    let asset = linkRecord[RecordLink.assetKey] as? CKAsset
                    decoded.loadAsset(source.property, id: UUID(uuidString: assetID), file: asset?.fileURL)
                }
                continue
            }
            // The owning side: this record is the link's source.
            if link.sourceName == sourceName,
               let source = link.source, source.type == R.recordType,
               let targetID = link.targetName.flatMap(UUID.init(uuidString:)) {
                byProperty[source.property, default: []].append((ReferenceTarget(id: targetID, order: link.order), linkRecord))
            }
            // The `@Reference(from:)` side: this record is the link's target.
            if link.targetName == sourceName,
               let target = link.target, target.type == R.recordType,
               let sourceID = UUID(uuidString: link.sourceName) {
                byProperty[target.property, default: []].append((ReferenceTarget(id: sourceID), linkRecord))
            }
        }

        for (property, entries) in byProperty {
            let ordered = entries.sorted { lhs, rhs in
                let (a, b) = (lhs.target.order ?? "", rhs.target.order ?? "")
                if a != b { return OrderKey.precedes(a, b) }
                let (dateA, dateB) = (lhs.link.creationDate ?? .distantPast, rhs.link.creationDate ?? .distantPast)
                if dateA != dateB { return dateA < dateB }
                return lhs.link.recordID.recordName < rhs.link.recordID.recordName
            }
            try decoded.loadReference(property, to: ordered.map(\.target), from: targets, links: links, depth: depth)
        }
        return decoded
    }

    /// The record's `id`, parsed from its record name. Used by the code `@Record` generates.
    public static func decodeID(from record: CKRecord) throws -> UUID {
        let name = record.recordID.recordName
        guard let id = UUID(uuidString: name) else {
            throw CKRecordDecodingError.invalidRecordName(name)
        }
        return id
    }

    // The overloads below match `FieldCoding`'s, so a field type that can't be stored is a
    // compile error, and the most direct storage wins when a type matches more than one.

    /// The value of `key` as `T`. Used by the code `@Record` generates for non-optional properties.
    /// Pass `record.encryptedValues` for an `@Encrypted` field.
    public static func decode<T: CKRecordValueProtocol>(_ type: T.Type, forKey key: String, from record: any CKRecordKeyValueSetting) throws -> T {
        try required(read(key, from: record, FieldCoding.reader(type)), key)
    }

    public static func decode<T: CKRecordValueProtocol & Decodable>(_ type: T.Type, forKey key: String, from record: any CKRecordKeyValueSetting) throws -> T {
        try required(read(key, from: record, FieldCoding.reader(type)), key)
    }

    public static func decode<T: RawRepresentable>(_ type: T.Type, forKey key: String, from record: any CKRecordKeyValueSetting) throws -> T
    where T.RawValue: CKRecordValueProtocol {
        try required(read(key, from: record, FieldCoding.reader(type)), key)
    }

    public static func decode<T: RawRepresentable & Decodable>(_ type: T.Type, forKey key: String, from record: any CKRecordKeyValueSetting) throws -> T
    where T.RawValue: CKRecordValueProtocol {
        try required(read(key, from: record, FieldCoding.reader(type)), key)
    }

    public static func decode<T: Decodable>(_ type: T.Type, forKey key: String, from record: any CKRecordKeyValueSetting) throws -> T {
        try required(read(key, from: record, FieldCoding.reader(type)), key)
    }

    /// The value of `key` as `T`, or `nil` when the field is missing. Used by the code `@Record`
    /// generates for optional properties and arrays.
    /// Pass `record.encryptedValues` for an `@Encrypted` field.
    public static func decodeIfPresent<T: CKRecordValueProtocol>(_ type: T.Type, forKey key: String, from record: any CKRecordKeyValueSetting) throws -> T? {
        try read(key, from: record, FieldCoding.reader(type))
    }

    public static func decodeIfPresent<T: CKRecordValueProtocol & Decodable>(_ type: T.Type, forKey key: String, from record: any CKRecordKeyValueSetting) throws -> T? {
        try read(key, from: record, FieldCoding.reader(type))
    }

    public static func decodeIfPresent<T: RawRepresentable>(_ type: T.Type, forKey key: String, from record: any CKRecordKeyValueSetting) throws -> T?
    where T.RawValue: CKRecordValueProtocol {
        try read(key, from: record, FieldCoding.reader(type))
    }

    public static func decodeIfPresent<T: RawRepresentable & Decodable>(_ type: T.Type, forKey key: String, from record: any CKRecordKeyValueSetting) throws -> T?
    where T.RawValue: CKRecordValueProtocol {
        try read(key, from: record, FieldCoding.reader(type))
    }

    public static func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: String, from record: any CKRecordKeyValueSetting) throws -> T? {
        try read(key, from: record, FieldCoding.reader(type))
    }

    /// The field `key` read with `reader`, or `nil` when it is missing.
    private static func read<T>(_ key: String, from record: any CKRecordKeyValueSetting, _ reader: (Any) throws -> T?) throws -> T? {
        guard let value = record.object(forKey: key) else { return nil }
        guard let typed = try? reader(value) else {
            throw CKRecordDecodingError.typeMismatch(field: key)
        }
        return typed
    }

    private static func required<T>(_ value: T?, _ key: String) throws -> T {
        guard let value else { throw CKRecordDecodingError.missingField(key) }
        return value
    }
}
