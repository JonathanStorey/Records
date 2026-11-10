import CloudKit

/// One target of a reference, with its position among the others.
public struct ReferenceTarget: Hashable, Sendable {
    /// The target record's ID.
    public let id: UUID
    /// The fractional index key that orders a to-many reference. `nil` for a to-one reference.
    public let order: String?

    public init(id: UUID, order: String? = nil) {
        self.id = id
        self.order = order
    }
}

/// The other side of a two-way relationship: the target's `@Reference(from:)` property.
///
/// `@Record` generates one for each `@Reference(from: \User.profile)` property, and the owner's
/// encoder looks it up with `Record.inverse(of:in:)`. The owner never names it.
public struct Inverse: Hashable, Sendable {
    /// The inverse property's name, such as `user`.
    public let property: String
    /// Whether the inverse holds many records.
    public let isToMany: Bool
    /// Whether the target is deleted with its owner.
    public let deleteSelf: Bool

    /// A to-one `from:` side, such as `var userID: UUID?` for `\User.profile`. The key path's
    /// value type must hold the `from:` side's type, here `Profile?`.
    public init<Owner: Record, Target: Record>(
        _ owner: KeyPath<Owner, Target?>, to target: Target.Type, property: String, deleteSelf: Bool = false
    ) {
        self.init(property: property, isToMany: false, deleteSelf: deleteSelf)
    }

    /// A to-one `from:` side of an owner that holds only the ID, such as `\Account.settingsID`.
    public init<Owner: Record, Target: Record>(
        _ owner: KeyPath<Owner, UUID?>, to target: Target.Type, property: String, deleteSelf: Bool = false
    ) {
        self.init(property: property, isToMany: false, deleteSelf: deleteSelf)
    }

    /// A to-one `from:` side of a to-many owner, such as `var albumID: UUID?` for `\Album.tracks`.
    public init<Owner: Record, Target: Record>(
        _ owner: KeyPath<Owner, [Target]>, to target: Target.Type, property: String, deleteSelf: Bool = false
    ) {
        self.init(property: property, isToMany: false, deleteSelf: deleteSelf)
    }

    /// A to-one `from:` side of a to-many owner that holds only IDs, such as `\Album.trackIDs`.
    public init<Owner: Record, Target: Record>(
        _ owner: KeyPath<Owner, [UUID]>, to target: Target.Type, property: String, deleteSelf: Bool = false
    ) {
        self.init(property: property, isToMany: false, deleteSelf: deleteSelf)
    }

    /// A to-many `from:` side of a to-one owner, such as `var bookIDs: [UUID]` for `\Book.shelf`:
    /// one-to-many.
    public init<Owner: Record, Target: Record>(
        many owner: KeyPath<Owner, Target?>, to target: Target.Type, property: String
    ) {
        self.init(property: property, isToMany: true, deleteSelf: false)
    }

    /// A to-many `from:` side of an owner that holds only the ID, such as `\Book.shelfID`.
    public init<Owner: Record, Target: Record>(
        many owner: KeyPath<Owner, UUID?>, to target: Target.Type, property: String
    ) {
        self.init(property: property, isToMany: true, deleteSelf: false)
    }

    /// A to-many `from:` side of a to-many owner, such as `var noteIDs: [UUID]` for `\Note.tags`:
    /// many-to-many.
    public init<Owner: Record, Target: Record>(
        many owner: KeyPath<Owner, [Target]>, to target: Target.Type, property: String
    ) {
        self.init(property: property, isToMany: true, deleteSelf: false)
    }

    /// A to-many `from:` side of a to-many owner that holds only IDs, such as `\Note.tagIDs`.
    public init<Owner: Record, Target: Record>(
        many owner: KeyPath<Owner, [UUID]>, to target: Target.Type, property: String
    ) {
        self.init(property: property, isToMany: true, deleteSelf: false)
    }

    init(property: String, isToMany: Bool, deleteSelf: Bool) {
        self.property = property
        self.isToMany = isToMany
        self.deleteSelf = deleteSelf
    }
}

/// One `@Reference` as the encoder needs it to write links.
public struct ReferenceState: Equatable, Sendable {
    /// The property name, such as `author`.
    public let property: String
    /// The target's record type, such as `Person`.
    public let targetType: CKRecord.RecordType
    /// Whether the property holds many targets.
    public let isToMany: Bool
    /// Whether a to-many property sorts its records, so its links carry no order keys.
    public let isSorted: Bool
    /// The target's `@Reference(from:)` side, when the relationship is two-way.
    public let inverse: Inverse?
    /// The targets' IDs, in order.
    public let ids: [UUID]
}

// MARK: - To one

/// Storage behind a to-one `@Reference` property. `@Reference` generates it, named with a
/// leading underscore, so code never needs to touch it.
///
/// It keeps the target's ID and, for `@Reference var author: Person?`, the loaded record. Two
/// values are equal when they point at the same target, whether or not it is loaded.
public struct ToOne<Target: Record> {
    /// The target the reference points at now.
    public var id: UUID?
    /// The loaded target. A class, so a record can refer to its own type.
    private var box: Box?

    /// A reference to `id` that holds only the ID.
    public init(id: UUID?) {
        self.id = id
    }

    /// A reference to `value`, holding the record itself.
    public init(_ value: Target?) {
        self.id = value?.id
        self.box = value.map(Box.init)
    }

    /// The loaded target, or `nil` when the reference is empty or its target isn't loaded.
    public var value: Target? {
        get {
            guard let box, box.value.id == id else { return nil }
            return box.value
        }
        set {
            id = newValue?.id
            box = newValue.map(Box.init)
        }
    }

    /// Sets the reference as read from storage. Uses the first of `targets`. When `depth` is at least 1 and `records` holds the target, decodes it with
    /// `depth - 1`, so its own references hold records `depth - 1` levels further.
    public mutating func load(_ targets: [ReferenceTarget], from records: [CKRecord], links: [CKRecord], depth: Int = 1) throws {
        id = targets.first?.id
        guard depth > 0 else { box = nil; return }
        box = try id
            .flatMap { id in records.first { Target.matches($0, id: id) } }
            .map { Box(try CKRecordDecoder().decode(Target.self, from: $0, links: links, targets: records, depth: depth - 1)) }
    }

    /// The reference's state for the encoder. `owner` is the record type that declares it, used
    /// to find the target's `@Reference(from:)` side.
    public func state(property: String, owner: CKRecord.RecordType) -> ReferenceState {
        ReferenceState(
            property: property, targetType: Target.recordType, isToMany: false, isSorted: false,
            inverse: Target.inverse(of: property, in: owner),
            ids: id.map { [$0] } ?? []
        )
    }

    private final class Box {
        let value: Target
        init(_ value: Target) { self.value = value }
    }
}

extension ToOne: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

extension ToOne: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// The box is immutable, so sharing it is safe whenever the target is.
extension ToOne: @unchecked Sendable where Target: Sendable {}

// MARK: - To many

/// Storage behind a to-many `@Reference` property. `@Reference` generates it, named with a
/// leading underscore, so code never needs to touch it.
///
/// It keeps the target IDs in order and, for `@Reference var tags: [Tag]`, the loaded records.
/// Each target appears once: a repeated ID keeps its first position. Two values are equal when
/// they point at the same targets in the same order.
public struct ToMany<Target: Record> {
    private var storedIDs: [UUID] = []
    /// The loaded targets by ID. A class, so a record can refer to its own type.
    private var box: Box?
    /// Whether the property sorts its records, so its links carry no order keys.
    public let isSorted: Bool

    /// A reference to `ids` that holds only the IDs. A sorted reference writes no order keys.
    public init(ids: [UUID], sorted: Bool = false) {
        isSorted = sorted
        self.ids = ids
    }

    /// A reference to `values`, holding the records themselves. A sorted reference writes no
    /// order keys.
    public init(_ values: [Target], sorted: Bool = false) {
        isSorted = sorted
        self.values = values
    }

    /// The targets the reference points at now, in order.
    public var ids: [UUID] {
        get { storedIDs }
        set {
            var seen = Set<UUID>()
            storedIDs = newValue.filter { seen.insert($0).inserted }
        }
    }

    /// The loaded targets, in order. A target that isn't loaded is left out.
    ///
    /// Setting it keeps any target that wasn't loaded, at its old position, because code that
    /// never saw a target cannot have meant to remove it. To remove one, set `ids`.
    public var values: [Target] {
        get { storedIDs.compactMap { box?.values[$0] } }
        set {
            var ids = newValue.map(\.id)
            for (index, id) in storedIDs.enumerated() where box?.values[id] == nil && !ids.contains(id) {
                ids.insert(id, at: min(index, ids.count))
            }
            self.ids = ids
            box = Box(Dictionary(newValue.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
        }
    }

    /// Sets the reference as read from storage. `targets` must already be in order. When `depth` is at least 1, decodes each target whose record
    /// `records` holds with `depth - 1`, so its own references hold records `depth - 1` levels
    /// further.
    public mutating func load(_ targets: [ReferenceTarget], from records: [CKRecord], links: [CKRecord], depth: Int = 1) throws {
        ids = targets.map(\.id)

        var values: [UUID: Target] = [:]
        if depth > 0 {
            for id in storedIDs {
                if let record = records.first(where: { Target.matches($0, id: id) }) {
                    values[id] = try CKRecordDecoder().decode(
                        Target.self, from: record, links: links, targets: records, depth: depth - 1
                    )
                }
            }
        }
        box = values.isEmpty ? nil : Box(values)
    }

    /// The reference's state for the encoder. `owner` is the record type that declares it, used
    /// to find the target's `@Reference(from:)` side.
    public func state(property: String, owner: CKRecord.RecordType) -> ReferenceState {
        ReferenceState(
            property: property, targetType: Target.recordType, isToMany: true, isSorted: isSorted,
            inverse: Target.inverse(of: property, in: owner),
            ids: storedIDs
        )
    }

    private final class Box {
        let values: [UUID: Target]
        init(_ values: [UUID: Target]) { self.values = values }
    }
}

extension ToMany: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.storedIDs == rhs.storedIDs
    }
}

extension ToMany: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(storedIDs)
    }
}

// The box is immutable, so sharing it is safe whenever the target is.
extension ToMany: @unchecked Sendable where Target: Sendable {}

extension Record {
    /// Whether `record` is this type's record for `id`.
    static func matches(_ record: CKRecord, id: UUID) -> Bool {
        record.recordType == recordType && record.recordID.recordName == id.uuidString
    }
}
