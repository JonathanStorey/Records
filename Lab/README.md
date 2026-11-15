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
| Scenarios | Tests grouped by kind, each with its steps, timings, and result. Some ask you to look or tap something. |
| Catalog | The app's own records, editable with `@Recordable`, including two editors on one album side by side. |
| Log | What Records and the Lab logged since launch, with sync events under Sync. |

## Results for an agent

Every scenario prints one line when it ends, so a run from Xcode or `xcrun simctl launch --console`
shows results without reading the screen:

```
LAB PASS local.fields in 84 ms
LAB FAIL local.cascade after 31 ms: Its tracks are gone: expected 0, found 5
LAB SUMMARY 9 passed, 1 failed: local.cascade
```

Failures are also logged as errors under the subsystem `RecordsLab`.
