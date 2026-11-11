import CloudKit
import CryptoKit

/// The shape of a relationship, from both sides' cardinality. Derived from the schema, never
/// stored.
enum Relationship: String, Sendable, CaseIterable {
    case oneToOne
    case oneToMany
    case manyToOne
    case manyToMany

    /// The shape of the relationship a `@Reference` declares. Without an inverse, a to-one
    /// reference reads as many-to-one and a to-many reference as many-to-many.
    init(_ reference: ReferenceState) {
        self = switch (reference.isToMany, reference.inverse?.isToMany) {
        case (false, false?): .oneToOne
        case (false, _): .manyToOne
        case (true, false?): .oneToMany
        case (true, _): .manyToMany
        }
    }
}

/// One link of a relationship, or one `@Asset`, stored as its own internal `RecordLink` record.
///
/// A link stores only data: which property of which record it belongs to, the target, its order,
/// and, for an asset, the asset. Everything else about the relationship, such as the target type,
/// the inverse, and `deleteSelf`, comes from the types' declarations, so changing an inverse never
/// rewrites a link.
///
/// The `id` is derived from the link's identity, so creating the same link twice, on any device,
/// produces the same record.
@Record("RecordLink")
struct RecordLink: Equatable, Sendable {
    /// Derived from the link's identity. See `id(source:kind:sourceName:targetName:)`.
    var id: UUID
    /// The owning property, as `Type.property`, such as `Album.tracks`. For a `@Reference` it is
    /// the property that writes links. For an `@Asset` it is the asset's property.
    var source: String
    /// The source record's name, its `id` as a UUID string.
    var sourceName: String
    /// The target record's name, its `id` as a UUID string. `nil` on an asset's link.
    var targetName: String?
    /// Fractional index key. Required on ordered to-many links, empty otherwise.
    var order: String?
    /// The asset's ID as a UUID string, on an `@Asset`'s link only. The asset itself is the
    /// link's `asset` field, which the encoder writes and the decoder reads.
    var assetID: String?

    /// The field that holds an asset link's `CKAsset`.
    static let assetKey = "asset"

    /// The source's record type, such as `Album`.
    var sourceType: Substring {
        source.split(separator: ".", maxSplits: 1).first ?? ""
    }

    /// The source's property, such as `tracks`.
    var sourceProperty: Substring {
        source.split(separator: ".", maxSplits: 1).dropFirst().first ?? ""
    }

    /// `Type.property`, as `source` stores it.
    static func source(type: CKRecord.RecordType, property: String) -> String {
        "\(type).\(property)"
    }

    /// The full signature of the relationship a `@Reference` declares, such as
    /// `Album.tracks:[Track] <-> Track.albumID:Album`. Brackets mean many. It is computed from the
    /// declarations for reading and is never stored.
    static func signature(of reference: ReferenceState, in sourceType: CKRecord.RecordType) -> String {
        let forward = "\(source(type: sourceType, property: reference.property)):"
            + (reference.isToMany ? "[\(reference.targetType)]" : reference.targetType)
        guard let inverse = reference.inverse else { return forward }
        let backward = "\(reference.targetType).\(inverse.property):"
            + (inverse.isToMany ? "[\(sourceType)]" : sourceType)
        return forward + " <-> " + backward
    }

    /// A UUID built from the SHA-256 of the fields that identify the link.
    ///
    /// A to-one link leaves out the target, so pointing at a new target overwrites the same
    /// record. A one-to-many link leaves out the source, so each target belongs to one source. A
    /// many-to-many link has one per pair.
    ///
    /// The first 16 bytes of the digest become the UUID, marked as version 8 (custom) with the
    /// RFC 9562 variant, so it is a valid UUID that never collides with random v4 IDs.
    static func id(source: String, kind: Relationship, sourceName: String, targetName: String) -> UUID {
        let parts: [String] = switch kind {
        case .oneToOne, .manyToOne: [source, sourceName]
        case .oneToMany: [source, targetName]
        case .manyToMany: [source, sourceName, targetName]
        }
        var bytes = Array(SHA256.hash(data: Data(parts.joined(separator: "|").utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80 // version 8
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 9562 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

// MARK: - References

extension RecordLink {
    /// The link a `@Reference` writes to `target`.
    init(reference: ReferenceState, sourceType: CKRecord.RecordType, sourceID: UUID, target: ReferenceTarget) {
        self.init(
            id: Self.id(reference: reference, sourceType: sourceType, sourceID: sourceID, targetID: target.id),
            source: Self.source(type: sourceType, property: reference.property),
            sourceName: sourceID.uuidString,
            targetName: target.id.uuidString,
            order: target.order
        )
    }

    /// The ID of the link a `@Reference` writes to `targetID`.
    static func id(reference: ReferenceState, sourceType: CKRecord.RecordType, sourceID: UUID, targetID: UUID) -> UUID {
        id(
            source: source(type: sourceType, property: reference.property),
            kind: Relationship(reference),
            sourceName: sourceID.uuidString,
            targetName: targetID.uuidString
        )
    }
}

// MARK: - Assets

extension RecordLink {
    /// The link an `@Asset` writes. Like any to-one link, its ID leaves out the target, so a new
    /// value overwrites the same link.
    init(asset: AssetState, assetID: UUID, sourceType: CKRecord.RecordType, sourceID: UUID) {
        let source = Self.source(type: sourceType, property: asset.property)
        self.init(
            id: Self.id(source: source, kind: .manyToOne, sourceName: sourceID.uuidString, targetName: ""),
            source: source,
            sourceName: sourceID.uuidString,
            targetName: nil,
            order: nil,
            assetID: assetID.uuidString
        )
    }
}
