import CloudKit
import Foundation

/// Makes a struct a `Record`, with the struct's name as its record type.
///
/// ```swift
/// @Record struct Note {
///     var title: String
/// }
///
/// let note = Note(title: "Groceries")
/// ```
///
/// A struct that declares no `id` gets `var id = Note.ID()`, so each new note has its own ID,
/// which sorts in the order the notes were made. Declare `var id: Note.ID` to supply IDs yourself.
///
/// Generic types must pass a name with `@Record("Name")`.
@attached(member, names: named(id))
@attached(extension, conformances: Record, names: named(recordType), named(schema), named(keyPaths), named(encodeFields), named(referenceStates), named(loadReference), named(assetStates), named(loadAsset), named(_RecordCodingKeys), named(encode(to:)), named(init(from:)))
public macro Record() = #externalMacro(module: "RecordsMacros", type: "RecordMacro")

/// Makes a struct a `Record` with an explicit record type.
///
/// ```swift
/// @Record("Box") struct Box<Value: CKRecordValueProtocol> { ... }
/// ```
@attached(member, names: named(id))
@attached(extension, conformances: Record, names: named(recordType), named(schema), named(keyPaths), named(encodeFields), named(referenceStates), named(loadReference), named(assetStates), named(loadAsset), named(_RecordCodingKeys), named(encode(to:)), named(init(from:)))
public macro Record(_ recordType: String) = #externalMacro(module: "RecordsMacros", type: "RecordMacro")

/// Marks a property that points at other `Record`s: one, as in `@Reference var author: Person?`,
/// or many, as in `@Reference var tags: [Tag]`, sorted by ID, which is the order they were made.
///
/// The property is never written as a field. Records stores each target as a separate link,
/// which `CKRecordEncoder.links(for:in:)` writes. A decoded record has `nil` or `[]` here
/// until its links are loaded. A to-one reference must be optional and a to-many reference a
/// non-optional array, in a `var` with no initial value. Either may point at its own type.
///
/// Where loading stopped, the property reads `nil` or `[]` even when it has targets.
/// `$name` gives the IDs either way: `album.$tracks.ids`, `album.$artist.id`.
///
/// The property is read-only after the record is made. Change its targets through `$name` and a
/// context: `album.$tracks.insert(track, in: context)`, `album.$artist.set(nova, in: context)`.
@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(_), prefixed(`$`))
public macro Reference() = #externalMacro(module: "RecordsMacros", type: "ReferenceMacro")

/// Marks a to-many property whose records are sorted by their fields instead of by ID, using the
/// same parameters as SwiftData's `@Query`.
///
/// ```swift
/// @Reference(sort: [SortDescriptor(\Tag.name)]) var tags: [Tag]
/// ```
///
/// The records are sorted each time the property is read. `$tags.ids` stays sorted by ID, because
/// sorting by fields needs the records.
@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(_), prefixed(`$`))
public macro Reference<Element: Record>(sort descriptors: [SortDescriptor<Element>]) = #externalMacro(module: "RecordsMacros", type: "ReferenceMacro")

/// Marks a to-many property whose records are sorted by one descriptor, as in
/// `@Reference(sort: SortDescriptor(\Tag.name)) var tags: [Tag]`. See `Reference(sort:)`.
@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(_), prefixed(`$`))
public macro Reference<Element: Record>(sort descriptor: SortDescriptor<Element>) = #externalMacro(module: "RecordsMacros", type: "ReferenceMacro")

/// Marks a to-many property whose records are sorted by one field, as in
/// `@Reference(sort: \Tag.name, order: .reverse) var tags: [Tag]`. See `Reference(sort:)`.
@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(_), prefixed(`$`))
public macro Reference<Element: Record, Value: Comparable>(sort keyPath: KeyPath<Element, Value>, order: SortOrder = .forward) = #externalMacro(module: "RecordsMacros", type: "ReferenceMacro")

/// Marks a to-many property whose records are sorted by one optional field, as in
/// `@Reference(sort: \Album.year) var albums: [Album]` where `year` is an `Int?`.
@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(_), prefixed(`$`))
public macro Reference<Element: Record, Value: Comparable>(sort keyPath: KeyPath<Element, Value?>, order: SortOrder = .forward) = #externalMacro(module: "RecordsMacros", type: "ReferenceMacro")

/// Marks the read-only side of a two-way relationship, naming the owner's property.
///
/// ```swift
/// // One-to-one
/// @Reference var profile: Profile?                                      // on User
/// @Reference(from: \User.profile, deleteSelf: true) var userID: User.ID? // on Profile
///
/// // One-to-many, owned by the many side: links are written per book, unordered
/// @Reference var shelf: Shelf?                                       // on Book
/// @Reference(from: \Book.shelf) var bookIDs: [Book.ID]               // on Shelf
///
/// // One-to-many, owned by the one side: tracks are deleted with their album
/// @Reference var tracks: [Track]                                     // on Album
/// @Reference(from: \Album.tracks, deleteSelf: true) var albumID: Album.ID? // on Track
///
/// // Many-to-many: the note holds its tags, and each tag lists its notes
/// @Reference var tags: [Tag]                                         // on Note
/// @Reference(from: \Note.tags) var noteIDs: [Note.ID]                // on Tag
/// ```
///
/// This side always holds the owner's IDs, such as `User.ID?` or `[Book.ID]`. The owner holds
/// records, because its code chose them. This side is a back-pointer: anything can point at a record, so loading every
/// owner would have no limit. To show an owner's fields, fetch it by ID, or make this side the
/// owner instead.
/// The owner writes the links, each naming only the owner's property, such as `User.profile`. This
/// side never writes links, so renaming it never rewrites one. Adding a to-one side to a to-many
/// owner does change its link IDs, because a one-to-many link leaves out the source. This side is
/// filled from the owner's links when the record is decoded, and can only be set when the record
/// is made. A to-many side lists its owners sorted by ID. With
/// `deleteSelf: true`, which needs a to-one side, the record is deleted when its owner is deleted.
@attached(accessor, names: named(init), named(get))
@attached(peer, names: prefixed(_), prefixed(`$`))
public macro Reference<Owner: Record, Value>(from owner: KeyPath<Owner, Value>, deleteSelf: Bool = false) = #externalMacro(module: "RecordsMacros", type: "ReferenceMacro")

/// Stores a field of a `@Record` in the record's `encryptedValues`, so CloudKit encrypts it with
/// a key only the user's devices hold.
///
/// ```swift
/// @Record struct Account {
///     var name: String
///     @Encrypted var note: String
/// }
/// ```
///
/// An encrypted field can hold strings, numbers, dates, data, locations, and arrays of them, but
/// not a `CKAsset`. CloudKit can't index or query it on the server, and a field can't switch between
/// encrypted and plain once its schema is deployed.
@attached(peer)
public macro Encrypted() = #externalMacro(module: "RecordsMacros", type: "MarkerMacro")

/// Stores a `Data?` field of a `@Record` as a `CKAsset`, for images and files too large to keep
/// in the record itself.
///
/// ```swift
/// @Record struct Album {
///     @Asset var cover: Data?
/// }
///
/// album.cover = pngData    // written to a new .asset file right away
/// album.$cover             // that file's URL
/// album.cover              // read from the file only when asked for
/// ```
///
/// The asset isn't a field of the record. It is stored on its own link for `Album.cover`, so
/// saving the record's other fields never uploads it again. Each new value gets a new ID and its
/// own `<ID>.asset` file in `AssetField.directory`. CloudKit can't encrypt an asset, so a property
/// can't be both `@Asset` and `@Encrypted`.
@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(_), prefixed(`$`))
public macro Asset() = #externalMacro(module: "RecordsMacros", type: "AssetMacro")

/// Stores a `Coordinate?` property as an encrypted location.
///
/// The property reads and sets a `Coordinate`, a plain value that is easy to compare and encode.
/// `$name` reads and sets the full `CLLocation`, keeping its timestamp, accuracy, course, and speed
/// for code that needs them.
///
/// A location says where someone is, so it is always end-to-end encrypted. `@Encrypted` on it is
/// allowed but changes nothing.
///
/// ```swift
/// @Location var venue: Coordinate?
/// ```
@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(_), prefixed(`$`))
public macro Location() = #externalMacro(module: "RecordsMacros", type: "LocationMacro")

/// A date the server keeps for every record.
public enum Timestamp: Sendable {
    /// When the record was first saved.
    case created
    /// When the record was last saved, from any device.
    case modified
}

/// Reads a date the server keeps for every record, in place of a field.
///
/// The server's clock sets it, so it is the same on every device. It is `nil` until the record is
/// first saved, can't be assigned, and stays out of the memberwise initializer.
///
/// ```swift
/// @Timestamped(.created) var createdAt: Date?
/// @Timestamped(.modified) var modifiedAt: Date?
/// ```
@attached(accessor, names: named(get))
@attached(peer, names: prefixed(_))
public macro Timestamped(_ timestamp: Timestamp) = #externalMacro(module: "RecordsMacros", type: "TimestampedMacro")

/// Stores a field of a `@Record` under its original CloudKit name after the Swift property is
/// renamed, so records already saved keep their data.
///
/// ```swift
/// @Renamed("released") var year: Int   // was `var released: Int`
/// ```
@attached(peer)
public macro Renamed(_ originalName: String) = #externalMacro(module: "RecordsMacros", type: "MarkerMacro")
