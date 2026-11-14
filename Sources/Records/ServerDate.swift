import Foundation
import Synchronization

/// The storage behind a `@Timestamped` property: a date the server keeps for every record.
///
/// `@Timestamped` stores it in a `let` with a default value, which keeps it out of the memberwise
/// initializer. Decoding a record fills it once, and copies of a record share it.
@_documentation(visibility: internal)
public final class ServerDate: Hashable, Sendable {
    private let storage = Mutex<Date?>(nil)

    public init() {}

    /// The server's date, or `nil` until the record is first saved.
    public var date: Date? { storage.withLock { $0 } }

    /// Fills the date from a decoded record. Only generated code calls this, while it decodes.
    public func load(_ date: Date?) {
        storage.withLock { $0 = date }
    }

    public static func == (lhs: ServerDate, rhs: ServerDate) -> Bool {
        lhs.date == rhs.date
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(date)
    }
}
