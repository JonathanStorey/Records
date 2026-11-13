import CloudKit

/// Saved records and the links between them, which references load their targets from. Used by
/// the code `@Record` generates.
///
/// A record reads its references from the links that name it: the ones it owns, and the ones
/// that point at it for its `@Reference(from:)` sides. A reference that holds records finds its
/// targets' rows here.
@_documentation(visibility: internal)
public struct RecordGraph {
    /// Each record's row, by `key(_:_:)`.
    private var rows: [String: RecordRow] = [:]
    /// Each link, under the name of each record it names.
    private(set) var linksByName: [String: [RecordLink]] = [:]
    /// The file each asset was downloaded to, by asset ID, for assets read from a `CKRecord`.
    private var assetFiles: [String: URL] = [:]
    private var linkIDs: Set<UUID> = []

    init() {}

    // MARK: Building

    /// The row of the record of type `recordType` named `name`.
    subscript(recordType: CKRecord.RecordType, name: String) -> RecordRow? {
        get { rows[Self.key(recordType, name)] }
        set { rows[Self.key(recordType, name)] = newValue }
    }

    /// Adds `link` under each record it names, once.
    mutating func add(_ link: RecordLink) {
        guard linkIDs.insert(link.uuid).inserted else { return }
        linksByName[link.sourceName, default: []].append(link)
        if let target = link.targetName, target != link.sourceName {
            linksByName[target, default: []].append(link)
        }
    }

    /// Adds the link saved as `row`, named `name`. A row that can't be read is skipped.
    mutating func addLink(_ row: [String: SQLValue], name: String) {
        var row = RecordRow(row)
        row.values["_name"] = .text(name)
        guard let link = try? RecordLink(from: row) else { return }
        add(link)
    }

    /// A graph of `records` and `links` as CloudKit returns them. Each record is read as `root`
    /// or the type one of its references points at, and records of other types are left out.
    /// Links that can't be read are skipped.
    init(records: [CKRecord], links: [CKRecord], reachableFrom root: any Record.Type) throws {
        let decoder = CKRecordDecoder()
        for record in links where record.recordType == RecordLink.recordType {
            guard let row = try? decoder.decode(record, of: RecordLink.self), let link = try? RecordLink(from: row)
            else { continue }
            add(link)
            if let assetID = link.assetID, let file = (record[RecordLink.assetKey] as? CKAsset)?.fileURL {
                assetFiles[assetID] = file
            }
        }
        var types: [CKRecord.RecordType: any Record.Type] = [root.recordType: root]
        for reference in root.schema.references {
            types[reference.target.recordType] = reference.target
        }
        for record in records {
            guard let type = types[record.recordType] else { continue }
            self[record.recordType, record.recordID.recordName] = try decoder.decode(record, of: type)
        }
    }

    private static func key(_ recordType: CKRecord.RecordType, _ name: String) -> String {
        recordType + "/" + name
    }

    // MARK: Reading

    /// The record of type `T` with `id`, with its references holding records `depth` levels deep,
    /// or `nil` when the graph doesn't hold it.
    func record<T: Record>(_ type: T.Type, id: UUID, depth: Int) throws -> T? {
        guard let row = self[T.recordType, id.uuidString] else { return nil }
        var record = try T(from: row)
        try load(&record, depth: depth)
        return record
    }

    /// Fills `record`'s `@Reference` and `@Asset` properties from the links that name it.
    ///
    /// A reference that holds records is filled from the graph's rows, `depth` levels deep. With
    /// 0, every reference holds only IDs. A to-many reference sorts its targets by ID.
    func load<R: Record>(_ record: inout R, depth: Int) throws {
        let name = record.id.uuidString
        var byProperty: [String: [UUID]] = [:]
        for link in linksByName[name] ?? [] {
            let property = String(link.sourceProperty)
            let ownsLink = link.sourceName == name && link.sourceType == R.recordType
            // An `@Asset`'s link: this record is its source.
            if let assetID = link.assetID {
                if ownsLink {
                    record.loadAsset(property, id: UUID(uuidString: assetID), file: assetFiles[assetID])
                }
                continue
            }
            // The owning side: this record is the link's source.
            if ownsLink, let targetID = link.targetName.flatMap(UUID.init(uuidString:)) {
                byProperty[property, default: []].append(targetID)
            }
            // The `@Reference(from:)` side: this record is the link's target, and its type names
            // the owner's property as an inverse.
            if link.targetName == name,
               let inverse = R.schema.reference(from: String(link.sourceType), property),
               let sourceID = UUID(uuidString: link.sourceName) {
                byProperty[inverse.property, default: []].append(sourceID)
            }
        }

        for (property, ids) in byProperty {
            try record.loadReference(property, to: ids, from: self, depth: depth)
        }
    }
}
