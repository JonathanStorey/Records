import CloudKit
import Foundation
import Observation

/// Why a `RecordContext` couldn't read or write a record.
public enum RecordContextError: Error, Equatable, CustomStringConvertible {
    /// The record's type isn't registered with the container.
    case unregisteredType(String)

    public var description: String {
        switch self {
        case .unregisteredType(let type):
            "'\(type)' isn't registered with this container. Pass it, or a type that refers to it, to RecordContainer(for:)."
        }
    }
}

/// Reads and writes records in a container's database.
///
/// The app's main actor uses `container.mainContext`. Changes wait in the context and reach
/// the database together when `save()` runs, in one transaction:
///
/// ```swift
/// context.insert(album)
/// context.delete(oldAlbum)
/// try context.save()
/// ```
///
/// Saving writes only the fields and links that differ from the saved copy, so a record saved
/// again unchanged writes nothing and stays in sync.
///
/// Views observe two properties: `version`, which goes up when saved records change, and
/// `changes`. Nothing else in the context redraws a view.
@MainActor
@Observable
public final class RecordContext {
    /// Every registered type by record type, shared with the container.
    @ObservationIgnored let types: [CKRecord.RecordType: any Record.Type]
    /// The container's database. The context holds it, not the container, so the container can
    /// keep its main context without the two keeping each other alive.
    @ObservationIgnored let database: Database

    /// The zone records are inserted into and deleted from. It starts as the container's
    /// `defaultZone`. Set it to switch zones at any time. Pending changes keep the zone they
    /// were made in.
    @ObservationIgnored public var zone: Zone {
        didSet { if zone != oldValue { updateChanges() } }
    }
    /// The container's `defaultZone`, which `@Recordable` edits in when it isn't given a zone.
    @ObservationIgnored let defaultZone: Zone

    /// The pending edits, by each edit's `id`. A record can have several: one per `@Recordable`
    /// that edited it, and one per direct `insert` or `delete`.
    @ObservationIgnored var differences: [UUID: RecordDifference] = [:]
    /// The `id` of each pending edit, in the order the edits began.
    @ObservationIgnored private var editOrder: [UUID] = []
    /// The edit `insert` and `delete` share for each record, so calling them again replaces
    /// that edit and keeps its base.
    @ObservationIgnored private var directEdits: [RecordKey: UUID] = [:]

    /// Goes up each time the saved records may have changed: on `save()`, `rollback()` and
    /// `rollback(id:)`. Reading a record in a view's body reads it too, so the view redraws then.
    public private(set) var version = 0

    /// The current `zone`'s pending changes, one per edit, in the order the edits began, such
    /// as `[.update(album.id), .delete(oldAlbum.id)]`. A record edited by two views appears
    /// twice, so use `Set(changes.map(\.id))` for the records changed. It changes only when an
    /// edit begins, turns into another kind of change, or ends, so typing doesn't redraw a view
    /// that reads it. `save()` writes the changes of every zone, not only these.
    public private(set) var changes: [RecordDifference.Change] = []

    init(container: RecordContainer) {
        types = container.types
        database = container.database
        defaultZone = container.defaultZone
        zone = container.defaultZone
    }

    /// Whether any change is waiting for `save()`, in any zone.
    public var hasChanges: Bool { !differences.isEmpty }

    /// Sets `changes` from the pending edits, only when they differ, so a view reading it
    /// redraws only when it changes.
    private func updateChanges() {
        editOrder.removeAll { differences[$0] == nil }
        let current = editOrder.compactMap { differences[$0] }.filter { $0.zone == zone }.map(\.change)
        if current != changes { changes = current }
    }

    /// Marks the saved records as changed, so every view that read one redraws.
    private func bump() {
        version += 1
    }

    // MARK: - Editing

    /// Adds `record` to the current `zone`, or updates it there. Nothing is written until
    /// `save()`.
    ///
    /// `save()` adds the record if it is new, and otherwise writes the fields and links that
    /// differ from the saved copy. Only `record` itself is changed. Records its references point
    /// at are changed by inserting them too.
    public func insert(_ record: some Record) {
        edit(id: directEdit(of: record), of: record, in: zone, with: record)
    }

    /// Deletes `record` from the current `zone` when the context saves, with the links it owns.
    /// When saved, a record that never synced is removed outright, and a synced one is kept as a
    /// deletion until the server confirms it.
    ///
    /// Saving also removes the links other records hold to it, so their references drop it, and
    /// deletes the records it owns through a reference whose `from:` side says `deleteSelf: true`,
    /// unless another record has taken them over in the same save.
    public func delete(_ record: some Record) {
        edit(id: directEdit(of: record), of: record, in: zone, with: nil)
    }

    /// The ID of the edit `insert` and `delete` make to `record` in the current `zone`.
    private func directEdit<R: Record>(of record: R) -> UUID {
        let key = RecordKey(recordType: R.recordType, name: record.id.uuidString, zone: zone)
        if let id = directEdits[key], differences[id] != nil { return id }
        let id = UUID()
        directEdits[key] = id
        return id
    }

    /// Records one edit to `record` in `zone` under the edit's `id`. This is the only way an
    /// edit enters the context. `newValue` is the record as edited, or `nil` to delete it.
    ///
    /// The first call for an `id` sets its base: the saved record, or for a record not yet
    /// saved, the record as the context's pending edits make it. Later calls replace the edit
    /// and keep that base. `date` orders the edits when they are saved.
    func edit(id: UUID, of record: any Record, in zone: Zone, with newValue: (any Record)?, on date: Date = Date()) {
        var difference = differences[id] ?? RecordDifference(
            id: id, zone: zone, base: base(for: record, in: zone), edit: newValue, modified: date
        )
        if differences[id] == nil { editOrder.append(id) }
        difference.edit = newValue
        difference.modified = date
        // A record never saved and then deleted leaves nothing to write.
        differences[id] = difference.base == nil && newValue == nil ? nil : difference
        updateChanges()
    }

    /// The base of a first edit to `record` in `zone`: the saved record, or for a record not
    /// yet saved, the record as the pending edits make it.
    private func base<R: Record>(for record: R, in zone: Zone) -> R? {
        checkRegistered(R.self)
        return draft(id: record.id, for: R.self, in: zone, savedFirst: true)
    }

    /// The record with `id` in `zone` as `save()` would write it: the saved record with every
    /// pending edit to it laid over, oldest first, or `nil` when it is missing or deleted.
    func draft<R: Record>(id: UUID, for type: R.Type, in zone: Zone) -> R? {
        _ = version
        return draft(id: id, for: type, in: zone, savedFirst: false)
    }

    /// `draft(id:for:in:)`, or with `savedFirst`, the saved record when there is one.
    private func draft<R: Record>(id: UUID, for type: R.Type, in zone: Zone, savedFirst: Bool) -> R? {
        let key = RecordKey(recordType: R.recordType, name: id.uuidString, zone: zone)
        let saved = (try? Self.load(R.self, key: key, in: database)) ?? nil
        if savedFirst, let saved { return saved }
        return pending(for: key).reduce(saved) { record, difference in
            difference.laid(over: record) as? R
        }
    }

    /// The pending edits to the record `key` names, oldest first.
    private func pending(for key: RecordKey) -> [RecordDifference] {
        differences.values.filter { $0.key == key }.sorted(by: RecordDifference.isOlder)
    }

    /// Writes every pending edit in one transaction, oldest first, then clears them. If any
    /// write fails, nothing is written and the edits stay pending.
    public func save() throws {
        guard hasChanges else { return }
        let changes = differences.values.sorted(by: RecordDifference.isOlder)
        let now = Date().timeIntervalSince1970
        let database = self.database
        try database.transaction {
            var deleted: [(RecordKey, [String: [String: SQLValue]])] = []
            for difference in changes {
                // The links a deleted record owns, read before saving removes them.
                if difference.isDelete {
                    deleted.append((difference.key, try Self.currentLinks(of: difference.key, in: database)))
                }
                try Self.write(difference, now: now, in: database)
            }
            try insertNewTargets(of: changes, now: now, in: database)
            try finishDeleting(deleted, now: now, in: database)
        }
        rollback()
    }

    /// Discards every pending edit, and redraws the views showing records.
    public func rollback() {
        differences = [:]
        directEdits = [:]
        updateChanges()
        bump()
    }

    /// Discards every pending edit to the record with `id` in the current `zone`, and redraws
    /// the views showing records.
    public func rollback(id: UUID) {
        differences = differences.filter { $0.value.zone != zone || $0.value.recordID != id }
        updateChanges()
        bump()
    }

    /// Removes the links that point at each deleted record, and deletes the records it owned
    /// through a reference whose `from:` side says `deleteSelf: true`, the same way in turn.
    /// `deleted` holds each record's owned links as they were before saving.
    private func finishDeleting(
        _ deleted: [(RecordKey, [String: [String: SQLValue]])], now: Double, in database: Database
    ) throws {
        var queue = deleted
        var finished: Set<RecordKey> = []
        while !queue.isEmpty {
            let (key, owned) = queue.removeFirst()
            guard finished.insert(key).inserted else { continue }
            try removeLinks(to: key, now: now, in: database)

            for row in owned.values {
                guard case .text(let source) = row["source"], case .text(let targetName) = row["targetName"],
                      let target = deletedWithOwner(source: source),
                      // Another record may have taken the target over in this save.
                      try !Self.isLinked(source: source, targetName: targetName, zone: key.zone, in: database)
                else { continue }
                let targetKey = RecordKey(recordType: target.recordType, name: targetName, zone: key.zone)
                guard let targetRow = try Self.currentRow(of: targetKey, in: database), targetRow["_deleted"] != .integer(1) else { continue }
                let targetOwned = try Self.currentLinks(of: targetKey, in: database)
                try Self.remove(targetKey, now: now, in: database)
                try Self.writeLinks([], of: targetKey, saved: targetOwned, removing: nil, now: now, in: database)
                queue.append((targetKey, targetOwned))
            }
        }
    }

    /// The type a link with `source` points at, when that type's `from:` side for it says
    /// `deleteSelf: true`.
    private func deletedWithOwner(source: String) -> (any Record.Type)? {
        guard let found = linkReference(named: source) else { return nil }
        let target = found.reference.target
        let deletesSelf = target.schema.references.contains {
            $0.inverseOf == found.reference.property && $0.target.recordType == found.owner.recordType && $0.deleteSelf
        }
        return deletesSelf ? target : nil
    }

    /// The owning type and reference a link's `source`, `Type.property`, names.
    private func linkReference(named source: String) -> (owner: any Record.Type, reference: ReferenceSchema)? {
        let parts = source.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2, let owner = types[parts[0]],
              let reference = owner.schema.references.first(where: { $0.property == parts[1] && !$0.isFrom })
        else { return nil }
        return (owner, reference)
    }

    /// Removes every current link that points at `key`'s record through a reference.
    private func removeLinks(to key: RecordKey, now: Double, in database: Database) throws {
        let rows = try database.rows(
            """
            SELECT "_name", "source" FROM \(database.quoted(RecordLink.recordType)) \
            WHERE "_zoneName" = ? AND "_zoneOwner" = ? AND "targetName" = ? AND "_isCurrent" = 1 AND "_deleted" = 0
            """,
            key.values
        )
        for row in rows {
            guard case .text(let name) = row["_name"], case .text(let source) = row["source"],
                  linkReference(named: source)?.reference.target.recordType == key.recordType
            else { continue }
            try Self.remove(RecordKey(recordType: RecordLink.recordType, name: name, zone: key.zone), now: now, in: database)
        }
    }

    /// Whether a current link from `source` points at `targetName`.
    private nonisolated static func isLinked(source: String, targetName: String, zone: Zone, in database: Database) throws -> Bool {
        try !database.rows(
            """
            SELECT 1 FROM \(database.quoted(RecordLink.recordType)) \
            WHERE "_zoneName" = ? AND "_zoneOwner" = ? AND "source" = ? AND "targetName" = ? \
            AND "_isCurrent" = 1 AND "_deleted" = 0 LIMIT 1
            """,
            [.text(zone.name), .text(zone.ownerName), .text(source), .text(targetName)]
        ).isEmpty
    }

    /// Inserts the loaded targets of the saved records that exist nowhere yet: not saved in the
    /// zone, deleted or not, and not pending. A target that exists is never written, so a stale
    /// copy can't overwrite it. New targets' own new targets are inserted too.
    private func insertNewTargets(of changes: [RecordDifference], now: Double, in database: Database) throws {
        var visited = Set(changes.map(\.key))
        var queue = changes.compactMap { change in change.edit.map { (change.zone, $0) } }
        while !queue.isEmpty {
            let (zone, record) = queue.removeFirst()
            for target in record.loadedTargets {
                let key = RecordKey(recordType: type(of: target).recordType, name: target.id.uuidString, zone: zone)
                guard visited.insert(key).inserted,
                      try Self.currentRow(of: key, in: database) == nil
                else { continue }
                try Self.write(RecordDifference(id: UUID(), zone: zone, base: nil, edit: target, modified: .now), now: now, in: database)
                queue.append((zone, target))
            }
        }
    }

    /// Writes one edit: the record's row and its links. With a base, only the fields and links
    /// the edit changed from it are written, so the saved record keeps anything changed
    /// elsewhere since that the edit didn't touch.
    private static func write(_ change: RecordDifference, now: Double, in database: Database) throws {
        let key = change.key
        let savedLinks = try currentLinks(of: key, in: database)
        guard !change.isDelete else {
            try remove(key, now: now, in: database)
            try writeLinks([], of: key, saved: savedLinks, removing: nil, now: now, in: database)
            return
        }
        // A record removed or deleted since it was edited comes back whole.
        let savedRow = try currentRow(of: key, in: database)
        let hasOriginal = savedRow != nil && savedRow?["_deleted"] != .integer(1) && change.base != nil
        let edited = hasOriginal ? change.originalValues.map { original in change.values.filter { original[$0.key] != $0.value } } : nil
        try writeRecord(change.schema, key: key, values: change.values, edited: edited, now: now, in: database)

        let orders = orders(of: savedLinks)
        let links = change.links(orders)
        guard hasOriginal, let originalLinks = change.originalLinks(orders) else {
            try writeLinks(links, of: key, saved: savedLinks, removing: nil, now: now, in: database)
            return
        }
        let original = Dictionary(originalLinks, uniquingKeysWith: { first, _ in first })
        let kept = Set(links.map(\.0))
        try writeLinks(
            links.filter { !matches(original[$0.0], $0.1) }, of: key, saved: savedLinks,
            removing: Set(original.keys.filter { !kept.contains($0) }), now: now, in: database
        )
    }

    // MARK: - Reading

    /// The saved `R` with `id` in the current `zone`, or `nil` when there is none. Changes not
    /// yet saved don't show until `save()`.
    ///
    /// References hold their targets' IDs. Load the targets themselves with `record(id:for:)`.
    public func record<R: Record>(id: UUID, for type: R.Type = R.self) throws -> R? {
        _ = version
        checkRegistered(R.self)
        let key = RecordKey(recordType: R.recordType, name: id.uuidString, zone: zone)
        return try Self.load(R.self, key: key, in: database)
    }

    /// The saved record with `id` in the current `zone`, whatever its type, or `nil` when there
    /// is none. Finding the type takes one indexed query across every table.
    public func record(id: UUID) throws -> (any Record)? {
        _ = version
        let name = id.uuidString
        let lookup = recordTypeLookup
        let values = Array(repeating: RecordKey(recordType: "", name: name, zone: zone).values, count: lookup.tables).flatMap { $0 }
        guard case .text(let recordType) = try database.rows(lookup.sql, values).first?["type"],
              let type = types[recordType]
        else { return nil }
        return try Self.load(type, key: RecordKey(recordType: recordType, name: name, zone: zone), in: database)
    }

    /// The saved records of `R` in the current `zone` that match `descriptor`, sorted and limited
    /// as it says. Changes not yet saved don't show until `save()`. References hold their
    /// targets' IDs.
    ///
    /// The references named in `relationshipKeyPathsForPrefetching` come back holding their
    /// records, loaded together for every result.
    public func fetch<R: Record>(_ descriptor: RecordDescriptor<R>) throws -> [R] {
        _ = version
        checkRegistered(R.self)
        let records = try fetchRecords(descriptor)
        guard !descriptor.relationshipKeyPathsForPrefetching.isEmpty else { return records }
        return try prefetch(descriptor.relationshipKeyPathsForPrefetching, into: records)
    }

    /// `fetch(descriptor)` without prefetching.
    private func fetchRecords<R: Record>(_ descriptor: RecordDescriptor<R>) throws -> [R] {
        let plan = self.plan(for: descriptor)
        if let page = plan.page {
            // The database sorts and limits exactly as Swift would.
            return try Self.loadAll(R.self, zone: zone, filter: plan.filter, page: page, in: database)
        }

        if let predicate = descriptor.predicate, let traversal = plan.traversal {
            // The predicate reads through references, so Swift needs the records it reaches.
            return try fetch(descriptor, matching: predicate, through: traversal, filter: plan.filter)
        }

        // The SQL narrows the rows read. The predicate still decides the result below, so a part
        // of it SQL can't express only widens the query.
        var records = try Self.loadAll(R.self, zone: zone, filter: plan.filter, page: nil, in: database)

        if let predicate = descriptor.predicate {
            records = try records.filter { try predicate.evaluate($0) }
        }
        if !descriptor.sortBy.isEmpty {
            records.sort(using: descriptor.sortBy)
        }
        let start = min(max(descriptor.fetchOffset ?? 0, 0), records.count)
        let end = descriptor.fetchLimit.map { min(start + max($0, 0), records.count) } ?? records.count
        return Array(records[start..<end])
    }

    /// How many records `fetch(descriptor)` would return.
    public func fetchCount<R: Record>(_ descriptor: RecordDescriptor<R>) throws -> Int {
        _ = version
        checkRegistered(R.self)
        let plan = self.plan(for: descriptor)
        guard plan.page != nil else { return try fetchRecords(descriptor).count }
        // The database counts the matches without reading them.
        let (matching, values) = Self.matching(zone: zone, filter: plan.filter)
        let rows = try database.rows(
            "SELECT COUNT(*) AS \"count\" FROM \(database.quoted(R.recordType)) WHERE \(matching)", values
        )
        guard case .integer(let total)? = rows.first?["count"] else { return 0 }
        let remaining = max(Int(total) - max(descriptor.fetchOffset ?? 0, 0), 0)
        return descriptor.fetchLimit.map { min(remaining, max($0, 0)) } ?? remaining
    }

    /// The SQL for `descriptor`: a filter that narrows the rows read, and, when the database can
    /// answer the whole descriptor alone, the order and range of rows to read. When the
    /// predicate reads through references to records, also the references it reads.
    ///
    /// The database answers alone when the predicate translates exactly and every sort
    /// translates.
    private func plan<R: Record>(
        for descriptor: RecordDescriptor<R>
    ) -> (filter: SQLFilter?, page: SQLPage?, traversal: Traversal?) {
        let traversal = descriptor.predicate.map { Traversal($0.expression) }.flatMap { $0.isEmpty ? nil : $0 }
        let translator = PredicateTranslator(for: R.self)
        var filter: SQLFilter?
        var isExact = true
        if let predicate = descriptor.predicate {
            let translated = translator.translate(predicate)
            filter = translated?.filter
            isExact = translated?.isExact ?? false
        }
        guard isExact, let order = translator.orderBy(descriptor.sortBy) else {
            return (filter, nil, traversal)
        }
        let page = SQLPage(
            orderBy: order,
            limit: descriptor.fetchLimit.map { max($0, 0) },
            offset: max(descriptor.fetchOffset ?? 0, 0)
        )
        return (filter, page, traversal)
    }

    /// The condition for current, undeleted rows in `zone` that meet `filter`, and its values.
    nonisolated static func matching(zone: Zone, filter: SQLFilter?) -> (sql: String, values: [SQLValue]) {
        let current = "\"_zoneName\" = ? AND \"_zoneOwner\" = ? AND \"_isCurrent\" = 1 AND \"_deleted\" = 0"
        let zoneValues: [SQLValue] = [.text(zone.name), .text(zone.ownerName)]
        return (current + (filter.map { " AND \($0.sql)" } ?? ""), zoneValues + (filter?.values ?? []))
    }

    /// Every saved, undeleted `R` in `zone` that meets `filter`, in the order and range of `page`
    /// when given, with references holding IDs. One query reads the rows and one reads every
    /// link they own or are the target of.
    private nonisolated static func loadAll<R: Record>(
        _ type: R.Type, zone: Zone, filter: SQLFilter?, page: SQLPage?, in database: Database
    ) throws -> [R] {
        let table = database.quoted(R.recordType)
        var (matching, matchingValues) = Self.matching(zone: zone, filter: filter)
        if let page {
            matching += " ORDER BY \(page.orderBy) LIMIT ? OFFSET ?"
            matchingValues += [.integer(Int64(page.limit ?? -1)), .integer(Int64(page.offset))]
        }
        let rows = try database.rows("SELECT * FROM \(table) WHERE \(matching)", matchingValues)
        guard !rows.isEmpty else { return [] }

        let (current, zoneValues) = Self.matching(zone: zone, filter: nil)
        let names = "SELECT \"_name\" FROM \(table) WHERE \(matching)"
        let linkRows = try database.rows(
            """
            SELECT * FROM \(database.quoted(RecordLink.recordType)) WHERE \(current) \
            AND ("sourceName" IN (\(names)) OR "targetName" IN (\(names)))
            """,
            zoneValues + matchingValues + matchingValues
        )
        var linksByName: [String: [CKRecord]] = [:]
        for row in linkRows {
            guard case .text(let name) = row["_name"] else { continue }
            let link = RecordLink.schema.record(from: row, name: name, zone: zone)
            if case .text(let source) = row["sourceName"] { linksByName[source, default: []].append(link) }
            if case .text(let target) = row["targetName"], row["targetName"] != row["sourceName"] {
                linksByName[target, default: []].append(link)
            }
        }

        let decoder = CKRecordDecoder()
        return try rows.compactMap { row in
            guard case .text(let name) = row["_name"] else { return nil }
            let record = R.schema.record(from: row, name: name, zone: zone)
            return try decoder.decode(R.self, from: record, links: linksByName[name] ?? [], depth: 0)
        }
    }

    /// One query that names the table holding a current, undeleted record, given the record's
    /// zone and name once per table. Built once, and its statement is cached like any other.
    @ObservationIgnored private lazy var recordTypeLookup: (sql: String, tables: Int) = {
        let recordTypes = types.keys.filter { $0 != RecordLink.recordType }.sorted()
        let selects = recordTypes.map { recordType in
            let literal = "'" + recordType.replacingOccurrences(of: "'", with: "''") + "'"
            return "SELECT \(literal) AS \"type\" FROM \(database.quoted(recordType)) "
                + "WHERE \(Self.named) AND \"_isCurrent\" = 1 AND \"_deleted\" = 0"
        }
        return (selects.joined(separator: " UNION ALL ") + " LIMIT 1", recordTypes.count)
    }()

    /// The saved `R` for `key`, with its references holding IDs, or `nil` when it is missing or
    /// deleted.
    private nonisolated static func load<R: Record>(_ type: R.Type, key: RecordKey, in database: Database) throws -> R? {
        guard let row = try currentRow(of: key, in: database), row["_deleted"] != .integer(1) else { return nil }
        let record = R.schema.record(from: row, name: key.name, zone: key.zone)
        let links = try savedLinks(touching: key, in: database).map { name, row in
            RecordLink.schema.record(from: row, name: name, zone: key.zone)
        }
        return try CKRecordDecoder().decode(R.self, from: record, links: links, depth: 0)
    }

    /// The record's own saved links, and the saved links that point at it for its `from:` sides,
    /// by link name.
    private nonisolated static func savedLinks(touching key: RecordKey, in database: Database) throws -> [String: [String: SQLValue]] {
        let rows = try database.rows(
            """
            SELECT * FROM \(database.quoted(RecordLink.recordType)) \
            WHERE "_zoneName" = ? AND "_zoneOwner" = ? AND "_isCurrent" = 1 AND "_deleted" = 0 \
            AND ("sourceName" = ? OR "targetName" = ?)
            """,
            key.values + [.text(key.name)]
        )
        return Dictionary(
            rows.compactMap { row in
                guard case .text(let name) = row["_name"] else { return nil }
                return (name, row)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Stops with a message when `R` isn't registered, which is a programmer error.
    private func checkRegistered<R: Record>(_ type: R.Type) {
        guard let registered = types[R.recordType], ObjectIdentifier(registered) == ObjectIdentifier(R.self) else {
            preconditionFailure(RecordContextError.unregisteredType(R.recordType).description)
        }
    }

    // MARK: - Writing

    /// Writes an edited record. A new one is inserted with every field. An existing one has the
    /// fields that differ updated, and a deleted one comes back with every field. Before a synced
    /// row first changes, it is copied to its base row, and once it matches its base again the
    /// base is dropped.
    private nonisolated static func writeRecord(
        _ schema: RecordSchema, key: RecordKey, values: [String: SQLValue], edited: [String: SQLValue]?,
        now: Double, in database: Database
    ) throws {
        guard let saved = try currentRow(of: key, in: database) else {
            try insertRow(schema.recordType, key: key, fields: values, now: now, in: database)
            return
        }
        // A deleted row comes back whole. Otherwise only the edited fields count, or every field
        // when there is no original to compare with.
        let candidates = saved["_deleted"] == .integer(1) ? values : (edited ?? values)
        let fields = saved["_deleted"] == .integer(1) ? values : candidates.filter { saved[$0.key] != $0.value }
        guard !fields.isEmpty else { return }
        try keepBase(of: key, in: database)
        try updateRow(key, fields: fields, now: now, in: database)
        try dropBaseIfUnchanged(key, schema: schema, in: database)
    }

    /// Writes `links` where they differ from the saved ones. Removes the saved links named in
    /// `removing`, or, when it is `nil`, every saved link not in `links`.
    private nonisolated static func writeLinks(
        _ links: [(String, [String: SQLValue])], of key: RecordKey, saved: [String: [String: SQLValue]],
        removing: Set<String>?, now: Double, in database: Database
    ) throws {
        for (name, values) in links where !matches(saved[name], values) {
            let linkKey = RecordKey(recordType: RecordLink.recordType, name: name, zone: key.zone)
            if try currentRow(of: linkKey, in: database) == nil {
                try insertRow(RecordLink.recordType, key: linkKey, fields: values, now: now, in: database)
            } else {
                // A one-to-many target moves to its new source, so its link may belong to another record.
                try keepBase(of: linkKey, in: database)
                try updateRow(linkKey, fields: values, now: now, in: database)
                try dropBaseIfUnchanged(linkKey, schema: RecordLink.schema, in: database)
            }
        }
        let kept = Set(links.map(\.0))
        for name in saved.keys where removing?.contains(name) ?? !kept.contains(name) {
            try remove(RecordKey(recordType: RecordLink.recordType, name: name, zone: key.zone), now: now, in: database)
        }
    }

    /// Removes the current row of `key`. A row that never synced is deleted with any base row.
    /// A synced row is marked deleted, so the deletion reaches the server.
    private nonisolated static func remove(_ key: RecordKey, now: Double, in database: Database) throws {
        guard let row = try currentRow(of: key, in: database) else { return }
        let table = database.quoted(key.recordType)
        if row["_systemFields"] == .null {
            try database.run("DELETE FROM \(table) WHERE \(named)", key.values)
        } else {
            try database.run(
                "UPDATE \(table) SET \"_deleted\" = 1, \"_modifiedAt\" = ? WHERE \(named) AND \"_isCurrent\" = 1",
                [.real(now)] + key.values
            )
        }
    }

    private nonisolated static func insertRow(
        _ recordType: CKRecord.RecordType, key: RecordKey, fields: [String: SQLValue], now: Double, in database: Database
    ) throws {
        let names = Array(fields.keys)
        let columns = ["_name", "_isCurrent", "_zoneName", "_zoneOwner", "_createdAt", "_modifiedAt"] + names
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        try database.run(
            "INSERT INTO \(database.quoted(recordType)) (\(columns.map(database.quoted).joined(separator: ", "))) VALUES (\(placeholders))",
            [.text(key.name), .integer(1), .text(key.zone.name), .text(key.zone.ownerName), .real(now), .real(now)]
                + names.map { fields[$0]! }
        )
    }

    private nonisolated static func updateRow(_ key: RecordKey, fields: [String: SQLValue], now: Double, in database: Database) throws {
        let names = Array(fields.keys)
        let assignments = ["\"_deleted\" = 0", "\"_modifiedAt\" = ?"] + names.map { "\(database.quoted($0)) = ?" }
        try database.run(
            "UPDATE \(database.quoted(key.recordType)) SET \(assignments.joined(separator: ", ")) WHERE \(named) AND \"_isCurrent\" = 1",
            [.real(now)] + names.map { fields[$0]! } + key.values
        )
    }

    /// Copies the current row of `key` to its base row when the current row has synced and no
    /// base row exists. The base row holds the server's last known values until the next upload.
    private nonisolated static func keepBase(of key: RecordKey, in database: Database) throws {
        let table = database.quoted(key.recordType)
        let columns = try database.columnNames(key.recordType).map(database.quoted)
        let selected = columns.map { $0 == "\"_isCurrent\"" ? "0" : $0 }
        try database.run(
            """
            INSERT OR IGNORE INTO \(table) (\(columns.joined(separator: ", "))) \
            SELECT \(selected.joined(separator: ", ")) FROM \(table) \
            WHERE \(named) AND "_isCurrent" = 1 AND "_systemFields" IS NOT NULL
            """,
            key.values
        )
    }

    /// Drops the base row of `key` when the current row's fields match it again, so an edit that
    /// is undone leaves the record with nothing to upload.
    private nonisolated static func dropBaseIfUnchanged(_ key: RecordKey, schema: RecordSchema, in database: Database) throws {
        let rows = try database.rows("SELECT * FROM \(database.quoted(key.recordType)) WHERE \(named)", key.values)
        guard let current = rows.first(where: { $0["_isCurrent"] == .integer(1) }),
              let base = rows.first(where: { $0["_isCurrent"] == .integer(0) }),
              current["_deleted"] == .integer(0),
              schema.fields.allSatisfy({ current[$0.key] == base[$0.key] })
        else { return }
        try database.run(
            "DELETE FROM \(database.quoted(key.recordType)) WHERE \(named) AND \"_isCurrent\" = 0", key.values
        )
    }

    // MARK: - Reading

    /// Matches one record's rows by zone and name.
    private nonisolated static let named = "\"_zoneName\" = ? AND \"_zoneOwner\" = ? AND \"_name\" = ?"

    /// The current row of `key`, or `nil` when there is none.
    private nonisolated static func currentRow(of key: RecordKey, in database: Database) throws -> [String: SQLValue]? {
        try database.rows(
            "SELECT * FROM \(database.quoted(key.recordType)) WHERE \(named) AND \"_isCurrent\" = 1", key.values
        ).first
    }

    /// The current, undeleted links `key`'s record owns, by link name.
    private nonisolated static func currentLinks(of key: RecordKey, in database: Database) throws -> [String: [String: SQLValue]] {
        let prefix = key.recordType + "."
        let rows = try database.rows(
            """
            SELECT * FROM \(database.quoted(RecordLink.recordType)) \
            WHERE "_zoneName" = ? AND "_zoneOwner" = ? AND "sourceName" = ? AND "_isCurrent" = 1 AND "_deleted" = 0 \
            AND substr("source", 1, ?) = ?
            """,
            key.values + [.integer(Int64(prefix.count)), .text(prefix)]
        )
        return Dictionary(
            rows.compactMap { row in
                guard case .text(let name) = row["_name"] else { return nil }
                return (name, row)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Whether `row` exists and holds every value in `values`.
    nonisolated static func matches(_ row: [String: SQLValue]?, _ values: [String: SQLValue]) -> Bool {
        guard let row else { return false }
        return values.allSatisfy { row[$0.key] == $0.value }
    }

    /// The saved order key of each link target in `links`, by `source|targetName`, so a target
    /// that keeps its place keeps its key.
    nonisolated static func orders(of links: [String: [String: SQLValue]]) -> [String: String] {
        Dictionary(
            links.values.compactMap { row -> (String, String)? in
                guard case .text(let source) = row["source"], case .text(let target) = row["targetName"],
                      case .text(let order) = row["order"] else { return nil }
                return (source + "|" + target, order)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: - Links

    /// A link for each target of each reference that writes links, in order, and one for each
    /// `@Asset` that holds data. `orders` holds the saved order key of each target by
    /// `source|targetName`, so a target that keeps its place keeps its key.
    nonisolated static func links<R: Record>(for record: R, orders: [String: String] = [:]) -> [RecordLink] {
        let references = record.referenceStates.flatMap { reference -> [RecordLink] in
            let source = RecordLink.source(type: R.recordType, property: reference.property)
            // A sorted reference is ordered by its records' fields, so its links carry no keys.
            let keys: [String?] = reference.isToMany && !reference.isSorted
                ? OrderKey.assign(reference.ids.map { orders[source + "|" + $0.uuidString] })
                : reference.ids.map { _ in nil }
            return zip(reference.ids, keys).map { id, order in
                RecordLink(reference: reference, sourceType: R.recordType, sourceID: record.id, target: ReferenceTarget(id: id, order: order))
            }
        }
        let assets = record.assetStates.compactMap { asset in
            asset.id.map { RecordLink(asset: asset, assetID: $0, sourceType: R.recordType, sourceID: record.id) }
        }
        return references + assets
    }
}

/// One record's identity in the database: its type, name, and zone.
struct RecordKey: Hashable, Sendable {
    let recordType: CKRecord.RecordType
    let name: String
    let zone: Zone

    /// The values for `RecordContext.named`, in order.
    var values: [SQLValue] { [.text(zone.name), .text(zone.ownerName), .text(name)] }
}

/// One pending edit to a record in a `RecordContext`, waiting for `save()`.
///
/// Each `@Recordable` that edits a record makes its own, and so does each direct `insert` or
/// `delete`. Only its `id` and `Change` are public.
public struct RecordDifference: Identifiable {
    /// What is to happen to a record when its context saves.
    public enum Change: Hashable, Sendable, Identifiable {
        /// The record is added.
        case insert(UUID)
        /// The record is updated where it was edited.
        case update(UUID)
        /// The record is deleted with the links it owns.
        case delete(UUID)

        /// The record's ID.
        public var id: UUID {
            switch self {
            case .insert(let id), .update(let id), .delete(let id): id
            }
        }
    }

    /// The edit's ID: a `@Recordable`'s own, or a new one for each direct `insert` or `delete`.
    public let id: UUID
    /// The zone the record is in.
    let zone: Zone
    /// The record the edit started from, or `nil` for a new record. `save()` writes only what
    /// `edit` changed from it.
    var base: (any Record)?
    /// The record as edited, or `nil` for a delete.
    var edit: (any Record)?
    /// When the record was last edited. Saves write the oldest edit first.
    var modified: Date

    /// What saving does: an insert without a base, a delete without an edit, and otherwise an
    /// update.
    public var change: Change {
        guard edit != nil else { return .delete(recordID) }
        return base == nil ? .insert(recordID) : .update(recordID)
    }

    /// Moves the edit onto `newBase`, the record as saved elsewhere since: each field and link
    /// the edit changed from `base` is laid over `newBase`. When `newBase` is `nil`, the record
    /// was deleted elsewhere, and an edit brings it back as an insert.
    mutating func rebase(onto newBase: (any Record)?) {
        if let edit, let base, let newBase { self.edit = Self.merged(edit, over: newBase, original: base) }
        base = newBase
    }

    /// `record` with this edit laid over it, as `save()` would leave it: `nil` for a delete,
    /// the edit whole for an insert or when `record` is `nil`, and otherwise the fields and
    /// links the edit changed from `base` laid over `record`.
    func laid(over record: (any Record)?) -> (any Record)? {
        guard let edit else { return nil }
        guard let base, let record else { return edit }
        return Self.merged(edit, over: record, original: base)
    }

    /// Whether `a` is saved before `b`: the older edit first, and by `id` when both are as old.
    static func isOlder(_ a: RecordDifference, _ b: RecordDifference) -> Bool {
        a.modified != b.modified ? a.modified < b.modified : a.id.uuidString < b.id.uuidString
    }
}

// What `save()` and reads need, worked out from the edit and the base when asked.
extension RecordDifference {
    var isDelete: Bool { edit == nil }

    /// The edit, or the base for a delete. A difference always has one of them.
    var record: any Record {
        guard let record = edit ?? base else { preconditionFailure("A difference has no record") }
        return record
    }

    /// The ID of the record edited.
    var recordID: UUID { record.id }

    /// Where the record is kept: its type, its ID and its zone.
    var key: RecordKey {
        RecordKey(recordType: type(of: record).recordType, name: recordID.uuidString, zone: zone)
    }

    var schema: RecordSchema { type(of: record).schema }

    /// Every field's column value, by field key.
    var values: [String: SQLValue] { Self.columns(of: record) }

    /// `base`'s column values, by field key.
    var originalValues: [String: SQLValue]? { base.map { Self.columns(of: $0) } }

    /// The edit's links by name, given the saved order key of each target by
    /// `source|targetName`.
    func links(_ orders: [String: String]) -> [(String, [String: SQLValue])] {
        Self.linkRows(of: record, orders: orders)
    }

    /// `base`'s links, the same way, or `nil` when there is no base.
    func originalLinks(_ orders: [String: String]) -> [(String, [String: SQLValue])]? {
        base.map { Self.linkRows(of: $0, orders: orders) }
    }

    /// `draft` laid over `saved`: each field and owned link the draft changed from `original`
    /// replaces the saved one. The `from:` sides, which the record doesn't own, come from
    /// `saved`. A record of another type, or one that can't be read back, reads as the draft.
    fileprivate static func merged<R: Record>(_ draft: R, over saved: any Record, original: any Record) -> any Record {
        guard let saved = saved as? R, let original = original as? R else { return draft }
        var row = columns(of: saved)
        let originalValues = columns(of: original)
        for (field, value) in columns(of: draft) where originalValues[field] != value {
            row[field] = value
        }

        var links = Dictionary(linkRows(of: saved, orders: [:]), uniquingKeysWith: { first, _ in first })
        let orders = RecordContext.orders(of: links)
        let originalLinks = Dictionary(linkRows(of: original, orders: orders), uniquingKeysWith: { first, _ in first })
        let draftLinks = linkRows(of: draft, orders: orders)
        let kept = Set(draftLinks.map(\.0))
        for name in originalLinks.keys where !kept.contains(name) {
            links[name] = nil
        }
        for (name, values) in draftLinks where !RecordContext.matches(originalLinks[name], values) {
            links[name] = (links[name] ?? [:]).merging(values) { $1 }
        }

        let zone = Zone.records
        let record = R.schema.record(from: row, name: draft.id.uuidString, zone: zone)
        let linkRecords = links.map { name, row in RecordLink.schema.record(from: row, name: name, zone: zone) }
        guard var merged = try? CKRecordDecoder().decode(R.self, from: record, links: linkRecords, depth: 0) else {
            return draft
        }
        for reference in R.schema.references where reference.isFrom {
            let ids = saved.referencedIDs(reference.property)
            try? merged.loadReference(reference.property, to: ids.map { ReferenceTarget(id: $0) }, from: [], links: [], depth: 0)
        }
        return merged
    }

    private static func columns<R: Record>(of record: R) -> [String: SQLValue] {
        Dictionary(uniqueKeysWithValues: zip(R.schema.fields.map(\.key), record.columnValues()))
    }

    private static func linkRows<R: Record>(of record: R, orders: [String: String]) -> [(String, [String: SQLValue])] {
        let linkKeys = RecordLink.schema.fields.map(\.key)
        return RecordContext.links(for: record, orders: orders).map { link in
            (link.id.uuidString, Dictionary(uniqueKeysWithValues: zip(linkKeys, link.columnValues())))
        }
    }
}

