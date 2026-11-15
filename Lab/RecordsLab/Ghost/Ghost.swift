@preconcurrency import CloudKit
import Records

/// Another device, played by the Lab. It reads and writes the app's records in iCloud directly
/// with CloudKit, and builds them with Records' public encoder, so what it writes matches what a
/// device running Records sends. It works in the Lab zone, so the seeded catalog is never touched.
///
/// CloudKit doesn't push a change to the device that made it, so the app sees the ghost's
/// changes when it fetches, as `refresh()` does.
@MainActor
struct Ghost {
    /// The zone every sync scenario works in.
    static let zone: Zone = "Lab"

    private let database = CKContainer.default().privateCloudDatabase
    private let encoder = CKRecordEncoder()
    private let decoder = CKRecordDecoder()

    // MARK: Reading

    /// The server's ID for `record` in the Lab zone.
    func id(of record: some Record) -> CKRecord.ID {
        CKRecord.ID(recordName: record.id.rawValue.uuidString, zoneID: Self.zone.zoneID)
    }

    /// The server's IDs for the links `record`'s references and assets write.
    func linkIDs(of record: some Record) -> [CKRecord.ID] {
        encoder.links(for: record, in: Self.zone).map(\.recordID)
    }

    /// The server's IDs for the links that carry `record`'s assets.
    func assetLinkIDs(of record: some Record) -> [CKRecord.ID] {
        encoder.links(for: record, in: Self.zone).filter { $0["assetID"] != nil }.map(\.recordID)
    }

    /// A new server record for `record` in the Lab zone, as the encoder writes it.
    func encode(_ record: some Record) -> CKRecord {
        encoder.encode(record, in: Self.zone)
    }

    /// The server's copies of the records with `ids` that exist. A record or zone that doesn't
    /// exist is left out, and any other error throws.
    func fetch(_ ids: [CKRecord.ID]) async throws -> [CKRecord.ID: CKRecord] {
        guard !ids.isEmpty else { return [:] }
        let results: [CKRecord.ID: Result<CKRecord, any Error>]
        do {
            results = try await database.records(for: ids)
        } catch let error as CKError where error.code == .zoneNotFound {
            return [:]
        }
        var found: [CKRecord.ID: CKRecord] = [:]
        for (id, result) in results {
            switch result {
            case .success(let record): found[id] = record
            case .failure(let error as CKError) where error.code == .unknownItem || error.code == .zoneNotFound: continue
            case .failure(let error): throw error
            }
        }
        return found
    }

    /// The server's copy of the record with `id`, or `nil` when there is none.
    func fetch(_ id: CKRecord.ID) async throws -> CKRecord? {
        try await fetch([id])[id]
    }

    /// The server's copy of `record`, decoded with its own fields, or `nil` when there is none.
    func copy<R: Record>(of record: R) async throws -> R? {
        try await fetch(id(of: record)).map { try decode(R.self, $0) }
    }

    /// `record` decoded as `type`, with its references and assets read from `links` and its
    /// loaded targets from `targets`, as a device would decode what it fetched.
    func decode<R: Record>(_ type: R.Type, _ record: CKRecord, links: [CKRecord] = [], targets: [CKRecord] = []) throws -> R {
        try decoder.decode(type, from: record, links: links, targets: targets)
    }

    /// Whether `zone` exists on the server.
    func zoneExists(_ zone: Zone) async throws -> Bool {
        do {
            _ = try await database.recordZone(for: zone.zoneID)
            return true
        } catch let error as CKError where error.code == .zoneNotFound {
            return false
        }
    }

    // MARK: Writing

    /// Changes the server's copy of `record` with `change` and saves it as another device would:
    /// every field from the encoder, sent with the server's change tag. Only the record's own
    /// fields change. Its links stay as they are.
    func edit<R: Record>(_ record: R, _ change: (inout R) -> Void) async throws {
        guard let server = try await fetch(id(of: record)) else {
            throw LabFailure(step: "The ghost edits \(R.recordType)", expected: "the server's copy", actual: "none")
        }
        var edited = try decode(R.self, server)
        change(&edited)
        let fresh = encoder.encode(edited, in: Self.zone)
        for field in R.schema.fields {
            if field.isEncrypted {
                let value = fresh.encryptedValues[field.key]
                server.encryptedValues[field.key] = value
            } else {
                let value = fresh[field.key]
                server[field.key] = value
            }
        }
        try await save([server])
    }

    /// Saves the links `record` writes, such as an asset's link after a new value. Each replaces
    /// the server's copy, if there is one.
    func saveLinks(of record: some Record, where include: (CKRecord) -> Bool = { _ in true }) async throws {
        let links = encoder.links(for: record, in: Self.zone).filter(include)
        let servers = try await fetch(links.map(\.recordID))
        try await save(links.map { link in
            guard let server = servers[link.recordID] else { return link }
            for key in Set(server.allKeys()).subtracting(link.allKeys()) { server[key] = nil }
            for key in link.allKeys() {
                let value = link[key]
                server[key] = value
            }
            return server
        })
    }

    /// Saves `records` as they are, checking change tags, so a record the server changed since
    /// it was fetched fails.
    func save(_ records: [CKRecord]) async throws {
        let (saved, _) = try await database.modifyRecords(saving: records, deleting: [], atomically: false)
        for (_, result) in saved {
            if case .failure(let error) = result { throw error }
        }
    }

    /// Deletes `records` and the links they own, as a device running Records does. Records the
    /// server doesn't have are skipped.
    func delete(_ records: [any Record]) async throws {
        try await delete(ids: records.flatMap { [id(of: $0)] + linkIDs(of: $0) })
    }

    /// Deletes the records with `ids`. Records the server doesn't have are skipped.
    func delete(ids: [CKRecord.ID]) async throws {
        guard !ids.isEmpty else { return }
        let (_, deleted) = try await database.modifyRecords(saving: [], deleting: ids, atomically: false)
        for (_, result) in deleted {
            guard case .failure(let error) = result, (error as? CKError)?.code != .unknownItem else { continue }
            throw error
        }
    }

    /// Creates the Lab zone, as another device does before saving to it. An existing zone is kept.
    func createZone() async throws {
        _ = try await database.save(CKRecordZone(zoneID: Self.zone.zoneID))
    }

    /// Deletes the Lab zone with everything in it. A zone that doesn't exist is fine.
    func deleteZone() async throws {
        do {
            _ = try await database.deleteRecordZone(withID: Self.zone.zoneID)
        } catch let error as CKError where error.code == .zoneNotFound {
            return
        }
    }
}
