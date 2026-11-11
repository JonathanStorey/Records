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
        "Location": MacroSpec(type: LocationMacro.self),
        "Timestamped": MacroSpec(type: TimestampedMacro.self),
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

            extension Note: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "Note"
                }
                static let schema = Records.RecordSchema(
                    recordType: "Note",
                    fields: [
                        Records.FieldSchema(name: "title", key: "title", isOptional: false, isEncrypted: false, kind: Records.FieldCoding((String).self).kind),
                        Records.FieldSchema(name: "isPinned", key: "isPinned", isOptional: false, isEncrypted: false, kind: Records.FieldCoding((Bool).self).kind),
                        Records.FieldSchema(name: "rating", key: "rating", isOptional: true, isEncrypted: false, kind: Records.FieldCoding((Int).self).kind),
                        Records.FieldSchema(name: "tags", key: "tags", isOptional: false, isEncrypted: false, kind: Records.FieldCoding(([String]).self).kind),
                    ],
                    references: []
                )
                static var keyPaths: [PartialKeyPath<Self>: String] {
                    [\\Note.id: "_name", \\Note.title: "title", \\Note.isPinned: "isPinned", \\Note.rating: "rating", \\Note.tags: "tags"]
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self.title = try Records.FieldCoding((String).self).decode("title", from: record)
                    self.isPinned = try Records.FieldCoding((Bool).self).decode("isPinned", from: record)
                    self.rating = try Records.FieldCoding((Int).self).decodeIfPresent("rating", from: record)
                    self.tags = try Records.FieldCoding(([String]).self).decodeIfPresent("tags", from: record) ?? []
                }
                func encodeFields(into record: CKRecord) {
                    record["title"] = Records.FieldCoding((String).self).value(self.title)
                    record["isPinned"] = Records.FieldCoding((Bool).self).value(self.isPinned)
                    record["rating"] = Records.FieldCoding((Int).self).value(self.rating)
                    record["tags"] = Records.FieldCoding(([String]).self).value(self.tags)
                }
                init(from row: Records.RecordRow) throws {
                    self.id = try row.id
                    self.title = try Records.FieldCoding((String).self).decode("title", from: row)
                    self.isPinned = try Records.FieldCoding((Bool).self).decode("isPinned", from: row)
                    self.rating = try Records.FieldCoding((Int).self).decodeIfPresent("rating", from: row)
                    self.tags = try Records.FieldCoding(([String]).self).decodeIfPresent("tags", from: row) ?? []
                }
                func encodeFields(into row: inout Records.RecordRow) {
                    Records.FieldCoding((String).self).encode(self.title, into: &row, forKey: "title")
                    Records.FieldCoding((Bool).self).encode(self.isPinned, into: &row, forKey: "isPinned")
                    Records.FieldCoding((Int).self).encode(self.rating, into: &row, forKey: "rating")
                    Records.FieldCoding(([String]).self).encode(self.tags, into: &row, forKey: "tags")
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
                public var `default`: Bool
            }

            extension LegacyFolder: Records.Record {
                public static var recordType: CKRecord.RecordType {
                    "Folder"
                }
                public static let schema = Records.RecordSchema(
                    recordType: "Folder",
                    fields: [
                        Records.FieldSchema(name: "default", key: "default", isOptional: false, isEncrypted: false, kind: Records.FieldCoding((Bool).self).kind),
                    ],
                    references: []
                )
                public static var keyPaths: [PartialKeyPath<Self>: String] {
                    [\\LegacyFolder.id: "_name", \\LegacyFolder.default: "default"]
                }
                public init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self.`default` = try Records.FieldCoding((Bool).self).decode("default", from: record)
                }
                public func encodeFields(into record: CKRecord) {
                    record["default"] = Records.FieldCoding((Bool).self).value(self.`default`)
                }
                public init(from row: Records.RecordRow) throws {
                    self.id = try row.id
                    self.`default` = try Records.FieldCoding((Bool).self).decode("default", from: row)
                }
                public func encodeFields(into row: inout Records.RecordRow) {
                    Records.FieldCoding((Bool).self).encode(self.`default`, into: &row, forKey: "default")
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
                var value: Optional<Value>
            }

            extension Box: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "Box"
                }
                static var schema: Records.RecordSchema {
                    Records.RecordSchema(
                        recordType: "Box",
                        fields: [
                            Records.FieldSchema(name: "value", key: "value", isOptional: true, isEncrypted: false, kind: Records.FieldCoding((Value).self).kind),
                        ],
                        references: []
                    )
                }
                static var keyPaths: [PartialKeyPath<Self>: String] {
                    [\\Box.id: "_name", \\Box.value: "value"]
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self.value = try Records.FieldCoding((Value).self).decodeIfPresent("value", from: record)
                }
                func encodeFields(into record: CKRecord) {
                    record["value"] = Records.FieldCoding((Value).self).value(self.value)
                }
                init(from row: Records.RecordRow) throws {
                    self.id = try row.id
                    self.value = try Records.FieldCoding((Value).self).decodeIfPresent("value", from: row)
                }
                func encodeFields(into row: inout Records.RecordRow) {
                    Records.FieldCoding((Value).self).encode(self.value, into: &row, forKey: "value")
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
            }

            extension Article: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "Article"
                }
                static let schema = Records.RecordSchema(
                    recordType: "Article",
                    fields: [
                        Records.FieldSchema(name: "title", key: "title", isOptional: false, isEncrypted: false, kind: Records.FieldCoding((String).self).kind),
                    ],
                    references: [
                        Records.ReferenceSchema(property: "author", target: Person.self, isToMany: false, isSorted: false, holdsIDs: false),
                    ]
                )
                static var keyPaths: [PartialKeyPath<Self>: String] {
                    [\\Article.id: "_name", \\Article.title: "title", \\Article.author: "author"]
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self.title = try Records.FieldCoding((String).self).decode("title", from: record)
                    self._author = Records.ToOne(id: nil)
                }
                func encodeFields(into record: CKRecord) {
                    record["title"] = Records.FieldCoding((String).self).value(self.title)
                }
                init(from row: Records.RecordRow) throws {
                    self.id = try row.id
                    self.title = try Records.FieldCoding((String).self).decode("title", from: row)
                    self._author = Records.ToOne(id: nil)
                }
                func encodeFields(into row: inout Records.RecordRow) {
                    Records.FieldCoding((String).self).encode(self.title, into: &row, forKey: "title")
                }
                var referenceStates: [Records.ReferenceState] {
                    Records.ReferenceState.all(of: Self.self, targets: [
                        "author": (self._author.ids, self._author.loadedRecords),
                    ])
                }
                mutating func loadReference(_ property: String, to targets: [Records.ReferenceTarget], from records: [CKRecord], links: [CKRecord], depth: Int) throws {
                    switch property {
                    case "author":
                        try self._author.load(targets, from: records, links: links, depth: depth)
                    default:
                        break
                    }
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
                static let schema = Records.RecordSchema(
                    recordType: "Note",
                    fields: [],
                    references: [
                        Records.ReferenceSchema(property: "tags", target: Tag.self, isToMany: true, isSorted: false, holdsIDs: false),
                        Records.ReferenceSchema(property: "pinnedIDs", target: Tag.self, isToMany: true, isSorted: false, holdsIDs: true),
                    ]
                )
                static var keyPaths: [PartialKeyPath<Self>: String] {
                    [\\Note.id: "_name", \\Note.tags: "tags", \\Note.pinnedIDs: "pinnedIDs"]
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self._tags = Records.ToMany(ids: [])
                    self._pinnedIDs = Records.ToMany(ids: [])
                }
                func encodeFields(into record: CKRecord) {
                }
                init(from row: Records.RecordRow) throws {
                    self.id = try row.id
                    self._tags = Records.ToMany(ids: [])
                    self._pinnedIDs = Records.ToMany(ids: [])
                }
                func encodeFields(into row: inout Records.RecordRow) {
                }
                var referenceStates: [Records.ReferenceState] {
                    Records.ReferenceState.all(of: Self.self, targets: [
                        "tags": (self._tags.ids, self._tags.loadedRecords),
                        "pinnedIDs": (self._pinnedIDs.ids, self._pinnedIDs.loadedRecords),
                    ])
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
                static let schema = Records.RecordSchema(
                    recordType: "Article",
                    fields: [],
                    references: [
                        Records.ReferenceSchema(property: "authorID", target: Person.self, isToMany: false, isSorted: false, holdsIDs: true),
                    ]
                )
                static var keyPaths: [PartialKeyPath<Self>: String] {
                    [\\Article.id: "_name", \\Article.authorID: "authorID"]
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self._authorID = Records.ToOne(id: nil)
                }
                func encodeFields(into record: CKRecord) {
                }
                init(from row: Records.RecordRow) throws {
                    self.id = try row.id
                    self._authorID = Records.ToOne(id: nil)
                }
                func encodeFields(into row: inout Records.RecordRow) {
                }
                var referenceStates: [Records.ReferenceState] {
                    Records.ReferenceState.all(of: Self.self, targets: [
                        "authorID": (self._authorID.ids, self._authorID.loadedRecords),
                    ])
                }
                mutating func loadReference(_ property: String, to targets: [Records.ReferenceTarget], from records: [CKRecord], links: [CKRecord], depth: Int) throws {
                    switch property {
                    case "authorID":
                        try self._authorID.load(targets, from: [], links: [], depth: 0)
                    default:
                        break
                    }
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
            }

            extension User: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "User"
                }
                static let schema = Records.RecordSchema(
                    recordType: "User",
                    fields: [],
                    references: [
                        Records.ReferenceSchema(property: "profile", target: Profile.self, isToMany: false, isSorted: false, holdsIDs: false),
                    ]
                )
                static var keyPaths: [PartialKeyPath<Self>: String] {
                    [\\User.id: "_name", \\User.profile: "profile"]
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self._profile = Records.ToOne(id: nil)
                }
                func encodeFields(into record: CKRecord) {
                }
                init(from row: Records.RecordRow) throws {
                    self.id = try row.id
                    self._profile = Records.ToOne(id: nil)
                }
                func encodeFields(into row: inout Records.RecordRow) {
                }
                var referenceStates: [Records.ReferenceState] {
                    Records.ReferenceState.all(of: Self.self, targets: [
                        "profile": (self._profile.ids, self._profile.loadedRecords),
                    ])
                }
                mutating func loadReference(_ property: String, to targets: [Records.ReferenceTarget], from records: [CKRecord], links: [CKRecord], depth: Int) throws {
                    switch property {
                    case "profile":
                        try self._profile.load(targets, from: records, links: links, depth: depth)
                    default:
                        break
                    }
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
                static let schema = Records.RecordSchema(
                    recordType: "Profile",
                    fields: [],
                    references: [
                        Records.ReferenceSchema(property: "userID", target: User.self, isToMany: false, isSorted: false, holdsIDs: true, inverseOf: "profile", deleteSelf: true),
                        Records.ReferenceSchema(property: "accountID", target: Account.self, isToMany: false, isSorted: false, holdsIDs: true, inverseOf: "settingsID", deleteSelf: false),
                    ]
                )
                static var keyPaths: [PartialKeyPath<Self>: String] {
                    [\\Profile.id: "_name", \\Profile.userID: "userID", \\Profile.accountID: "accountID"]
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self._userID = Records.ToOne(id: nil)
                    self._accountID = Records.ToOne(id: nil)
                }
                func encodeFields(into record: CKRecord) {
                }
                init(from row: Records.RecordRow) throws {
                    self.id = try row.id
                    self._userID = Records.ToOne(id: nil)
                    self._accountID = Records.ToOne(id: nil)
                }
                func encodeFields(into row: inout Records.RecordRow) {
                }
                var referenceStates: [Records.ReferenceState] {
                    Records.ReferenceState.all(of: Self.self, targets: [:])
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
                static let schema = Records.RecordSchema(
                    recordType: "Shelf",
                    fields: [],
                    references: [
                        Records.ReferenceSchema(property: "bookIDs", target: Book.self, isToMany: true, isSorted: false, holdsIDs: true, inverseOf: "shelf", deleteSelf: false),
                        Records.ReferenceSchema(property: "crateIDs", target: Crate.self, isToMany: true, isSorted: false, holdsIDs: true, inverseOf: "shelf", deleteSelf: false),
                    ]
                )
                static var keyPaths: [PartialKeyPath<Self>: String] {
                    [\\Shelf.id: "_name", \\Shelf.bookIDs: "bookIDs", \\Shelf.crateIDs: "crateIDs"]
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self._bookIDs = Records.ToMany(ids: [])
                    self._crateIDs = Records.ToMany(ids: [])
                }
                func encodeFields(into record: CKRecord) {
                }
                init(from row: Records.RecordRow) throws {
                    self.id = try row.id
                    self._bookIDs = Records.ToMany(ids: [])
                    self._crateIDs = Records.ToMany(ids: [])
                }
                func encodeFields(into row: inout Records.RecordRow) {
                }
                var referenceStates: [Records.ReferenceState] {
                    Records.ReferenceState.all(of: Self.self, targets: [:])
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

    // MARK: - Plain fields

    func testFieldsDeclaredTogetherOrObservedAreStored() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Note {
                var id: UUID
                var first, last: String
                var rating: Int? {
                    didSet { print("changed") }
                }
            }
            """,
            expandedSource: """
            struct Note {
                var id: UUID
                var first, last: String
                var rating: Int? {
                    didSet { print("changed") }
                }
            }

            extension Note: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "Note"
                }
                static let schema = Records.RecordSchema(
                    recordType: "Note",
                    fields: [
                        Records.FieldSchema(name: "first", key: "first", isOptional: false, isEncrypted: false, kind: Records.FieldCoding((String).self).kind),
                        Records.FieldSchema(name: "last", key: "last", isOptional: false, isEncrypted: false, kind: Records.FieldCoding((String).self).kind),
                        Records.FieldSchema(name: "rating", key: "rating", isOptional: true, isEncrypted: false, kind: Records.FieldCoding((Int).self).kind),
                    ],
                    references: []
                )
                static var keyPaths: [PartialKeyPath<Self>: String] {
                    [\\Note.id: "_name", \\Note.first: "first", \\Note.last: "last", \\Note.rating: "rating"]
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self.first = try Records.FieldCoding((String).self).decode("first", from: record)
                    self.last = try Records.FieldCoding((String).self).decode("last", from: record)
                    self.rating = try Records.FieldCoding((Int).self).decodeIfPresent("rating", from: record)
                }
                func encodeFields(into record: CKRecord) {
                    record["first"] = Records.FieldCoding((String).self).value(self.first)
                    record["last"] = Records.FieldCoding((String).self).value(self.last)
                    record["rating"] = Records.FieldCoding((Int).self).value(self.rating)
                }
                init(from row: Records.RecordRow) throws {
                    self.id = try row.id
                    self.first = try Records.FieldCoding((String).self).decode("first", from: row)
                    self.last = try Records.FieldCoding((String).self).decode("last", from: row)
                    self.rating = try Records.FieldCoding((Int).self).decodeIfPresent("rating", from: row)
                }
                func encodeFields(into row: inout Records.RecordRow) {
                    Records.FieldCoding((String).self).encode(self.first, into: &row, forKey: "first")
                    Records.FieldCoding((String).self).encode(self.last, into: &row, forKey: "last")
                    Records.FieldCoding((Int).self).encode(self.rating, into: &row, forKey: "rating")
                }
            }
            """,
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
                var name: String
                var note: String?
                let pin: Int
            }

            extension Account: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "Account"
                }
                static let schema = Records.RecordSchema(
                    recordType: "Account",
                    fields: [
                        Records.FieldSchema(name: "name", key: "name", isOptional: false, isEncrypted: false, kind: Records.FieldCoding((String).self).kind),
                        Records.FieldSchema(name: "note", key: "note", isOptional: true, isEncrypted: true, kind: Records.FieldCoding((String).self).kind),
                        Records.FieldSchema(name: "pin", key: "pin", isOptional: false, isEncrypted: true, kind: Records.FieldCoding((Int).self).kind),
                    ],
                    references: []
                )
                static var keyPaths: [PartialKeyPath<Self>: String] {
                    [\\Account.id: "_name", \\Account.name: "name", \\Account.note: "note", \\Account.pin: "pin"]
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self.name = try Records.FieldCoding((String).self).decode("name", from: record)
                    self.note = try Records.FieldCoding((String).self).decodeIfPresent("note", from: record.encryptedValues)
                    self.pin = try Records.FieldCoding((Int).self).decode("pin", from: record.encryptedValues)
                }
                func encodeFields(into record: CKRecord) {
                    record["name"] = Records.FieldCoding((String).self).value(self.name)
                    record.encryptedValues["note"] = Records.FieldCoding((String).self).value(self.note)
                    record.encryptedValues["pin"] = Records.FieldCoding((Int).self).value(self.pin)
                }
                init(from row: Records.RecordRow) throws {
                    self.id = try row.id
                    self.name = try Records.FieldCoding((String).self).decode("name", from: row)
                    self.note = try Records.FieldCoding((String).self).decodeIfPresent("note", from: row)
                    self.pin = try Records.FieldCoding((Int).self).decode("pin", from: row)
                }
                func encodeFields(into row: inout Records.RecordRow) {
                    Records.FieldCoding((String).self).encode(self.name, into: &row, forKey: "name")
                    Records.FieldCoding((String).self).encode(self.note, into: &row, forKey: "note")
                    Records.FieldCoding((Int).self).encode(self.pin, into: &row, forKey: "pin")
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

    func testAssetIsStoredOnItsLink() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Poster {
                var id: UUID
                @Asset var image: Data?
                @Asset @Renamed("thumb") var thumbnail: Data?
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
                    get {
                        _image.fileURL
                    }
                    set {
                        _image.fileURL = newValue
                    }
                }
                var thumbnail: Data? {
                    @storageRestrictions(initializes: _thumbnail)
                    init(initialValue) {
                        _thumbnail = Records.AssetField(initialValue)
                    }
                    get {
                        _thumbnail.data
                    }
                    set {
                        _thumbnail.data = newValue
                    }
                }

                var _thumbnail: Records.AssetField

                var $thumbnail: URL? {
                    get {
                        _thumbnail.fileURL
                    }
                    set {
                        _thumbnail.fileURL = newValue
                    }
                }
            }

            extension Poster: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "Poster"
                }
                static let schema = Records.RecordSchema(
                    recordType: "Poster",
                    fields: [],
                    references: []
                )
                static var keyPaths: [PartialKeyPath<Self>: String] {
                    [\\Poster.id: "_name"]
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self._image = Records.AssetField(id: nil, file: nil)
                    self._thumbnail = Records.AssetField(id: nil, file: nil)
                }
                func encodeFields(into record: CKRecord) {
                }
                init(from row: Records.RecordRow) throws {
                    self.id = try row.id
                    self._image = Records.AssetField(id: nil, file: nil)
                    self._thumbnail = Records.AssetField(id: nil, file: nil)
                }
                func encodeFields(into row: inout Records.RecordRow) {
                }
                var assetStates: [Records.AssetState] {
                    [
                        self._image.state(property: "image"),
                        self._thumbnail.state(property: "thumb"),
                    ]
                }
                mutating func loadAsset(_ property: String, id: UUID?, file: URL?) {
                    switch property {
                    case "image":
                        self._image = Records.AssetField(id: id, file: file)
                    case "thumb":
                        self._thumbnail = Records.AssetField(id: id, file: file)
                    default:
                        break
                    }
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

    // MARK: - Locations

    func testLocationIsStoredAsACLLocation() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Gig {
                var id: UUID
                @Location var venue: Coordinate?
                @Location @Encrypted var home: Coordinate?
            }
            """,
            expandedSource: """
            struct Gig {
                var id: UUID
                var venue: Coordinate? {
                    @storageRestrictions(initializes: _venue)
                    init(initialValue) {
                        _venue = Records.LocationField(initialValue)
                    }
                    get {
                        _venue.coordinate
                    }
                    set {
                        _venue.coordinate = newValue
                    }
                }

                var _venue: Records.LocationField

                var $venue: Records.LocationField.Stored? {
                    get {
                        _venue.location
                    }
                    set {
                        _venue.location = newValue
                    }
                }
                var home: Coordinate? {
                    @storageRestrictions(initializes: _home)
                    init(initialValue) {
                        _home = Records.LocationField(initialValue)
                    }
                    get {
                        _home.coordinate
                    }
                    set {
                        _home.coordinate = newValue
                    }
                }

                var _home: Records.LocationField

                var $home: Records.LocationField.Stored? {
                    get {
                        _home.location
                    }
                    set {
                        _home.location = newValue
                    }
                }
            }

            extension Gig: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "Gig"
                }
                static let schema = Records.RecordSchema(
                    recordType: "Gig",
                    fields: [
                        Records.FieldSchema(name: "venue", key: "venue", isOptional: true, isEncrypted: true, kind: .archived),
                        Records.FieldSchema(name: "home", key: "home", isOptional: true, isEncrypted: true, kind: .archived),
                    ],
                    references: []
                )
                static var keyPaths: [PartialKeyPath<Self>: String] {
                    [\\Gig.id: "_name"]
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self._venue = try Records.LocationField(saved: Records.FieldCoding((Records.LocationField.Stored).self).decodeIfPresent("venue", from: record.encryptedValues))
                    self._home = try Records.LocationField(saved: Records.FieldCoding((Records.LocationField.Stored).self).decodeIfPresent("home", from: record.encryptedValues))
                }
                func encodeFields(into record: CKRecord) {
                    record.encryptedValues["venue"] = self._venue.location
                    record.encryptedValues["home"] = self._home.location
                }
                init(from row: Records.RecordRow) throws {
                    self.id = try row.id
                    self._venue = try Records.LocationField(saved: Records.FieldCoding((Records.LocationField.Stored).self).decodeIfPresent("venue", from: row))
                    self._home = try Records.LocationField(saved: Records.FieldCoding((Records.LocationField.Stored).self).decodeIfPresent("home", from: row))
                }
                func encodeFields(into row: inout Records.RecordRow) {
                    Records.FieldCoding((Records.LocationField.Stored).self).encode(self._venue.location, into: &row, forKey: "venue")
                    Records.FieldCoding((Records.LocationField.Stored).self).encode(self._home.location, into: &row, forKey: "home")
                }
            }
            """,
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testLocationMustHoldOptionalCoordinate() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Gig {
                @Location var venue: CLLocation?
            }
            """,
            expandedSource: """
            struct Gig {
                var venue: CLLocation?
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Location holds 'Coordinate?', e.g. 'var venue: Coordinate?'", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    // MARK: - Timestamps

    func testTimestampsReadServerDates() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Memo {
                var id: UUID
                @Timestamped(.created) var createdAt: Date?
                @Timestamped(.modified) var modifiedAt: Date?
            }
            """,
            expandedSource: """
            struct Memo {
                var id: UUID
                var createdAt: Date? {
                    get {
                        _createdAt.date
                    }
                }

                let _createdAt = Records.ServerDate()
                var modifiedAt: Date? {
                    get {
                        _modifiedAt.date
                    }
                }

                let _modifiedAt = Records.ServerDate()
            }

            extension Memo: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "Memo"
                }
                static let schema = Records.RecordSchema(
                    recordType: "Memo",
                    fields: [],
                    references: []
                )
                static var keyPaths: [PartialKeyPath<Self>: String] {
                    [\\Memo.id: "_name"]
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self._createdAt.load(record.creationDate)
                    self._modifiedAt.load(record.modificationDate)
                }
                func encodeFields(into record: CKRecord) {
                }
                init(from row: Records.RecordRow) throws {
                    self.id = try row.id
                    self._createdAt.load(row.createdAt)
                    self._modifiedAt.load(row.modifiedAt)
                }
                func encodeFields(into row: inout Records.RecordRow) {
                }
            }
            """,
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testTimestampMustHoldOptionalDate() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Memo {
                @Timestamped(.created) var createdAt: Date
            }
            """,
            expandedSource: """
            struct Memo {
                var createdAt: Date
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Timestamped holds 'Date?', which is nil until the record is first saved", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testTimestampNeedsAKind() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Memo {
                @Timestamped(.edited) var editedAt: Date?
            }
            """,
            expandedSource: """
            struct Memo {
                var editedAt: Date?
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Timestamped takes .created or .modified, e.g. @Timestamped(.created)", line: 2, column: 5),
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
                var year: Int
            }

            extension Album: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "Album"
                }
                static let schema = Records.RecordSchema(
                    recordType: "Album",
                    fields: [
                        Records.FieldSchema(name: "year", key: "released", isOptional: false, isEncrypted: false, kind: Records.FieldCoding((Int).self).kind),
                    ],
                    references: []
                )
                static var keyPaths: [PartialKeyPath<Self>: String] {
                    [\\Album.id: "_name", \\Album.year: "released"]
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self.year = try Records.FieldCoding((Int).self).decode("released", from: record)
                }
                func encodeFields(into record: CKRecord) {
                    record["released"] = Records.FieldCoding((Int).self).value(self.year)
                }
                init(from row: Records.RecordRow) throws {
                    self.id = try row.id
                    self.year = try Records.FieldCoding((Int).self).decode("released", from: row)
                }
                func encodeFields(into row: inout Records.RecordRow) {
                    Records.FieldCoding((Int).self).encode(self.year, into: &row, forKey: "released")
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
                var released: Date
                var year: Int
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
                var year: Int
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

    // MARK: - Sorted references

    func testSortByKeyPath() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Crate {
                @Reference(sort: \\Disc.title, order: .reverse) var discs: [Disc]
            }
            """,
            expandedSource: """
            struct Crate {
                var discs: [Disc] {
                    @storageRestrictions(initializes: _discs)
                    init(initialValue) {
                        _discs = Records.ToMany(initialValue, sorted: true)
                    }
                    get {
                        _discs.values.sorted(using: [SortDescriptor(\\Disc.title, order: .reverse)])
                    }
                    set {
                        _discs.values = newValue
                    }
                }

                var _discs: Records.ToMany<Disc>
            }
            """,
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testSortByDescriptors() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Crate {
                @Reference(sort: [SortDescriptor(\\Disc.year)]) var discs: [Disc]
            }
            """,
            expandedSource: """
            struct Crate {
                var discs: [Disc] {
                    @storageRestrictions(initializes: _discs)
                    init(initialValue) {
                        _discs = Records.ToMany(initialValue, sorted: true)
                    }
                    get {
                        _discs.values.sorted(using: [SortDescriptor(\\Disc.year)])
                    }
                    set {
                        _discs.values = newValue
                    }
                }

                var _discs: Records.ToMany<Disc>
            }
            """,
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testSortNeedsRecords() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Crate {
                @Reference(Disc.self, sort: \\Disc.title) var discIDs: [UUID]
            }
            """,
            expandedSource: """
            struct Crate {
                var discIDs: [UUID]
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "'sort:' needs a to-many @Reference that holds records, e.g. 'var tags: [Tag]'", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testSortNeedsToMany() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Crate {
                @Reference(sort: \\Disc.title) var disc: Disc?
            }
            """,
            expandedSource: """
            struct Crate {
                var disc: Disc?
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "'sort:' needs a to-many @Reference that holds records, e.g. 'var tags: [Tag]'", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testOrderNeedsAKeyPath() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Crate {
                @Reference(sort: [SortDescriptor(\\Disc.year)], order: .reverse) var discs: [Disc]
            }
            """,
            expandedSource: """
            struct Crate {
                var discs: [Disc]
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "'order:' goes with a key path, e.g. 'sort: \\Tag.name, order: .reverse'", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testLocationMustBeVar() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Note {
                @Location let venue: Coordinate?
            }
            """,
            expandedSource: """
            struct Note {
                let venue: Coordinate?
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Location needs a 'var'", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testTimestampedMustBeVar() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Note {
                @Timestamped(.created) let createdAt: Date?
            }
            """,
            expandedSource: """
            struct Note {
                let createdAt: Date?
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Timestamped needs a 'var'", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testTimestampedCannotHaveAnInitialValue() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Note {
                @Timestamped(.created) var createdAt: Date? = nil
            }
            """,
            expandedSource: """
            struct Note {
                var createdAt: Date? = nil
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "The server sets @Timestamped dates, so remove the initial value", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testDeleteSelfNeedsABooleanLiteral() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Note {
                @Reference(from: \\Album.tracks, deleteSelf: maybe) var albumID: UUID?
            }
            """,
            expandedSource: """
            struct Note {
                var albumID: UUID?
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "'deleteSelf:' must be 'true' or 'false'", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testOrderNeedsSort() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Note {
                @Reference(order: .reverse) var tags: [Tag]
            }
            """,
            expandedSource: """
            struct Note {
                var tags: [Tag]
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "'order:' goes with 'sort:', e.g. 'sort: \\Tag.name, order: .reverse'", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testReferenceRejectsUnknownArguments() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Note {
                @Reference(color: 1) var tags: [Tag]
            }
            """,
            expandedSource: """
            struct Note {
                var tags: [Tag]
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Reference doesn't take 'color:'", line: 2, column: 5),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testRecordNameMustBeALiteral() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record(name)
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
                DiagnosticSpec(message: "@Record name must be a string literal", line: 1, column: 1),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testIDCannotBeRenamed() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Note {
                @Renamed("ident") var id: UUID
            }
            """,
            expandedSource: """
            struct Note {
                var id: UUID
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "'id' is the record name, so it has no field to rename", line: 1, column: 1),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testRenamedNeedsAValidFieldName() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Note {
                var id: UUID
                @Renamed("bad name") var title: String
            }
            """,
            expandedSource: """
            struct Note {
                var id: UUID
                var title: String
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "'bad name' is not a valid field name; use letters, digits, and underscores, starting with a letter", line: 1, column: 1),
            ],
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }

    func testCodableRecordGetsEncodeAndDecode() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            @Record
            struct Note: Codable {
                var id: UUID
                var title: String
                var rating: Int?
            }
            """,
            expandedSource: """
            struct Note: Codable {
                var id: UUID
                var title: String
                var rating: Int?
            }

            extension Note: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "Note"
                }
                static let schema = Records.RecordSchema(
                    recordType: "Note",
                    fields: [
                        Records.FieldSchema(name: "title", key: "title", isOptional: false, isEncrypted: false, kind: Records.FieldCoding((String).self).kind),
                        Records.FieldSchema(name: "rating", key: "rating", isOptional: true, isEncrypted: false, kind: Records.FieldCoding((Int).self).kind),
                    ],
                    references: []
                )
                static var keyPaths: [PartialKeyPath<Self>: String] {
                    [\\Note.id: "_name", \\Note.title: "title", \\Note.rating: "rating"]
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self.title = try Records.FieldCoding((String).self).decode("title", from: record)
                    self.rating = try Records.FieldCoding((Int).self).decodeIfPresent("rating", from: record)
                }
                func encodeFields(into record: CKRecord) {
                    record["title"] = Records.FieldCoding((String).self).value(self.title)
                    record["rating"] = Records.FieldCoding((Int).self).value(self.rating)
                }
                init(from row: Records.RecordRow) throws {
                    self.id = try row.id
                    self.title = try Records.FieldCoding((String).self).decode("title", from: row)
                    self.rating = try Records.FieldCoding((Int).self).decodeIfPresent("rating", from: row)
                }
                func encodeFields(into row: inout Records.RecordRow) {
                    Records.FieldCoding((String).self).encode(self.title, into: &row, forKey: "title")
                    Records.FieldCoding((Int).self).encode(self.rating, into: &row, forKey: "rating")
                }
                private enum _RecordCodingKeys: String, CodingKey {
                    case `id`
                    case `title`
                    case `rating`
                }
                func encode(to encoder: any Encoder) throws {
                    var container = encoder.container(keyedBy: _RecordCodingKeys.self)
                    try container.encode(self.id, forKey: .`id`)
                    try container.encode(self.title, forKey: .`title`)
                    try container.encodeIfPresent(self.rating, forKey: .`rating`)
                }
                init(from decoder: any Decoder) throws {
                    let container = try decoder.container(keyedBy: _RecordCodingKeys.self)
                    self.id = try container.decode((UUID).self, forKey: .`id`)
                    self.title = try container.decode((String).self, forKey: .`title`)
                    self.rating = try container.decodeIfPresent((Int).self, forKey: .`rating`)
                }
            }
            """,
            macroSpecs: macroSpecs
        )
        #else
        throw XCTSkip("macros are only supported when running tests for the host platform")
        #endif
    }
}
