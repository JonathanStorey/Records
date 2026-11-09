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

/// The state of one `@Reference`, as the encoder needs it to write links.
public struct ReferenceState: Equatable, Sendable {
    /// The property name, such as `author`.
    public let property: String
    /// The target's record type, such as `Person`.
    public let targetType: CKRecord.RecordType
    /// Whether the property holds many targets.
    public let isToMany: Bool
    /// The targets now, in order, each with the order key it will be saved with.
    public let targets: [ReferenceTarget]
    /// The targets when the record was last loaded or saved. Empty for a record never saved.
    public let loaded: [ReferenceTarget]

    /// Whether the reference changed since it was loaded or saved.
    public var hasChanges: Bool { targets != loaded }
}

// MARK: - To one

/// Storage behind a to-one `@Reference` property. `@Reference` generates it, named with a
/// leading underscore, so code never needs to touch it.
///
/// It keeps the target's ID, the ID when the record was last loaded or saved, and, for
/// `@Reference var author: Person?`, the loaded record. Two values are equal when they point at
/// the same target, whether or not it is loaded.
public struct ToOne<Target: Record> {
    /// The target the reference points at now.
    public var id: UUID?
    /// The target when the record was last loaded or saved.
    public private(set) var loadedID: UUID?
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

    /// Sets the reference as read from storage, so it starts out unchanged. Uses the first of
    /// `targets`, and decodes its record when `records` holds it.
    public mutating func load(_ targets: [ReferenceTarget], from records: [CKRecord]) throws {
        id = targets.first?.id
        loadedID = id
        box = try id
            .flatMap { id in records.first { Target.matches($0, id: id) } }
            .map { Box(try CKRecordDecoder().decode(Target.self, from: $0)) }
    }

    /// Records that the current target was saved.
    public mutating func markSaved() {
        loadedID = id
    }

    /// The reference's state for the encoder.
    public func state(property: String) -> ReferenceState {
        ReferenceState(
            property: property, targetType: Target.recordType, isToMany: false,
            targets: id.map { [ReferenceTarget(id: $0)] } ?? [],
            loaded: loadedID.map { [ReferenceTarget(id: $0)] } ?? []
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
/// It keeps the target IDs in order, the targets and their order keys when the record was last
/// loaded or saved, and, for `@Reference var tags: [Tag]`, the loaded records. Each target
/// appears once: a repeated ID keeps its first position. Two values are equal when they point at
/// the same targets in the same order.
public struct ToMany<Target: Record> {
    private var storedIDs: [UUID] = []
    /// The targets when the record was last loaded or saved, with their order keys.
    public private(set) var loaded: [ReferenceTarget] = []
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

    /// Sets the reference as read from storage, so it starts out unchanged. `targets` must
    /// already be in order. Decodes each target whose record `records` holds.
    public mutating func load(_ targets: [ReferenceTarget], from records: [CKRecord]) throws {
        ids = targets.map(\.id)
        var seen = Set<UUID>()
        loaded = targets.filter { seen.insert($0.id).inserted }

        var values: [UUID: Target] = [:]
        for id in storedIDs {
            if let record = records.first(where: { Target.matches($0, id: id) }) {
                values[id] = try CKRecordDecoder().decode(Target.self, from: record)
            }
        }
        box = values.isEmpty ? nil : Box(values)
    }

    /// Records that the current targets were saved, with the order keys they were saved with.
    public mutating func markSaved() {
        loaded = plannedTargets
    }

    /// The reference's state for the encoder.
    public func state(property: String) -> ReferenceState {
        ReferenceState(
            property: property, targetType: Target.recordType, isToMany: true,
            targets: plannedTargets, loaded: loaded
        )
    }

    /// The current targets with order keys: loaded keys where they still sort correctly, new
    /// keys for added and moved targets.
    private var plannedTargets: [ReferenceTarget] {
        var keys: [UUID: String] = [:]
        for target in loaded {
            if let order = target.order { keys[target.id] = order }
        }
        return zip(storedIDs, OrderKey.assign(storedIDs.map { keys[$0] }))
            .map { ReferenceTarget(id: $0, order: $1) }
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
