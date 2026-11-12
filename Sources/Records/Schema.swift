import CloudKit

/// What a `Record` type stores, as `@Record` describes it. The container reads it to build and
/// check its tables, because Swift can't read property attributes at runtime.
public struct RecordSchema: Sendable {
    /// The record type, such as `Album`.
    public let recordType: CKRecord.RecordType
    /// Every stored field except `id`, in declaration order. `@Asset` properties aren't fields.
    public let fields: [FieldSchema]
    /// Every `@Reference`, including the `@Reference(from:)` sides.
    public let references: [ReferenceSchema]

    public init(recordType: CKRecord.RecordType, fields: [FieldSchema], references: [ReferenceSchema]) {
        self.recordType = recordType
        self.fields = fields
        self.references = references
    }

    /// The `@Reference(from:)` side of `target` that names `property` of this type, such as
    /// `User.profile`'s `Profile.user`, or `nil` when the relationship is one-way.
    func inverse(of property: String, in target: any Record.Type) -> ReferenceSchema? {
        target.schema.references.first { $0.inverseOf == property && $0.target.recordType == recordType }
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
    /// How its value is stored in its column.
    public let kind: FieldKind

    public init(name: String, key: String, isOptional: Bool, isEncrypted: Bool, kind: FieldKind) {
        self.name = name
        self.key = key
        self.isOptional = isOptional
        self.isEncrypted = isEncrypted
        self.kind = kind
    }
}

/// How a field's value is stored in its SQLite column.
///
/// `FieldCoding` gives each field the kind of what it writes: an enum its raw value's kind, and
/// any other Codable value `.bytes` of JSON.
public enum FieldKind: String, Hashable, Sendable {
    /// `TEXT`, from a `String`.
    case text
    /// `INTEGER`, from a `Bool` or an integer.
    case integer
    /// `REAL`, from a `Double` or `Float`.
    case real
    /// `REAL` seconds since 2001, the way `Date` holds them, so a date reads back exactly and
    /// dates sort and compare in SQL.
    case date
    /// `BLOB`, from `Data`, including Codable values stored as JSON.
    case bytes
    /// `BLOB` of a keyed archive, from a list or a `CLLocation` field.
    case archived

    /// The kind of a value CloudKit stores as is.
    static func direct(_ type: Any.Type) -> FieldKind {
        switch type {
        case is String.Type: .text
        case is Date.Type: .date
        case is Data.Type: .bytes
        case is Bool.Type, is Int.Type, is Int8.Type, is Int16.Type, is Int32.Type, is Int64.Type,
             is UInt.Type, is UInt8.Type, is UInt16.Type, is UInt32.Type, is UInt64.Type: .integer
        case is Double.Type, is Float.Type: .real
        default: .archived
        }
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
