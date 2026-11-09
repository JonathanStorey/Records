// swift-tools-version: 6.0
// Swift 5.9 introduced macros. Swift 6 tools give strict concurrency by default,
// which matters for a package built on CKSyncEngine delegates.

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "Records",
    // CKSyncEngine is the floor: iOS 17, macOS 14, tvOS 17, watchOS 10, visionOS 1.
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .macCatalyst(.v17),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "Records", targets: ["Records"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"700.0.0"),
    ],
    targets: [
        // Compiler plugin that implements the macros. Runs on the host at build time.
        .macro(
            name: "RecordsMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
            ]
        ),

        // Public library: macro declarations, the Record protocol, SQLite storage, CKSyncEngine sync.
        .target(
            name: "Records",
            dependencies: ["RecordsMacros"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),

        .testTarget(
            name: "RecordsTests",
            dependencies: ["Records"]
        ),
        .testTarget(
            name: "RecordsMacrosTests",
            dependencies: [
                "RecordsMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)
