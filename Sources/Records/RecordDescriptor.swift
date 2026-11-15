import Foundation

/// What `RecordContext.fetch(_:)` returns: the records of one type that match `predicate`, in
/// the order of `sortBy`, from `fetchOffset` for up to `fetchLimit` records. Their references
/// hold records, whose own references hold IDs.
///
/// ```swift
/// let albums = try context.fetch(RecordDescriptor<Album>(
///     predicate: #Predicate { $0.year > 1970 },
///     sortBy: [SortDescriptor(\.title)],
///     fetchLimit: 50
/// ))
/// ```
public struct RecordDescriptor<R: Record> {
    /// The records to include, or `nil` for every record.
    public var predicate: Predicate<R>?
    /// The order to return them in. Records that compare equal keep no particular order.
    public var sortBy: [SortDescriptor<R>]
    /// The most records to return, or `nil` for no limit.
    public var fetchLimit: Int?
    /// How many matching records to skip before the first one returned.
    public var fetchOffset: Int?
    public init(
        predicate: Predicate<R>? = nil,
        sortBy: [SortDescriptor<R>] = [],
        fetchLimit: Int? = nil,
        fetchOffset: Int? = nil
    ) {
        self.predicate = predicate
        self.sortBy = sortBy
        self.fetchLimit = fetchLimit
        self.fetchOffset = fetchOffset
    }

    /// The part of `records` from `fetchOffset` for up to `fetchLimit`.
    func page<T>(of records: [T]) -> ArraySlice<T> {
        let start = min(max(fetchOffset ?? 0, 0), records.count)
        let end = fetchLimit.map { min(start + max($0, 0), records.count) } ?? records.count
        return records[start..<end]
    }
}
