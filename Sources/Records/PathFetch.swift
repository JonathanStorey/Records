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

    /// The references `keyPaths` name, each on its own record type, for prefetching from `R`.
    /// The hops are as many as the named references chain from `R`, so `[\Review.album,
    /// \Album.artist]` takes two. A chain that loops takes at most one hop per reference.
    init<R: Record>(prefetching keyPaths: [AnyKeyPath], from _: R.Type) {
        var targets: [CKRecord.RecordType: [any Record.Type]] = [:]
        for keyPath in keyPaths {
            guard let root = type(of: keyPath).rootType as? any Record.Type,
                  let reference = root.recordReference(for: keyPath)
            else { continue }
            if references.insert(Reference(recordType: root.recordType, property: reference.property)).inserted {
                targets[root.recordType, default: []].append(reference.target)
            }
        }
        var frontier: Set<CKRecord.RecordType> = [R.recordType]
        while hops < references.count {
            let next = Set(frontier.flatMap { targets[$0] ?? [] }.map { $0.recordType })
            guard !next.isEmpty else { break }
            hops += 1
            frontier = next
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
    private var linkNames: Set<String> = []

    /// Adds `link` under each record it names, once.
    mutating func add(link: CKRecord) {
        guard linkNames.insert(link.recordID.recordName).inserted else { return }
        let source = link["sourceName"] as? String
        if let source { linksByName[source, default: []].append(link) }
        if let target = link["targetName"] as? String, target != source { linksByName[target, default: []].append(link) }
    }
}

/// What loading a path needs to know about one record type, read from its schema once.
private struct PathInfo {
    /// The traversed references the type declares, with the type each one reaches.
    let traversed: [(link: PredicateTranslator.Link, target: CKRecord.RecordType)]
    /// The `source` of every link the type reads from the target end, for its `from:` sides.
    let inverseSources: Set<String>
}

/// `PathInfo` by record type, filled as types come up.
private final class PathInfos {
    private let types: [CKRecord.RecordType: any Record.Type]
    private let traversal: Traversal
    private var infos: [CKRecord.RecordType: PathInfo] = [:]

    init(types: [CKRecord.RecordType: any Record.Type], traversal: Traversal) {
        self.types = types
        self.traversal = traversal
    }

    subscript(recordType: CKRecord.RecordType) -> PathInfo {
        if let info = infos[recordType] { return info }
        let references = types[recordType]?.schema.references ?? []
        let info = PathInfo(
            traversed: references.compactMap { reference in
                guard traversal.contains(recordType, reference.property) else { return nil }
                return (PredicateTranslator.Link(reference, of: recordType), reference.target.recordType)
            },
            inverseSources: Set(references.compactMap { reference in
                reference.inverseOf.map { RecordLink.source(type: reference.target.recordType, property: $0) }
            })
        )
        infos[recordType] = info
        return info
    }
}

/// Decodes roots from a loaded graph with the records their traversed references reach. Each
/// record gets only the links it reads, cached per record, so decoding stays proportional to
/// what the references reach.
private final class LoadedReader {
    private let graph: Graph
    private let traversal: Traversal
    private let infos: PathInfos
    private var linksRead: [NodeKey: [CKRecord]] = [:]

    init(graph: Graph, traversal: Traversal, infos: PathInfos) {
        self.graph = graph
        self.traversal = traversal
        self.infos = infos
    }

    /// `root` decoded with its traversed references holding records, `traversal.hops` deep, or
    /// `nil` when the graph doesn't hold it.
    func decode<R: Record>(_ type: R.Type, root: NodeKey) throws -> R? {
        guard let record = graph.records[root] else { return nil }
        let reached = reachable(from: root)
        var seen: Set<String> = []
        let links = reached.flatMap(links(readBy:)).filter { seen.insert($0.recordID.recordName).inserted }
        let targets = reached.filter { $0 != root }.compactMap { graph.records[$0] }
        return try CKRecordDecoder().decode(R.self, from: record, links: links, targets: targets, depth: traversal.hops)
    }

    /// The links `node` reads: the ones it owns, and the ones that point at it for its `from:` sides.
    private func links(readBy node: NodeKey) -> [CKRecord] {
        if let links = linksRead[node] { return links }
        let links = (graph.linksByName[node.name] ?? []).filter { link in
            guard let source = link["source"] as? String else { return false }
            let owns = link["sourceName"] as? String == node.name && source.hasPrefix(node.recordType + ".")
            let reads = link["targetName"] as? String == node.name && infos[node.recordType].inverseSources.contains(source)
            return owns || reads
        }
        linksRead[node] = links
        return links
    }

    /// `root` and the records it reaches through the traversed references, at most `hops` deep.
    private func reachable(from root: NodeKey) -> [NodeKey] {
        var found: [NodeKey] = [root]
        var seen: Set<NodeKey> = [root]
        var frontier = [root]
        for _ in 0..<traversal.hops {
            var next: [NodeKey] = []
            for node in frontier {
                for (link, target) in infos[node.recordType].traversed {
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
        let overlay = try overlay()

        // The rows the SQL lets through, with staged records of `R` in place of their rows.
        let (matching, values) = Self.matching(zone: zone, filter: filter)
        let rows = try database.rows("SELECT * FROM \(database.quoted(R.recordType)) WHERE \(matching)", values)
        var roots: [NodeKey] = []
        var graph = Graph()
        let schema = R.schema
        for row in rows {
            guard case .text(let name) = row["_name"] else { continue }
            let key = NodeKey(recordType: R.recordType, name: name)
            guard !overlay.staged.contains(key) else { continue }
            graph.records[key] = schema.record(from: row, name: name, zone: zone)
            roots.append(key)
        }
        for key in changedKeys(R.recordType) {
            let node = NodeKey(recordType: R.recordType, name: key.name)
            if let record = overlay.saved[node] {
                graph.records[node] = record
                roots.append(node)
            }
        }
        let infos = PathInfos(types: types, traversal: traversal)
        try load(&graph, from: roots, through: traversal, infos: infos, overlay: overlay)

        // Check each root with the records its paths reach loaded.
        let reader = LoadedReader(graph: graph, traversal: traversal, infos: infos)
        var matches: [(loaded: R, root: NodeKey)] = []
        for root in roots {
            guard let loaded = try reader.decode(R.self, root: root) else { continue }
            if try predicate.evaluate(loaded) { matches.append((loaded, root)) }
        }
        let decoder = CKRecordDecoder()

        if !descriptor.sortBy.isEmpty {
            let order = descriptor.sortBy
            matches.sort { order.compare($0.loaded, $1.loaded) == .orderedAscending }
        }
        let start = min(max(descriptor.fetchOffset ?? 0, 0), matches.count)
        let end = descriptor.fetchLimit.map { min(start + max($0, 0), matches.count) } ?? matches.count

        // Return records as `fetch` always does, with references holding IDs.
        return try matches[start..<end].map { match in
            guard let record = graph.records[match.root] else { return match.loaded }
            return try decoder.decode(R.self, from: record, links: graph.linksByName[match.root.name] ?? [], depth: 0)
        }
    }

    /// `records` with the references `keyPaths` name holding their records, as deep as they
    /// chain. The targets are read together, one query per type per level, with staged changes
    /// laid over them.
    func prefetch<R: Record>(_ keyPaths: [AnyKeyPath], into records: [R]) throws -> [R] {
        let traversal = Traversal(prefetching: keyPaths, from: R.self)
        guard !traversal.isEmpty, !records.isEmpty else { return records }
        let overlay = try overlay()
        let encoder = CKRecordEncoder()
        var graph = Graph()
        let roots = records.map { record in
            let node = NodeKey(recordType: R.recordType, name: record.id.uuidString)
            graph.records[node] = encoder.encode(record, in: zone)
            return node
        }
        let infos = PathInfos(types: types, traversal: traversal)
        try load(&graph, from: roots, through: traversal, infos: infos, overlay: overlay)

        let reader = LoadedReader(graph: graph, traversal: traversal, infos: infos)
        return try zip(records, roots).map { record, root in
            try reader.decode(R.self, root: root) ?? record
        }
    }

    /// The staged changes in the current zone, each draft laid over its latest saved record.
    private func overlay() throws -> Overlay {
        var overlay = Overlay()
        let encoder = CKRecordEncoder()
        for key in changedKeys() {
            guard let change = changed(key) else { continue }
            let node = NodeKey(recordType: key.recordType, name: key.name)
            overlay.staged.insert(node)
            if let record = try draftRecord(change, key: key) {
                overlay.saved[node] = encoder.encode(record, in: zone)
                overlay.links += encoder.links(for: record, in: zone)
            }
        }
        return overlay
    }

    /// Loads the records `roots` reach through `traversal`, level by level, with every link
    /// that touches each record loaded.
    private func load(
        _ graph: inout Graph, from roots: [NodeKey], through traversal: Traversal, infos: PathInfos, overlay: Overlay
    ) throws {
        var frontier = roots
        for level in 0...traversal.hops {
            try loadLinks(for: frontier.map(\.name), into: &graph, overlay: overlay)
            guard level < traversal.hops else { break }

            // The records the traversed references of the frontier point at.
            var next: [CKRecord.RecordType: Set<String>] = [:]
            for node in frontier {
                for (link, target) in infos[node.recordType].traversed {
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
                guard let schema = types[recordType]?.schema else { continue }
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
                        graph.records[node] = schema.record(from: row, name: name, zone: zone)
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
        let linkSchema = RecordLink.schema
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
                let link = linkSchema.record(from: row, name: name, zone: zone)
                if !overlay.replaces(link) { graph.add(link: link) }
            }
        }
        let wanted = Set(missing)
        for link in overlay.links {
            let source = link["sourceName"] as? String, target = link["targetName"] as? String
            if source.map(wanted.contains) == true || target.map(wanted.contains) == true { graph.add(link: link) }
        }
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
