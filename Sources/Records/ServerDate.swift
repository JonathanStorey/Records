import Foundation

/// The storage behind a `@Timestamped` property: a date the server keeps for every record.
///
/// `@Timestamped` stores it in a `let` with a default value, which keeps it out of the memberwise
/// initializer. Decoding a record fills it once, and nothing changes it afterward, so copies of a
/// record can share it safely.
public final class ServerDate: Hashable, @unchecked Sendable {
    /// The server's date, or `nil` until the record is first saved.
    public private(set) var date: Date?

    public init() {}

    /// Fills the date from a decoded record. Only generated code calls this, while it decodes.
    public func load(_ date: Date?) {
        self.date = date
    }

    public static func == (lhs: ServerDate, rhs: ServerDate) -> Bool {
        lhs.date == rhs.date
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(date)
    }
}
