# Android app - plan & tracking

Run Notchline on an Android phone: the same conditions, avalanche danger and ski day planner the Mac shows, with the planner's notifications and ratings. The Mac's notch and menu bar have no Android counterpart, so the phone gets a home screen widget, a full app screen and notifications instead.

## Decisions locked

2026-10-25:

- **One Swift core for both platforms.** `NotchlineCore` is compiled for Android with the Swift SDK for Android rather than ported to Kotlin, so scoring and confidence logic exist once. A spike built the core and its tests for `aarch64-unknown-linux-android28` with Swift 6.4.1 and NDK r30 and ran them on an API 36 arm64 emulator: 170 of 171 passed. The one failure, `sourcesUseTextResponseForText`, reads the repo's sources through `#filePath` and can't find them on a device.
- **UI in Kotlin and Jetpack Compose.** The Mac app layer (AppKit, SwiftUI, DynamicNotchKit) stays Mac only.
- **arm64-v8a only.** Current phones are all arm64. armv7 and x86_64 can be added later if an emulator or device needs them.
- **Hand-written JNI bridge, JSON across it.** Kotlin calls a few `external` functions in `android/swift/Sources/NotchlineJNI`. Values cross as UTF-8 JSON in byte arrays, since the core's models are already `Codable` and JNI strings are modified UTF-8, which breaks on emoji. Native calls block until the core's async work finishes, and Kotlin makes them on the IO dispatcher. Chosen in Phase 1 over swift-java, which adds a code generator to the build for a bridge this small.
- **Swift runtime linked statically into the app.** One `libNotchlineJNI.so` (56 MB stripped, mostly ICU data) plus `libc++_shared.so`, against about 100 MB for the shared runtime libraries. Only the device test runner links the runtime dynamically, because Swift Testing ships only as shared libraries.
- **Platform code stays behind the core's existing seams.** The spike gated MapKit (`#if canImport(MapKit)`), Combine view models (`#if canImport(Combine)`) and added `FoundationNetworking` where `URLSession` lives on Android. `SkiDayPlanner.live(travel:)` takes any `TravelTimeProvider`.
- **No drive times in the Android app. Google Maps does the drive.** The app doesn't estimate drive times or departures. Instead, each planned day has a button that opens Google Maps with driving directions to the resort already loaded (a Maps URL with `api=1`, `destination` set to the location's coordinate and `travelmode=driving`). Google Maps then gives the live ETA and handles navigation. Maps URLs can't set an arrive-by time, so the user checks the ETA in Maps against the lift time the app shows.
- **Kotlin owns screen state; the core owns the rules behind it.** Decided in Phase 2. The Combine view models stay Mac only. What they did that Android needs moved into plain core types the Mac models now use too: `ConditionsCache` (the session's snapshots, cached versus refreshed, in-flight refreshes, saving to `SnapshotStore`) and `ConditionsSummary` (every display string, unit rule and stale, outdated and expiry rule of the conditions summary). Phase 3 did the same for the planner with `PlannerSummary`. Kotlin holds the selection and units and decides when to refresh and plan. This keeps the macOS 13 minimum.
- **Snapshots and planner records live in the app's files directory.** Kotlin passes `filesDir` to `configure`, which builds the `SnapshotStore` in `snapshots/` and the `PlannerArchive` in `planner/`, rather than relying on Foundation's Application Support mapping.
- **Alarms deliver notifications; WorkManager refreshes.** Android has no scheduled notifications, so each planner notification is an alarm, exact when the user allows alarms and inexact otherwise. A 30 minute WorkManager job refreshes and replans the selected location in the background and replaces the alarms. Decided in Phase 4.
- **Nothing asks for ratings, on Android or the Mac.** Decided in Phase 4. Whether someone skied doesn't follow from the score or from checking the conditions, so the "Did you ski?" question after every planned day and the rating notification after days over the threshold would nag. Both are gone from the core and both apps. The user rates one of the last seven days when they choose to.
- **No departures on Android at all.** The departure planner (departure times, route-midpoint road weather, crowd buffers, the overnight option) and departure reminders are left out rather than approximated. The scores, best windows and confidence are unchanged. The only planner notification is the evening-before summary.

## Open questions

- **Samsung delivery.** Phase 4's alarms and WorkManager refresh worked on the emulator. Whether Samsung's default battery settings delay them, and whether the in-app battery note is enough, needs a real phone.

## Phases

| Phase | Scope | Status |
|---|---|---|
| 0 | Spike: build `NotchlineCore` and its tests for Android and run them on an emulator | Done 2026-10-25 |
| 1 | Build setup: core as an Android library, Gradle project, Swift to Kotlin bridge, CI build | Done 2026-10-25, CI workflow not yet run |
| 2 | Conditions: location picker, current conditions and avalanche danger on an app screen | Done 2026-10-25 |
| 3 | Planner: scores, best windows and confidence, with a Google Maps directions button per day | Done 2026-10-25, Google Maps not yet tried on a device |
| 4 | Background and notifications: periodic refresh, evening-before summaries, ratings | Done 2026-10-25, not yet checked on a Samsung phone |
| 5 | Widget: home screen widget showing the headline score and lift time | Not started |
| 6 | Release: signing, sideloadable APK, optional Play Store listing | Not started |

### Phase 0 - spike

As built:

- Toolchain: Swift 6.4.1 open-source toolchain through swiftly, `swift-6.4.1-RELEASE_android` SDK, NDK r30. Xcode's toolchain can't cross-compile with the SDK.
- Changes to the core: MapKit drive times and the MapKit route-midpoint test are gated with `#if canImport(MapKit)`. `ConditionsModel`, `PlannerModel` and the tests that use them are gated with `#if canImport(Combine)`. `Providers.swift` imports `FoundationNetworking` when it exists. `SkiDayPlanner.live(travel:)` added; the Mac's `live()` calls it with `MapKitTravelTimes`.
- The repo's `Package.swift` also builds the AppKit app targets, so `--build-tests` for Android fails there. The spike used a throwaway package that symlinked `Sources/NotchlineCore` and `Tests/NotchlineTests`.
- Swift Testing ships in the SDK only as shared libraries, so tests build without `--static-swift-stdlib`. The test runner needs about 20 Swift runtime `.so` files and `libc++_shared.so` pushed beside it. `Bundle.module` finds the resource bundles beside the executable.
- Not run on Android: the Combine view model tests and the MapKit midpoint test. The source-scanning tests in `SharedBehaviorTests` pass vacuously on a device because they find no files.

### Phase 1 - build setup

- Split the manifest so the core and its tests build for Android without the Mac app targets: a separate package for the core, or app targets added only when building on macOS.
- Build `NotchlineCore` as a shared library per ABI and copy it, the Swift runtime libraries and `libc++_shared.so` into the app's `jniLibs`. Decide static versus dynamic Swift runtime for the release build (static is smaller and avoids shipping each runtime `.so`, but tests need dynamic).
- Pick the bridge (see Open questions) and expose a first call end to end: fetch a snapshot for one location and show its JSON in a Compose screen.
- Skip the `#filePath` source-scanning tests when the sources aren't on disk, so a device test run is clean.
- A script or Gradle task that builds the core, runs its tests on a connected device or emulator and assembles a debug APK.

As built:

- `android/swift` is a second Swift package for Android. Its `NotchlineCore` and `NotchlineTests` are symlinks into the root package, so both platforms build the same sources and the root `Package.swift` is unchanged. It adds `CJNI` (exports `<jni.h>`) and `NotchlineJNI`, a dynamic library product with the JNI entry points. `.swift-version` pins the toolchain for swiftly.
- `NotchlineJNI` exposes `configure(locationsJson)` and `refresh(locationId)`. `refresh` returns the snapshot with its errors and warnings. A shared `ConditionsService` keeps provider caches across calls. Errors come back to Kotlin as `IllegalStateException`.
- An app process can't use `Bundle.module`, so the app copies `locations.json` into its assets at build time and passes it to `configure`, which uses `LocationCatalog.load(from:)`. Phase 3 needs the same for `confidence.json`.
- A static FoundationNetworking links curl but not the TLS libraries curl needs, so `NotchlineJNI` links the SDK's static `libssl`, `libcrypto` and the system `libz`. Without them the library fails to load with an unresolved `X509_free`. HTTPS works on the emulator with the system's CA certificates and no extra setup.
- `android/` is a Gradle project (AGP 9.3.1, Gradle 9.6.1, Kotlin with Compose, compileSdk 37 since Compose BOM 2026.09.00 needs it, minSdk 28, targetSdk 36, arm64-v8a only). The `buildNotchlineCore` task runs `scripts/android.sh core` before each build, and AGP strips the library.
- `MainActivity` is the end-to-end check: a chip per location, a Refresh button and the snapshot JSON. It loads live NWS, NWAC and SNOTEL data for Mt. Baker on an API 36 emulator.
- The source-scanning tests use `RepoSources` in `Support.swift` and are skipped when the sources aren't on disk. A device run is 171 tests passing with those 3 skipped.
- `scripts/android.sh` has `core`, `test` (build, push and run the tests on the connected device) and `apk`. `make android` and `make android-test` call it. `.github/workflows/android.yml` builds the APK on macOS for pushes and pull requests that touch the core or the app, and uploads it. It hasn't run yet. Tests need an arm64 device, so CI doesn't run them.

### Phase 2 - conditions

- Location picker from the bundled `locations.json`.
- Current conditions, forecast, and avalanche danger, in the same units rules as the Mac (`UnitPreference`, per-location defaults).
- Snapshot cache through `SnapshotStore` in the app's files directory, with the Mac's stale and offline behavior.

As built:

- Core: `ConditionsCache` and `ConditionsSummary` (see Decisions locked). `ConditionsModel` and the Mac's `ConditionsSummaryView` now use them, so the Mac and Android show the same strings. `MetricState.problems` replaces the Mac's joined tooltip string, since the core doesn't split or join on line breaks. `DangerLevel.badgeText` moved into the core. Tests in `ConditionsSummaryTests.swift` cover both, and run on Android as well as the Mac.
- Bridge: `configure(locationsJson, snapshotsDir)` returns the catalog by region. `conditions(locationId, units)` returns the cached `ConditionsSummary` without fetching. `refresh(locationId, units)` fetches and returns it. `units` is a `UnitPreference` raw value. Phase 1's raw snapshot JSON call is gone.
- App: `ConditionsViewModel` keeps the selected location and units in shared preferences and refreshes on launch, on location change, on returning to the app after 30 minutes (the Mac's default interval) and when the network comes back. While visible it rereads the cached summary each minute so ages and outdated dimming stay current. `ConditionsScreen` has the location picker grouped by region, a units menu, the six metric cells, the avalanche line with the danger scale colors and an "Avalanche forecast" button, and pull to refresh. Tapping a value marked ⓘ shows the last refresh's errors and warnings, where the Mac shows a tooltip.
- Checked on the API 36 emulator: live data for Mt. Baker (imperial) and Whistler (metric), the units override, and a relaunch in airplane mode showing the cached snapshot with failed metrics marked stale with their ages, then refreshing by itself when the network came back. Device tests: 176 passed.
- `scripts/android.sh test` now builds only the test product. `--build-tests` also built a debug `NotchlineJNI`, which fails to link because the static TLS libraries aren't among the SDK's shared ones.

### Phase 3 - planner

- Planning without departures in the core. `SkiDayPlanner.plan` always runs `DeparturePlanner` today, so `travel` becomes optional and nil skips departures, with no "no route" warning on each day. Tested on the Mac like the rest of the planner.
- Planner section: groomed and ungroomed scores, best windows and confidence, matching the Mac's day picker, with the lift time for the best window.
- A "Directions" button on each day that opens Google Maps driving directions to the location. Maps uses the phone's current location as the start, so the app needs no home address. Fall back to the browser when Google Maps isn't installed.

As built:

- Core: `SkiDayPlanner` takes an optional `travel`. nil skips `DeparturePlanner` and road weather, so days have no departures and no "set a home" or "no drive time" warnings. `live(travel:table:http:)` takes the confidence table as a closure, and `ConfidenceTable.load(from:)` reads it from data, since an app process can't use `Bundle.module`. The app copies `confidence.json` into its assets beside `locations.json`.
- Core: `PlannerSummary` holds the planner section's strings per day: day name, scores with the headline first, confidence and its notes, one row per terrain or one "Both" row, the reason nothing scored, and the headline window's lift time. `ScoreHelp.paragraphs` holds the "?" text. The Mac's `PlannerSectionView` now renders from both, so the "Both" row and no-score rules exist once. Tests in `PlannerSummaryTests.swift`.
- Bridge: the location calls take one `LocationRequest` JSON (location, units and the phone's locale for times and weekday names) and return `LocationResponse`: the conditions summary, the latest plan's summary, whether the location was planned yet, and the score help. A new `plan` call plans from the cached snapshot with the default planner settings (45 mph gust threshold) and fetches the comparison models. Plans are kept per location for the session.
- App: each refresh replans, as on the Mac, and a location shown from the cache is planned from it at once. A refresh that lands during a plan replans after it. `PlannerSection` has the day chips, both scores, the best windows, confidence (tap for its notes), the "?" help, planner warnings behind ⓘ, "Be on the lift by" the lift time and a Directions button. Directions opens `https://www.google.com/maps/dir/?api=1&destination=<lat>,<lon>&travelmode=driving` in Google Maps, or in the browser when Maps isn't installed.
- Checked on the API 36 emulator for Whistler: four days, measured confidence with the model spread, and the lift time in the phone's locale. The emulator has no Google Maps, so only the browser fallback was exercised. Device tests: 179 passed. Mac tests: 200 passed.
- Times follow the phone's locale, not Android's separate 24-hour setting.

### Phase 4 - background and notifications

- Periodic refresh and replanning with WorkManager.
- Evening-before summaries from `PlannerNotifications`, delivered through `NotificationManager`. Tapping one opens Google Maps directions for that day's location. With no departure, the summary gives the score and lift time without "leave at".
- Day ratings, stored with the day's plan in `PlannerArchive`.
- Check delivery on a Samsung device with default battery settings, and tell the user how to exempt the app if summaries arrive late.

As built:

- Core: an evening summary with no departure says "On the lift by 8:30 AM." where the departure would go, on the Mac without a home too. `RatingPrompt` holds the rating window's day label, title and forecast note. The rating notification, `PlannerArchive.pendingRating`, `PlannerModel.pendingRating` and `DayRating.didNotSki` are gone; `PlannerNotifications.schedule` no longer takes today's record. Tests in `PlannerAppTests.swift`.
- Mac: the planner section in the notch and the menu has "Rate a day you skied…" in place of the question. It opens the rating window with a day picker over the selected location's last seven days, each starting from its stored rating and times. "I didn't ski" is gone, since the user opens the window only to rate. Tapping a summary or departure reminder still shows that location in the notch.
- Bridge: `configure` takes `filesDir`. Each request also carries the phone's time zone (the summary time is in it) and the planner settings the app has, which decode into `PlannerSettings` with defaults for the rest. `plan` records the plan in the archive as the Mac's `PlannerModel` does and returns the evening summaries from `PlannerNotifications.schedule`. New calls: `ratableDays` lists the days to rate and `rate` stores a rating.
- App: `AppPreferences` holds the selection, units, notification threshold (60 to 90, or off; 80 by default) and summary time (19:00 by default), shared by the screen and the worker. The Settings menu in the top bar replaces the units menu and adds the threshold and a summary time picker.
- App: `PlannerAlarms` replaces every pending alarm after each plan of the selected location, keeps them in preferences, and sets them again after a reboot or update (`RestoreReceiver`). A summary notification opens Google Maps directions to that location, or the browser. `RefreshWorker` runs every 30 minutes with a network, refreshes and replans the selected location, and replaces the alarms.
- Ratings: nothing asks. "Rate a day you skied" under the planner opens a dialog with today and the six days before it at the selected location (`PlannerArchive.recentDays`, the bridge's `ratableDays`). A day already rated is marked ✓ and starts from its rating, and saving replaces it. A day the planner never planned can be rated too, which stores a record with only the rating. Groomed and ungroomed go from 1 to 5. The Mac's optional left-home and on-lift times are left out. `RatingPrompt.dayLabel` gives the picker's Today, Yesterday and weekday names.
- App: the notification permission is asked for once, when the first plan arrives with notifications on. Under the planner, notes with a Settings button appear when notifications are off, when exact alarms aren't allowed, and when battery optimization is on, which tells the user to set battery use to Unrestricted.
- Checked on the API 36 emulator: the worker ran on first launch; at a threshold of 60 two Whistler summaries were scheduled for 19:00. Without the alarms permission Android gave them a one-hour window. With it (granted through adb) and the clock moved to 18:59:50, "Tomorrow at Whistler Blackcomb: 68 groomed, 32 ungroomed / On the lift by 8:30 AM. Confidence 93%." arrived at 19:00, and tapping it opened the directions URL. A reboot restored both alarms. In the rating dialog, today showed ✓ with its stored groomed 4, and rating yesterday, which was never planned, stored a record with only `ungroomed: 3`. Device tests: 181 passed. Mac tests: 202 passed. The Mac's rating window and planner link were built and tested but not looked at in the running app.

### Phase 5 - widget

- Glance widget for the selected location: headline score, the other terrain's score and the best window's lift time, updated after each background refresh. Tapping it opens the app; a directions action opens Google Maps.

### Phase 6 - release

- Release signing and a sideloadable APK built by the same script as Phase 1.
- Decide whether a Play Store listing is worth it. It needs a developer account, a privacy policy and target API upkeep.
