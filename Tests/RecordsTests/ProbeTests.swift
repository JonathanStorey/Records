import Records
import Testing

struct ProbeA {
    @Probe(\ProbeB.aID) var bID: UUID?
}

struct ProbeB {
    @ProbeGet(\ProbeA.bID) var aID: UUID?
}

@Record
struct ProbeUser {
    var id: UUID
    @Probe(\ProbeProfile.userID) var profileID: UUID?
}

@Record
struct ProbeProfile {
    var id: UUID
    @ProbeGet(\ProbeUser.profileID) var userID: UUID?
}

@Test func keyPathsAcrossMacroBackedPropertiesCompile() {
    let a = ProbeA(bID: UUID())
    let b = ProbeB(aID: a.bID)
    #expect(b.aID == a.bID)
}
