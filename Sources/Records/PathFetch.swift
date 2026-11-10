import CloudKit
import Foundation

// Fetching with a predicate that reads through references to records, such as
// `$0.album?.artist?.name == "Nova"`. The database narrows the rows as usual. Swift then checks
// each one with the records its paths reach loaded, read from the database with staged changes
// laid over them, so drafts count at every level.

/// The references to records a predicate reads through.
struct Traversal {
    /// The references, by the record type that declares them and their property.
    private(set) var references: Set<Reference> = []
    /// The most hops a path can take: each hop reads through a closure variable of its own, so
    /// the predicate's variables beyond its input bound it.
    private(set) var hops = 0

    struct Reference: Hashable {
        let recordType: CKRecord.RecordType
        let property: String
    }

    var isEmpty: Bool { references.isEmpty }

    init(_ expression: Any) {
        var variables: Set<PredicateExpressions.VariableID> = []
        walk(expression, variables: &variables, depth: 0)
        hops = max(variables.count - 1, 1)
    }

    private mutating func walk(_ value: Any, variables: inout Set<PredicateExpressions.VariableID>, depth: Int) {
        guard depth < 100, !(value is any ConstantExpression) else { return }
        if let keyPath = value as? AnyKeyPath {
            if let root = type(of: keyPath).rootType as? any Record.Type,
               let reference = root.recordReference(for: keyPath) {
                references.insert(Reference(recordType: root.recordType, property: reference.property))
            }
            return
        }
        if let variable = value as? any PredicateVariable {
            variables.insert(variable.variableKey)
            return
        }
        for child in Mirror(reflecting: value).children {
            walk(child.value, variables: &variables, depth: depth + 1)
        }
    }

    func contains(_ recordType: CKRecord.RecordType, _ property: String) -> Bool {
        references.contains(Reference(recordType: recordType, property: property))
    }
}

extension Record {
    /// The reference `keyPath` reads, when it is one of this type's references that hold records.
    static func recordReference(for keyPath: AnyKeyPath) -> ReferenceSchema? {
        guard let partial = keyPath as? PartialKeyPath<Self>, let property = referenceKeyPaths[partial] else { return nil }
        return schema.references.first { $0.property == property && !$0.holdsIDs }
    }
}

/// A record of any type in the context's zone, by its type and name.
private struct NodeKey: Hashable {
    let recordType: CKRecord.RecordType
    let name: String
}

/// The records a predicate's paths reach, with every link that touches them.
private struct Graph {
    var records: [NodeKey: CKRecord] = [:]
    var linksByName: [String: [CKRecord]] = [:]
    var linksLoaded: Set<String> = []

    /// Adds `link` under each record it names, once.
    mutating func add(link: CKRecord) {
        let name = link.recordID.recordName
        var touched: [String] = []
        if let source = link["sourceName"] as? String { touched.append(source) }
        if let target = link["targetName"] as? String, !touched.contains(target) { touched.append(target) }
        for record in touched where !(linksByName[record]?.contains { $0.recordID.recordName == name } ?? false) {
            linksByName[record, default: []].append(link)
        }
    }
}

/// The context's staged changes in one zone, as the database would hold them after `save()`.
private struct Overlay {
    /// Every staged record, saved or deleted. Its own links in the database no longer count.
    var staged: Set<NodeKey> = []
    /// Staged saves, as records.
    var saved: [NodeKey: CKRecord] = [:]
    /// The links staged saves own.
    var links: [CKRecord] = []

    /// Whether the database's copy of `link` is replaced by a staged change to its source.
    func replaces(_ link: CKRecord) -> Bool {
        guard let source = link["source"] as? String, let sourceName = link["sourceName"] as? String else { return false }
        let sourceType = String(source.split(separator: ".", maxSplits: 1).first ?? "")
        return staged.contains(NodeKey(recordType: sourceType, name: sourceName))
    }
}

extension RecordContext {
    /// `fetch` for a predicate that reads through references to records.
    func fetch<R: Record>(
        _ descriptor: RecordDescriptor<R>, matching predicate: Predicate<R>, through traversal: Traversal, filter: SQLFilter?
    ) throws -> [R] {
        let overlay = overlay()

        // The rows the SQL lets through, with staged records of `R` in place of their rows.
        let (matching, values) = Self.matching(zone: zone, filter: filter)
        let rows = try database.rows("SELECT * FROM \(database.quoted(R.recordType)) WHERE \(matching)", values)
        var roots: [NodeKey] = []
        var graph = Graph()
        for row in rows {
            guard case .text(let name) = row["_name"] else { continue }
            let key = NodeKey(recordType: R.recordType, name: name)
            guard !overlay.staged.contains(key) else { continue }
            graph.records[key] = R.schema.record(from: row, name: name, zone: zone)
            roots.append(key)
        }
        for key in stagedKeys(R.self) {
            let node = NodeKey(recordType: R.recordType, name: key.name)
            if let record = overlay.saved[node] {
                graph.records[node] = record
                roots.append(node)
            }
        }
        try load(&graph, from: roots, through: traversal, overlay: overlay)

        // Check each root with the records its paths reach loaded.
        let decoder = CKRecordDecoder()
        var matches: [(loaded: R, root: NodeKey)] = []
        for root in roots {
            guard let record = graph.records[root] else { continue }
            let reached = reachable(from: root, in: graph, through: traversal)
            var seen: Set<String> = []
            let links = reached.flatMap { graph.linksByName[$0.name] ?? [] }.filter { seen.insert($0.recordID.recordName).inserted }
            let targets = reached.filter { $0 != root }.compactMap { graph.records[$0] }
            let loaded = try decoder.decode(R.self, from: record, links: links, targets: targets, depth: traversal.hops)
            if try predicate.evaluate(loaded) { matches.append((loaded, root)) }
        }

        if !descriptor.sortBy.isEmpty {
            let order = descriptor.sortBy
            matches.sort { order.compare($0.loaded, $1.loaded) == .orderedAscending }
        }
        let start = min(max(descriptor.fetchOffset ?? 0, 0), matches.count)
        let end = descriptor.fetchLimit.map { min(start + max($0, 0), matches.count) } ?? matches.count

        // Return records as `fetch` always does: staged as staged, saved with references holding IDs.
        return try matches[start..<end].map { match in
            if let change = staged[RecordKey(recordType: R.recordType, name: match.root.name, zone: zone)],
               let record = change.record as? R {
                return record
            }
            guard let record = graph.records[match.root] else { return match.loaded }
            return try decoder.decode(R.self, from: record, links: graph.linksByName[match.root.name] ?? [], depth: 0)
        }
    }

    /// The staged changes in the current zone.
    private func overlay() -> Overlay {
        var overlay = Overlay()
        let encoder = CKRecordEncoder()
        for key in stagedOrder where key.zone == zone {
            guard let change = staged[key] else { continue }
            let node = NodeKey(recordType: key.recordType, name: key.name)
            overlay.staged.insert(node)
            if change.kind == .save {
                overlay.saved[node] = encoder.encode(change.record, in: zone)
                overlay.links += encoder.links(for: change.record, in: zone)
            }
        }
        return overlay
    }

    /// Loads the records `roots` reach through `traversal`, level by level, with every link
    /// that touches each record loaded.
    private func load(_ graph: inout Graph, from roots: [NodeKey], through traversal: Traversal, overlay: Overlay) throws {
        var frontier = roots
        for level in 0...traversal.hops {
            try loadLinks(for: frontier.map(\.name), into: &graph, overlay: overlay)
            guard level < traversal.hops else { break }

            // The records the traversed references of the frontier point at.
            var next: [CKRecord.RecordType: Set<String>] = [:]
            for node in frontier {
                for (link, target) in traversedLinks(of: node, through: traversal) {
                    for record in graph.linksByName[node.name] ?? []
                    where record["source"] as? String == link.source && record[link.ownName] as? String == node.name {
                        if let other = record[link.otherName] as? String, graph.records[NodeKey(recordType: target, name: other)] == nil {
                            next[target, default: []].insert(other)
                        }
                    }
                }
            }

            frontier = []
            for (recordType, names) in next {
                guard let type = types[recordType] else { continue }
                for name in names where overlay.staged.contains(NodeKey(recordType: recordType, name: name)) {
                    let node = NodeKey(recordType: recordType, name: name)
                    if let record = overlay.saved[node] {
                        graph.records[node] = record
                        frontier.append(node)
                    }
                }
                let saved = names.filter { !overlay.staged.contains(NodeKey(recordType: recordType, name: $0)) }
                for chunk in Array(saved).chunked(400) {
                    let (current, zoneValues) = Self.matching(zone: zone, filter: nil)
                    let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                    let rows = try database.rows(
                        "SELECT * FROM \(database.quoted(recordType)) WHERE \(current) AND \"_name\" IN (\(placeholders))",
                        zoneValues + chunk.map(SQLValue.text)
                    )
                    for row in rows {
                        guard case .text(let name) = row["_name"] else { continue }
                        let node = NodeKey(recordType: recordType, name: name)
                        graph.records[node] = type.schema.record(from: row, name: name, zone: zone)
                        frontier.append(node)
                    }
                }
            }
            if frontier.isEmpty { break }
        }
    }

    /// Loads every link that touches the records named `names`, with staged links in place of
    /// the saved links of staged records.
    private func loadLinks(for names: [String], into graph: inout Graph, overlay: Overlay) throws {
        let missing = Array(Set(names).subtracting(graph.linksLoaded))
        guard !missing.isEmpty else { return }
        graph.linksLoaded.formUnion(missing)
        let (current, zoneValues) = Self.matching(zone: zone, filter: nil)
        for chunk in missing.chunked(400) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let values = chunk.map(SQLValue.text)
            let rows = try database.rows(
                """
                SELECT * FROM \(database.quoted(RecordLink.recordType)) WHERE \(current) \
                AND ("sourceName" IN (\(placeholders)) OR "targetName" IN (\(placeholders)))
                """,
                zoneValues + values + values
            )
            for row in rows {
                guard case .text(let name) = row["_name"] else { continue }
                let link = RecordLink.schema.record(from: row, name: name, zone: zone)
                if !overlay.replaces(link) { graph.add(link: link) }
            }
        }
        let wanted = Set(missing)
        for link in overlay.links {
            let source = link["sourceName"] as? String, target = link["targetName"] as? String
            if source.map(wanted.contains) == true || target.map(wanted.contains) == true { graph.add(link: link) }
        }
    }

    /// The traversed references `node`'s type declares, with the type each one reaches.
    private func traversedLinks(of node: NodeKey, through traversal: Traversal) -> [(PredicateTranslator.Link, CKRecord.RecordType)] {
        guard let type = types[node.recordType] else { return [] }
        return type.schema.references.compactMap { reference in
            guard traversal.contains(node.recordType, reference.property) else { return nil }
            return (PredicateTranslator.Link(reference, of: node.recordType), reference.target.recordType)
        }
    }

    /// `root` and the records it reaches through `traversal`, at most `traversal.hops` deep.
    private func reachable(from root: NodeKey, in graph: Graph, through traversal: Traversal) -> [NodeKey] {
        var found: [NodeKey] = [root]
        var seen: Set<NodeKey> = [root]
        var frontier = [root]
        for _ in 0..<traversal.hops {
            var next: [NodeKey] = []
            for node in frontier {
                for (link, target) in traversedLinks(of: node, through: traversal) {
                    for record in graph.linksByName[node.name] ?? []
                    where record["source"] as? String == link.source && record[link.ownName] as? String == node.name {
                        guard let other = record[link.otherName] as? String else { continue }
                        let key = NodeKey(recordType: target, name: other)
                        if graph.records[key] != nil, seen.insert(key).inserted {
                            found.append(key)
                            next.append(key)
                        }
                    }
                }
            }
            frontier = next
        }
        return found
    }
}

extension Array {
    /// The array in consecutive pieces of at most `size` elements.
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}

extension Sequence {
    /// How two values compare under every descriptor in turn.
    fileprivate func compare<Compared>(_ lhs: Compared, _ rhs: Compared) -> ComparisonResult
    where Element == SortDescriptor<Compared> {
        for descriptor in self {
            let result = descriptor.compare(lhs, rhs)
            if result != .orderedSame { return result }
        }
        return .orderedSame
    }
}
