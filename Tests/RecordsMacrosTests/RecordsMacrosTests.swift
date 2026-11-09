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
                var rating: Int? {
                    didSet { print("changed") }
                }
                var summary: String {
                    title
                }
                static var shared = 0
                lazy var cache = 0
                let version = 1
                var first, last: String
                var tags: [String] = []
            }
            """,
            expandedSource: """
            struct Note {
                var id: UUID
                var title: String
                let isPinned: Bool
                var rating: Int? {
                    didSet { print("changed") }
                }
                var summary: String {
                    title
                }
                static var shared = 0
                lazy var cache = 0
                let version = 1
                var first, last: String
                var tags: [String] = []
            }

            extension Note: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "Note"
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self.title = try CKRecordDecoder.decode((String).self, forKey: "title", from: record)
                    self.isPinned = try CKRecordDecoder.decode((Bool).self, forKey: "isPinned", from: record)
                    self.rating = try CKRecordDecoder.decodeIfPresent((Int).self, forKey: "rating", from: record)
                    self.first = try CKRecordDecoder.decode((String).self, forKey: "first", from: record)
                    self.last = try CKRecordDecoder.decode((String).self, forKey: "last", from: record)
                    self.tags = try CKRecordDecoder.decodeIfPresent(([String]).self, forKey: "tags", from: record) ?? []
                }
                func encodeFields(into record: CKRecord) {
                    record["title"] = self.title
                    record["isPinned"] = self.isPinned
                    record["rating"] = self.rating
                    record["first"] = self.first
                    record["last"] = self.last
                    record["tags"] = self.tags
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
                public init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self.`default` = try CKRecordDecoder.decode((Bool).self, forKey: "default", from: record)
                }
                public func encodeFields(into record: CKRecord) {
                    record["default"] = self.`default`
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
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self.value = try CKRecordDecoder.decodeIfPresent((Value).self, forKey: "value", from: record)
                }
                func encodeFields(into record: CKRecord) {
                    record["value"] = self.value
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
                var author: Person?
            }

            extension Article: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "Article"
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                    self.title = try CKRecordDecoder.decode((String).self, forKey: "title", from: record)
                }
                func encodeFields(into record: CKRecord) {
                    record["title"] = self.title
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

    func testReferenceToManyNotSupportedYet() throws {
        #if canImport(RecordsMacros)
        assertMacroExpansion(
            """
            struct Note {
                @Reference var tags: [Tag]
            }
            """,
            expandedSource: """
            struct Note {
                var tags: [Tag]
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Reference does not support to-many properties yet", line: 2, column: 5),
            ],
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
                @Reference(to: Person.self) var authorID: UUID?
            }
            """,
            expandedSource: """
            struct Article {
                var id: UUID
                var authorID: UUID?
            }

            extension Article: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "Article"
                }
                init(record: CKRecord) throws {
                    self.id = try CKRecordDecoder.decodeID(from: record)
                }
                func encodeFields(into record: CKRecord) {
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
                DiagnosticSpec(message: "@Reference on a UUID needs the record type it points at, e.g. '@Reference(to: Person.self)'", line: 2, column: 5),
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
                @Reference(to: Person.self) var authorID: UUID
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
                @Reference(to: Person.self) var author: Person?
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
}
