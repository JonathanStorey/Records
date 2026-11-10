import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct RecordsPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        RecordMacro.self,
        ReferenceMacro.self,
        EncryptedMacro.self,
        AssetMacro.self,
        RenamedMacro.self,
        LocationMacro.self,
        TimestampedMacro.self,
    ]
}
