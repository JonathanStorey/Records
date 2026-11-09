import CloudKit

/// The state of one to-one `@Reference`, as the encoder needs it to write links.
public struct ReferenceState: Equatable, Sendable {
    /// The property name, such as `author`.
    public let property: String
    /// The target's record type, such as `Person`.
    public let targetType: CKRecord.RecordType
    /// The target the property points at now.
    public let id: UUID?
    /// The target when the record was last loaded or saved. `nil` for a record never saved.
    public let loadedID: UUID?

    /// Whether the reference changed since it was loaded or saved.
    public var hasChanges: Bool { id != loadedID }
}

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

    /// Sets the reference as read from storage, so it starts out unchanged. Decodes `target`
    /// when it is given and is the record `id` names.
    public mutating func load(id: UUID?, from target: CKRecord?) throws {
        self.id = id
        self.loadedID = id
        if let target, target.recordID.recordName == id?.uuidString {
            box = Box(try CKRecordDecoder().decode(Target.self, from: target))
        } else {
            box = nil
        }
    }

    /// Records that the current target was saved.
    public mutating func markSaved() {
        loadedID = id
    }

    /// The reference's state for the encoder.
    public func state(property: String) -> ReferenceState {
        ReferenceState(property: property, targetType: Target.recordType, id: id, loadedID: loadedID)
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
