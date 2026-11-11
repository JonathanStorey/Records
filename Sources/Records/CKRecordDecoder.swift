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
            let property = String(link.sourceProperty)
            let ownsLink = link.sourceName == sourceName && link.sourceType == R.recordType
            // An `@Asset`'s link: this record is its source.
            if let assetID = link.assetID {
                if ownsLink {
                    let asset = linkRecord[RecordLink.assetKey] as? CKAsset
                    decoded.loadAsset(property, id: UUID(uuidString: assetID), file: asset?.fileURL)
                }
                continue
            }
            // The owning side: this record is the link's source.
            if ownsLink, let targetID = link.targetName.flatMap(UUID.init(uuidString:)) {
                byProperty[property, default: []].append((ReferenceTarget(id: targetID, order: link.order), linkRecord))
            }
            // The `@Reference(from:)` side: this record is the link's target, and its type names
            // the owner's property as an inverse.
            if link.targetName == sourceName,
               let inverse = R.schema.references.first(where: { $0.inverseOf == property && $0.target.recordType == link.sourceType }),
               let sourceID = UUID(uuidString: link.sourceName) {
                byProperty[inverse.property, default: []].append((ReferenceTarget(id: sourceID), linkRecord))
            }
        }

        for (property, entries) in byProperty {
            let ordered = entries.sorted(by: Self.precedes)
            try decoded.loadReference(property, to: ordered.map(\.target), from: targets, links: links, depth: depth)
        }
        return decoded
    }

    /// Whether `a` comes before `b` in a to-many reference: by order key, then by when its link
    /// was created, then by the link's name.
    private static func precedes(_ a: (target: ReferenceTarget, link: CKRecord), _ b: (target: ReferenceTarget, link: CKRecord)) -> Bool {
        let (orderA, orderB) = (a.target.order ?? "", b.target.order ?? "")
        if orderA != orderB { return OrderKey.precedes(orderA, orderB) }
        let (dateA, dateB) = (a.link.creationDate ?? .distantPast, b.link.creationDate ?? .distantPast)
        if dateA != dateB { return dateA < dateB }
        return a.link.recordID.recordName < b.link.recordID.recordName
    }

    /// The record's `id`, parsed from its record name. Used by the code `@Record` generates.
    public static func decodeID(from record: CKRecord) throws -> UUID {
        let name = record.recordID.recordName
        guard let id = UUID(uuidString: name) else {
            throw CKRecordDecodingError.invalidRecordName(name)
        }
        return id
    }
}
