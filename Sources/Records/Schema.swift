import CloudKit

/// What a `Record` type stores, as `@Record` describes it. The container reads it to build and
/// check its tables, because Swift can't read property attributes at runtime.
public struct RecordSchema: Sendable {
    /// The record type, such as `Album`.
    public let recordType: CKRecord.RecordType
    /// Every stored field except `id`, in declaration order. `@Asset` properties aren't fields.
    public let fields: [FieldSchema]
    /// The stored key of each `@Asset`, which names its link.
    public let assets: [String]
    /// Every `@Reference`, including the `@Reference(from:)` sides.
    public let references: [ReferenceSchema]

    public init(recordType: CKRecord.RecordType, fields: [FieldSchema], assets: [String], references: [ReferenceSchema]) {
        self.recordType = recordType
        self.fields = fields
        self.assets = assets
        self.references = references
    }
}

/// One stored field of a `Record`.
public struct FieldSchema: Hashable, Sendable {
    /// The Swift property name.
    public let name: String
    /// The name it is stored under: its `@Renamed` name, or `name`.
    public let key: String
    /// Whether the property is optional, so a missing value is `nil`.
    public let isOptional: Bool
    /// Whether CloudKit stores it encrypted.
    public let isEncrypted: Bool

    public init(name: String, key: String, isOptional: Bool, isEncrypted: Bool) {
        self.name = name
        self.key = key
        self.isOptional = isOptional
        self.isEncrypted = isEncrypted
    }
}

/// One `@Reference` of a `Record`.
public struct ReferenceSchema: Sendable {
    /// The property name, which its links name.
    public let property: String
    /// The type it points at. For a `@Reference(from:)` side, the owner's type.
    public let target: any Record.Type
    /// Whether it holds many targets.
    public let isToMany: Bool
    /// Whether it sorts its records, so its links carry no order keys.
    public let isSorted: Bool
    /// Whether it holds only IDs.
    public let holdsIDs: Bool
    /// For a `@Reference(from:)` side, the owner's property, such as `profile` for `\User.profile`.
    public let inverseOf: String?
    /// For a `@Reference(from:)` side, whether this record is deleted with its owner.
    public let deleteSelf: Bool

    public init(
        property: String, target: any Record.Type, isToMany: Bool, isSorted: Bool, holdsIDs: Bool,
        inverseOf: String? = nil, deleteSelf: Bool = false
    ) {
        self.property = property
        self.target = target
        self.isToMany = isToMany
        self.isSorted = isSorted
        self.holdsIDs = holdsIDs
        self.inverseOf = inverseOf
        self.deleteSelf = deleteSelf
    }

    /// Whether this is a read-only `@Reference(from:)` side, which writes no links.
    public var isFrom: Bool { inverseOf != nil }
}
