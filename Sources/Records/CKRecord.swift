import CloudKit

extension CKRecord {
    /// When CloudKit last saved this record, read from its system fields.
    /// `nil` for a record that has never reached the server.
    public var lastSynced: Date? { modificationDate }

    /// The record's system fields (record ID, zone, server change tag, dates) archived to `Data`.
    ///
    /// Store this beside the local row. Rebuild the record with `init?(changeTag:)` before sending
    /// changes so CloudKit can detect conflicts.
    public var changeTag: Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    /// Recreates a record, system fields only, from data produced by `changeTag`.
    public convenience init?(changeTag: Data) {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: changeTag) else { return nil }
        unarchiver.requiresSecureCoding = true
        self.init(coder: unarchiver)
    }
}
