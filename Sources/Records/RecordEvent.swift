import CloudKit

/// Something that happened to a context's saved records or to sync, kept in
/// `RecordContext.events`.
public enum RecordEvent: Sendable, Equatable {
    /// A save wrote records, in this context or another context of the same container.
    case saved(Date)
    /// Sync wrote the server's changes into the records.
    case synced(Date)
    /// The iCloud account's status, read at launch and after each account change.
    case account(Date, CKAccountStatus)
    /// Whether iCloud storage is full: `true` when an upload fails for lack of space, and `false`
    /// when the next upload succeeds.
    case storage(Date, isFull: Bool)

    /// Whether `event` is the same kind as this one, with the same status or flag, so it replaces
    /// this one in the log and adds no entry.
    func isRepeated(by event: RecordEvent) -> Bool {
        switch (self, event) {
        case (.saved, .saved), (.synced, .synced): true
        case (.account(_, let old), .account(_, let new)): old == new
        case (.storage(_, let old), .storage(_, let new)): old == new
        default: false
        }
    }
}

extension [RecordEvent] {
    /// When a save last wrote records, or `nil` before the first save since launch.
    public var lastSaved: Date? {
        for case .saved(let date) in reversed() { return date }
        return nil
    }

    /// When sync last wrote the server's changes, or `nil` before the first since launch.
    public var lastSynced: Date? {
        for case .synced(let date) in reversed() { return date }
        return nil
    }
}
