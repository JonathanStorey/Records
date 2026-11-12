import CloudKit

/// One `@Reference` that writes links, with its current targets, as the encoder needs it.
public struct ReferenceState {
    /// The reference as `@Record` describes it.
    public let schema: ReferenceSchema
    /// The target's `@Reference(from:)` side, when the relationship is two-way.
    public let inverse: ReferenceSchema?
    /// The targets' IDs, in order.
    public let ids: [UUID]
    /// The loaded targets, in order. Empty where loading stopped.
    public let records: [any Record]

    /// The property name, such as `author`.
    public var property: String { schema.property }
    /// The target's record type, such as `Person`.
    public var targetType: CKRecord.RecordType { schema.target.recordType }
    /// Whether the property holds many targets.
    public var isToMany: Bool { schema.isToMany }

    /// Every `@Reference` of `type` that writes links, with its targets' IDs and loaded records
    /// from `targets` by property. Used by the code `@Record` generates.
    public static func all<R: Record>(of type: R.Type, targets: [String: (ids: [UUID], records: [any Record])]) -> [ReferenceState] {
        let schema = R.schema
        return schema.references.filter { !$0.isFrom }.map { reference in
            let target = targets[reference.property]
            return ReferenceState(
                schema: reference, inverse: schema.inverse(of: reference.property, in: reference.target),
                ids: target?.ids ?? [], records: target?.records ?? []
            )
        }
    }
}

// MARK: - To one

/// A to-one `@Reference` itself, which `$author` gives for `@Reference var author: Person?`.
///
/// It keeps the target's ID and the loaded record. `$author.id` reads the ID even when the record
/// isn't loaded. Two values are equal when they point at the same target, whether or not it is
/// loaded.
public struct ToOne<Target: Record> {
    /// The target the reference points at now, loaded or not. To change it, set the record.
    public internal(set) var id: UUID?
    /// The target's ID as a list, empty when there is none, matching `ToMany`.
    public var ids: [UUID] { id.map { [$0] } ?? [] }
    /// The loaded target as a list, empty when it isn't loaded, matching `ToMany`.
    public var loadedRecords: [any Record] { value.map { [$0] } ?? [] }
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

    /// Sets the reference as read from storage. Uses the first of `ids`. When `depth` is at
    /// least 1 and `graph` holds the target, reads it with `depth - 1`, so its own references
    /// hold records `depth - 1` levels further.
    public mutating func load(_ ids: [UUID], from graph: RecordGraph, depth: Int = 1) throws {
        id = ids.first
        guard depth > 0, let id else { box = nil; return }
        box = try graph.record(Target.self, id: id, depth: depth - 1).map(Box.init)
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

/// A to-many `@Reference` itself, which `$tags` gives for `@Reference var tags: [Tag]`.
///
/// It keeps the target IDs and the loaded records, in the order the targets were added.
/// `$tags.ids` reads every ID even when the records aren't loaded. Each target appears once: a
/// repeated ID keeps its first position. Two values are equal when they point at the same targets
/// in the same order.
public struct ToMany<Target: Record> {
    private var storedIDs: [UUID] = []
    /// The loaded targets by ID. A class, so a record can refer to its own type.
    private var box: Box?

    /// A reference to `ids` that holds only the IDs.
    public init(ids: [UUID]) {
        self.ids = ids
    }

    /// A reference to `values`, holding the records themselves.
    public init(_ values: [Target]) {
        self.values = values
    }

    /// The loaded targets as `values` holds them. Empty where loading stopped.
    public var loadedRecords: [any Record] { values }

    /// The targets the reference points at now, in order, loaded or not. To change them, set the
    /// records, or remove one with `remove(id:)`.
    public internal(set) var ids: [UUID] {
        get { storedIDs }
        set {
            var seen = Set<UUID>()
            storedIDs = newValue.filter { seen.insert($0).inserted }
        }
    }

    /// The loaded targets, in order. A target that isn't loaded is left out.
    ///
    /// Setting it keeps any target that wasn't loaded, at its old position, because code that
    /// never saw a target cannot have meant to remove it. To remove one, use `remove(id:)`.
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

    /// Removes the target with `id`, whether or not it is loaded.
    public mutating func remove(id: UUID) {
        storedIDs.removeAll { $0 == id }
    }

    /// Sets the reference as read from storage. `ids` must already be in the order they were added.
    /// When `depth` is at least 1, reads each target `graph` holds with `depth - 1`, so its own
    /// references hold records `depth - 1` levels further.
    public mutating func load(_ ids: [UUID], from graph: RecordGraph, depth: Int = 1) throws {
        self.ids = ids

        var values: [UUID: Target] = [:]
        if depth > 0 {
            for id in storedIDs {
                values[id] = try graph.record(Target.self, id: id, depth: depth - 1)
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

// MARK: - Loaded targets

extension Record {
    /// The target records loaded into the references that write links. `@Reference(from:)`
    /// sides are left out, since this record doesn't own those links.
    var loadedTargets: [any Record] {
        referenceStates.flatMap(\.records)
    }
}
