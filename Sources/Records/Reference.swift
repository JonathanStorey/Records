import CloudKit

/// One `@Reference` that writes links, with its current targets, as the encoder needs it.
public struct ReferenceState {
    /// The reference as `@Record` describes it.
    public let schema: ReferenceSchema
    /// The target's `@Reference(from:)` side, when the relationship is two-way.
    public let inverse: ReferenceSchema?
    /// The targets' IDs.
    public let ids: [UUID]
    /// The loaded targets. Empty where loading stopped.
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

/// Storage behind a to-one `@Reference` property. `@Reference` generates it, named with a
/// leading underscore, so code never needs to touch it.
///
/// It keeps the target's ID and, for `@Reference var author: Person?`, the loaded record. Two
/// values are equal when they point at the same target, whether or not it is loaded.
public struct ToOne<Target: Record> {
    /// The target the reference points at now.
    public internal(set) var id: Target.ID?
    /// The target's ID as a list, empty when there is none, matching `ToMany`.
    public var ids: [Target.ID] { id.map { [$0] } ?? [] }
    /// The loaded target as a list, empty when it isn't loaded, matching `ToMany`.
    public var loadedRecords: [any Record] { value.map { [$0] } ?? [] }
    /// The loaded target. A class, so a record can refer to its own type.
    private var box: Box?

    /// A reference to `id` that holds only the ID.
    public init(id: Target.ID?) {
        self.id = id
    }

    /// A reference to `value`, holding the record itself.
    public init(_ value: Target?) {
        self.id = value?.id
        self.box = value.map(Box.init)
    }

    /// The loaded target, or `nil` when the reference is empty or its target isn't loaded.
    public internal(set) var value: Target? {
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
    public mutating func load(_ ids: [UUID], from graph: RecordGraph, depth: Int) throws {
        id = ids.first.map { Target.ID(rawValue: $0) }
        guard depth > 0, let id else { box = nil; return }
        box = try graph.record(Target.self, id: id.rawValue, depth: depth - 1).map(Box.init)
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
/// It keeps the target IDs and, for `@Reference var tags: [Tag]`, the loaded records. The targets
/// are sorted by ID, which is the order they were made, and each appears once. Two values are
/// equal when they point at the same targets.
public struct ToMany<Target: Record> {
    private var storedIDs: [Target.ID] = []
    /// The loaded targets by ID. A class, so a record can refer to its own type.
    private var box: Box?

    /// A reference to `ids` that holds only the IDs.
    public init(ids: [Target.ID]) {
        self.ids = ids
    }

    /// A reference to `values`, holding the records themselves.
    public init(_ values: [Target]) {
        self.values = values
    }

    /// The loaded targets as `values` holds them. Empty where loading stopped.
    public var loadedRecords: [any Record] { values }

    /// The targets the reference points at now, sorted by ID.
    public internal(set) var ids: [Target.ID] {
        get { storedIDs }
        set { storedIDs = Set(newValue).sorted() }
    }

    /// The loaded targets, sorted by ID. A target that isn't loaded is left out.
    ///
    /// Setting it keeps any target that wasn't loaded, because code that never saw a target
    /// cannot have meant to remove it. To remove one, set `ids`.
    public internal(set) var values: [Target] {
        get { storedIDs.compactMap { box?.values[$0] } }
        set {
            ids = storedIDs.filter { box?.values[$0] == nil } + newValue.map(\.id)
            box = Box(Dictionary(newValue.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
        }
    }

    /// Sets the reference to the targets `ids` as read from storage. When `depth` is at least 1,
    /// reads each target `graph` holds with `depth - 1`, so its own references hold records
    /// `depth - 1` levels further.
    public mutating func load(_ ids: [UUID], from graph: RecordGraph, depth: Int) throws {
        self.ids = ids.map { Target.ID(rawValue: $0) }

        var values: [Target.ID: Target] = [:]
        if depth > 0 {
            for id in storedIDs {
                values[id] = try graph.record(Target.self, id: id.rawValue, depth: depth - 1)
            }
        }
        box = values.isEmpty ? nil : Box(values)
    }

    private final class Box {
        let values: [Target.ID: Target]
        init(_ values: [Target.ID: Target]) { self.values = values }
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

// MARK: - Handles

/// A to-many `@Reference` as its target IDs, which `$tracks` gives for
/// `@Reference var tracks: [Track]`.
///
/// It lists every target, sorted by ID, whether or not its record is loaded, so `count` is always
/// the true count. `album.tracks` holds the loaded records and can't be changed. Change the targets
/// here, through a context:
///
/// ```swift
/// album.$tracks.insert(track, in: context)
/// album.$tracks.remove(track.id, in: context)
/// .onDelete { album.$tracks.remove(atOffsets: $0, in: context) }
/// ```
///
/// Each change updates `album` at once and waits in the context, as one link, until it saves.
/// The album's own record is never written, so the change can't conflict with edits to its fields.
public struct ReferenceIDs<Target: Record>: RandomAccessCollection, Equatable {
    /// The record type that holds the reference.
    public let ownerType: any Record.Type
    /// The ID of the record that holds the reference.
    public let ownerID: UUID
    /// The reference's property, such as `tracks`.
    public let property: String
    /// The reference's storage. Used by the code `@Reference` generates.
    public internal(set) var storage: ToMany<Target>

    /// Used by the code `@Reference` generates.
    public init<Owner: Record>(owner: Owner.Type, id: Owner.ID, property: String, storage: ToMany<Target>) {
        ownerType = owner
        ownerID = id.rawValue
        self.property = property
        self.storage = storage
    }

    /// Every target's ID, sorted, loaded or not.
    public var ids: [Target.ID] { storage.ids }

    public var startIndex: Int { 0 }
    public var endIndex: Int { storage.ids.count }
    public subscript(position: Int) -> Target.ID { storage.ids[position] }

    /// Adds `record`. A target already held stays once.
    @MainActor
    public mutating func insert(_ record: Target, in context: RecordContext) {
        insert([record], in: context)
    }

    /// Adds `records`. Targets already held stay once.
    @MainActor
    public mutating func insert(_ records: [Target], in context: RecordContext) {
        context.insert(records, into: property, of: ownerType, id: ownerID)
        storage.values += records
    }

    /// Takes the target with `id` out, whether or not its record is loaded. The target itself is
    /// kept.
    @MainActor
    public mutating func remove(_ id: Target.ID, in context: RecordContext) {
        remove([id], in: context)
    }

    /// Takes the targets with `ids` out. See `remove(_:in:)`.
    @MainActor
    public mutating func remove(_ ids: [Target.ID], in context: RecordContext) {
        context.remove(ids.map(\.rawValue), from: property, of: ownerType, id: ownerID)
        storage.ids.removeAll { ids.contains($0) }
    }

    /// Takes the targets at `offsets` out, as SwiftUI's `onDelete` gives them.
    @MainActor
    public mutating func remove(atOffsets offsets: IndexSet, in context: RecordContext) {
        remove(offsets.map { storage.ids[$0] }, in: context)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.ownerID == rhs.ownerID && lhs.property == rhs.property && lhs.storage == rhs.storage
    }
}

/// A to-one `@Reference` as its target ID, which `$artist` gives for
/// `@Reference var artist: Artist?`.
///
/// `id` is the target's ID, whether or not its record is loaded. `album.artist` holds the loaded
/// record and can't be changed. Change the target here, through a context:
///
/// ```swift
/// album.$artist.set(nova, in: context)
/// album.$artist.clear(in: context)
/// ```
///
/// Each change updates `album` at once and waits in the context, as one link, until it saves.
public struct ReferenceID<Target: Record>: Equatable {
    /// The record type that holds the reference.
    public let ownerType: any Record.Type
    /// The ID of the record that holds the reference.
    public let ownerID: UUID
    /// The reference's property, such as `artist`.
    public let property: String
    /// The reference's storage. Used by the code `@Reference` generates.
    public internal(set) var storage: ToOne<Target>

    /// Used by the code `@Reference` generates.
    public init<Owner: Record>(owner: Owner.Type, id: Owner.ID, property: String, storage: ToOne<Target>) {
        ownerType = owner
        ownerID = id.rawValue
        self.property = property
        self.storage = storage
    }

    /// The target's ID, loaded or not, or `nil` when there is none.
    public var id: Target.ID? { storage.id }

    /// Points the reference at `record`, replacing any target it had.
    @MainActor
    public mutating func set(_ record: Target, in context: RecordContext) {
        context.insert([record], into: property, of: ownerType, id: ownerID)
        storage.value = record
    }

    /// Clears the reference. The target itself is kept.
    @MainActor
    public mutating func clear(in context: RecordContext) {
        guard let id = storage.id else { return }
        context.remove([id.rawValue], from: property, of: ownerType, id: ownerID)
        storage.value = nil
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.ownerID == rhs.ownerID && lhs.property == rhs.property && lhs.storage == rhs.storage
    }
}

// MARK: - Loaded targets

extension Record {
    /// The target records loaded into the references that write links. `@Reference(from:)`
    /// sides are left out, since this record doesn't own those links.
    var loadedTargets: [any Record] {
        referenceStates.flatMap(\.records)
    }
}
