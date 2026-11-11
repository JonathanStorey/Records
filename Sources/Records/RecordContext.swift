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
/// The app's main actor uses `container.mainContext`. Changes are staged in the context and
/// reach the database together when `save()` runs, in one transaction:
///
/// ```swift
/// context.insert(album)
/// context.delete(oldAlbum)
/// try context.save()
/// ```
///
/// Saving writes only the fields and links that differ from the saved copy, so a record saved
/// again unchanged writes nothing and stays in sync.
@MainActor
public final class RecordContext {
    /// Every registered type by record type, shared with the container.
    let types: [CKRecord.RecordType: any Record.Type]
    /// The container's database. The context holds it, not the container, so the container can
    /// keep its main context without the two keeping each other alive.
    let database: Database

    /// The zone records are inserted into and deleted from. It starts as the container's
    /// `defaultZone`. Set it to switch zones at any time. Changes already staged keep the zone
    /// they were staged in.
    public var zone: Zone
    /// The container's `defaultZone`, which `@Recordable` edits in when it isn't given a zone.
    let defaultZone: Zone

    /// Staged changes by record, in the order they were first staged.
    var staged: [RecordKey: RecordDifference] = [:]
    var stagedOrder: [RecordKey] = []
    /// Differences handed out but not staged. One is dropped once the context is all that holds it.
    private var shown: [RecordKey: RecordDifference] = [:]

    init(container: RecordContainer) {
        types = container.types
        database = container.database
        defaultZone = container.defaultZone
        zone = container.defaultZone
    }

    /// Whether any change is staged and not yet saved, in any zone.
    public var hasChanges: Bool { !staged.isEmpty }

    /// The changes staged in the current `zone`, in the order they were first staged, such as
    /// `.insert(album.id)`. A record appears at most once: staging it again replaces its change.
    /// `save()` writes the changes of every zone, not only these.
    public var changes: [RecordDifference.Change] {
        differences.compactMap(\.change)
    }

    /// The staged differences in the current `zone`, in the order they were first staged.
    var differences: [RecordDifference] {
        stagedOrder.filter { $0.zone == zone }.compactMap { staged[$0] }.filter { $0.change != nil }
    }

    /// The difference staged for the record with `id` in the current `zone`, or `nil` when none
    /// is staged. It is `@Observable` and stays the same object while the record is staged, so a
    /// view or property wrapper holding it sees each new change.
    func difference(id: UUID) -> RecordDifference? {
        let name = id.uuidString
        return stagedOrder.first { $0.zone == zone && $0.name == name }.flatMap { staged[$0] }
    }

    /// The difference for `record` in `zone`, or the current `zone` when `nil`, staged or not.
    /// Everything that asks for the same record gets the same object while any of them holds it.
    /// A new one starts from the saved record, or from `record` when none is saved, with nothing
    /// staged.
    func difference<R: Record>(for record: R, in zone: Zone? = nil) -> RecordDifference {
        checkRegistered(R.self)
        let zone = zone ?? self.zone
        let key = RecordKey(recordType: R.recordType, name: record.id.uuidString, zone: zone)
        if let difference = existingDifference(for: key) { return difference }
        dropUnused()
        let original = (try? Self.load(R.self, key: key, in: database)) ?? nil
        let difference = RecordDifference(id: record.id, zone: zone, original: original, draft: original ?? record)
        shown[key] = difference
        return difference
    }

    /// Called after `difference`'s draft was edited: stages it as an insert of its draft.
    func didEdit(_ difference: RecordDifference) {
        let key = RecordKey(recordType: type(of: difference.record).recordType, name: difference.id.uuidString, zone: difference.zone)
        difference.change = .insert(difference.id)
        stage(difference, key: key)
    }

    /// The difference already handed out or staged for `key`.
    private func existingDifference(for key: RecordKey) -> RecordDifference? {
        staged[key] ?? shown[key]
    }

    /// Drops the unstaged differences nothing else holds any more.
    private func dropUnused() {
        for key in Array(shown.keys) where isKnownUniquelyReferenced(&shown[key]!) {
            shown[key] = nil
        }
    }

    /// Puts `difference` among the staged ones, if it isn't already.
    private func stage(_ difference: RecordDifference, key: RecordKey) {
        guard staged[key] == nil else { return }
        shown[key] = nil
        staged[key] = difference
        stagedOrder.append(key)
    }

    /// Moves every staged difference back to shown, then drops the ones nothing uses.
    private func unstageAll() {
        shown.merge(staged) { current, _ in current }
        staged.removeAll()
        stagedOrder.removeAll()
        dropUnused()
    }

    // MARK: - Staging

    /// Stages `record` in the current `zone`. Nothing is written until `save()`.
    ///
    /// `record` becomes the record's value: `save()` adds it if it is new, and otherwise writes
    /// the fields and links that differ from the saved copy. Only `record` itself is staged.
    /// Records its references point at are staged by inserting them too.
    public func insert(_ record: some Record) {
        stage(record, isDelete: false)
    }

    /// Stages deleting `record` from the current `zone`, with the links it owns. When saved, a
    /// record that never synced is removed outright, and a synced one is kept as a deletion until
    /// the server confirms it.
    ///
    /// Saving also removes the links other records hold to it, so their references drop it, and
    /// deletes the records it owns through a reference whose `from:` side says `deleteSelf: true`,
    /// unless another record has taken them over in the same save.
    public func delete(_ record: some Record) {
        stage(record, isDelete: true)
    }

    /// Writes every staged change in one transaction, then clears them. If any write fails,
    /// nothing is written and the changes stay staged.
    public func save() throws {
        guard hasChanges else { return }
        // Written in its own function, so nothing here still holds a difference when
        // `unstageAll()` drops the ones no view uses.
        try writeStaged()
        unstageAll()
    }

    /// Writes every staged change in one transaction, then starts each difference over from the
    /// record as written.
    private func writeStaged() throws {
        let changes = stagedOrder.compactMap { key in staged[key].map { (key, $0) } }
        let now = Date().timeIntervalSince1970
        let database = self.database
        try database.transaction {
            // The links each deleted record owns, read before saving removes them.
            let deleted = try changes.filter { $0.1.isDelete }.map { key, _ in
                (key, try Self.currentLinks(of: key, in: database))
            }
            for (key, change) in changes {
                try Self.write(change, key: key, now: now, in: database)
            }
            try insertNewTargets(of: changes, now: now, in: database)
            try finishDeleting(deleted, now: now, in: database)
        }
        // Each difference starts over from the record as written, so later edits compare with it.
        for (key, difference) in changes {
            let written = difference.isDelete ? nil : (try? Self.loadSaved(like: difference.record, key: key, in: database)) ?? nil
            difference.original = written
            difference.saved = nil
            if let written { difference.draft = written }
            difference.change = nil
        }
    }

    /// Discards every staged change. Each record's draft goes back to its saved record.
    public func rollback() {
        for difference in staged.values {
            if let saved = difference.saved ?? difference.original { difference.draft = saved }
            difference.change = nil
        }
        unstageAll()
    }

    /// Stages `record`. The first time, the saved record becomes the original that `save()`
    /// compares with. Staging it again updates the same difference and keeps that original.
    private func stage<R: Record>(_ record: R, isDelete: Bool) {
        checkRegistered(R.self)
        let key = RecordKey(recordType: R.recordType, name: record.id.uuidString, zone: zone)
        let change: RecordDifference.Change = isDelete ? .delete(record.id) : .insert(record.id)
        if let existing = existingDifference(for: key) {
            existing.draft = record
            existing.change = change
            stage(existing, key: key)
            return
        }
        // A record that can't be read counts as unsaved, so save writes every field.
        let original = (try? Self.load(R.self, key: key, in: database)) ?? nil
        stage(RecordDifference(id: record.id, zone: zone, original: original, draft: record, change: change), key: key)
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
    /// zone, deleted or not, and not staged. A target that exists is never written, so a stale
    /// copy can't overwrite it. New targets' own new targets are inserted too.
    private func insertNewTargets(of changes: [(RecordKey, RecordDifference)], now: Double, in database: Database) throws {
        var visited = Set(changes.map(\.0))
        var queue = changes.compactMap { key, change in change.isDelete ? nil : (key.zone, change.record) }
        while !queue.isEmpty {
            let (zone, record) = queue.removeFirst()
            for target in record.loadedTargets {
                let key = RecordKey(recordType: type(of: target).recordType, name: target.id.uuidString, zone: zone)
                guard visited.insert(key).inserted,
                      try Self.currentRow(of: key, in: database) == nil
                else { continue }
                try Self.write(RecordDifference(id: target.id, zone: zone, original: nil, draft: target, change: .insert(target.id)), key: key, now: now, in: database)
                queue.append((zone, target))
            }
        }
    }

    /// Writes one change: the record's row and its links. With an original, only the fields and
    /// links that differ from it are written, so the saved record keeps anything changed
    /// elsewhere since that the draft didn't touch.
    private static func write(_ change: RecordDifference, key: RecordKey, now: Double, in database: Database) throws {
        let savedLinks = try currentLinks(of: key, in: database)
        guard !change.isDelete else {
            try remove(key, now: now, in: database)
            try writeLinks([], of: key, saved: savedLinks, removing: nil, now: now, in: database)
            return
        }
        // A record removed or deleted since it was staged comes back whole.
        let savedRow = try currentRow(of: key, in: database)
        let hasOriginal = savedRow != nil && savedRow?["_deleted"] != .integer(1) && change.original != nil
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

    /// The `R` with `id` in the current `zone`, or `nil` when there is none. A staged change
    /// comes first: a staged insert returns the latest saved record with the draft's edits laid
    /// over it, and a staged delete returns `nil`.
    ///
    /// References hold their targets' IDs. Load the targets themselves with `record(id:for:)`.
    public func record<R: Record>(id: UUID, for type: R.Type = R.self) throws -> R? {
        checkRegistered(R.self)
        let key = RecordKey(recordType: R.recordType, name: id.uuidString, zone: zone)
        if let change = staged[key] {
            return try draftRecord(change, key: key) as? R
        }
        return try Self.load(R.self, key: key, in: database)
    }

    /// The record with `id` in the current `zone`, whatever its type, or `nil` when there is none.
    /// A staged change comes first, as in `record(id:for:)`. Finding the type takes one indexed
    /// query across every table.
    public func record(id: UUID) throws -> (any Record)? {
        let name = id.uuidString
        if let key = stagedOrder.first(where: { $0.name == name && $0.zone == zone && $0.recordType != RecordLink.recordType }),
           let change = staged[key] {
            return try draftRecord(change, key: key)
        }
        let lookup = recordTypeLookup
        let values = Array(repeating: RecordKey(recordType: "", name: name, zone: zone).values, count: lookup.tables).flatMap { $0 }
        guard case .text(let recordType) = try database.rows(lookup.sql, values).first?["type"],
              let type = types[recordType]
        else { return nil }
        return try Self.load(type, key: RecordKey(recordType: recordType, name: name, zone: zone), in: database)
    }

    /// The records of `R` in the current `zone` that match `descriptor`, sorted and limited as it
    /// says. Staged changes count: a staged insert is the latest saved record with the draft's
    /// edits laid over it, and a staged delete leaves its record out. References hold their targets' IDs.
    ///
    /// The references named in `relationshipKeyPathsForPrefetching` come back holding their
    /// records, loaded together for every result.
    public func fetch<R: Record>(_ descriptor: RecordDescriptor<R>) throws -> [R] {
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

        // Staged changes in this zone replace or remove the saved records they name.
        let stagedHere = stagedKeys(R.self)
        if !stagedHere.isEmpty {
            let names = Set(stagedHere.map(\.name))
            records.removeAll { names.contains($0.id.uuidString) }
            records += try stagedHere.compactMap { key in
                guard let change = staged[key] else { return nil }
                return try draftRecord(change, key: key) as? R
            }
        }

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

    /// The staged changes to records of `R` in the current zone.
    func stagedKeys<R: Record>(_ type: R.Type) -> [RecordKey] {
        stagedOrder.filter { $0.zone == zone && $0.recordType == R.recordType }
    }

    /// The SQL for `descriptor`: a filter that narrows the rows read, and, when the database can
    /// answer the whole descriptor alone, the order and range of rows to read. When the
    /// predicate reads through references to records, also the references it reads.
    ///
    /// The database answers alone when the predicate translates exactly, every sort translates,
    /// and no change to `R` is staged in this zone. A path into linked records is left to Swift
    /// when a change to a type it could reach is staged, since the database doesn't hold it.
    private func plan<R: Record>(
        for descriptor: RecordDescriptor<R>
    ) -> (filter: SQLFilter?, page: SQLPage?, traversal: Traversal?) {
        let traversal = descriptor.predicate.map { Traversal($0.expression) }.flatMap { $0.isEmpty ? nil : $0 }
        let reachable = traversal == nil ? [] : Self.reachableTypes(from: R.self)
        let allowsPaths = !stagedOrder.contains { $0.zone == zone && reachable.contains($0.recordType) }
        let translator = PredicateTranslator(for: R.self, allowsPaths: allowsPaths)
        var filter: SQLFilter?
        var isExact = true
        if let predicate = descriptor.predicate {
            let translated = translator.translate(predicate)
            filter = translated?.filter
            isExact = translated?.isExact ?? false
        }
        guard isExact, stagedKeys(R.self).isEmpty, let order = translator.orderBy(descriptor.sortBy) else {
            return (filter, nil, traversal)
        }
        let page = SQLPage(
            orderBy: order,
            limit: descriptor.fetchLimit.map { max($0, 0) },
            offset: max(descriptor.fetchOffset ?? 0, 0)
        )
        return (filter, page, traversal)
    }

    /// Every record type a reference of `R` reaches, directly or through other records.
    private nonisolated static func reachableTypes<R: Record>(from type: R.Type) -> Set<CKRecord.RecordType> {
        var found: Set<CKRecord.RecordType> = [R.recordType]
        var pending: [any Record.Type] = [R.self]
        while let next = pending.popLast() {
            for reference in next.schema.references where found.insert(reference.target.recordType).inserted {
                pending.append(reference.target)
            }
        }
        return found
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
    private lazy var recordTypeLookup: (sql: String, tables: Int) = {
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

    /// The record a staged change reads as: the latest saved record with the draft's edited
    /// fields and links laid over it, as `save()` would write it, or `nil` for a delete. Reading
    /// writes nothing, and a record with no draft never comes here.
    func draftRecord(_ change: RecordDifference, key: RecordKey) throws -> (any Record)? {
        guard !change.isDelete else { return nil }
        guard change.original != nil else { return change.draft }
        return change.value(over: try Self.loadSaved(like: change.record, key: key, in: database))
    }

    /// The saved record of `key`, of the same type as `record`.
    private nonisolated static func loadSaved<R: Record>(like _: R, key: RecordKey, in database: Database) throws -> (any Record)? {
        try load(R.self, key: key, in: database)
    }

    /// Stops with a message when `R` isn't registered, which is a programmer error.
    private func checkRegistered<R: Record>(_ type: R.Type) {
        guard let registered = types[R.recordType], ObjectIdentifier(registered) == ObjectIdentifier(R.self) else {
            preconditionFailure(RecordContextError.unregisteredType(R.recordType).description)
        }
    }

    // MARK: - Writing

    /// Writes a staged record. A new one is inserted with every field. An existing one has the
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

/// A record staged in a `RecordContext`, waiting for `save()`, or one being edited.
///
/// The context keeps one per staged record. Staging the record again updates the same
/// difference, so anything observing it stays current. Only its `Change` is public.
@MainActor
@Observable
public final class RecordDifference {
    /// What is to happen to a staged record when its context saves.
    public enum Change: Hashable, Sendable, Identifiable {
        /// The record is saved: added if new, or updated where it was edited.
        case insert(UUID)
        /// The record is deleted with the links it owns.
        case delete(UUID)

        /// The record's ID.
        public var id: UUID {
            switch self {
            case .insert(let id), .delete(let id): id
            }
        }
    }

    /// The record's ID.
    let id: UUID
    /// The zone the record is in.
    let zone: Zone
    /// What is to happen, or `nil` while the record is only shown and not yet staged.
    var change: Change?

    /// The saved record when editing began, or `nil` when none was saved. `save()` writes only
    /// what the draft changed from it.
    var original: (any Record)?
    /// A record saved since `original`, or `nil` when nothing newer is known, so the draft reads
    /// as it is without merging.
    var saved: (any Record)?
    /// The record as edited.
    var draft: (any Record)?

    init(
        id: UUID, zone: Zone = .records, original: (any Record)?, draft: (any Record)? = nil,
        change: RecordDifference.Change? = nil
    ) {
        self.id = id
        self.zone = zone
        self.original = original
        self.draft = draft
        self.change = change
    }

    /// The record as it reads: `saved` with what `draft` changed from `original` laid over it,
    /// so changes made elsewhere to anything else show. `nil` for a delete. Without an original
    /// or a newer saved record, the draft reads whole, with no merging.
    var value: (any Record)? { value(over: saved) }

    /// The record as it reads over `saved` instead of the saved record it holds.
    func value(over saved: (any Record)?) -> (any Record)? {
        guard !isDelete, let draft else { return nil }
        guard let original, let saved else { return draft }
        return Self.merged(draft, over: saved, original: original)
    }
}

// What `save()` and reads need, worked out from the draft and the original when asked.
extension RecordDifference {
    var isDelete: Bool {
        if case .delete = change { true } else { false }
    }

    /// The draft, which every staged difference has.
    var record: any Record {
        guard let draft else { preconditionFailure("A staged difference has no draft") }
        return draft
    }

    var schema: RecordSchema { type(of: record).schema }

    /// Every field's column value, by field key.
    var values: [String: SQLValue] { Self.columns(of: record) }

    /// `original`'s column values, by field key.
    var originalValues: [String: SQLValue]? { original.map { Self.columns(of: $0) } }

    /// The draft's links by name, given the saved order key of each target by
    /// `source|targetName`.
    func links(_ orders: [String: String]) -> [(String, [String: SQLValue])] {
        Self.linkRows(of: record, orders: orders)
    }

    /// `original`'s links, the same way, or `nil` when there is no original.
    func originalLinks(_ orders: [String: String]) -> [(String, [String: SQLValue])]? {
        original.map { Self.linkRows(of: $0, orders: orders) }
    }

    /// `draft` laid over `saved`: each field and owned link the draft changed from `original`
    /// replaces the saved one. The `from:` sides, which the record doesn't own, come from
    /// `saved`. A record of another type, or one that can't be read back, reads as the draft.
    private static func merged<R: Record>(_ draft: R, over saved: any Record, original: any Record) -> any Record {
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

