import SwiftSyntax
import SwiftSyntaxMacros

/// `@Asset` on a `Data?` property of a `@Record`, stored as a `CKAsset` on its own link.
///
/// The property is backed by a `Records.AssetField`, which keeps the file and reads it only when
/// the property is read. `$name` gives the file's URL, and setting it copies a file in without
/// reading it.
public struct AssetMacro: AccessorMacro, PeerMacro {
    static let property = BackedProperty(
        attribute: "Asset", field: "AssetField", value: "data",
        projected: ("URL?", "fileURL"), wrapped: ["Data"], example: "var cover: Data?"
    )

    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        property.accessors(of: declaration)
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        try property.peers(of: declaration)
    }
}
