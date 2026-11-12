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
    @Reference(from: \User.profile, deleteSelf: true) var userID: UUID?
}

@Record
struct Account: Equatable {
    var id: UUID
    @Reference var settings: Settings?
}

@Record
struct Settings: Equatable {
    var id: UUID
    @Reference(from: \Account.settings) var accountID: UUID?
}

/// A one-way to-one: the crest has no `from:` side.
@Record
struct Team: Equatable {
    var id: UUID
    @Reference var crest: Crest?
}

@Record
struct Crest: Equatable {
    var id: UUID
    @Reference(from: \Team.crest, deleteSelf: true) var teamID: UUID?
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
    Profile(id: UUID(), bio: "Engineer", userID: nil)
}

// MARK: - Links

@Test func owningSideWritesAOneToOneLink() throws {
    let profile = makeProfile()
    let user = makeUser(with: profile)

    let links = try encoder.links(for: user, in: .records).map(link)
    #expect(links.count == 1)
    let written = try #require(links.first)
    #expect(written.source == "User.profile")
    #expect(written.sourceName == user.id.uuidString)
    #expect(written.targetName == profile.id.uuidString)

    #expect(signatures(of: user) == ["User.profile:Profile <-> Profile.userID:User"])
    #expect(Relationship(user.referenceStates[0]) == .oneToOne)
}

@Test func fromSideWritesNoLinks() {
    let owner = makeUser(with: nil)
    let profile = Profile(id: UUID(), bio: "Engineer", userID: owner.id)
    #expect(profile.userID == owner.id)
    #expect(encoder.links(for: profile, in: .records).isEmpty)
}

@Test func deleteSelfIsDeclaredByTheFromSide() {
    let deleteSelf = { (type: any Record.Type) in type.schema.references.filter(\.deleteSelf).map(\.property) }
    #expect(deleteSelf(Profile.self) == ["userID"])
    #expect(deleteSelf(User.self).isEmpty)
    #expect(deleteSelf(Settings.self).isEmpty)
}

@Test func theOwnerFindsItsInverseOnTheTarget() {
    let profile = User.schema.inverse(of: "profile", in: Profile.self)
    #expect(profile?.property == "userID")
    #expect(profile?.deleteSelf == true)
    #expect(Account.schema.inverse(of: "settings", in: Settings.self)?.property == "accountID")
    #expect(Account.schema.inverse(of: "settings", in: Settings.self)?.deleteSelf == false)
    #expect(User.schema.inverse(of: "bio", in: Profile.self) == nil)
    #expect(Account.schema.inverse(of: "profile", in: Profile.self) == nil)
    #expect(Profile.schema.inverse(of: "userID", in: User.self) == nil)

    let state = makeUser(with: nil).referenceStates.first
    #expect(state?.inverse?.property == "userID")
    #expect(state?.inverse?.deleteSelf == true)
}

@Test func addingAnInverseKeepsToOneLinkIDs() {
    let sourceID = UUID()
    let twoWay = makeUser(with: nil).referenceStates[0]
    let oneWay = ReferenceState(schema: twoWay.schema, inverse: nil, ids: [], records: [])
    #expect(twoWay.inverse != nil)
    #expect(
        RecordLink.id(reference: oneWay, sourceType: "User", sourceID: sourceID, targetID: UUID())
            == RecordLink.id(reference: twoWay, sourceType: "User", sourceID: sourceID, targetID: UUID())
    )
}

// MARK: - Round trip

@Test func bothSidesDecodeFromTheSameLink() throws {
    let profile = makeProfile()
    let user = makeUser(with: profile)
    let links = encoder.links(for: user, in: .records)
    let records = [encoder.encode(user, in: .records), encoder.encode(profile, in: .records)]

    let userAgain = try decoder.decode(User.self, from: records[0], links: links, targets: records)
    #expect(userAgain.profile?.bio == "Engineer")
    #expect(userAgain.profile?.userID == user.id)

    let profileAgain = try decoder.decode(Profile.self, from: records[1], links: links, targets: records)
    #expect(profileAgain.userID == user.id)
    #expect(encoder.links(for: profileAgain, in: .records).isEmpty)
}

@Test func idFormsDecodeOnBothSides() throws {
    let settings = Settings(id: UUID(), accountID: nil)
    let account = Account(id: UUID(), settings: settings)
    let links = encoder.links(for: account, in: .records)
    #expect(try links.map { try link($0).source } == ["Account.settings"])
    #expect(signatures(of: account) == ["Account.settings:Settings <-> Settings.accountID:Account"])

    let settingsAgain = try decoder.decode(Settings.self, from: encoder.encode(settings, in: .records), links: links)
    #expect(settingsAgain.accountID == account.id)

    let accountAgain = try decoder.decode(Account.self, from: encoder.encode(account, in: .records), links: links)
    #expect(accountAgain == account)
    #expect(encoder.changes(for: accountAgain, from: links).isEmpty)
}

@Test func retargetingMovesTheFromSide() throws {
    let first = makeProfile(), second = makeProfile()
    var user = makeUser(with: first)
    let original = encoder.links(for: user, in: .records)

    user._profile.value = second
    let changes = encoder.changes(for: user, from: original)
    let moved = changes.saves
    #expect(moved.map(\.recordID) == original.map(\.recordID))
    #expect(changes.deletes.isEmpty)

    let firstAgain = try decoder.decode(Profile.self, from: encoder.encode(first, in: .records), links: moved)
    let secondAgain = try decoder.decode(Profile.self, from: encoder.encode(second, in: .records), links: moved)
    #expect(firstAgain.userID == nil)
    #expect(secondAgain.userID == user.id)
}

@Test func clearingTheOwnerDeletesTheLink() throws {
    let profile = makeProfile()
    var user = makeUser(with: profile)
    let original = encoder.links(for: user, in: .records)

    user._profile.value = nil
    let changes = encoder.changes(for: user, from: original)
    #expect(changes.saves.isEmpty)
    #expect(changes.deletes == original.map(\.recordID))
}

@Test func recordOwnerWithIDFromSide() throws {
    let crest = Crest(id: UUID(), teamID: nil)
    let team = Team(id: UUID(), crest: crest)
    let teamLinks = encoder.links(for: team, in: .records)
    #expect(try teamLinks.map { try link($0).source } == ["Team.crest"])
    #expect(signatures(of: team) == ["Team.crest:Crest <-> Crest.teamID:Team"])
    let crestAgain = try decoder.decode(Crest.self, from: encoder.encode(crest, in: .records), links: teamLinks)
    #expect(crestAgain.teamID == team.id)
}
