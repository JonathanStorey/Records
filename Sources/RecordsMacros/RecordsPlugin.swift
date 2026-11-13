import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct RecordsPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        RecordMacro.self,
        ReferenceMacro.self,
        MarkerMacro.self,
        AssetMacro.self,
        LocationMacro.self,
        TimestampedMacro.self,
    ]
}
