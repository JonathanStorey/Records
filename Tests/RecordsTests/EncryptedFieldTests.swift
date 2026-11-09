import CloudKit
import Records
import Testing

@Record
struct Vault: Equatable {
    var id: UUID
    var name: String
    @Encrypted var secret: String
    @Encrypted var pin: Int?
    @Encrypted var codes: [String]
}

@Test func encryptedFieldsAreWrittenToEncryptedValues() {
    let vault = Vault(id: UUID(), name: "Home", secret: "s3cret", pin: 1234, codes: ["a", "b"])
    let record = CKRecordEncoder().encode(vault, in: .records)

    #expect(record["name"] as? String == "Home")
    #expect(record.encryptedValues["secret"] as? String == "s3cret")
    #expect(record.encryptedValues["pin"] as? Int == 1234)
    #expect(record.encryptedValues["codes"] as? [String] == ["a", "b"])
    #expect(record["secret"] == nil)
}

@Test func encryptedFieldsRoundTrip() throws {
    let vault = Vault(id: UUID(), name: "Home", secret: "s3cret", pin: nil, codes: [])
    let decoded = try CKRecordDecoder().decode(Vault.self, from: CKRecordEncoder().encode(vault, in: .records))
    #expect(decoded == vault)
    #expect(!decoded.hasChanges)
}

@Test func changedEncryptedFieldsAreWrittenAlone() throws {
    let record = CKRecordEncoder().encode(Vault(id: UUID(), name: "Home", secret: "a", pin: 1, codes: []), in: .records)
    var vault = try CKRecordDecoder().decode(Vault.self, from: record)
    record.encryptedValues["pin"] = 2   // another device changed the pin

    vault.secret = "b"
    try CKRecordEncoder().encode(vault, into: record)

    #expect(record.encryptedValues["secret"] as? String == "b")
    #expect(record.encryptedValues["pin"] as? Int == 2)
}
