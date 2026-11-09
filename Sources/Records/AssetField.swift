import CloudKit
import Foundation

/// The storage behind an `@Asset` property: the file that holds its data, and whether it changed
/// since the record was loaded or last saved.
///
/// Setting the property writes the data to a new `.asset` file in `directory` right away, so
/// `$name` always has a URL to hand to a view. Reading the property reads that file, so a record
/// that is loaded but never asked for its data never loads it.
public struct AssetField {
    /// Where new asset files are written: `Application Support/Records/Assets`.
    public static let directory: URL = URL.applicationSupportDirectory
        .appending(path: "Records", directoryHint: .isDirectory)
        .appending(path: "Assets", directoryHint: .isDirectory)

    private enum Source: Equatable {
        case none
        case file(URL)
        /// Data that couldn't be written to a file, kept in memory instead.
        case data(Data)
    }

    private var source: Source

    /// When the data was last set, or `nil` if it hasn't been since the record was loaded or last
    /// saved.
    public private(set) var changedAt: Date?

    /// Whether the data was set since the record was loaded or last saved.
    public var isChanged: Bool { changedAt != nil }

    /// Data set in code, which counts as changed.
    public init(_ data: Data?) {
        source = Self.source(for: data)
        changedAt = Date()
    }

    /// An asset read from storage, which counts as unchanged.
    public init(saved asset: CKAsset?) {
        source = asset?.fileURL.map(Source.file) ?? .none
        changedAt = nil
    }

    /// The asset's data, read from its file each time. Setting it writes a new file.
    public var data: Data? {
        get {
            switch source {
            case .none: nil
            case .file(let url): try? Data(contentsOf: url)
            case .data(let data): data
            }
        }
        set {
            source = Self.source(for: newValue)
            changedAt = Date()
        }
    }

    /// The file that holds the data, or `nil` when there is none.
    public var fileURL: URL? {
        if case .file(let url) = source { url } else { nil }
    }

    /// The `CKAsset` to save, or `nil` to clear the field.
    public var asset: CKAsset? {
        switch source {
        case .none: return nil
        case .file(let url): return CKAsset(fileURL: url)
        case .data(let data):
            // Writing failed when the data was set, so try once more for the save.
            guard let url = try? Self.write(data) else { return nil }
            return CKAsset(fileURL: url)
        }
    }

    /// Marks the data as saved, so it reports no change until it is set again.
    public mutating func markSaved() {
        changedAt = nil
    }

    private static func source(for data: Data?) -> Source {
        guard let data else { return .none }
        return (try? write(data)).map(Source.file) ?? .data(data)
    }

    /// Writes `data` to a new `<UUID>.asset` file in `directory`.
    private static func write(_ data: Data) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(UUID().uuidString).asset", directoryHint: .notDirectory)
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// Two assets are equal when they hold the same file or the same data.
extension AssetField: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source == rhs.source || lhs.data == rhs.data
    }
}

extension AssetField: Hashable {
    public func hash(into hasher: inout Hasher) {
        // Equal assets can live in different files, so hash what they share.
        hasher.combine(data?.count)
    }
}

extension AssetField: Sendable {}
