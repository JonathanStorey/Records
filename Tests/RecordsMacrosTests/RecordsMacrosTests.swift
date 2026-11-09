import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

#if canImport(RecordsMacros)
import RecordsMacros

private var macroSpecs: [String: MacroSpec] {
    [
        "Record": MacroSpec(type: RecordMacro.self, conformances: ["Record"]),
        "Reference": MacroSpec(type: ReferenceMacro.self),
        "Encrypted": MacroSpec(type: EncryptedMacro.self),
        "Asset": MacroSpec(type: AssetMacro.self),
        "Renamed": MacroSpec(type: RenamedMacro.self),
    ]
}
#endif

final class RecordMacroTests: XCTestCase {
    func testEncodesStoredPropertiesExceptID() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Note {
                var id: UUID
                var title: String
                let isPinned: Bool
                var rating: Int?
                var summary: String {
                    title
                }
                static var shared = 0
                lazy var cache = 0
                let version = 1
                var tags: [String] = []
            }
            """,
            expandedSource: """
            struct Note {
                var id: UUID
                @RecordField
                var title: String
                let isPinned: Bool
                @RecordField
                var rating: Int?
                var summary: String {
                    title
                }
                static var shared = 0
                lazy var cache = 0
                let version = 1
                @RecordField
                var tags: [String] = []
            }

            extension Note: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "Note"
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self._title = try Records.Field(saved: CKRecordDecoder.decode((String).self, forKey: "title", from: record))
                    self.isPinned = try CKRecordDecoder.decode((Bool).self, forKey: "isPinned", from: record)
                    self._rating = try Records.Field(saved: CKRecordDecoder.decodeIfPresent((Int).self, forKey: "rating", from: record))
                    self._tags = try Records.Field(saved: CKRecordDecoder.decodeIfPresent(([String]).self, forKey: "tags", from: record) ?? [])
                }
                func encodeFields(into record: CKRecord) {
                    record["title"] = Records.FieldCoding.value(self.title)
                    record["isPinned"] = Records.FieldCoding.value(self.isPinned)
                    record["rating"] = Records.FieldCoding.value(self.rating)
                    record["tags"] = Records.FieldCoding.value(self.tags)
                }
                var changedFields: Set<String> {
                    var fields: Set<String> = []
                    if self._title.isChanged {
                        fields.insert("title")
                    }
                    if self._rating.isChanged {
                        fields.insert("rating")
                    }
                    if self._tags.isChanged {
                        fields.insert("tags")
                    }
                    return fields
                }
                func encodeChangedFields(into record: CKRecord) {
                    if self._title.isChanged {
                        record["title"] = Records.FieldCoding.value(self.title)
                    }
                    if self._rating.isChanged {
                        record["rating"] = Records.FieldCoding.value(self.rating)
                    }
                    if self._tags.isChanged {
                        record["tags"] = Records.FieldCoding.value(self.tags)
                    }
                }
                mutating func markFieldsSaved() {
                    self._title.markSaved()
                    self._rating.markSaved()
                    self._tags.markSaved()
                }
            }
            """,
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testExplicitNameAndPublicAccess() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record("Folder")
            public struct LegacyFolder {
                public var id: UUID
                public var `default`: Bool
            }
            """,
            expandedSource: """
            public struct LegacyFolder {
                public var id: UUID
                @RecordField
                public var `default`: Bool
            }

            extension LegacyFolder: Records.Record {
                public static var recordType: CKRecord.RecordType {
                    "Folder"
                }
                public init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self._default = try Records.Field(saved: CKRecordDecoder.decode((Bool).self, forKey: "default", from: record))
                }
                public func encodeFields(into record: CKRecord) {
                    record["default"] = Records.FieldCoding.value(self.`default`)
                }
                public var changedFields: Set<String> {
                    var fields: Set<String> = []
                    if self._default.isChanged {
                        fields.insert("default")
                    }
                    return fields
                }
                public func encodeChangedFields(into record: CKRecord) {
                    if self._default.isChanged {
                        record["default"] = Records.FieldCoding.value(self.`default`)
                    }
                }
                public mutating func markFieldsSaved() {
                    self._default.markSaved()
                }
            }
            """,
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testGenericTypeWithName() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record("Box")
            struct Box<Value> {
                var id: UUID
                var value: Optional<Value>
            }
            """,
            expandedSource: """
            struct Box<Value> {
                var id: UUID
                @RecordField
                var value: Optional<Value>
            }

            extension Box: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "Box"
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self._value = try Records.Field(saved: CKRecordDecoder.decodeIfPresent((Value).self, forKey: "value", from: record))
                }
                func encodeFields(into record: CKRecord) {
                    record["value"] = Records.FieldCoding.value(self.value)
                }
                var changedFields: Set<String> {
                    var fields: Set<String> = []
                    if self._value.isChanged {
                        fields.insert("value")
                    }
                    return fields
                }
                func encodeChangedFields(into record: CKRecord) {
                    if self._value.isChanged {
                        record["value"] = Records.FieldCoding.value(self.value)
                    }
                }
                mutating func markFieldsSaved() {
                    self._value.markSaved()
                }
            }
            """,
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testGenericTypeWithoutNameIsAnError() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Box<Value> {
                var id: UUID
            }
            """,
            expandedSource: """
            struct Box<Value> {
                var id: UUID
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Generic types need an explicit record type, e.g. @Record(\"Box\")",
                    line: 1,
                    column: 1
                ),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testInvalidNameIsAnError() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record("My Note")
            struct Note {
                var id: UUID
            }
            """,
            expandedSource: """
            struct Note {
                var id: UUID
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "'My Note' is not a valid record type; use letters, digits, and underscores, starting with a letter",
                    line: 1,
                    column: 1
                ),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testClassIsAnError() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            class Note {
                var id = UUID()
            }
            """,
            expandedSource: """
            class Note {
                var id = UUID()
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Record can only be applied to a struct", line: 1, column: 1),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testMissingTypeAnnotationIsAnError() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Note {
                var id: UUID
                var count = 0
            }
            """,
            expandedSource: """
            struct Note {
                var id: UUID
                var count = 0
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Record property 'count' needs an explicit type annotation", line: 1, column: 1),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testMissingIDIsAnError() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Note {
                var title: String
            }
            """,
            expandedSource: """
            struct Note {
                @RecordField
                var title: String
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Record requires a stored 'id: UUID' property", line: 1, column: 1),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testConstantIDIsAnError() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Note {
                let id = UUID()
            }
            """,
            expandedSource: """
            struct Note {
                let id = UUID()
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Record cannot decode 'id' because it is a 'let' with an initial value; use 'var id = UUID()' or 'let id: UUID'",
                    line: 1,
                    column: 1
                ),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testOptionalArrayIsAnError() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Note {
                var id: UUID
                var tags: [String]?
            }
            """,
            expandedSource: """
            struct Note {
                var id: UUID
                @RecordField
                var tags: [String]?
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "Record does not support an optional array",
                    line: 1,
                    column: 1
                ),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testRecordSkipsReferenceProperties() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Article {
                var id: UUID
                var title: String
                @Reference var author: Person?
            }
            """,
            expandedSource: """
            struct Article {
                var id: UUID
                @RecordField
                var title: String
                var author: Person? {
                    @storageRestrictions(initializes: _author)
                    init(initialValue) {
                        _author = Records.ToOne(initialValue)
                    }
                    get {
                        _author.value
                    }
                    set {
                        _author.value = newValue
                    }
                }

                var _author: Records.ToOne<Person>

                var $author: UUID? {
                    _author.id
                }
            }

            extension Article: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "Article"
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self._title = try Records.Field(saved: CKRecordDecoder.decode((String).self, forKey: "title", from: record))
                    self._author = Records.ToOne(id: nil)
                }
                func encodeFields(into record: CKRecord) {
                    record["title"] = Records.FieldCoding.value(self.title)
                }
                var changedFields: Set<String> {
                    var fields: Set<String> = []
                    if self._title.isChanged {
                        fields.insert("title")
                    }
                    return fields
                }
                func encodeChangedFields(into record: CKRecord) {
                    if self._title.isChanged {
                        record["title"] = Records.FieldCoding.value(self.title)
                    }
                }
                mutating func markFieldsSaved() {
                    self._title.markSaved()
                }
                var referenceStates: [Records.ReferenceState] {
                    [
                        self._author.state(property: "author", owner: Self.recordType),
                    ]
                }
                mutating func loadReference(_ property: String, to targets: [Records.ReferenceTarget], from records: [CKRecord], links: [CKRecord], depth: Int) throws {
                    switch property {
                    case "author":
                        try self._author.load(targets, from: records, links: links, depth: depth)
                    default:
                        break
                    }
                }
                mutating func markReferencesSaved() {
                    self._author.markSaved()
                }
            }
            """,
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testReferenceMustBeOptional() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Note {
                @Reference var author: Person
            }
            """,
            expandedSource: """
            struct Note {
                var author: Person
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Reference to one record must be optional", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testReferenceMustBeVar() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Note {
                @Reference let author: Person?
            }
            """,
            expandedSource: """
            struct Note {
                let author: Person?
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Reference property must be a 'var'", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testReferenceCannotHaveInitialValue() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Note {
                @Reference var author: Person? = nil
            }
            """,
            expandedSource: """
            struct Note {
                var author: Person? = nil
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Reference property cannot have an initial value", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testReferenceToManyMustNotBeOptional() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Note {
                @Reference var tags: [Tag]?
            }
            """,
            expandedSource: """
            struct Note {
                var tags: [Tag]?
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Reference to many records must be a non-optional array", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testRecordWithToManyReferences() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Note {
                var id: UUID
                @Reference var tags: [Tag]
                @Reference(Tag.self) var pinnedIDs: [UUID]
            }
            """,
            expandedSource: """
            struct Note {
                var id: UUID
                var tags: [Tag] {
                    @storageRestrictions(initializes: _tags)
                    init(initialValue) {
                        _tags = Records.ToMany(initialValue)
                    }
                    get {
                        _tags.values
                    }
                    set {
                        _tags.values = newValue
                    }
                }

                var _tags: Records.ToMany<Tag>

                var $tags: [UUID] {
                    _tags.ids
                }
                var pinnedIDs: [UUID] {
                    @storageRestrictions(initializes: _pinnedIDs)
                    init(initialValue) {
                        _pinnedIDs = Records.ToMany(ids: initialValue)
                    }
                    get {
                        _pinnedIDs.ids
                    }
                    set {
                        _pinnedIDs.ids = newValue
                    }
                }

                var _pinnedIDs: Records.ToMany<Tag>
            }

            extension Note: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "Note"
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self._tags = Records.ToMany(ids: [])
                    self._pinnedIDs = Records.ToMany(ids: [])
                }
                func encodeFields(into record: CKRecord) {
                }
                var referenceStates: [Records.ReferenceState] {
                    [
                        self._tags.state(property: "tags", owner: Self.recordType),
                        self._pinnedIDs.state(property: "pinnedIDs", owner: Self.recordType),
                    ]
                }
                mutating func loadReference(_ property: String, to targets: [Records.ReferenceTarget], from records: [CKRecord], links: [CKRecord], depth: Int) throws {
                    switch property {
                    case "tags":
                        try self._tags.load(targets, from: records, links: links, depth: depth)
                    case "pinnedIDs":
                        try self._pinnedIDs.load(targets, from: [], links: [], depth: 0)
                    default:
                        break
                    }
                }
                mutating func markReferencesSaved() {
                    self._tags.markSaved()
                    self._pinnedIDs.markSaved()
                }
            }
            """,
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testRecordSkipsIDReferences() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Article {
                var id: UUID
                @Reference(Person.self) var authorID: UUID?
            }
            """,
            expandedSource: """
            struct Article {
                var id: UUID
                var authorID: UUID? {
                    @storageRestrictions(initializes: _authorID)
                    init(initialValue) {
                        _authorID = Records.ToOne(id: initialValue)
                    }
                    get {
                        _authorID.id
                    }
                    set {
                        _authorID.id = newValue
                    }
                }

                var _authorID: Records.ToOne<Person>
            }

            extension Article: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "Article"
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self._authorID = Records.ToOne(id: nil)
                }
                func encodeFields(into record: CKRecord) {
                }
                var referenceStates: [Records.ReferenceState] {
                    [
                        self._authorID.state(property: "authorID", owner: Self.recordType),
                    ]
                }
                mutating func loadReference(_ property: String, to targets: [Records.ReferenceTarget], from records: [CKRecord], links: [CKRecord], depth: Int) throws {
                    switch property {
                    case "authorID":
                        try self._authorID.load(targets, from: [], links: [], depth: 0)
                    default:
                        break
                    }
                }
                mutating func markReferencesSaved() {
                    self._authorID.markSaved()
                }
            }
            """,
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testIDReferenceNeedsTargetType() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Note {
                @Reference var authorID: UUID?
            }
            """,
            expandedSource: """
            struct Note {
                var authorID: UUID?
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Reference on a UUID needs the record type it points at, e.g. '@Reference(Person.self)'", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testIDReferenceMustBeOptional() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Note {
                @Reference(Person.self) var authorID: UUID
            }
            """,
            expandedSource: """
            struct Note {
                var authorID: UUID
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Reference to one record must be optional", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testRecordReferenceRejectsTargetType() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Note {
                @Reference(Person.self) var author: Person?
            }
            """,
            expandedSource: """
            struct Note {
                var author: Person?
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Reference only takes a record type on a UUID property; 'Person' already names it", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testSelfReferenceByRecordIsAllowed() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Person {
                @Reference var manager: Person?
                @Reference var mentor: Self?
            }
            """,
            expandedSource: """
            struct Person {
                var manager: Person? {
                    @storageRestrictions(initializes: _manager)
                    init(initialValue) {
                        _manager = Records.ToOne(initialValue)
                    }
                    get {
                        _manager.value
                    }
                    set {
                        _manager.value = newValue
                    }
                }

                var _manager: Records.ToOne<Person>

                var $manager: UUID? {
                    _manager.id
                }
                var mentor: Self? {
                    @storageRestrictions(initializes: _mentor)
                    init(initialValue) {
                        _mentor = Records.ToOne(initialValue)
                    }
                    get {
                        _mentor.value
                    }
                    set {
                        _mentor.value = newValue
                    }
                }

                var _mentor: Records.ToOne<Person>

                var $mentor: UUID? {
                    _mentor.id
                }
            }
            """,
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testSelfReferenceByIDIsAllowed() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Person {
                @Reference(Person.self) var managerID: UUID?
            }
            """,
            expandedSource: """
            struct Person {
                var managerID: UUID? {
                    @storageRestrictions(initializes: _managerID)
                    init(initialValue) {
                        _managerID = Records.ToOne(id: initialValue)
                    }
                    get {
                        _managerID.id
                    }
                    set {
                        _managerID.id = newValue
                    }
                }

                var _managerID: Records.ToOne<Person>
            }
            """,
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testReferenceTargetMustBeAType() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Note {
                @Reference(person) var authorID: UUID?
            }
            """,
            expandedSource: """
            struct Note {
                var authorID: UUID?
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Reference takes a record type, e.g. 'Person.self'", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testOneToOneOwningSide() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct User {
                var id: UUID
                @Reference var profile: Profile?
            }
            """,
            expandedSource: """
            struct User {
                var id: UUID
                var profile: Profile? {
                    @storageRestrictions(initializes: _profile)
                    init(initialValue) {
                        _profile = Records.ToOne(initialValue)
                    }
                    get {
                        _profile.value
                    }
                    set {
                        _profile.value = newValue
                    }
                }

                var _profile: Records.ToOne<Profile>

                var $profile: UUID? {
                    _profile.id
                }
            }

            extension User: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "User"
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self._profile = Records.ToOne(id: nil)
                }
                func encodeFields(into record: CKRecord) {
                }
                var referenceStates: [Records.ReferenceState] {
                    [
                        self._profile.state(property: "profile", owner: Self.recordType),
                    ]
                }
                mutating func loadReference(_ property: String, to targets: [Records.ReferenceTarget], from records: [CKRecord], links: [CKRecord], depth: Int) throws {
                    switch property {
                    case "profile":
                        try self._profile.load(targets, from: records, links: links, depth: depth)
                    default:
                        break
                    }
                }
                mutating func markReferencesSaved() {
                    self._profile.markSaved()
                }
            }
            """,
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testOneToOneFromSide() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Profile {
                var id: UUID
                @Reference(from: \\User.profile, deleteSelf: true) var userID: UUID?
                @Reference(from: \\Account.settingsID) var accountID: UUID?
            }
            """,
            expandedSource: """
            struct Profile {
                var id: UUID
                var userID: UUID? {
                    @storageRestrictions(initializes: _userID)
                    init(initialValue) {
                        _userID = Records.ToOne(id: initialValue)
                    }
                    get {
                        _userID.id
                    }
                }

                var _userID: Records.ToOne<User>
                var accountID: UUID? {
                    @storageRestrictions(initializes: _accountID)
                    init(initialValue) {
                        _accountID = Records.ToOne(id: initialValue)
                    }
                    get {
                        _accountID.id
                    }
                }

                var _accountID: Records.ToOne<Account>
            }

            extension Profile: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "Profile"
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self._userID = Records.ToOne(id: nil)
                    self._accountID = Records.ToOne(id: nil)
                }
                func encodeFields(into record: CKRecord) {
                }
                static var deleteSelfReferences: Set<String> {
                    ["userID"]
                }
                static func inverse(of property: String, in owner: CKRecord.RecordType) -> Records.Inverse? {
                    switch (owner, property) {
                    case (User.recordType, "profile"):
                        return Records.Inverse(\\User.profile, to: Self.self, property: "userID", deleteSelf: true)
                    case (Account.recordType, "settingsID"):
                        return Records.Inverse(\\Account.settingsID, to: Self.self, property: "accountID")
                    default:
                        return nil
                    }
                }
                var referenceStates: [Records.ReferenceState] {
                    [
                    ]
                }
                mutating func loadReference(_ property: String, to targets: [Records.ReferenceTarget], from records: [CKRecord], links: [CKRecord], depth: Int) throws {
                    switch property {
                    case "userID":
                        try self._userID.load(targets, from: [], links: [], depth: 0)
                    case "accountID":
                        try self._accountID.load(targets, from: [], links: [], depth: 0)
                    default:
                        break
                    }
                }
                mutating func markReferencesSaved() {
                    self._userID.markSaved()
                    self._accountID.markSaved()
                }
            }
            """,
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testFromNeedsAKeyPath() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Profile {
                @Reference(from: User.self) var user: User?
            }
            """,
            expandedSource: """
            struct Profile {
                var user: User?
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Reference(from:) takes the owner's property, e.g. '\\User.profile'", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testOwnerTakesNoKeyPath() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct User {
                @Reference(\\Profile.user) var profile: Profile?
            }
            """,
            expandedSource: """
            struct User {
                var profile: Profile?
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Reference takes a record type; name this property in the other side's '@Reference(from:)' instead",
                    line: 2, column: 5
                ),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testDeleteSelfOnlyOnFrom() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct User {
                @Reference(Profile.self, deleteSelf: true) var profileID: UUID?
            }
            """,
            expandedSource: """
            struct User {
                var profileID: UUID?
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "Only @Reference(from:) takes 'deleteSelf:'", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testOneToManyFromSide() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Shelf {
                var id: UUID
                @Reference(from: \\Book.shelf) var bookIDs: [UUID]
                @Reference(from: \\Crate.shelf) var crateIDs: [UUID]
            }
            """,
            expandedSource: """
            struct Shelf {
                var id: UUID
                var bookIDs: [UUID] {
                    @storageRestrictions(initializes: _bookIDs)
                    init(initialValue) {
                        _bookIDs = Records.ToMany(ids: initialValue)
                    }
                    get {
                        _bookIDs.ids
                    }
                }

                var _bookIDs: Records.ToMany<Book>
                var crateIDs: [UUID] {
                    @storageRestrictions(initializes: _crateIDs)
                    init(initialValue) {
                        _crateIDs = Records.ToMany(ids: initialValue)
                    }
                    get {
                        _crateIDs.ids
                    }
                }

                var _crateIDs: Records.ToMany<Crate>
            }

            extension Shelf: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "Shelf"
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self._bookIDs = Records.ToMany(ids: [])
                    self._crateIDs = Records.ToMany(ids: [])
                }
                func encodeFields(into record: CKRecord) {
                }
                static func inverse(of property: String, in owner: CKRecord.RecordType) -> Records.Inverse? {
                    switch (owner, property) {
                    case (Book.recordType, "shelf"):
                        return Records.Inverse(many: \\Book.shelf, to: Self.self, property: "bookIDs")
                    case (Crate.recordType, "shelf"):
                        return Records.Inverse(many: \\Crate.shelf, to: Self.self, property: "crateIDs")
                    default:
                        return nil
                    }
                }
                var referenceStates: [Records.ReferenceState] {
                    [
                    ]
                }
                mutating func loadReference(_ property: String, to targets: [Records.ReferenceTarget], from records: [CKRecord], links: [CKRecord], depth: Int) throws {
                    switch property {
                    case "bookIDs":
                        try self._bookIDs.load(targets, from: [], links: [], depth: 0)
                    case "crateIDs":
                        try self._crateIDs.load(targets, from: [], links: [], depth: 0)
                    default:
                        break
                    }
                }
                mutating func markReferencesSaved() {
                    self._bookIDs.markSaved()
                    self._crateIDs.markSaved()
                }
            }
            """,
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testDeleteSelfNeedsAToOneFromSide() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Shelf {
                @Reference(from: \\Book.shelf, deleteSelf: true) var bookIDs: [UUID]
            }
            """,
            expandedSource: """
            struct Shelf {
                var bookIDs: [UUID]
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "'deleteSelf:' needs a to-one @Reference(from:) property", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testOneFromSidePerOwnerProperty() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Shelf {
                var id: UUID
                @Reference(from: \\Book.shelf) var bookIDs: [UUID]
                @Reference(from: \\Book.shelf) var otherIDs: [UUID]
            }
            """,
            expandedSource: """
            struct Shelf {
                var id: UUID
                var bookIDs: [UUID] {
                    @storageRestrictions(initializes: _bookIDs)
                    init(initialValue) {
                        _bookIDs = Records.ToMany(ids: initialValue)
                    }
                    get {
                        _bookIDs.ids
                    }
                }

                var _bookIDs: Records.ToMany<Book>
                var otherIDs: [UUID] {
                    @storageRestrictions(initializes: _otherIDs)
                    init(initialValue) {
                        _otherIDs = Records.ToMany(ids: initialValue)
                    }
                    get {
                        _otherIDs.ids
                    }
                }

                var _otherIDs: Records.ToMany<Book>
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "Only one @Reference(from:) can name 'Book.shelf'", line: 1, column: 1),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testFromSideHoldsIDs() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Shelf {
                @Reference(from: \\Book.shelf) var books: [Book]
            }
            """,
            expandedSource: """
            struct Shelf {
                var books: [Book]
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Reference(from:) holds IDs, e.g. 'var bookIDs: [UUID]'", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        assertMacroExpansion(
            """
            struct Profile {
                @Reference(from: \\User.profile) var user: User?
            }
            """,
            expandedSource: """
            struct Profile {
                var user: User?
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Reference(from:) holds IDs, e.g. 'var userID: UUID?'", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testReferenceToItselfNotSupported() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Person {
                @Reference(from: \\Person.spouseID) var spouseID: UUID?
            }
            """,
            expandedSource: """
            struct Person {
                var spouseID: UUID?
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Reference to itself is not supported yet", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    // MARK: - Field changes

    func testFieldIsBackedByStorage() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Note {
                @RecordField var title: String
            }
            """,
            expandedSource: """
            struct Note {
                var title: String {
                    @storageRestrictions(initializes: _title)
                    init(initialValue) {
                        _title = Records.Field(initialValue)
                    }
                    get {
                        _title.value
                    }
                    set {
                        _title.value = newValue
                    }
                }

                var _title: Records.Field<String>
            }
            """,
            macroSpecs: ["RecordField": MacroSpec(type: RecordFieldMacro.self)]
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testFieldsDeclaredTogetherAreAnError() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Note {
                var id: UUID
                var first, last: String
            }
            """,
            expandedSource: """
            struct Note {
                var id: UUID
                var first, last: String
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Record tracks each field's changes, so declare 'first' and 'last' separately",
                    line: 1,
                    column: 1
                ),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testFieldObserverIsAnError() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Note {
                var id: UUID
                var rating: Int? {
                    didSet { print("changed") }
                }
            }
            """,
            expandedSource: """
            struct Note {
                var id: UUID
                var rating: Int? {
                    didSet { print("changed") }
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Record tracks changes to 'rating', so it can't have 'willSet' or 'didSet'",
                    line: 1,
                    column: 1
                ),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    // MARK: - Encrypted fields

    func testEncryptedFieldsUseEncryptedValues() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Account {
                var id: UUID
                var name: String
                @Encrypted var note: String?
                @Encrypted let pin: Int
            }
            """,
            expandedSource: """
            struct Account {
                var id: UUID
                @RecordField
                var name: String
                @RecordField var note: String?
                let pin: Int
            }

            extension Account: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "Account"
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self._name = try Records.Field(saved: CKRecordDecoder.decode((String).self, forKey: "name", from: record))
                    self._note = try Records.Field(saved: CKRecordDecoder.decodeIfPresent((String).self, forKey: "note", from: record.encryptedValues))
                    self.pin = try CKRecordDecoder.decode((Int).self, forKey: "pin", from: record.encryptedValues)
                }
                func encodeFields(into record: CKRecord) {
                    record["name"] = Records.FieldCoding.value(self.name)
                    record.encryptedValues["note"] = Records.FieldCoding.value(self.note)
                    record.encryptedValues["pin"] = Records.FieldCoding.value(self.pin)
                }
                var changedFields: Set<String> {
                    var fields: Set<String> = []
                    if self._name.isChanged {
                        fields.insert("name")
                    }
                    if self._note.isChanged {
                        fields.insert("note")
                    }
                    return fields
                }
                func encodeChangedFields(into record: CKRecord) {
                    if self._name.isChanged {
                        record["name"] = Records.FieldCoding.value(self.name)
                    }
                    if self._note.isChanged {
                        record.encryptedValues["note"] = Records.FieldCoding.value(self.note)
                    }
                }
                mutating func markFieldsSaved() {
                    self._name.markSaved()
                    self._note.markSaved()
                }
            }
            """,
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testEncryptedIDIsAnError() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Account {
                @Encrypted var id: UUID
            }
            """,
            expandedSource: """
            struct Account {
                var id: UUID
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "'id' is the record name, which CloudKit can't encrypt", line: 1, column: 1),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testEncryptedReferenceIsAnError() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Account {
                var id: UUID
                @Encrypted @Reference var owner: Account?
            }
            """,
            expandedSource: """
            struct Account {
                var id: UUID
                var owner: Account? {
                    @storageRestrictions(initializes: _owner)
                    init(initialValue) {
                        _owner = Records.ToOne(initialValue)
                    }
                    get {
                        _owner.value
                    }
                    set {
                        _owner.value = newValue
                    }
                }

                var _owner: Records.ToOne<Account>

                var $owner: UUID? {
                    _owner.id
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Encrypted applies to fields, not to a @Reference", line: 1, column: 1),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    // MARK: - Assets

    func testAssetIsBackedByAFile() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Poster {
                var id: UUID
                @Asset var image: Data?
            }
            """,
            expandedSource: """
            struct Poster {
                var id: UUID
                var image: Data? {
                    @storageRestrictions(initializes: _image)
                    init(initialValue) {
                        _image = Records.AssetField(initialValue)
                    }
                    get {
                        _image.data
                    }
                    set {
                        _image.data = newValue
                    }
                }

                var _image: Records.AssetField

                var $image: URL? {
                    _image.fileURL
                }
            }

            extension Poster: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "Poster"
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self._image = try Records.AssetField(saved: CKRecordDecoder.decodeIfPresent((CKAsset).self, forKey: "image", from: record))
                }
                func encodeFields(into record: CKRecord) {
                    record["image"] = self._image.asset
                }
                var changedFields: Set<String> {
                    var fields: Set<String> = []
                    if self._image.isChanged {
                        fields.insert("image")
                    }
                    return fields
                }
                func encodeChangedFields(into record: CKRecord) {
                    if self._image.isChanged {
                        record["image"] = self._image.asset
                    }
                }
                mutating func markFieldsSaved() {
                    self._image.markSaved()
                }
            }
            """,
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testAssetMustHoldOptionalData() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Poster {
                @Asset var image: Data
            }
            """,
            expandedSource: """
            struct Poster {
                var image: Data
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Asset holds 'Data?', e.g. 'var cover: Data?'", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testAssetMustBeVar() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Poster {
                @Asset let image: Data?
            }
            """,
            expandedSource: """
            struct Poster {
                let image: Data?
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Asset needs a 'var'", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testAssetCannotBeEncrypted() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Poster {
                @Asset @Encrypted var image: Data?
            }
            """,
            expandedSource: """
            struct Poster {
                var image: Data?
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "CloudKit can't encrypt an asset, so a property can't be both @Asset and @Encrypted", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    // MARK: - Renamed fields

    func testRenamedFieldUsesItsOriginalName() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Album {
                var id: UUID
                @Renamed("released") var year: Int
            }
            """,
            expandedSource: """
            struct Album {
                var id: UUID
                @RecordField var year: Int
            }

            extension Album: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "Album"
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self._year = try Records.Field(saved: CKRecordDecoder.decode((Int).self, forKey: "released", from: record))
                }
                func encodeFields(into record: CKRecord) {
                    record["released"] = Records.FieldCoding.value(self.year)
                }
                var changedFields: Set<String> {
                    var fields: Set<String> = []
                    if self._year.isChanged {
                        fields.insert("year")
                    }
                    return fields
                }
                func encodeChangedFields(into record: CKRecord) {
                    if self._year.isChanged {
                        record["released"] = Records.FieldCoding.value(self.year)
                    }
                }
                mutating func markFieldsSaved() {
                    self._year.markSaved()
                }
            }
            """,
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testTwoFieldsCannotShareAName() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Album {
                var id: UUID
                var released: Date
                @Renamed("released") var year: Int
            }
            """,
            expandedSource: """
            struct Album {
                var id: UUID
                @RecordField
                var released: Date
                @RecordField var year: Int
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "Two properties are stored in the field 'released'", line: 1, column: 1),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testRenamedNeedsAStringLiteral() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Album {
                var id: UUID
                @Renamed(oldName) var year: Int
            }
            """,
            expandedSource: """
            struct Album {
                var id: UUID
                @RecordField var year: Int
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Renamed takes the field's original name as a string literal, e.g. @Renamed(\"released\")",
                    line: 1,
                    column: 1
                ),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }
}
