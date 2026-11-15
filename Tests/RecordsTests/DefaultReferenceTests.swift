import Testing
@testable import Records

// References that start empty with `= nil` or `= []`, so the memberwise initializer can leave
// them out.

@Record
struct Drawer {
    var label: String
    @Reference var socks: [Sock] = []
    @Reference var lid: Lid? = nil
}

@Record
struct Sock {
    var color: String
    @Reference(from: \Drawer.socks) var drawerID: Drawer.ID? = nil
}

@Record
struct Lid {
    var shape: String
    @Reference(from: \Drawer.lid) var drawerIDs: [Drawer.ID] = []
}

@Test func referencesThatStartEmptyCanBeLeftOut() {
    let drawer = Drawer(label: "Top")
    #expect(drawer.socks.isEmpty)
    #expect(drawer.lid == nil)
    #expect(Sock(color: "Red").drawerID == nil)
    #expect(Lid(shape: "Round").drawerIDs.isEmpty)
}

@Test func aReferenceThatStartsEmptyCanStillBeGiven() {
    let sock = Sock(color: "Red")
    let drawer = Drawer(label: "Top", socks: [sock])
    #expect(drawer.$socks.ids == [sock.id])
    #expect(drawer.lid == nil)
}

@MainActor
@Test func referencesThatStartEmptySaveAndLoad() throws {
    let context = try RecordContainer(for: Drawer.self, sync: .inMemory).mainContext
    let sock = Sock(color: "Red")
    let lid = Lid(shape: "Round")
    let drawer = Drawer(label: "Top", socks: [sock], lid: lid)
    context.insert(drawer)
    try context.save()

    #expect(try context.record(id: drawer.id)?.$socks.ids == [sock.id])
    #expect(try context.record(id: sock.id)?.drawerID == drawer.id)
    #expect(try context.record(id: lid.id)?.drawerIDs == [drawer.id])
}
