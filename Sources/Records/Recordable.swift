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
public struct Recordable<R: Record> {
    @Environment(\.recordContext) private var environmentContext
    @State private var storage: RecordableStorage<R>

    /// A property that edits `record` in `zone`, or in the container's `defaultZone` without one,
    /// with the references `expand` names loaded.
    public init(_ record: R, zone: Zone? = nil, expand: AnyKeyPath...) {
        _storage = State(initialValue: RecordableStorage(record, zone: zone, expand: expand))
    }

    /// A property that edits `wrappedValue` in `zone`, as `@Recordable(.records) var album = album`,
    /// with the references `expand` names loaded.
    public init(wrappedValue: R, _ zone: Zone? = nil, expand: AnyKeyPath...) {
        _storage = State(initialValue: RecordableStorage(wrappedValue, zone: zone, expand: expand))
    }

    /// The record as edited.
    public var wrappedValue: R {
        get { storage.value }
        nonmutating set { storage.value = newValue }
    }

    /// A binding to the record, so `$album.title` binds to one field.
    public var projectedValue: Binding<R> {
        Bindable(storage).value
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
final class RecordableStorage<R: Record> {
    @ObservationIgnored private var record: R
    @ObservationIgnored private weak var context: RecordContext?
    @ObservationIgnored private(set) var difference: RecordDifference?
    /// The zone the record is edited in, or `nil` for the container's `defaultZone`.
    @ObservationIgnored let zone: Zone?
    /// The references to load each time the record is read.
    @ObservationIgnored let expand: [AnyKeyPath]

    init(_ record: R, zone: Zone? = nil, expand: [AnyKeyPath] = []) {
        self.record = record
        self.zone = zone
        self.expand = expand
    }

    /// Uses `context`'s difference for the record, in the wrapper's zone or the container's
    /// `defaultZone`. The context's current `zone` never matters.
    func connect(to context: RecordContext) {
        guard context !== self.context || difference == nil else { return }
        self.context = context
        difference = context.difference(for: record, in: zone ?? context.defaultZone)
    }

    /// The record as edited, with the references `expand` names loaded. Setting it stages the
    /// edit in the context.
    ///
    /// A record that isn't saved and has no change reads as the record the wrapper was given, so
    /// rolling back an edit to a new record shows it as it started.
    var value: R {
        get {
            guard let difference, difference.change != nil || difference.original != nil,
                  let value = difference.value as? R
            else { return record }
            guard !expand.isEmpty, let context else { return value }
            // Read each time, so the targets show the context's latest changes to them.
            return context.expanded(value, expand, in: difference.zone)
        }
        set {
            guard let context, let difference else {
                record = newValue
                return
            }
            difference.draft = newValue
            context.didEdit(difference)
        }
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
