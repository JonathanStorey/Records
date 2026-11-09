# Records

A Swift persistence package that keeps your models as plain structs. Records stores them in SQLite on
device and syncs them through CloudKit with `CKSyncEngine`, following `CKRecord` conventions. Swift
macros generate the mapping code.

> Skeleton only. No implementation yet.

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
| `Records` | Public library: macros, model protocols, SQLite storage, CKSyncEngine sync |
| `RecordsMacros` | Compiler plugin built on swift-syntax |
| `RecordsTests` | Library tests (Swift Testing) |
| `RecordsMacrosTests` | Macro expansion tests |

## Development

```sh
swift build
swift test
```
