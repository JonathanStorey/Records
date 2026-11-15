# Records Lab

An iPhone app that runs Records the way an app would: on a device, signed in to iCloud. It shows
the pipeline working and finds what breaks.

## Running it

1. Open `Lab/RecordsLab.xcodeproj` in Xcode 16 or later.
2. Select the RecordsLab target, open **Signing & Capabilities**, and choose your team. The bundle
   ID becomes `com.recordslab.<your team ID>` and the iCloud container
   `iCloud.com.recordslab.<your team ID>`.
3. Under **iCloud**, check that container. If it isn't listed, press the refresh button or add it
   with **+**.
4. Run on an iPhone or a simulator signed in to iCloud.

## Tabs

| Tab | What it shows |
| --- | --- |
| Dashboard | The iCloud account, the last save and fetch, what waits to upload per table, and buttons to seed, bulk-add, or erase the catalog. Pull to refresh. |
| Scenarios | Tests grouped by kind, each with its steps, timings, and result. Some ask you to look or tap something. **Report** shares every result as text. |
| Catalog | The app's own records, editable with `@Recordable`, including two editors on one album side by side. |
| Log | What Records and the Lab logged since launch, with sync events under Sync. |

## Groups

| Group | Needs |
| --- | --- |
| Local | Nothing. Runs on any simulator. |
| Round trip, Ghost | iCloud. Works in a zone of its own, `Lab`, so the catalog is never touched. |
| Relaunch | Each scenario asks you to tap **Quit now** and open the Lab again, then finishes on its own. One asks you to turn airplane mode on and off. *Records stay without iCloud* runs only on a device that isn't signed in. |
| Failures | iCloud. Saves a record over 1 MB, which must throw, and uploads an album of 5,000 tracks. |
| Two devices | A second device running the Lab, signed in to the same account. Seed the catalog on one device only and let the other fetch it. |

**Run every scenario** leaves out Relaunch and Two devices, because they quit the app or need you
at both devices. Results are kept across a relaunch until you clear them.

## Results for an agent

Every scenario prints one line when it ends, so a run from Xcode or `xcrun simctl launch --console`
shows results without reading the screen:

```
LAB PASS local.fields in 84 ms
LAB FAIL local.cascade after 31 ms: Its tracks are gone: expected 0, found 5
LAB SKIP relaunch.signedOut: Runs only on a device that isn't signed in to iCloud
LAB SUMMARY 9 passed, 1 failed, 0 skipped: local.cascade
```

Failures are also logged as errors under the subsystem `RecordsLab`.
