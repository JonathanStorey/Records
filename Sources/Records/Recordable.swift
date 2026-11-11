import SwiftUI

// MARK: - Environment

private struct RecordContextKey: EnvironmentKey {
    static var defaultValue: RecordContext? { nil }
}

extension EnvironmentValues {
    /// The context that `@Recordable` properties edit records in.
    public var recordContext: RecordContext? {
        get { self[RecordContextKey.self] }
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
@MainActor
@propertyWrapper
public struct Recordable<R: Record> {
    @Environment(\.recordContext) private var environmentContext
    @State private var storage: RecordableStorage<R>

    /// A property that edits `record`.
    public init(_ record: R) {
        _storage = State(initialValue: RecordableStorage(record))
    }

    /// A property that edits `wrappedValue`.
    public init(wrappedValue: R) {
        self.init(wrappedValue)
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

    init(_ record: R) {
        self.record = record
    }

    /// Uses `context`'s difference for the record, or none without a context.
    func connect(to context: RecordContext?) {
        guard context !== self.context || difference == nil else { return }
        self.context = context
        difference = context?.difference(for: record)
    }

    /// The record as edited. Setting it stages the edit in the context, or only keeps it here
    /// when there is no context.
    var value: R {
        get { (difference?.value as? R) ?? record }
        set {
            record = newValue
            if let context, let difference {
                context.edit(difference, to: newValue)
            }
        }
    }
}
