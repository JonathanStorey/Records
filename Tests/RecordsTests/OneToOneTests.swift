import CloudKit
import Testing
@testable import Records

@Record
struct User: Equatable {
    var id: UUID
    var name: String
    @Reference var profile: Profile?
}

@Record
struct Profile: Equatable {
    var id: UUID
    var bio: String
    @Reference(from: \User.profile, deleteSelf: true) var user: User?
}

@Record
struct Account: Equatable {
    var id: UUID
    @Reference(Settings.self) var settingsID: UUID?
}

@Record
struct Settings: Equatable {
    var id: UUID
    @Reference(from: \Account.settingsID) var accountID: UUID?
}

private let encoder = CKRecordEncoder()
private let decoder = CKRecordDecoder()

private func link(_ record: CKRecord) throws -> RecordLink {
    try decoder.decode(RecordLink.self, from: record)
}

private func makeUser(with profile: Profile?) -> User {
    User(id: UUID(), name: "Ada", profile: profile)
}

private func makeProfile() -> Profile {
    Profile(id: UUID(), bio: "Engineer", user: nil)
}

// MARK: - Links

@Test func owningSideWritesAOneToOneLink() throws {
    let profile = makeProfile()
    let user = makeUser(with: profile)

    let links = try encoder.linksToSave(for: user, in: .records).map(link)
    #expect(links.count == 1)
    let written = try #require(links.first)
    #expect(written.relationship == "User.profile:Profile <-> Profile.user:User")
    #expect(try written.kind == .oneToOne)
    #expect(written.deleteSelf)
    #expect(written.sourceName == user.id.uuidString)
    #expect(written.targetName == profile.id.uuidString)

    let built = try RecordLink.oneToOne(
        from: user, property: "profile", to: Profile.self, id: profile.id, inverse: "user", deleteSelf: true
    )
    #expect(written == built)
}

@Test func fromSideWritesNoLinks() {
    let owner = makeUser(with: nil)
    let profile = Profile(id: UUID(), bio: "Engineer", user: owner)
    #expect(profile.user == owner)
    #expect(encoder.linksToSave(for: profile, in: .records).isEmpty)
    #expect(encoder.linkIDsToDelete(for: profile, in: .records).isEmpty)
}

@Test func deleteSelfIsDeclaredByTheFromSide() {
    #expect(Profile.deleteSelfReferences == ["user"])
    #expect(User.deleteSelfReferences.isEmpty)
    #expect(Settings.deleteSelfReferences.isEmpty)
}

@Test func theOwnerFindsItsInverseOnTheTarget() {
    #expect(Profile.inverse(of: "profile", in: "User") == Inverse(\User.profile, to: Profile.self, property: "user", deleteSelf: true))
    #expect(Settings.inverse(of: "settingsID", in: "Account")?.property == "accountID")
    #expect(Settings.inverse(of: "settingsID", in: "Account")?.deleteSelf == false)
    #expect(Profile.inverse(of: "bio", in: "User") == nil)
    #expect(Profile.inverse(of: "profile", in: "Account") == nil)
    #expect(User.inverse(of: "user", in: "Profile") == nil)

    let state = makeUser(with: nil).referenceStates.first
    #expect(state?.inverse?.property == "user")
    #expect(state?.inverse?.deleteSelf == true)
}

@Test func addingAnInverseKeepsToOneLinkIDs() {
    let sourceID = UUID()
    let oneWay = ReferenceState(
        property: "profile", targetType: "Profile", isToMany: false, inverse: nil, targets: [], loaded: []
    )
    let twoWay = ReferenceState(
        property: "profile", targetType: "Profile", isToMany: false,
        inverse: Inverse(\User.profile, to: Profile.self, property: "user"), targets: [], loaded: []
    )
    #expect(
        RecordLink.id(reference: oneWay, sourceType: "User", sourceID: sourceID, targetID: UUID())
            == RecordLink.id(reference: twoWay, sourceType: "User", sourceID: sourceID, targetID: UUID())
    )
}

// MARK: - Round trip

@Test func bothSidesDecodeFromTheSameLink() throws {
    let profile = makeProfile()
    let user = makeUser(with: profile)
    let links = encoder.linksToSave(for: user, in: .records)
    let records = [encoder.encode(user, in: .records), encoder.encode(profile, in: .records)]

    let userAgain = try decoder.decode(User.self, from: records[0], links: links, targets: records)
    #expect(userAgain.profile?.bio == "Engineer")
    #expect(userAgain.profile?.user == nil) // one level deep
    #expect(userAgain.profile?._user.id == user.id)

    let profileAgain = try decoder.decode(Profile.self, from: records[1], links: links, targets: records)
    #expect(profileAgain.user?.name == "Ada")
    #expect(profileAgain.user?._profile.id == profile.id)
    #expect(encoder.linksToSave(for: profileAgain, in: .records).isEmpty)
}

@Test func idFormsDecodeOnBothSides() throws {
    let settings = Settings(id: UUID(), accountID: nil)
    let account = Account(id: UUID(), settingsID: settings.id)
    let links = encoder.linksToSave(for: account, in: .records)
    #expect(try links.map { try link($0).relationship } == ["Account.settingsID:Settings <-> Settings.accountID:Account"])

    let settingsAgain = try decoder.decode(Settings.self, from: encoder.encode(settings, in: .records), links: links)
    #expect(settingsAgain.accountID == account.id)

    let accountAgain = try decoder.decode(Account.self, from: encoder.encode(account, in: .records), links: links)
    #expect(accountAgain == account)
    #expect(encoder.linksToSave(for: accountAgain, in: .records).isEmpty)
}

@Test func retargetingMovesTheFromSide() throws {
    let first = makeProfile(), second = makeProfile()
    var user = makeUser(with: first)
    let original = encoder.linksToSave(for: user, in: .records)
    user.markReferencesSaved()

    user.profile = second
    let moved = encoder.linksToSave(for: user, in: .records)
    #expect(moved.map(\.recordID) == original.map(\.recordID))
    #expect(encoder.linkIDsToDelete(for: user, in: .records).isEmpty)

    let firstAgain = try decoder.decode(Profile.self, from: encoder.encode(first, in: .records), links: moved)
    let secondAgain = try decoder.decode(Profile.self, from: encoder.encode(second, in: .records), links: moved)
    #expect(firstAgain.user == nil)
    #expect(secondAgain._user.id == user.id)
}

@Test func clearingTheOwnerDeletesTheLink() throws {
    let profile = makeProfile()
    var user = makeUser(with: profile)
    let original = encoder.linksToSave(for: user, in: .records)
    user.markReferencesSaved()

    user.profile = nil
    #expect(encoder.linksToSave(for: user, in: .records).isEmpty)
    #expect(encoder.linkIDsToDelete(for: user, in: .records) == original.map(\.recordID))
}
