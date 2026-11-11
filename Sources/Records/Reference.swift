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

/// One `@Reference` that writes links, with its current targets, as the encoder needs it.
public struct ReferenceState: Sendable {
    /// The reference as `@Record` describes it.
    public let schema: ReferenceSchema
    /// The target's `@Reference(from:)` side, when the relationship is two-way.
    public let inverse: ReferenceSchema?
    /// The targets' IDs, in order.
    public let ids: [UUID]

    /// The property name, such as `author`.
    public var property: String { schema.property }
    /// The target's record type, such as `Person`.
    public var targetType: CKRecord.RecordType { schema.target.recordType }
    /// Whether the property holds many targets.
    public var isToMany: Bool { schema.isToMany }
    /// Whether a to-many property sorts its records, so its links carry no order keys.
    public var isSorted: Bool { schema.isSorted }

    /// Every `@Reference` of `type` that writes links, with its targets' IDs from `ids` by
    /// property. Used by the code `@Record` generates.
    public static func all<R: Record>(of type: R.Type, ids: [String: [UUID]]) -> [ReferenceState] {
        let schema = R.schema
        return schema.references.filter { !$0.isFrom }.map { reference in
            ReferenceState(
                schema: reference, inverse: schema.inverse(of: reference.property, in: reference.target),
                ids: ids[reference.property] ?? []
            )
        }
    }
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

// MARK: - Loaded targets

/// Reference storage that can hold loaded target records.
protocol LoadedReference {
    /// The target records the reference holds, in order. Empty when it holds only IDs.
    var loadedRecords: [any Record] { get }
    /// The target IDs the reference holds, in order.
    var targetIDs: [UUID] { get }
}

extension ToOne: LoadedReference {
    var loadedRecords: [any Record] { value.map { [$0] } ?? [] }
    var targetIDs: [UUID] { id.map { [$0] } ?? [] }
}

extension ToMany: LoadedReference {
    var loadedRecords: [any Record] { values }
    var targetIDs: [UUID] { ids }
}

extension Record {
    /// The target records loaded into the references that write links. `@Reference(from:)`
    /// sides are left out, since this record doesn't own those links.
    var loadedTargets: [any Record] {
        let owning = Set(referenceStates.map(\.property))
        return Mirror(reflecting: self).children.flatMap { child -> [any Record] in
            guard let label = child.label, label.hasPrefix("_"), owning.contains(String(label.dropFirst())),
                  let reference = child.value as? LoadedReference
            else { return [] }
            return reference.loadedRecords
        }
    }

    /// The target IDs of the `@Reference` named `property`, including a `from:` side, in order.
    func referencedIDs(_ property: String) -> [UUID] {
        let label = "_" + property
        let reference = Mirror(reflecting: self).children.first { $0.label == label }?.value as? LoadedReference
        return reference?.targetIDs ?? []
    }
}
