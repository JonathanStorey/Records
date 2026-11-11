import SwiftUI

// MARK: - Environment

private struct RecordContextKey: EnvironmentKey {
    static var defaultValue: RecordContext? { nil }
}

extension EnvironmentValues {
    /// The context that `@Recordable` properties edit records in, set with `.recordContext(_:)`.
    /// Reading it where none is set stops with a message, since that is a programmer error.
    public var recordContext: RecordContext {
        get {
            guard let context = self[RecordContextKey.self] else {
                preconditionFailure("No RecordContext in the environment. Set one with .recordContext(_:).")
            }
            return context
        }
        set { self[RecordContextKey.self] = newValue }
    }
}

extension View {
    /// Sets the context that `@Recordable` properties in this view and its children edit records in.
    public func recordContext(_ context: RecordContext) -> some View {
        environment(\.recordContext, context)
    }
}

// MARK: - @Recordable

/// A record a view edits. Reading it shows the record as edited, and each change stages it in
/// the environment's `recordContext`. Nothing is written until the context saves.
///
/// ```swift
/// struct AlbumEditor: View {
///     @Recordable var album: Album
///
///     init(album: Album) {
///         _album = Recordable(album)
///     }
///
///     var body: some View {
///         TextField("Title", text: $album.title)
///     }
/// }
/// ```
///
/// Every `@Recordable` showing the same record shares its edits, so two views stay in step as
/// you type. Set the context once with `.recordContext(_:)`, and save with `context.save()`.
///
/// Declare it optional, as `@Recordable var album: Album?`, to see deletes: it reads `nil` once
/// the record is deleted, and setting it to `nil` deletes the record.
///
/// References hold IDs. Name the ones to load with `expand:`, as with
/// `relationshipKeyPathsForPrefetching`:
///
/// ```swift
/// @Recordable(expand: \Album.artist, \Album.tracks) var album = album
/// ```
///
/// Expanded targets are for showing. Editing one through the wrapper doesn't save it, so edit
/// it with its own `@Recordable`.
@MainActor
@propertyWrapper
public struct Recordable<Value> {
    @Environment(\.recordContext) private var environmentContext
    @State private var storage: RecordableStorage<Value>

    /// The record as edited.
    public var wrappedValue: Value {
        get { storage.value }
        nonmutating set { storage.value = newValue }
    }

    /// A binding to the record, so `$album.title` binds to one field.
    public var projectedValue: Binding<Value> {
        Bindable(storage).value
    }
}

extension Recordable where Value: Record {
    /// A property that edits `record` in `zone`, or in the container's `defaultZone` without one,
    /// with the references `expand` names loaded.
    public init(_ record: Value, zone: Zone? = nil, expand: AnyKeyPath...) {
        _storage = State(initialValue: RecordableStorage(record, zone: zone, expand: expand))
    }

    /// A property that edits `wrappedValue` in `zone`, as `@Recordable(.records) var album = album`,
    /// with the references `expand` names loaded.
    public init(wrappedValue: Value, _ zone: Zone? = nil, expand: AnyKeyPath...) {
        _storage = State(initialValue: RecordableStorage(wrappedValue, zone: zone, expand: expand))
    }
}

extension Recordable {
    /// An optional property that edits `record` in `zone`, or in the container's `defaultZone`
    /// without one, with the references `expand` names loaded. It reads `nil` once the record
    /// is deleted.
    public init<R: Record>(_ record: R, zone: Zone? = nil, expand: AnyKeyPath...) where Value == R? {
        _storage = State(initialValue: RecordableStorage(optional: record, zone: zone, expand: expand))
    }

    /// An optional property that edits `wrappedValue`, as `@Recordable var album: Album? = album`.
    /// `wrappedValue` must hold a record.
    public init<R: Record>(wrappedValue: R?, _ zone: Zone? = nil, expand: AnyKeyPath...) where Value == R? {
        guard let record = wrappedValue else {
            preconditionFailure("An optional @Recordable starts from a record, not nil.")
        }
        _storage = State(initialValue: RecordableStorage(optional: record, zone: zone, expand: expand))
    }
}

extension Recordable: @preconcurrency DynamicProperty {
    public mutating func update() {
        storage.connect(to: environmentContext)
    }
}

/// What a `@Recordable` holds: the record's difference in its context, which it reads and edits.
@MainActor
@Observable
final class RecordableStorage<Value> {
    @ObservationIgnored private var record: any Record
    @ObservationIgnored private weak var context: RecordContext?
    @ObservationIgnored private(set) var difference: RecordDifference?
    /// The zone the record is edited in, or `nil` for the container's `defaultZone`.
    @ObservationIgnored let zone: Zone?
    /// The references to load each time the record is read.
    @ObservationIgnored let expand: [AnyKeyPath]
    /// What an optional wrapper reads once its record is deleted. `nil` for one that isn't optional.
    @ObservationIgnored private let deleted: Value?

    private init(record: any Record, zone: Zone?, expand: [AnyKeyPath], deleted: Value?) {
        self.record = record
        self.zone = zone
        self.expand = expand
        self.deleted = deleted
    }

    /// Uses `context`'s difference for the record, in the wrapper's zone or the container's
    /// `defaultZone`. The context's current `zone` never matters.
    func connect(to context: RecordContext) {
        guard context !== self.context || difference == nil else { return }
        self.context = context
        difference = context.difference(for: record, in: zone ?? context.defaultZone)
    }

    /// The record as edited, with the references `expand` names loaded. Setting it stages the
    /// edit in the context, and setting `nil` stages deleting the record.
    ///
    /// A record that isn't saved and has no change reads as the record the wrapper was given, so
    /// rolling back an edit to a new record shows it as it started. An optional wrapper reads
    /// `nil` once the record is deleted, whether or not the delete is saved yet.
    var value: Value {
        get {
            guard let difference else { return record as! Value }
            if let deleted, difference.isDelete || difference.draft == nil { return deleted }
            guard difference.change != nil || difference.original != nil, let value = difference.value
            else { return record as! Value }
            guard !expand.isEmpty, let context else { return value as! Value }
            // Read each time, so the targets show the context's latest changes to them.
            return context.expanded(value, expand, in: difference.zone) as! Value
        }
        set {
            let newRecord = newValue as? any Record
            guard context != nil, let difference else {
                if let newRecord { record = newRecord }
                return
            }
            // The difference is the context's own while this holds it, so setting its change
            // is all it takes to stage it.
            guard let newRecord else {
                if difference.original == nil {
                    // Never saved, so there is nothing to delete: drop the record and any insert.
                    difference.draft = nil
                    difference.change = nil
                } else if difference.draft != nil {
                    difference.change = .delete(difference.id)
                }
                return
            }
            difference.draft = newRecord
            difference.change = .insert(difference.id)
        }
    }
}

extension RecordableStorage where Value: Record {
    /// Storage for a wrapper that isn't optional.
    convenience init(_ record: Value, zone: Zone? = nil, expand: [AnyKeyPath] = []) {
        self.init(record: record, zone: zone, expand: expand, deleted: nil)
    }
}

extension RecordableStorage {
    /// Storage for an optional wrapper, which reads `nil` once its record is deleted.
    convenience init<R: Record>(optional record: R, zone: Zone? = nil, expand: [AnyKeyPath] = []) where Value == R? {
        self.init(record: record, zone: zone, expand: expand, deleted: .some(nil))
    }
}

extension RecordContext {
    /// `record` with the references `keyPaths` name holding their records, read in `zone`
    /// whatever the current `zone`. A record that can't be read stays as it is.
    func expanded<R: Record>(_ record: R, _ keyPaths: [AnyKeyPath], in zone: Zone) -> R {
        let current = self.zone
        self.zone = zone
        defer { self.zone = current }
        return (try? prefetch(keyPaths, into: [record]).first) ?? record
    }
}
