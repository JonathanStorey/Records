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

    /// Creates a `RecordLink` record connecting `source` to `target`.
    ///
    /// The record name is derived from the link's identity, so creating the same link twice,
    /// on any device, produces the same record. The parent is set to `source` so the link
    /// travels with shares.
    ///
    /// - Parameters:
    ///   - relationship: The relationship signature, e.g. `Note.tags:[Tag] <-> Tag.notes:[Note]`.
    ///   - source: The record that declares the relationship.
    ///   - target: The record it points at. Must be in the same zone as `source`.
    ///   - sourceRule: What happens to the target when the source is deleted.
    ///   - targetRule: What happens to the source when the target is deleted.
    ///   - order: Fractional index key for ordered to-many relationships.
    public static func Link(
        relationship: String,
        source: CKRecord.ID,
        target: CKRecord.ID,
        sourceRule: DeleteRule = .nullify,
        targetRule: DeleteRule = .nullify,
        order: String? = nil
    ) throws -> CKRecord {
        guard source.zoneID == target.zoneID else { throw RecordLinkError.zoneMismatch }

        let kind = try Relationship(signature: relationship)
        let recordID = CKRecord.ID(
            recordName: linkRecordName(
                kind: kind,
                relationship: relationship,
                sourceName: source.recordName,
                targetName: target.recordName
            ),
            zoneID: source.zoneID
        )

        let record = CKRecord(recordType: linkRecordType, recordID: recordID)
        record[LinkKey.relationship] = relationship
        record[LinkKey.sourceName] = source.recordName
        record[LinkKey.targetName] = target.recordName
        record[LinkKey.sourceRule] = sourceRule.rawValue
        record[LinkKey.targetRule] = targetRule.rawValue
        record[LinkKey.version] = linkVersion
        if let order {
            record[LinkKey.order] = order
        }
        record.setParent(source)
        return record
    }

    /// `link-` followed by the hex SHA-256 of the fields that identify the link.
    ///
    /// To-one links leave out the target, so pointing at a new target overwrites the same
    /// record. One-to-many links leave out the source, so each target has one source.
    static func linkRecordName(
        kind: Relationship,
        relationship: String,
        sourceName: String,
        targetName: String
    ) -> String {
        let parts: [String] = switch kind {
        case .oneToOne, .manyToOne: [relationship, sourceName]
        case .oneToMany: [relationship, targetName]
        case .manyToMany: [relationship, sourceName, targetName]
        }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
        return "link-" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
