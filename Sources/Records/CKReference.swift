import CloudKit

extension CKRecord.Reference {
    /// The ID of the record this reference points to.
    public var id: CKRecord.ID { recordID }

    /// `true` when deleting the referenced record also deletes the record that owns this reference.
    public var deleteSelf: Bool { action == .deleteSelf }

    /// Creates a reference to `recordID`, using `.deleteSelf` when `deleteSelf` is `true` and `.none` otherwise.
    public convenience init(recordID: CKRecord.ID, deleteSelf: Bool) {
        self.init(recordID: recordID, action: deleteSelf ? .deleteSelf : .none)
    }
}
