import SwiftUI

// MARK: - Environment

extension EnvironmentValues {
    /// The context, or `nil` where none is set. SwiftUI reads environment values when it
    /// pleases, so `@Recordable` reads this one and stops only when it uses a missing context.
    @Entry var recordContextIfSet: RecordContext? = nil

    /// The context that `@Recordable` properties edit records in, set with `.recordContext(_:)`.
    /// Reading it where none is set stops with a message, since that is a programmer error.
    public var recordContext: RecordContext {
        get {
            guard let context = recordContextIfSet else {
                preconditionFailure("No RecordContext in the environment. Set one with .recordContext(_:).")
            }
            return context
        }
        set { recordContextIfSet = newValue }
    }
}

extension View {
    /// Sets the context that `@Recordable` properties in this view and its children edit records in.
    public func recordContext(_ context: RecordContext) -> some View {
        environment(\.recordContextIfSet, context)
    }
}

// MARK: - @Recordable

/// A record a view edits. Reading it shows the record with its pending edits, and each change
/// is recorded in the environment's `recordContext`. Nothing is written until the context saves.
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
/// Each `@Recordable` is one edit, named by its `id`, so `_album.id` names the edit and
/// `album.id` the record. Two editors of one record each save only the fields they changed.
/// Set the context once with `.recordContext(_:)`, and save with `context.save()`.
///
/// Declare it optional, as `@Recordable var album: Album?`, to see deletes: it reads `nil` once
/// the record is deleted, and setting it to `nil` deletes the record.
///
/// Its references hold their records, as saved, and those records' references hold IDs. The
/// targets are for showing. Editing one through the wrapper doesn't save it, so edit it with its
/// own `@Recordable`.
@MainActor
@propertyWrapper
public struct Recordable<Value> {
    @Environment(\.recordContextIfSet) private var contextIfSet
    /// The ID of this wrapper's edit, which names its pending change in the context.
    @State public private(set) var id = UUID()
    /// When this wrapper last edited its record. Setting it redraws the view.
    @State private var modified = Date()

    /// The record the wrapper was given, which names the record it edits.
    private let record: any Record
    /// The zone the record is edited in, or `nil` for the container's `defaultZone`.
    private let zone: Zone?
    /// What reads when the record is missing or deleted: `nil` for an optional wrapper, and
    /// the record as given for one that isn't.
    private let missing: Value

    private init(record: any Record, zone: Zone?, missing: Value) {
        self.record = record
        self.zone = zone
        self.missing = missing
    }

    /// The record with its pending edits, and with its references holding records.
    /// Setting it records the edit in the context, and setting `nil` deletes the record.
    public var wrappedValue: Value {
        get {
            _ = modified
            let zone = self.zone ?? context.defaultZone
            guard let draft = context.draft(of: record, in: zone) else { return missing }
            // A record whose targets can't be read shows as it is.
            return ((try? context.loadingChildren(of: draft, in: zone)) ?? draft) as! Value
        }
        nonmutating set {
            let now = Date()
            modified = now
            context.edit(id: id, of: record, in: zone ?? context.defaultZone, with: newValue as? any Record, on: now)
        }
    }

    /// The environment's context. A missing one is a programmer error.
    private var context: RecordContext {
        guard let contextIfSet else {
            preconditionFailure("No RecordContext in the environment. Set one with .recordContext(_:).")
        }
        return contextIfSet
    }

    /// A binding to the record, so `$album.title` binds to one field.
    public var projectedValue: Binding<Value> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}

extension Recordable where Value: Record {
    /// A property that edits `record` in `zone`, or in the container's `defaultZone` without one.
    public init(_ record: Value, zone: Zone? = nil) {
        self.init(record: record, zone: zone, missing: record)
    }

    /// A property that edits `wrappedValue` in `zone`, as `@Recordable(.records) var album = album`.
    public init(wrappedValue: Value, _ zone: Zone? = nil) {
        self.init(record: wrappedValue, zone: zone, missing: wrappedValue)
    }
}

extension Recordable {
    /// An optional property that edits `record` in `zone`, or in the container's `defaultZone`
    /// without one. It reads `nil` once the record is deleted.
    public init<R: Record>(_ record: R, zone: Zone? = nil) where Value == R? {
        self.init(record: record, zone: zone, missing: nil)
    }

    /// An optional property that edits `wrappedValue`, as `@Recordable var album: Album? = album`.
    /// `wrappedValue` must hold a record.
    public init<R: Record>(wrappedValue: R?, _ zone: Zone? = nil) where Value == R? {
        guard let record = wrappedValue else {
            preconditionFailure("An optional @Recordable starts from a record, not nil.")
        }
        self.init(record: record, zone: zone, missing: nil)
    }
}

extension Recordable: DynamicProperty {}

extension Recordable: @preconcurrency Identifiable {}

extension RecordContext {
    /// The record `record` names, as `draft(id:for:in:)` reads it.
    func draft<R: Record>(of record: R, in zone: Zone) -> R? {
        draft(id: record.id, for: R.self, in: zone)
    }
}
