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

    /// Decodes `record` and fills its `@Reference` properties from `links`.
    ///
    /// `links` may hold any `RecordLink` records, such as every link in the zone. Only the ones
    /// whose source or, for `@Reference(from:)` properties, target is `record` are used, and links
    /// that can't be read or that come from a newer link version are skipped. To-many targets are ordered by their order keys, then
    /// by when the link was created, then by the link's name.
    ///
    /// A reference that holds records is filled from the matching records in `targets`, `depth`
    /// levels deep. With the default of 1, the targets are records and their own references
    /// hold only IDs. With 2, those references hold records too, and so on. With 0, every
    /// reference holds only IDs. A reference that holds IDs is always filled, at every level.
    /// Every reference starts out unchanged, so the encoder writes no links for it until it
    /// changes.
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
            // Skip links this build can't read, rather than fail or delete them: they may come
            // from a newer version of the app.
            guard let link = try? decode(RecordLink.self, from: linkRecord),
                  link.version <= RecordLink.currentVersion
            else { continue }
            // The owning side: this record is the link's source.
            if link.sourceName == sourceName,
               let source = link.source, source.type == R.recordType,
               let targetID = UUID(uuidString: link.targetName) {
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
