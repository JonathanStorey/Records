import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct RecordsPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        RecordMacro.self,
        ReferenceMacro.self,
        ProbeMacro.self,
    ]
}
