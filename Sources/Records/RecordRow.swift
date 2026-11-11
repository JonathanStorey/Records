import Foundation

/// A record as its database row holds it: each field's column value by field key, with the
/// record's name and dates.
///
/// `@Record` reads one in `init(from:)` and writes one in `encodeFields(into:)`, so the database
/// builds records without going through a `CKRecord`. Only Records makes rows.
public struct RecordRow: Equatable {
    /// Every column's value, by column name.
    var values: [String: SQLValue]

    init(_ values: [String: SQLValue] = [:]) {
        self.values = values
    }

    /// The record's `id`, from its name. Used by the code `@Record` generates.
    public var id: UUID {
        get throws {
            guard case .text(let name) = values["_name"], let id = UUID(uuidString: name) else {
                throw CKRecordDecodingError.invalidRecordName(values["_name"].map { "\($0)" } ?? "")
            }
            return id
        }
    }

    /// When the record was first saved, for `@Timestamped(.created)`.
    public var createdAt: Date? { date("_createdAt") }

    /// When the record was last saved, for `@Timestamped(.modified)`.
    public var modifiedAt: Date? { date("_modifiedAt") }

    private func date(_ column: String) -> Date? {
        guard case .real(let seconds) = values[column] else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
