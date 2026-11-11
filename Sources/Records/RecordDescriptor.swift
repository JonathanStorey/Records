import Foundation

/// What `RecordContext.fetch(_:)` returns: the records of one type that match `predicate`, in
/// the order of `sortBy`, from `fetchOffset` for up to `fetchLimit` records.
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
    /// References to load with the results, such as `\.artist` or `\.tracks`. Each comes back
    /// holding its records instead of only their IDs, loaded for every result at once. The
    /// loaded records' own references hold IDs. A reference that holds IDs is left as it is.
    public var relationshipKeyPathsForPrefetching: [PartialKeyPath<R>] = []

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
}
