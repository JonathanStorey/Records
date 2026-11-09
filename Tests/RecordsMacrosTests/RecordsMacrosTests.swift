import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

#if canImport(RecordsMacros)
import RecordsMacros

private var macroSpecs: [String: MacroSpec] {
    [
        "Record": MacroSpec(type: RecordMacro.self, conformances: ["Record"]),
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
            }

            extension Note: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "Note"
                }
                func encodeFields(into record: CKRecord) {
                    record["title"] = self.title
                    record["isPinned"] = self.isPinned
                    record["rating"] = self.rating
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
                var value: Value
            }
            """,
            expandedSource: """
            struct Box<Value> {
                var id: UUID
                var value: Value
            }

            extension Box: Records.Record {
                static var recordType: CKRecord.RecordType {
                    "Box"
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
}
