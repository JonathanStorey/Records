import CloudKit
import Foundation

// Fetching with a predicate that reads through references to records, such as
// `$0.album?.artist?.name == "Nova"`. The database narrows the rows as usual. Swift then checks
// each one with the saved records its paths reach loaded.

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
        guard let partial = keyPath as? PartialKeyPath<Self>, let property = keyPaths[partial] else { return nil }
        return schema.references.first { $0.property == property && !$0.isFrom }
    }
}

/// The records a predicate's paths reach, with every link that touches them.
private struct Graph {
    /// The zone every record in the graph is read from.
    let zone: Zone
    var records = RecordGraph()
    /// The names of the records whose links are loaded.
    var linksLoaded: Set<String> = []

    init(zone: Zone) {
        self.zone = zone
    }

    subscript(key: RecordKey) -> RecordRow? {
        get { records[key.recordType, key.name] }
        set { records[key.recordType, key.name] = newValue }
    }

    /// The links that name the record named `name`.
    func links(naming name: String) -> [RecordLink] {
        records.linksByName[name] ?? []
    }
}

private extension RecordLink {
    /// The record name the link holds in `column`, `sourceName` or `targetName`.
    func name(in column: String) -> String? {
        column == "sourceName" ? sourceName : column == "targetName" ? targetName : nil
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
    private var linksRead: [RecordKey: [RecordLink]] = [:]

    init(graph: Graph, traversal: Traversal, infos: PathInfos) {
        self.graph = graph
        self.traversal = traversal
        self.infos = infos
    }

    /// `root` decoded with its traversed references holding records, `traversal.hops` deep, or
    /// `nil` when the graph doesn't hold it.
    func decode<R: Record>(_ type: R.Type, root: RecordKey) throws -> R? {
        guard let row = graph[root] else { return nil }
        var loaded = RecordGraph()
        for node in reachable(from: root) {
            for link in links(readBy: node) { loaded.add(link, from: graph.records) }
            if node != root { loaded[node.recordType, node.name] = graph[node] }
        }
        var record = try R(from: row)
        try loaded.load(&record, depth: traversal.hops)
        return record
    }

    /// The links `node` reads: the ones it owns, and the ones that point at it for its `from:` sides.
    private func links(readBy node: RecordKey) -> [RecordLink] {
        if let links = linksRead[node] { return links }
        let links = graph.links(naming: node.name).filter { link in
            let owns = link.sourceName == node.name && link.sourceType == node.recordType
            let reads = link.targetName == node.name && infos[node.recordType].inverseSources.contains(link.source)
            return owns || reads
        }
        linksRead[node] = links
        return links
    }

    /// `root` and the records it reaches through the traversed references, at most `hops` deep.
    private func reachable(from root: RecordKey) -> [RecordKey] {
        var found: [RecordKey] = [root]
        var seen: Set<RecordKey> = [root]
        var frontier = [root]
        for _ in 0..<traversal.hops {
            var next: [RecordKey] = []
            for node in frontier {
                for (link, target) in infos[node.recordType].traversed {
                    for record in graph.links(naming: node.name)
                    where record.source == link.source && record.name(in: link.ownName) == node.name {
                        guard let other = record.name(in: link.otherName) else { continue }
                        let key = RecordKey(recordType: target, name: other, zone: graph.zone)
                        if graph[key] != nil, seen.insert(key).inserted {
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

extension RecordContext {
    /// `fetch` for a predicate that reads through references to records.
    func fetch<R: Record>(
        _ descriptor: RecordDescriptor<R>, matching predicate: Predicate<R>, through traversal: Traversal, filter: SQLFilter?
    ) throws -> [R] {
        // The rows the SQL lets through.
        let (matching, values) = Database.matching(zone: zone, filter: filter)
        let rows = try database.rows("SELECT * FROM \(database.quoted(R.recordType)) WHERE \(matching)", values)
        var roots: [RecordKey] = []
        var graph = Graph(zone: zone)
        for row in rows {
            guard case .text(let name) = row["_name"] else { continue }
            let key = RecordKey(recordType: R.recordType, name: name, zone: zone)
            graph[key] = RecordRow(row)
            roots.append(key)
        }
        let infos = PathInfos(types: types, traversal: traversal)
        try load(&graph, from: roots, through: traversal, infos: infos, in: zone)

        // Check each root with the records its paths reach loaded.
        let reader = LoadedReader(graph: graph, traversal: traversal, infos: infos)
        var matches: [(loaded: R, root: RecordKey)] = []
        for root in roots {
            guard let loaded = try reader.decode(R.self, root: root) else { continue }
            if try predicate.evaluate(loaded) { matches.append((loaded, root)) }
        }
        if !descriptor.sortBy.isEmpty {
            let order = descriptor.sortBy
            matches.sort { order.compare($0.loaded, $1.loaded) == .orderedAscending }
        }
        let start = min(max(descriptor.fetchOffset ?? 0, 0), matches.count)
        let end = descriptor.fetchLimit.map { min(start + max($0, 0), matches.count) } ?? matches.count

        // Return records as `fetch` always does, with references holding IDs.
        return try matches[start..<end].map { match in
            guard let row = graph[match.root] else { return match.loaded }
            var record = try R(from: row)
            try graph.records.load(&record, depth: 0)
            return record
        }
    }

    /// `records` with the references `keyPaths` name holding their records, as deep as they
    /// chain. The targets are saved records, read together, one query per type per level. Each
    /// of `records` follows its own references, even ones changed since it was saved. They are
    /// read in `zone`, or the context's `zone` without one.
    func prefetch<R: Record>(_ keyPaths: [AnyKeyPath], into records: [R], in zone: Zone? = nil) throws -> [R] {
        let zone = zone ?? self.zone
        let traversal = Traversal(prefetching: keyPaths, from: R.self)
        guard !traversal.isEmpty, !records.isEmpty else { return records }
        var graph = Graph(zone: zone)
        let roots = records.map { record in
            let node = RecordKey(recordType: R.recordType, name: record.id.uuidString, zone: zone)
            var row = RecordRow(["_name": .text(record.id.uuidString)])
            record.encodeFields(into: &row)
            graph[node] = row
            for link in record.links() { graph.records.add(link) }
            return node
        }
        let infos = PathInfos(types: types, traversal: traversal)
        try load(&graph, from: roots, through: traversal, infos: infos, in: zone, ownLinksGiven: Set(roots))

        let reader = LoadedReader(graph: graph, traversal: traversal, infos: infos)
        return try zip(records, roots).map { record, root in
            try reader.decode(R.self, root: root) ?? record
        }
    }

    /// Loads the records `roots` reach through `traversal`, level by level, with every link
    /// that touches each record loaded. The records in `ownLinksGiven` already hold the links
    /// they own, so their saved ones are left out.
    private func load(
        _ graph: inout Graph, from roots: [RecordKey], through traversal: Traversal, infos: PathInfos,
        in zone: Zone, ownLinksGiven: Set<RecordKey> = []
    ) throws {
        var frontier = roots
        for level in 0...traversal.hops {
            try loadLinks(for: frontier.map(\.name), into: &graph, in: zone, ownLinksGiven: ownLinksGiven)
            guard level < traversal.hops else { break }

            // The records the traversed references of the frontier point at.
            var next: [CKRecord.RecordType: Set<String>] = [:]
            for node in frontier {
                for (link, target) in infos[node.recordType].traversed {
                    for record in graph.links(naming: node.name)
                    where record.source == link.source && record.name(in: link.ownName) == node.name {
                        if let other = record.name(in: link.otherName), graph[RecordKey(recordType: target, name: other, zone: zone)] == nil {
                            next[target, default: []].insert(other)
                        }
                    }
                }
            }

            frontier = []
            for (recordType, names) in next {
                guard types[recordType] != nil else { continue }
                for chunk in Array(names).chunked(400) {
                    let (current, zoneValues) = Database.matching(zone: zone, filter: nil)
                    let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                    let rows = try database.rows(
                        "SELECT * FROM \(database.quoted(recordType)) WHERE \(current) AND \"_name\" IN (\(placeholders))",
                        zoneValues + chunk.map(SQLValue.text)
                    )
                    for row in rows {
                        guard case .text(let name) = row["_name"] else { continue }
                        let node = RecordKey(recordType: recordType, name: name, zone: zone)
                        graph[node] = RecordRow(row)
                        frontier.append(node)
                    }
                }
            }
            if frontier.isEmpty { break }
        }
    }

    /// Loads every saved link that touches the records named `names`, except the links owned by
    /// records in `ownLinksGiven`.
    private func loadLinks(for names: [String], into graph: inout Graph, in zone: Zone, ownLinksGiven: Set<RecordKey>) throws {
        let missing = Array(Set(names).subtracting(graph.linksLoaded))
        guard !missing.isEmpty else { return }
        graph.linksLoaded.formUnion(missing)
        let (current, zoneValues) = Database.matching(zone: zone, filter: nil)
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
                guard case .text(let name) = row["_name"], !Self.isOwned(row, byAnyOf: ownLinksGiven, in: zone) else { continue }
                graph.records.addLink(row, name: name)
            }
        }
    }

    /// Whether the link saved as `link` is owned by one of `records`: its source is that record's
    /// type and name.
    private nonisolated static func isOwned(_ link: [String: SQLValue], byAnyOf records: Set<RecordKey>, in zone: Zone) -> Bool {
        guard !records.isEmpty, case .text(let source) = link["source"], case .text(let sourceName) = link["sourceName"]
        else { return false }
        let sourceType = String(source.split(separator: ".", maxSplits: 1).first ?? "")
        return records.contains(RecordKey(recordType: sourceType, name: sourceName, zone: zone))
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
