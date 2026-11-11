import CloudKit
import Foundation

/// The storage behind an `@Asset` property: the asset's ID and the file that holds its data.
///
/// Each value gets a new ID, which names its file, `<id>.asset` in `directory`, and is stored on
/// the asset's link, so two devices can tell whether they hold the same data without comparing
/// it. Setting the property writes the file right away, so `$name` always has a URL to hand to a
/// view. Setting `$name` to a file copies it in instead, without reading it into memory. Reading the property reads that file, so a record that is loaded but never asked for its
/// data never loads it.
public struct AssetField {
    /// Where asset files are kept: `Application Support/Records/Assets`.
    public static let directory: URL = URL.applicationSupportDirectory
        .appending(path: "Records", directoryHint: .isDirectory)
        .appending(path: "Assets", directoryHint: .isDirectory)

    private enum Source: Equatable {
        case none
        case file(URL)
        /// Data that couldn't be written to a file, kept in memory instead.
        case data(Data)
    }

    /// Identifies this value of the data, or `nil` when there is none.
    public private(set) var id: UUID?
    private var source: Source

    /// Data set in code, written to a new file.
    public init(_ data: Data?) {
        (id, source) = Self.store(data)
    }

    /// An asset read from storage. Its own file is used when it is on this device, otherwise
    /// `file`, such as the one CloudKit downloaded.
    public init(id: UUID?, file: URL?) {
        self.id = id
        if let id, FileManager.default.fileExists(atPath: Self.url(for: id).path) {
            source = .file(Self.url(for: id))
        } else {
            source = file.map(Source.file) ?? .none
        }
    }

    /// The asset's data, read from its file each time. Setting it gives it a new ID and file.
    public var data: Data? {
        get {
            switch source {
            case .none: nil
            case .file(let url): try? Data(contentsOf: url)
            case .data(let data): data
            }
        }
        set {
            (id, source) = Self.store(newValue)
        }
    }

    /// The file that holds the data, or `nil` when there is none.
    ///
    /// Setting it to a file gives the asset a new ID and copies the file in as its `.asset` file,
    /// without reading the data into memory. When the copy fails, the asset uses the file where it
    /// is. Setting it to `nil` clears the asset.
    public var fileURL: URL? {
        get {
            if case .file(let url) = source { url } else { nil }
        }
        set {
            (id, source) = Self.store(file: newValue)
        }
    }

    /// An asset holding a copy of the file at `url`, read only when its data is asked for.
    public init(contentsOf url: URL) {
        (id, source) = Self.store(file: url)
    }

    /// The file to save, writing it first if that failed when the data was set.
    var savedFileURL: URL? {
        switch source {
        case .none: return nil
        case .file(let url): return url
        case .data(let data):
            guard let id else { return nil }
            return try? Self.write(data, id: id)
        }
    }

    /// The asset as its link needs it. `property` is the name the link is stored under.
    public func state(property: String) -> AssetState {
        AssetState(property: property, id: id, fileURL: savedFileURL)
    }

    /// The file for the asset with `id`.
    public static func url(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).asset", directoryHint: .notDirectory)
    }

    private static func store(_ data: Data?) -> (UUID?, Source) {
        guard let data else { return (nil, .none) }
        let id = UUID()
        return (id, (try? write(data, id: id)).map(Source.file) ?? .data(data))
    }

    private static func store(file url: URL?) -> (UUID?, Source) {
        guard let url else { return (nil, .none) }
        let id = UUID()
        return (id, .file((try? copy(url, id: id)) ?? url))
    }

    /// Copies the file at `url` in as the asset with `id`. On APFS the copy is a clone, so it
    /// takes no time or space until either file changes.
    private static func copy(_ url: URL, id: UUID) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = Self.url(for: id)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    private static func write(_ data: Data, id: UUID) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = url(for: id)
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// Two assets are equal when they have the same ID, so the same data.
extension AssetField: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }
}

extension AssetField: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension AssetField: Sendable {}

/// One `@Asset` as the encoder needs it to write its link.
public struct AssetState: Equatable, Sendable {
    /// The name the link is stored under: the property's name, or its `@Renamed` name.
    public let property: String
    /// The asset's ID, or `nil` when the property is `nil` and has no link.
    public let id: UUID?
    /// The file that holds the data.
    public let fileURL: URL?
}
