import CloudKit
import Foundation
import Observation

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
/// Views observe three properties: `lastSaved`, which moves when the saved records change,
/// and `changes` and `hasChanges`, which move when pending edits begin or end. Nothing else
/// in the context redraws a view.
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
    /// The container, which refreshes its other contexts after this one saves. Weak, so the
    /// container and its main context don't keep each other alive.
    @ObservationIgnored private weak var container: RecordContainer?

    /// The pending edits, by each edit's `id`. A record can have several: one per `@Recordable`
    /// that edited it, and one per direct `insert` or `delete`.
    @ObservationIgnored var differences: [UUID: RecordDifference] = [:]
    /// The `id` of each pending edit, in the order the edits began.
    @ObservationIgnored private var editOrder: [UUID] = []
    /// The edit `insert` and `delete` share for each record, so calling them again replaces
    /// that edit and keeps its base.
    @ObservationIgnored private var directEdits: [RecordKey: UUID] = [:]

    /// When the saved records this context reads last changed, or `nil` before the first
    /// change. `save()` sets it, and so does a save in another context of the same container.
    /// Every read of a record reads it, so a view showing records redraws when it moves.
    public private(set) var lastSaved: Date?

    /// Whether any change is waiting for `save()`, in any zone.
    public private(set) var hasChanges = false

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
        self.container = container
        container.add(self)
    }

    /// Sets `changes` and `hasChanges` from the pending edits, each only when it differs, so a
    /// view reading them redraws only when they change.
    private func updateChanges() {
        editOrder.removeAll { differences[$0] == nil }
        let current = editOrder.compactMap { differences[$0] }.filter { $0.zone == zone }.map(\.change)
        if current != changes { changes = current }
        if hasChanges == differences.isEmpty { hasChanges = !differences.isEmpty }
    }

    /// Reads what a record's pending edits depend on, so a view reading one redraws when the
    /// saved records change or a pending edit begins or ends.
    private func observeDrafts() {
        _ = lastSaved
        _ = changes
        _ = hasChanges
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
        return draft(id: record.uuid, for: R.self, in: zone, savedFirst: true)
    }

    /// The record with `id` in `zone` as `save()` would write it: the saved record with every
    /// pending edit to it laid over, oldest first, or `nil` when it is missing or deleted.
    func draft<R: Record>(id: RecordID<R>, for type: R.Type, in zone: Zone) -> R? {
        observeDrafts()
        return draft(id: id.rawValue, for: type, in: zone, savedFirst: false)
    }

    /// `draft(id:for:in:)`, or with `savedFirst`, the saved record when there is one.
    private func draft<R: Record>(id: UUID, for type: R.Type, in zone: Zone, savedFirst: Bool) -> R? {
        let key = RecordKey(recordType: R.recordType, name: id.uuidString, zone: zone)
        let saved = (try? database.load(R.self, key: key)) ?? nil
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
        // Links edited on their own go last, so a new record saved in the same save can't drop
        // them for not listing them.
        let sorted = differences.values.sorted(by: RecordDifference.isOlder)
        let changes = sorted.filter { $0.key.recordType != RecordLink.recordType }
            + sorted.filter { $0.key.recordType == RecordLink.recordType }
        let now = Date().timeIntervalSinceReferenceDate
        let database = self.database
        try database.transaction {
            var deleted: [(RecordKey, [String: [String: SQLValue]])] = []
            for difference in changes {
                // The links a deleted record owns, read before saving removes them.
                if difference.isDelete {
                    deleted.append((difference.key, try database.currentLinks(of: difference.key)))
                }
                try database.write(difference, now: now)
            }
            try insertNewTargets(of: changes, now: now)
            try finishDeleting(deleted, now: now)
        }
        rollback()
        lastSaved = .now
        container?.didSave(from: self)
    }

    /// Moves every pending edit onto its record as saved now, then redraws the views showing
    /// records. Call it after the saved records change from outside this context: the container
    /// does after another context saves, and sync does after it writes the server's changes.
    ///
    /// Each edit keeps the fields and links it changed and takes everything else from the
    /// record as saved now. An edit to a record deleted elsewhere becomes an insert, so editing
    /// brings the record back. A delete of a record already deleted is dropped.
    ///
    /// The edits `insert` and `delete` make keep their base. Their caller may insert again a
    /// copy made before the change, and the first base is what keeps that copy from undoing it.
    func rebase() {
        let direct = Set(directEdits.values)
        for (id, var difference) in differences where !direct.contains(id) {
            difference.rebase(onto: saved(like: difference.record, in: difference.zone))
            differences[id] = difference.base == nil && difference.edit == nil ? nil : difference
        }
        updateChanges()
        lastSaved = .now
    }

    /// The saved record `record` names in `zone`, or `nil` when it is missing or deleted.
    private func saved<R: Record>(like record: R, in zone: Zone) -> R? {
        let key = RecordKey(recordType: R.recordType, name: record.id.uuidString, zone: zone)
        return (try? database.load(R.self, key: key)) ?? nil
    }

    /// Discards every pending edit.
    public func rollback() {
        differences = [:]
        directEdits = [:]
        updateChanges()
    }

    /// Discards every pending edit to the record with `id` in the current `zone`.
    public func rollback<R: Record>(id: RecordID<R>) {
        differences = differences.filter { $0.value.zone != zone || $0.value.recordID != id.rawValue }
        updateChanges()
    }

    /// Removes the links that point at each deleted record, and deletes the records it owned
    /// through a reference whose `from:` side says `deleteSelf: true`, the same way in turn.
    /// `deleted` holds each record's owned links as they were before saving.
    private func finishDeleting(
        _ deleted: [(RecordKey, [String: [String: SQLValue]])], now: Double
    ) throws {
        var queue = deleted
        var finished: Set<RecordKey> = []
        while !queue.isEmpty {
            let (key, owned) = queue.removeFirst()
            guard finished.insert(key).inserted else { continue }
            try removeLinks(to: key, now: now)

            for row in owned.values {
                guard case .text(let source) = row["source"], case .text(let targetName) = row["targetName"],
                      let target = deletedWithOwner(source: source),
                      // Another record may have taken the target over in this save.
                      try !database.isLinked(source: source, targetName: targetName, zone: key.zone)
                else { continue }
                let targetKey = RecordKey(recordType: target.recordType, name: targetName, zone: key.zone)
                guard let targetRow = try database.currentRow(of: targetKey), targetRow["_deleted"] != .integer(1) else { continue }
                let targetOwned = try database.currentLinks(of: targetKey)
                try database.delete(targetKey, links: targetOwned, now: now)
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
    private func removeLinks(to key: RecordKey, now: Double) throws {
        for (name, row) in try database.links(in: key.zone, where: "\"targetName\" = ?", [.text(key.name)]) {
            guard case .text(let source) = row["source"],
                  linkReference(named: source)?.reference.target.recordType == key.recordType
            else { continue }
            try database.remove(RecordKey(recordType: RecordLink.recordType, name: name, zone: key.zone), now: now)
        }
    }

    /// Inserts the loaded targets of the saved records that exist nowhere yet: not saved in the
    /// zone, deleted or not, and not pending. A target that exists is never written, so a stale
    /// copy can't overwrite it. New targets' own new targets are inserted too.
    private func insertNewTargets(of changes: [RecordDifference], now: Double) throws {
        var visited = Set(changes.map(\.key))
        var queue = changes.compactMap { change in change.edit.map { (change.zone, $0) } }
        while !queue.isEmpty {
            let (zone, record) = queue.removeFirst()
            for target in record.loadedTargets {
                let key = RecordKey(recordType: type(of: target).recordType, name: target.uuid.uuidString, zone: zone)
                guard visited.insert(key).inserted,
                      try database.currentRow(of: key) == nil
                else { continue }
                try database.write(RecordDifference(id: UUID(), zone: zone, base: nil, edit: target, modified: .now), now: now)
                queue.append((zone, target))
            }
        }
    }

    // MARK: - Editing links

    /// Adds `target` to the reference `keyPath` names on the record with `ownerID` when the
    /// context saves. Only that one link is written: the owner's record
    /// is never read or changed, so this works whether or not its references are loaded.
    ///
    /// ```swift
    /// context.insert(track, into: \Album.tracks, of: album.id)
    /// ```
    ///
    /// `target` is inserted too when it exists nowhere yet. A target that exists is left as it
    /// is, so a stale copy can't overwrite it. A target already in the reference is left as it is.
    public func insert<Owner: Record, Target: Record>(
        _ target: Target, into keyPath: KeyPath<Owner, [Target]>, of ownerID: Owner.ID
    ) {
        insert([target], into: keyPath, of: ownerID)
    }

    /// Adds `targets` to the reference `keyPath` names on the record with `ownerID`. See
    /// `insert(_:into:of:)`.
    public func insert<Owner: Record, Target: Record>(
        _ targets: [Target], into keyPath: KeyPath<Owner, [Target]>, of ownerID: Owner.ID
    ) {
        insert(targets, into: property(keyPath), of: Owner.self, id: ownerID.rawValue)
    }

    /// Points the to-one reference `keyPath` names on the record with `ownerID` at `target`,
    /// replacing any target it had. See `insert(_:into:of:)`.
    ///
    /// ```swift
    /// context.insert(nova, into: \Album.artist, of: album.id)
    /// ```
    public func insert<Owner: Record, Target: Record>(
        _ target: Target, into keyPath: KeyPath<Owner, Target?>, of ownerID: Owner.ID
    ) {
        insert([target], into: property(keyPath), of: Owner.self, id: ownerID.rawValue)
    }

    /// Takes the target with `targetID` out of the reference `keyPath` names on the record with
    /// `ownerID` when the context saves. Only that one link is deleted. The target itself is
    /// kept, and so is the owner's record.
    ///
    /// ```swift
    /// context.remove(track.id, from: \Album.tracks, of: album.id)
    /// ```
    ///
    /// A target the reference doesn't hold is ignored.
    public func remove<Owner: Record, Target: Record>(
        _ targetID: Target.ID, from keyPath: KeyPath<Owner, [Target]>, of ownerID: Owner.ID
    ) {
        remove([targetID], from: keyPath, of: ownerID)
    }

    /// Takes the targets with `targetIDs` out of the reference `keyPath` names on the record with
    /// `ownerID`. See `remove(_:from:of:)`.
    public func remove<Owner: Record, Target: Record>(
        _ targetIDs: [Target.ID], from keyPath: KeyPath<Owner, [Target]>, of ownerID: Owner.ID
    ) {
        remove(targetIDs.map(\.rawValue), from: property(keyPath), of: Owner.self, id: ownerID.rawValue)
    }

    /// Clears the to-one reference `keyPath` names on the record with `ownerID` when it points at
    /// the target with `targetID`. See `remove(_:from:of:)`.
    public func remove<Owner: Record, Target: Record>(
        _ targetID: Target.ID, from keyPath: KeyPath<Owner, Target?>, of ownerID: Owner.ID
    ) {
        remove([targetID.rawValue], from: property(keyPath), of: Owner.self, id: ownerID.rawValue)
    }

    /// Links `targets` through the reference named `property` on the `Owner` with `ownerID`. Used
    /// by `insert(_:into:of:)` and by `ReferenceIDs` and `ReferenceID`.
    func insert<Owner: Record, Target: Record>(_ targets: [Target], into property: String, of owner: Owner.Type, id ownerID: UUID) {
        let reference = ownedReference(property, of: Owner.self)
        for target in targets {
            link(target, through: reference, of: Owner.self, ownerID: ownerID)
        }
    }

    /// Unlinks the targets with `targetIDs` from the reference named `property` on the `Owner`
    /// with `ownerID`. Used by `remove(_:from:of:)` and by `ReferenceIDs` and `ReferenceID`.
    func remove<Owner: Record>(_ targetIDs: [UUID], from property: String, of owner: Owner.Type, id ownerID: UUID) {
        let reference = ownedReference(property, of: Owner.self)
        for targetID in targetIDs {
            unlink(targetID, through: reference, of: Owner.self, ownerID: ownerID)
        }
    }

    /// The property `keyPath` names.
    private func property<Owner: Record>(_ keyPath: PartialKeyPath<Owner>) -> String {
        guard let property = Owner.keyPaths[keyPath] else {
            preconditionFailure("\(keyPath) is not a @Reference of \(Owner.self)")
        }
        return property
    }

    /// The reference named `property`, as the links it writes need it.
    private func ownedReference<Owner: Record>(_ property: String, of owner: Owner.Type) -> ReferenceState {
        checkRegistered(Owner.self)
        guard let schema = Owner.schema.references.first(where: { $0.property == property && !$0.isFrom })
        else { preconditionFailure("\(property) is not a @Reference of \(Owner.self)") }
        return ReferenceState(
            schema: schema, inverse: Owner.schema.inverse(of: property, in: schema.target), ids: [], records: []
        )
    }

    /// Records the edit that links `target` to the record with `ownerID`, and inserts `target`
    /// when it exists nowhere yet.
    private func link<Owner: Record, Target: Record>(
        _ target: Target, through reference: ReferenceState, of owner: Owner.Type, ownerID: UUID
    ) {
        if draft(id: target.uuid, for: Target.self, in: zone, savedFirst: true) == nil {
            insert(target)
        }
        let id = RecordLink.id(reference: reference, sourceType: Owner.recordType, sourceID: ownerID, targetID: target.uuid)
        let existing = draft(id: id, for: RecordLink.self, in: zone, savedFirst: false)
        if existing?.sourceName == ownerID.uuidString, existing?.targetName == target.id.uuidString { return }

        let link = RecordLink(reference: reference, sourceType: Owner.recordType, sourceID: ownerID, targetID: target.uuid)
        edit(id: directEdit(of: link), of: link, in: zone, with: link)
    }

    /// Records the edit that deletes the link from the record with `ownerID` to the target with
    /// `targetID`, when there is one.
    private func unlink<Owner: Record>(_ targetID: UUID, through reference: ReferenceState, of owner: Owner.Type, ownerID: UUID) {
        let id = RecordLink.id(reference: reference, sourceType: Owner.recordType, sourceID: ownerID, targetID: targetID)
        guard let link = draft(id: id, for: RecordLink.self, in: zone, savedFirst: false),
              link.sourceName == ownerID.uuidString, link.targetName == targetID.uuidString
        else { return }
        edit(id: directEdit(of: link), of: link, in: zone, with: nil)
    }

    // MARK: - Reading

    /// The saved `R` with `id` in the current `zone`, or `nil` when there is none. Changes not
    /// yet saved don't show until `save()`.
    ///
    /// References hold their targets' IDs. Load the targets themselves with `record(id:for:)`.
    public func record<R: Record>(id: RecordID<R>, for type: R.Type = R.self) throws -> R? {
        _ = lastSaved
        checkRegistered(R.self)
        let key = RecordKey(recordType: R.recordType, name: id.uuidString, zone: zone)
        return try database.load(R.self, key: key)
    }

    /// The saved record with `id` in the current `zone`, whatever its type, or `nil` when there
    /// is none. Finding the type takes one indexed query across every table.
    public func record(id: UUID) throws -> (any Record)? {
        _ = lastSaved
        let name = id.uuidString
        let lookup = recordTypeLookup
        let values = Array(repeating: RecordKey(recordType: "", name: name, zone: zone).values, count: lookup.tables).flatMap { $0 }
        guard case .text(let recordType) = try database.rows(lookup.sql, values).first?["type"],
              let type = types[recordType]
        else { return nil }
        return try database.load(type, key: RecordKey(recordType: recordType, name: name, zone: zone))
    }

    /// The saved records of `R` in the current `zone` that match `descriptor`, sorted and limited
    /// as it says. Changes not yet saved don't show until `save()`. References hold their
    /// targets' IDs.
    ///
    /// The references named in `relationshipKeyPathsForPrefetching` come back holding their
    /// records, loaded together for every result.
    public func fetch<R: Record>(_ descriptor: RecordDescriptor<R>) throws -> [R] {
        _ = lastSaved
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
            return try database.loadAll(R.self, zone: zone, filter: plan.filter, page: page)
        }

        if let predicate = descriptor.predicate, let traversal = plan.traversal {
            // The predicate reads through references, so Swift needs the records it reaches.
            return try fetch(descriptor, matching: predicate, through: traversal, filter: plan.filter)
        }

        // The SQL narrows the rows read. The predicate still decides the result below, so a part
        // of it SQL can't express only widens the query.
        var records = try database.loadAll(R.self, zone: zone, filter: plan.filter, page: nil)

        if let predicate = descriptor.predicate {
            records = try records.filter { try predicate.evaluate($0) }
        }
        if !descriptor.sortBy.isEmpty { records.sort(using: descriptor.sortBy) }
        return Array(descriptor.page(of: records))
    }

    /// How many records `fetch(descriptor)` would return.
    public func fetchCount<R: Record>(_ descriptor: RecordDescriptor<R>) throws -> Int {
        _ = lastSaved
        checkRegistered(R.self)
        let plan = self.plan(for: descriptor)
        guard plan.page != nil else { return try fetchRecords(descriptor).count }
        // The database counts the matches without reading them.
        let (matching, values) = Database.matching(zone: zone, filter: plan.filter)
        let rows = try database.rows(
            "SELECT COUNT(*) AS \"count\" FROM \(quoted(R.recordType)) WHERE \(matching)", values
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

    /// One query that names the table holding a current, undeleted record, given the record's
    /// zone and name once per table. Built once, and its statement is cached like any other.
    @ObservationIgnored private lazy var recordTypeLookup: (sql: String, tables: Int) = {
        let recordTypes = types.keys.filter { $0 != RecordLink.recordType }.sorted()
        let selects = recordTypes.map { recordType in
            let literal = "'" + recordType.replacingOccurrences(of: "'", with: "''") + "'"
            return "SELECT \(literal) AS \"type\" FROM \(quoted(recordType)) "
                + "WHERE \(Database.named) AND \"_isCurrent\" = 1 AND \"_deleted\" = 0"
        }
        return (selects.joined(separator: " UNION ALL ") + " LIMIT 1", recordTypes.count)
    }()

    /// Stops with a message when `R` isn't registered, which is a programmer error.
    private func checkRegistered<R: Record>(_ type: R.Type) {
        guard let registered = types[R.recordType], ObjectIdentifier(registered) == ObjectIdentifier(R.self) else {
            preconditionFailure(
                "'\(R.recordType)' isn't registered with this container. Pass it, or a type that refers to it, to RecordContainer(for:)."
            )
        }
    }

    /// Whether `row` exists and holds every value in `values`.
    nonisolated static func matches(_ row: [String: SQLValue]?, _ values: [String: SQLValue]) -> Bool {
        guard let row else { return false }
        return values.allSatisfy { row[$0.key] == $0.value }
    }
}

/// One record's identity in the database: its type, name, and zone.
struct RecordKey: Hashable, Sendable {
    let recordType: CKRecord.RecordType
    let name: String
    let zone: Zone

    /// The values for `Database.named`, in order.
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
    var recordID: UUID { record.uuid }

    /// Where the record is kept: its type, its ID and its zone.
    var key: RecordKey {
        RecordKey(recordType: type(of: record).recordType, name: recordID.uuidString, zone: zone)
    }

    var schema: RecordSchema { type(of: record).schema }

    /// Every field's column value, by field key.
    var values: [String: SQLValue] { record.columnValues() }

    /// `base`'s column values, by field key.
    var originalValues: [String: SQLValue]? { base?.columnValues() }

    /// The edit's links by name.
    var links: [(String, [String: SQLValue])] { Self.linkRows(of: record) }

    /// `base`'s links by name, or `nil` when there is no base.
    var originalLinks: [(String, [String: SQLValue])]? { base.map { Self.linkRows(of: $0) } }

    /// `draft` laid over `saved`: each field and owned link the draft changed from `original`
    /// replaces the saved one. The `from:` sides, which the record doesn't own, come from
    /// `saved`. A record of another type, or one that can't be read back, reads as the draft.
    fileprivate static func merged<R: Record>(_ draft: R, over saved: any Record, original: any Record) -> any Record {
        guard let saved = saved as? R, let original = original as? R else { return draft }
        var row = saved.columnValues()
        let originalValues = original.columnValues()
        for (field, value) in draft.columnValues() where originalValues[field] != value {
            row[field] = value
        }

        var links = Dictionary(linkRows(of: saved), uniquingKeysWith: { first, _ in first })
        let originalLinks = Dictionary(linkRows(of: original), uniquingKeysWith: { first, _ in first })
        let draftLinks = linkRows(of: draft)
        let kept = Set(draftLinks.map(\.0))
        for name in originalLinks.keys where !kept.contains(name) {
            links[name] = nil
        }
        for (name, values) in draftLinks where !RecordContext.matches(originalLinks[name], values) {
            links[name] = (links[name] ?? [:]).merging(values) { $1 }
        }

        row["_name"] = .text(draft.id.uuidString)
        var graph = RecordGraph()
        for (name, row) in links {
            graph.addLink(row, name: name)
        }
        guard var merged = try? R(from: RecordRow(row)) else { return draft }
        do {
            try graph.load(&merged, depth: 0)
        } catch {
            return draft
        }
        let fromSides = Set(R.schema.references.filter(\.isFrom).map(\.property))
        for (keyPath, property) in R.keyPaths where fromSides.contains(property) {
            // A `from:` side holds only IDs, as an `Owner.ID?` or an `[Owner.ID]`.
            let value = saved[keyPath: keyPath]
            let ids = (value as? [any RawRepresentable<UUID>])?.map(\.rawValue) ?? (value as? any RawRepresentable<UUID>).map { [$0.rawValue] } ?? []
            try? merged.loadReference(property, to: ids, from: graph, depth: 0)
        }
        return merged
    }

    private static func linkRows<R: Record>(of record: R) -> [(String, [String: SQLValue])] {
        record.links().map { link in
            (link.id.uuidString, link.columnValues())
        }
    }
}

