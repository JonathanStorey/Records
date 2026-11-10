# Records

A Swift persistence package that keeps your models as plain structs. Records maps them to
`CKRecord`s, with relationships stored as their own link records, and will store them in SQLite on
device and sync them through CloudKit with `CKSyncEngine`. Swift macros generate the mapping code.

> **Status:** the macros, the encoder, and the decoder are built and tested. The SQLite store and
> sync are not built yet.

- [Defining records](#defining-records)
- [References](#references)
- [Every relationship, by example](#every-relationship-by-example)
- [Choosing the owner](#choosing-the-owner)
- [Opening a container](#opening-a-container)
- [Writing records](#writing-records)
- [Saving and loading](#saving-and-loading)
- [What loading returns](#what-loading-returns)
- [Not built yet](#not-built-yet)

## Defining records

Mark a struct with `@Record`. It needs an `id: UUID`, which becomes the record name. Every other
stored property becomes a field of the same name.

```swift
import Records

@Record
struct Tag {
    var id: UUID
    var name: String
}
```

Mark a field `@Encrypted` to store it in the record's `encryptedValues`, so CloudKit encrypts it
with a key only the user's devices hold:

```swift
@Record
struct Listener {
    var id: UUID
    var name: String
    @Encrypted var email: String?
}
```

An encrypted field can't be a `CKAsset` and can't be queried on the server, and once its schema is
deployed it can't switch between encrypted and plain.

Mark a `Data?` field `@Asset` to store it as a `CKAsset`, for images and files too large for the
record itself:

```swift
@Record
struct Artwork {
    var id: UUID
    @Asset var image: Data?
}

artwork.image = pngData   // written to a new .asset file right away
artwork.$image            // that file's URL, ready for an image view
artwork.image             // read from the file only when asked for
```

The asset isn't a field of the record. It rides on its own link for `Artwork.image`, so
editing the record's other fields never uploads it again. Each new value gets a new ID and its own
`<ID>.asset` file in `Application Support/Records/Assets`, and the link carries that ID, so two
devices can tell whether they hold the same image without comparing the data. Loading a list never
reads the data until you ask for it. An asset can't be `@Encrypted`.

Mark a `Coordinate?` field `@Location` to store a place. The property is a plain value that is easy
to compare and encode, and `$name` is the full `CLLocation` for code that needs its timestamp,
accuracy, course, or speed:

```swift
@Record
struct Gig {
    var id: UUID
    @Location var venue: Coordinate?
}

gig.venue = Coordinate(latitude: 51.5009, longitude: -0.1773)
gig.venue?.latitude       // 51.5009
gig.$venue                // the CLLocation, with every detail it was saved with
gig.$venue = gpsFix       // keeps the fix's timestamp and accuracy
```

A location says where someone is, so it is always encrypted end to end, with no `@Encrypted`
needed.

Read the dates the server keeps for every record with `@Timestamped`:

```swift
@Timestamped(.created) var createdAt: Date?
@Timestamped(.modified) var modifiedAt: Date?
```

They come from the server's clock, so they match on every device, and `.modified` is the one to sort
a "recently updated" list by. They are `nil` until the record is first saved. They can't be assigned
and stay out of the memberwise initializer.

A field can hold any type CloudKit stores, such as `String`, `Int`, `Double`, `Bool`, `Date`, `Data`,
`CLLocation`, or an array of them. An enum with such a raw value is stored as its raw value, and any
other `Codable` type is stored as JSON:

```swift
enum Mood: String, Codable { case calm, energetic }
struct Credits: Codable { var producer: String; var engineer: String }

@Record
struct Track {
    var id: UUID
    var mood: Mood          // stored as "calm" or "energetic"
    var credits: Credits    // stored as JSON
}
```

To rename a property after its schema is deployed, keep its CloudKit name with `@Renamed`:

```swift
@Renamed("released") var year: Int   // was `var released: Int`
```

The record type is the struct's name. Pass a name to use another, which generic types must do:
`@Record("Tag")`.

### Changing a record

Records keeps no schema versions, because CloudKit's schema only grows. Change a record this way:

- **Rename** a type with `@Record("OldName")` and a field with `@Renamed("oldName")`.
- **Add** a field as an optional or with a default, because records saved before it existed don't
  have it.
- **Stop using** a field by deleting the property. Its data stays in CloudKit.
- **Never change a field's type.** Add a new field and stop writing the old one.

### Codable

A record can also conform to `Codable`. Declare it on the struct itself, and `@Record` writes
`encode(to:)` and `init(from:)`, keyed by each property's Swift name:

- A reference encodes its target IDs, so a decoded record holds IDs only, as after a load with
  depth 0.
- An `@Asset` encodes its ID. The data stays in its file, which a decoded record finds again on the
  same device.
- A `@Location` encodes its coordinate.
- `@Timestamped` dates are left out, since they come from storage.

A record that writes either method itself keeps its own.

## References

A property that points at other records is marked `@Reference`. It is never written as a field.
Each target is stored as a separate link record instead, so two devices can change different
links on the same record without conflicting.

There are three forms:

| Form | Declaration | Holds |
| --- | --- | --- |
| Records | `@Reference var artist: Artist?` or `@Reference var tags: [Tag]` | The records themselves |
| IDs | `@Reference(Genre.self) var genreID: UUID?` or `@Reference(Listener.self) var followingIDs: [UUID]` | Only the IDs |
| Read side | `@Reference(from: \Album.artist) var albumIDs: [UUID]` | The IDs of the records that point here |

Three rules cover every relationship:

1. **The side without `from:` owns the links.** It writes them when it is saved. The `from:`
   side never writes links. It is filled from the owner's links when the record is decoded, and
   can only be set when the record is made.
2. **A `from:` side always holds IDs**, `UUID?` or `[UUID]`. Anything can point at a record, so
   loading every owner as a record would have no limit. To show an owner's fields, fetch it by
   ID, or make the other side the owner.
3. **A to-one reference is optional and a to-many reference is a non-optional array.** A to-many
   owner keeps its order. A `from:` array lists its owners in the order their links were created.

A `from:` side names the owner's property with a key path. That makes the relationship two-way,
and determines its shape:

| Owner | `from:` side | Relationship |
| --- | --- | --- |
| to-one | to-one | one-to-one |
| to-one | to-many | one-to-many, owned by the many side |
| to-many | to-one | one-to-many, owned by the one side |
| to-many | to-many | many-to-many |
| either | none | one-way: many-to-one or many-to-many |

### Sorting instead of ordering

A to-many owner keeps the order you give it. To sort by the targets' fields instead, pass `sort:`
with the same parameters as SwiftData's `@Query`:

```swift
@Reference(sort: \Tag.name) var tags: [Tag]
@Reference(sort: \Album.year, order: .reverse) var albums: [Album]
@Reference(sort: SortDescriptor(\Track.title)) var tracks: [Track]
@Reference(sort: [SortDescriptor(\Track.disc), SortDescriptor(\Track.number)]) var all: [Track]
```

A sorted reference sorts each time it's read, and its links carry no order keys, so reordering it
never writes anything. `$tags` lists the IDs unsorted, because sorting needs the records.

## Every relationship, by example

These examples build one music library: artists, albums, tracks, artwork, genres, tags,
playlists, and listeners.

```swift
@Record
struct Artist {
    var id: UUID
    var name: String
    @Reference(from: \Album.artist) var albumIDs: [UUID]
}

@Record
struct Album {
    var id: UUID
    var title: String
    var year: Int
    @Reference var artist: Artist?
    @Reference var tracks: [Track]
    @Reference var cover: Artwork?
    @Reference(Genre.self) var genreID: UUID?
}

@Record
struct Artwork {
    var id: UUID
    var url: String
    @Reference(from: \Album.cover, deleteSelf: true) var albumID: UUID?
}

@Record
struct Track {
    var id: UUID
    var title: String
    var seconds: Int
    @Reference(from: \Album.tracks, deleteSelf: true) var albumID: UUID?
    @Reference var tags: [Tag]
    @Reference var featuring: [Artist]
    @Reference var remixOf: Track?
    @Reference(from: \Playlist.tracks) var playlistIDs: [UUID]
}

@Record
struct Tag {
    var id: UUID
    var name: String
}

@Record
struct Genre {
    var id: UUID
    var name: String
    @Reference(Genre.self) var parentID: UUID?
}

@Record
struct Playlist {
    var id: UUID
    var name: String
    @Reference var curator: Listener?
    @Reference var tracks: [Track]
    @Reference(Playlist.self) var folderID: UUID?
}

@Record
struct Listener {
    var id: UUID
    var name: String
    @Reference(from: \Playlist.curator) var playlistIDs: [UUID]
    @Reference var favorite: Track?
    @Reference(Listener.self) var followingIDs: [UUID]
}
```

### One-way to-one

A listener has one favorite track. Many listeners can share it, so this is many-to-one. The track
doesn't know who favorited it.

```swift
@Reference var favorite: Track?        // on Listener
```

### One-way to-many

A track has ordered tags. Many tracks can share a tag, so this is many-to-many. The tag doesn't
list its tracks. `Track.featuring: [Artist]` works the same way.

```swift
@Reference var tags: [Tag]             // on Track
```

### Holding only IDs

When you don't want the target's record loaded, hold its ID and name its type. Use this when you
have the ID but not the record, such as from a picker or a URL, or when a to-many list could grow
large.

```swift
@Reference(Genre.self) var genreID: UUID?              // on Album
@Reference(Listener.self) var followingIDs: [UUID]     // on Listener
```

### Pointing at the same type

Any form can point at its own type. A track can be a remix of another track, and a genre can sit
under a parent genre.

```swift
@Reference var remixOf: Track?                  // on Track
@Reference(Genre.self) var parentID: UUID?      // on Genre
```

A `from:` side can name a property of its own type, too:
`@Reference(from: \Employee.manager) var reportIDs: [UUID]`.

### One-to-one

An album has one cover, and a cover belongs to one album. The album owns the link. The artwork
names it with `from:`, and `deleteSelf: true` deletes the artwork with its album.

```swift
@Reference var cover: Artwork?                                             // on Album
@Reference(from: \Album.cover, deleteSelf: true) var albumID: UUID?        // on Artwork
```

### One-to-many, owned by the many side

An album has one artist, and an artist has many albums. Each album owns its own link, so adding an
album writes one link and never touches the artist. The artist lists its albums by ID.

```swift
@Reference var artist: Artist?                          // on Album
@Reference(from: \Album.artist) var albumIDs: [UUID]    // on Artist
```

`Playlist.curator` and `Listener.playlistIDs` are another example.

### One-to-many, owned by the one side

An album has ordered tracks, and a track is on one album. The album owns the links, so it keeps
the order, and `deleteSelf: true` deletes the tracks with their album. Adding a track to a second
album moves it there, because a track's link is keyed by the track alone.

```swift
@Reference var tracks: [Track]                                             // on Album
@Reference(from: \Album.tracks, deleteSelf: true) var albumID: UUID?       // on Track
```

### Many-to-many

A playlist has ordered tracks, and a track can be on many playlists. The playlist owns the links
and keeps their order. The track lists its playlists by ID.

```swift
@Reference var tracks: [Track]                              // on Playlist
@Reference(from: \Playlist.tracks) var playlistIDs: [UUID]  // on Track
```

A one-way to-many reference like `Track.tags` is already many-to-many, so adding a `from:` side
later keeps every existing link.

## Choosing the owner

The owner is the side your code edits, and the side whose order matters.

- **Put the owner on the side you display with the other's fields.** An album shows its tracks and
  its artist's name, so the album owns both.
- **For one-to-many, choose by order and deletion.** Owned by the one side, the list is ordered by
  hand and can delete its members. Owned by the many side, adding a member never touches the one
  side, and the list is ordered by creation.
- **`deleteSelf` always flows from the owner to the `from:` side**, and only onto a to-one `from:`
  side. To delete tracks with their album, the album must own the tracks.
- **Only one `from:` side can name a given owner property.**

## Opening a container

`RecordContainer` keeps records on device in SQLite and will sync them with CloudKit.

```swift
let container = try RecordContainer(for: Album.self)
```

Every type a registered type refers to is registered too, so `Album` brings `Track`, `Artist`, and
`Genre`. Opening checks the types against each other and throws a `RecordContainerError` that names
the problem: two types with the same record type, a field name starting with an underscore, or a
`@Reference(from:)` that names a property not pointing back. It then creates a table for each type,
or updates the table when fields were added or removed.

The database lives at `Application Support/Records/default.records` and syncs with the app's default
iCloud container. One container holds every zone. Tests and previews can use a throwaway database:

```swift
let preview = try RecordContainer.inMemory(for: Album.self)
```

To share the database with the app's extensions and widgets, pass its app group:
`RecordContainer(for: Album.self, appGroup: "group.com.example.music")`.

## Writing records

Records are read and written through a `RecordContext`. The main actor uses the container's
`mainContext`.

```swift
let context = container.mainContext
context.insert(album)
context.insert(artist)
try context.save()           // both in one transaction

album.title = "Kind of Blue (Remastered)"
context.insert(album)        // replaces the saved copy when saved
context.delete(oldAlbum)
try context.save()
```

`insert` and `delete` stage changes in the context. Nothing reaches the database until `save()`,
which writes every staged change in one transaction. `rollback()` discards them, and
`hasChanges` tells you whether any are waiting. `changes` lists the current zone's staged
changes, such as `.insert(album)`. Inserting a record again replaces its change, so each record
appears once per zone. `save()` writes the changes of every zone.

Inserting a record that is already saved makes the copy you pass its new value. Saving writes
only the fields and links that differ from the saved copy, keeps the creation date, and removes
links to targets the record no longer has.

A reference that holds records can hold new ones. When saved, any target that exists nowhere yet
(not saved in the zone and not staged) is inserted too, along with its own new targets. A target
that already exists is never written from a record that refers to it, so an old copy can't
overwrite newer values. Insert it directly to save changes to it.

Records go to the context's `zone`, `Records` unless you set another. Set it to switch zones at
any time. `Zone.local` keeps records on this device without syncing them. As in CloudKit, a record is
named by its zone and ID together, so the same record can be saved to more than one zone.

```swift
context.zone = "Work"
context.insert(note)   // staged for the Work zone
```

## Reading records

```swift
let album = try context.record(id: albumID, for: Album.self)   // Album?
let any = try context.record(id: someID)                       // (any Record)?
```

Both look in the context's `zone` and return `nil` when the record is missing or deleted. A
staged change comes first: a staged insert returns the staged record, and a staged delete returns
`nil`. References hold their targets' IDs. Without a type, one indexed query finds the table that
holds the ID.

## Fetching records

```swift
let albums = try context.fetch(RecordDescriptor<Album>(
    predicate: #Predicate { $0.year > 1970 && $0.title.contains("Blue") },
    sortBy: [SortDescriptor(\.title)],
    fetchLimit: 50
))
let count = try context.fetchCount(RecordDescriptor<Album>())
```

`RecordDescriptor` takes Foundation's `#Predicate` and `SortDescriptor`, as SwiftData's
`FetchDescriptor` does. `fetch` looks in the context's `zone` and includes staged changes: a
staged insert is returned as staged, and a staged delete leaves its record out. References hold
their targets' IDs.

The parts of a predicate the database can check run there, so only matching rows are read:
comparisons of numbers, Booleans, dates, enums, `nil`, and the `id`, string equality, `&&`,
`||`, `!`, and `[...].contains($0.property)`. Everything else, such as `contains` on a string or
a computed property, is checked in Swift on the rows read. Either way the results are the same.

When the whole predicate runs in the database and every sort is by a number or a date, the
database also sorts and applies `fetchLimit` and `fetchOffset`, so only the records returned are
read. `fetchCount` then counts without reading any. Staged changes to the type, a string sort, or
a predicate part Swift has to check keep the sorting and limiting in Swift.

## Saving and loading

`CKRecordEncoder` turns a record into a `CKRecord`, plus a link record for each target its
references point at. `CKRecordDecoder` turns them back.

```swift
let zone: Zone = "Music"
let encoder = CKRecordEncoder()

let album = Album(
    id: UUID(), title: "Signal Fires", year: 2019,
    artist: nova, tracks: [ignition, bloom], cover: art, genreID: indie.id
)

let record = encoder.encode(album, in: zone)                      // the album's fields
let links = encoder.links(for: album, in: zone, existing: saved)  // every link it has now
```

Pass the links the record already has as `existing`, and each track keeps its order key wherever it
still sorts in place, so reordering tracks changes only the links of the tracks that moved.
Pointing a to-one reference somewhere else keeps its link's ID and changes its target. Comparing
the result with `existing` gives the links to write and the ones to delete. A record's links cover
only its own references, so a record loaded inside another, such as `album.tracks[0]`, is saved
on its own.

To decode, pass the record, the links, and any target records you have:

```swift
let decoder = CKRecordDecoder()
let album = try decoder.decode(Album.self, from: record, links: allLinks, targets: trackAndArtistRecords)
```

`links` can hold every link in the zone. The decoder uses the ones whose owner is this record, and,
for `from:` properties, the ones that point at it. It skips links it can't read.

## What loading returns

Loading stops one level deep, so a fetch never grows into the whole graph.

```swift
let album = try decoder.decode(Album.self, from: record, links: links, targets: targets)

album.tracks.map(\.title)    // ["Ignition", "Static Bloom"]: level one holds records
album.artist?.name           // "Nova Static"

let track = album.tracks[0]
track.albumID                // the album's ID: IDs are always filled
track.playlistIDs            // every playlist's ID
track.tags                   // []: level two doesn't load records
```

A record-form reference at level two reads as `nil` or `[]` even when it has targets, but it still
holds their IDs, so its links stay the same. To tell "empty" from "not loaded", read the
reference's `$` projection, which holds the IDs either way:

```swift
track.tags               // []: the records weren't loaded at this level
track.$tags              // [energetic.id, live.id]: every ID, loaded or not
track.tags.count == track.$tags.count   // false here, so the tags weren't loaded
album.$cover             // nil only when the album truly has no cover
```

`$name` is `[UUID]` or `UUID?`, read-only, and as visible as the property, so a public record exposes it too. ID-form
and `from:` references don't have one, because they are always complete.

To load further, pass `depth:`. Each level multiplies what's loaded, so ask for depth only where a
screen shows it.

```swift
let album = try decoder.decode(Album.self, from: record, links: links, targets: targets, depth: 2)
album.tracks[0].tags.map(\.name)   // ["energetic", "live"]: level two holds records too

let bare = try decoder.decode(Album.self, from: record, links: links, depth: 0)
bare.tracks                        // []: depth 0 loads no records
bare.$tracks                       // but every ID is there
```

Depth also makes cycles safe. A mentor who mentors their mentor loads back and forth until the
depth runs out, then holds only an ID.

## Not built yet

- Saving to and loading from the container. The tables exist, and the store will keep the last
  synced copy of each record, so it finds the fields and links that changed by comparing against
  it, and uploads only those.
- `CKSyncEngine` sync.
- Deletion with `deleteSelf`. The container knows the flag from each type's `@Reference(from:)`
  declaration, and the store will delete the targets.
- Exclusivity for one-to-one. Two albums can each point at the same artwork until the store
  enforces it.

## Requirements

| Platform | Minimum |
| --- | --- |
| iOS / iPadOS / Mac Catalyst | 17 |
| macOS | 14 |
| tvOS | 17 |
| watchOS | 10 |
| visionOS | 1 |

Swift 6 toolchain (Xcode 16 or later). The floor is set by `CKSyncEngine`. Macros alone would allow
lower versions.

## Layout

| Target | Role |
| --- | --- |
| `Records` | Public library: macros, model protocols, encoder and decoder |
| `RecordsMacros` | Compiler plugin built on swift-syntax |
| `RecordsTests` | Library tests (Swift Testing) |
| `RecordsMacrosTests` | Macro expansion tests |

## Development

```sh
swift build
swift test
```
