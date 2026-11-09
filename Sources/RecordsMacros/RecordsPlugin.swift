import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct RecordsPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        RecordMacro.self,
        ReferenceMacro.self,
        RecordFieldMacro.self,
        EncryptedMacro.self,
        AssetMacro.self,
    ]
}
