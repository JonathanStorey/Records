import CloudKit
import CryptoKit

/// The shape of a relationship. Derived from a relationship signature, never stored.
public enum Relationship: String, Sendable, CaseIterable {
    case oneToOne
    case oneToMany
    case manyToOne
    case manyToMany
}

public enum RecordLinkError: Error, Equatable {
    /// The signature does not match `Type.property:Type` or `Type.property:[Type]`,
    /// optionally followed by ` <-> ` and the inverse side.
    case invalidSignature(String)
    /// `deleteSelf` needs an inverse, because only a two-way relationship can delete.
    case deleteSelfRequiresInverse
}

extension Relationship {
    /// Parses a relationship signature such as `Note.tags:[Tag] <-> Tag.notes:[Note]`.
    ///
    /// Brackets mean many. A signature without ` <-> ` has no inverse and is treated as
    /// `manyToOne` (to-one source) or `manyToMany` (to-many source).
    public init(signature: String) throws {
        let sides = signature.components(separatedBy: " <-> ")
        guard sides.count == 1 || sides.count == 2 else {
            throw RecordLinkError.invalidSignature(signature)
        }

        let source = try SignatureSide(sides[0], signature: signature)
        let inverse = try sides.count == 2 ? SignatureSide(sides[1], signature: signature) : nil

        if let inverse {
            // Each side must point at the other side's declaring type.
            guard source.targetType == inverse.declaringType,
                  inverse.targetType == source.declaringType
            else { throw RecordLinkError.invalidSignature(signature) }
        }

        switch (source.isToMany, inverse?.isToMany) {
        case (false, false?): self = .oneToOne
        case (false, _): self = .manyToOne
        case (true, false?): self = .oneToMany
        case (true, _): self = .manyToMany
        }
    }
}

/// One side of a signature: `Type.property:Type` or `Type.property:[Type]`.
private struct SignatureSide {
    let declaringType: Substring
    let property: Substring
    let targetType: Substring
    let isToMany: Bool

    init(_ side: String, signature: String) throws {
        let parts = side.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw RecordLinkError.invalidSignature(signature) }

        let declaring = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard declaring.count == 2 else { throw RecordLinkError.invalidSignature(signature) }

        var target = parts[1]
        let isToMany = target.hasPrefix("[") && target.hasSuffix("]")
        if isToMany { target = target.dropFirst().dropLast() }

        guard Self.isIdentifier(declaring[0]),
              Self.isIdentifier(declaring[1]),
              Self.isIdentifier(target)
        else { throw RecordLinkError.invalidSignature(signature) }

        self.declaringType = declaring[0]
        self.property = declaring[1]
        self.targetType = target
        self.isToMany = isToMany
    }

    private static func isIdentifier(_ text: Substring) -> Bool {
        guard let first = text.first, first.isLetter || first == "_" else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

/// A relationship between two records, stored as its own internal `RecordLink` record.
///
/// The source is always the owning side, the property a `@Reference(to:)` marks. The inverse is
/// the target's `@Reference(from:)` property, which never writes links.
///
/// Each factory builds the relationship signature from the records' types and the property
/// names, so the signature is always canonical. The `id` is derived from the link's identity,
/// so creating the same link twice, on any device, produces the same record.
///
/// `deleteSelf` belongs to the inverse side: when true, deleting the source also deletes the
/// target, like `CKRecord.Reference.Action.deleteSelf` on a child. It needs an inverse, because a
/// one-way reference never deletes anything. Records enforces it, never CloudKit.
///
/// ```swift
/// let link = try RecordLink.manyToOne(
///     from: note, property: "folder",
///     to: Folder.self, id: folder.id, inverse: "notes")
/// // relationship == "Note.folder:Folder <-> Folder.notes:[Note]"
/// ```
@Record("RecordLink")
struct RecordLink: Equatable, Sendable {
    /// Derived from the link's identity. See `id(forward:kind:sourceName:targetName:)`.
    var id: UUID
    /// The relationship signature, e.g. `Note.tags:[Tag] <-> Tag.notes:[Note]`.
    var relationship: String
    /// The source record's name, its `id` as a UUID string.
    var sourceName: String
    /// The target record's name, its `id` as a UUID string.
    var targetName: String
    /// Delete the target when the source is deleted.
    var deleteSelf: Bool
    /// Fractional index key. Required on to-many links, empty on to-one links.
    var order: String?
    /// The link format version.
    var version: Int64

    /// The current link format version.
    static let currentVersion: Int64 = 1

    /// The relationship's shape, read from its signature.
    var kind: Relationship {
        get throws { try Relationship(signature: relationship) }
    }

    // MARK: Factories

    /// One source to one target, e.g. `User.profile:Profile <-> Profile.user:User`.
    /// The inverse is required, because a to-one link without one reads as many-to-one.
    static func oneToOne<Source: Record, Target: Record>(
        from source: Source, property: String,
        to target: Target.Type, id targetID: UUID,
        inverse: String, deleteSelf: Bool = false
    ) throws -> RecordLink {
        try make(
            .oneToOne, source: source, property: property, sourceIsToMany: false,
            target: target, targetID: targetID, inverse: inverse, inverseIsToMany: false,
            deleteSelf: deleteSelf, order: nil
        )
    }

    /// One source to many targets, e.g. `Folder.notes:[Note] <-> Note.folder:Folder`.
    /// The inverse is required, because a to-many link without one reads as many-to-many.
    /// To-many links are always ordered, so `order` is a required fractional index key.
    static func oneToMany<Source: Record, Target: Record>(
        from source: Source, property: String,
        to target: Target.Type, id targetID: UUID,
        inverse: String, deleteSelf: Bool = false, order: String
    ) throws -> RecordLink {
        try make(
            .oneToMany, source: source, property: property, sourceIsToMany: true,
            target: target, targetID: targetID, inverse: inverse, inverseIsToMany: false,
            deleteSelf: deleteSelf, order: order
        )
    }

    /// Many sources to one target, e.g. `Note.folder:Folder <-> Folder.notes:[Note]`,
    /// or `Note.author:Person` without an inverse.
    static func manyToOne<Source: Record, Target: Record>(
        from source: Source, property: String,
        to target: Target.Type, id targetID: UUID,
        inverse: String? = nil, deleteSelf: Bool = false
    ) throws -> RecordLink {
        try make(
            .manyToOne, source: source, property: property, sourceIsToMany: false,
            target: target, targetID: targetID, inverse: inverse, inverseIsToMany: true,
            deleteSelf: deleteSelf, order: nil
        )
    }

    /// Many sources to many targets, e.g. `Note.tags:[Tag] <-> Tag.notes:[Note]`,
    /// or `Note.tags:[Tag]` without an inverse.
    /// To-many links are always ordered, so `order` is a required fractional index key.
    static func manyToMany<Source: Record, Target: Record>(
        from source: Source, property: String,
        to target: Target.Type, id targetID: UUID,
        inverse: String? = nil, deleteSelf: Bool = false, order: String
    ) throws -> RecordLink {
        try make(
            .manyToMany, source: source, property: property, sourceIsToMany: true,
            target: target, targetID: targetID, inverse: inverse, inverseIsToMany: true,
            deleteSelf: deleteSelf, order: order
        )
    }

    /// Builds the canonical signature, e.g. `Note.tags:[Tag] <-> Tag.notes:[Note]`.
    static func signature(
        sourceType: String,
        property: String,
        sourceIsToMany: Bool,
        targetType: String,
        inverse: String?,
        inverseIsToMany: Bool
    ) -> String {
        let forward = "\(sourceType).\(property):" + (sourceIsToMany ? "[\(targetType)]" : targetType)
        guard let inverse else { return forward }
        let backward = "\(targetType).\(inverse):" + (inverseIsToMany ? "[\(sourceType)]" : sourceType)
        return forward + " <-> " + backward
    }

    private static func make<Source: Record, Target: Record>(
        _ kind: Relationship,
        source: Source,
        property: String,
        sourceIsToMany: Bool,
        target: Target.Type,
        targetID: UUID,
        inverse: String?,
        inverseIsToMany: Bool,
        deleteSelf: Bool,
        order: String?
    ) throws -> RecordLink {
        guard !deleteSelf || inverse != nil else {
            throw RecordLinkError.deleteSelfRequiresInverse
        }

        let relationship = signature(
            sourceType: Source.recordType, property: property, sourceIsToMany: sourceIsToMany,
            targetType: Target.recordType, inverse: inverse, inverseIsToMany: inverseIsToMany
        )
        // Parsing validates the identifiers and confirms the signature reads back as `kind`.
        guard try Relationship(signature: relationship) == kind else {
            throw RecordLinkError.invalidSignature(relationship)
        }

        let forward = signature(
            sourceType: Source.recordType, property: property, sourceIsToMany: sourceIsToMany,
            targetType: Target.recordType, inverse: nil, inverseIsToMany: inverseIsToMany
        )
        let sourceName = source.id.uuidString
        let targetName = targetID.uuidString

        return RecordLink(
            id: id(forward: forward, kind: kind, sourceName: sourceName, targetName: targetName),
            relationship: relationship,
            sourceName: sourceName,
            targetName: targetName,
            deleteSelf: deleteSelf,
            order: order,
            version: currentVersion
        )
    }

    /// A UUID built from the SHA-256 of the fields that identify the link.
    ///
    /// Only the forward side of the signature (before ` <-> `) is hashed, so adding or
    /// renaming an inverse keeps existing link IDs. To-one links leave out the target, so
    /// pointing at a new target overwrites the same record. One-to-many links leave out the
    /// source, so each target belongs to one source.
    ///
    /// The first 16 bytes of the digest become the UUID, marked as version 8 (custom) with the
    /// RFC 9562 variant, so it is a valid UUID that never collides with random v4 IDs.
    static func id(forward: String, kind: Relationship, sourceName: String, targetName: String) -> UUID {
        let parts: [String] = switch kind {
        case .oneToOne, .manyToOne: [forward, sourceName]
        case .oneToMany: [forward, targetName]
        case .manyToMany: [forward, sourceName, targetName]
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
