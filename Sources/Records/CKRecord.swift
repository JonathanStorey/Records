import CloudKit
import CryptoKit

/// The shape of a relationship. Derived from a relationship signature, never stored.
public enum Relationship: String, Sendable, CaseIterable {
    case oneToOne
    case oneToMany
    case manyToOne
    case manyToMany
}

/// What happens to the record at the other end of a link when one end is deleted.
/// Stored as intent on the link and enforced by Records, never by CloudKit.
public enum DeleteRule: String, Sendable, CaseIterable {
    case cascade
    case nullify
    case deny
    case noAction
}

public enum RecordLinkError: Error, Equatable {
    /// The signature does not match `Type.property:Type` or `Type.property:[Type]`,
    /// optionally followed by ` <-> ` and the inverse side.
    case invalidSignature(String)
    /// Source and target must live in the same record zone.
    case zoneMismatch
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

extension CKRecord {
    /// The CloudKit record type for relationship links.
    public static let linkRecordType: CKRecord.RecordType = "RecordLink"

    /// Field keys on a `RecordLink` record.
    public enum LinkKey {
        public static let order = "order"
        public static let relationship = "relationship"
        public static let sourceName = "sourceName"
        public static let sourceRule = "sourceRule"
        public static let targetName = "targetName"
        public static let targetRule = "targetRule"
        public static let version = "version"
    }

    /// The current `RecordLink` format version.
    public static let linkVersion: Int64 = 1

    /// Factories for `RecordLink` records, one per relationship kind.
    ///
    /// Each factory builds the relationship signature from the records' types and the property
    /// names, so the signature is always canonical. The record name is derived from the link's
    /// identity, so creating the same link twice, on any device, produces the same record.
    /// The parent is set to `source` so the link travels with shares.
    ///
    /// ```swift
    /// let link = try CKRecord.Link.manyToOne(
    ///     source: note, property: "folder",
    ///     target: folder, inverse: "notes",
    ///     targetRule: .cascade)
    /// // relationship == "Note.folder:Folder <-> Folder.notes:[Note]"
    /// ```
    public enum Link {
        /// One source to one target, e.g. `User.profile:Profile <-> Profile.user:User`.
        /// The inverse is required, because a to-one link without one reads as many-to-one.
        public static func oneToOne(
            source: CKRecord,
            property: String,
            target: CKRecord,
            inverse: String,
            sourceRule: DeleteRule = .nullify,
            targetRule: DeleteRule = .nullify
        ) throws -> CKRecord {
            try make(
                .oneToOne,
                source: source, property: property, sourceIsToMany: false,
                target: target, inverse: inverse, inverseIsToMany: false,
                sourceRule: sourceRule, targetRule: targetRule, order: nil
            )
        }

        /// One source to many targets, e.g. `Folder.notes` holding notes that each have one folder.
        /// The inverse is required, because a to-many link without one reads as many-to-many.
        ///
        /// The link is stored from the target's side as many-to-one, so this returns exactly the
        /// record `manyToOne(source: target, property: inverse, target: source, inverse: property)`
        /// returns, with the rules swapped to match.
        public static func oneToMany(
            source: CKRecord,
            property: String,
            target: CKRecord,
            inverse: String,
            sourceRule: DeleteRule = .nullify,
            targetRule: DeleteRule = .nullify,
            order: String? = nil
        ) throws -> CKRecord {
            // Stored from the "many" side, so one-to-many and many-to-one never produce two
            // records for the same fact. Ends and rules swap; `order` keeps its meaning.
            try make(
                .manyToOne,
                source: target, property: inverse, sourceIsToMany: false,
                target: source, inverse: property, inverseIsToMany: true,
                sourceRule: targetRule, targetRule: sourceRule, order: order
            )
        }

        /// Many sources to one target, e.g. `Note.folder:Folder <-> Folder.notes:[Note]`,
        /// or `Note.author:Person` without an inverse.
        public static func manyToOne(
            source: CKRecord,
            property: String,
            target: CKRecord,
            inverse: String? = nil,
            sourceRule: DeleteRule = .nullify,
            targetRule: DeleteRule = .nullify
        ) throws -> CKRecord {
            try make(
                .manyToOne,
                source: source, property: property, sourceIsToMany: false,
                target: target, inverse: inverse, inverseIsToMany: true,
                sourceRule: sourceRule, targetRule: targetRule, order: nil
            )
        }

        /// Many sources to many targets, e.g. `Note.tags:[Tag] <-> Tag.notes:[Note]`,
        /// or `Note.tags:[Tag]` without an inverse.
        public static func manyToMany(
            source: CKRecord,
            property: String,
            target: CKRecord,
            inverse: String? = nil,
            sourceRule: DeleteRule = .nullify,
            targetRule: DeleteRule = .nullify,
            order: String? = nil
        ) throws -> CKRecord {
            try make(
                .manyToMany,
                source: source, property: property, sourceIsToMany: true,
                target: target, inverse: inverse, inverseIsToMany: true,
                sourceRule: sourceRule, targetRule: targetRule, order: order
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

        private static func make(
            _ kind: Relationship,
            source: CKRecord,
            property: String,
            sourceIsToMany: Bool,
            target: CKRecord,
            inverse: String?,
            inverseIsToMany: Bool,
            sourceRule: DeleteRule,
            targetRule: DeleteRule,
            order: String?
        ) throws -> CKRecord {
            guard source.recordID.zoneID == target.recordID.zoneID else {
                throw RecordLinkError.zoneMismatch
            }

            let relationship = signature(
                sourceType: source.recordType,
                property: property,
                sourceIsToMany: sourceIsToMany,
                targetType: target.recordType,
                inverse: inverse,
                inverseIsToMany: inverseIsToMany
            )
            // Parsing validates the identifiers and confirms the signature reads back as `kind`.
            guard try Relationship(signature: relationship) == kind else {
                throw RecordLinkError.invalidSignature(relationship)
            }

            let forward = signature(
                sourceType: source.recordType,
                property: property,
                sourceIsToMany: sourceIsToMany,
                targetType: target.recordType,
                inverse: nil,
                inverseIsToMany: inverseIsToMany
            )
            let recordID = CKRecord.ID(
                recordName: recordName(
                    forward: forward,
                    isToMany: sourceIsToMany,
                    sourceName: source.recordID.recordName,
                    targetName: target.recordID.recordName
                ),
                zoneID: source.recordID.zoneID
            )

            let record = CKRecord(recordType: CKRecord.linkRecordType, recordID: recordID)
            record[CKRecord.LinkKey.relationship] = relationship
            record[CKRecord.LinkKey.sourceName] = source.recordID.recordName
            record[CKRecord.LinkKey.targetName] = target.recordID.recordName
            record[CKRecord.LinkKey.sourceRule] = sourceRule.rawValue
            record[CKRecord.LinkKey.targetRule] = targetRule.rawValue
            record[CKRecord.LinkKey.version] = CKRecord.linkVersion
            if let order {
                record[CKRecord.LinkKey.order] = order
            }
            record.setParent(source.recordID)
            return record
        }

        /// `link-` followed by the hex SHA-256 of the fields that identify the link.
        ///
        /// Only the forward side of the signature (before ` <-> `) is hashed, so adding or
        /// renaming an inverse never changes existing link names. To-one links leave out the
        /// target, so pointing at a new target overwrites the same record.
        static func recordName(
            forward: String,
            isToMany: Bool,
            sourceName: String,
            targetName: String
        ) -> String {
            let parts = isToMany ? [forward, sourceName, targetName] : [forward, sourceName]
            let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
            return "link-" + digest.map { String(format: "%02x", $0) }.joined()
        }
    }
}
