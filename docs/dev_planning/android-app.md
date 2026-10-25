# Android app - plan & tracking

Run Notchline on an Android phone: the same conditions, avalanche danger and ski day planner the Mac shows, with the planner's notifications and ratings. The Mac's notch and menu bar have no Android counterpart, so the phone gets a home screen widget, a full app screen and notifications instead.

## Decisions locked

2026-10-25:

- **One Swift core for both platforms.** `NotchlineCore` is compiled for Android with the Swift SDK for Android rather than ported to Kotlin, so scoring and confidence logic exist once. A spike built the core and its tests for `aarch64-unknown-linux-android28` with Swift 6.4.1 and NDK r30 and ran them on an API 36 arm64 emulator: 170 of 171 passed. The one failure, `sourcesUseTextResponseForText`, reads the repo's sources through `#filePath` and can't find them on a device.
- **UI in Kotlin and Jetpack Compose.** The Mac app layer (AppKit, SwiftUI, DynamicNotchKit) stays Mac only.
- **arm64-v8a only.** Current phones are all arm64. armv7 and x86_64 can be added later if an emulator or device needs them.
- **Platform code stays behind the core's existing seams.** The spike gated MapKit (`#if canImport(MapKit)`), Combine view models (`#if canImport(Combine)`) and added `FoundationNetworking` where `URLSession` lives on Android. `SkiDayPlanner.live(travel:)` takes any `TravelTimeProvider`.
- **No drive times in the Android app. Google Maps does the drive.** The app doesn't estimate drive times or departures. Instead, each planned day has a button that opens Google Maps with driving directions to the resort already loaded (a Maps URL with `api=1`, `destination` set to the location's coordinate and `travelmode=driving`). Google Maps then gives the live ETA and handles navigation. Maps URLs can't set an arrive-by time, so the user checks the ETA in Maps against the lift time the app shows.
- **No departures on Android at all.** The departure planner (departure times, route-midpoint road weather, crowd buffers, the overnight option) and departure reminders are left out rather than approximated. The scores, best windows and confidence are unchanged. The only planner notification is the evening-before summary.

## Open questions

- **Swift to Kotlin bridge.** swift-java (jextract generating Java bindings) or a hand-written JNI layer over a small C-compatible API. swift-java is less code if it handles async and Codable types well enough. Phase 1 decides.
- **View models.** `ConditionsModel` and `PlannerModel` use Combine, which Android lacks. Either Kotlin owns the screen state and calls plain core functions, or the models move to Swift's `@Observable` (Observation ships in the Android SDK), which needs the Mac minimum raised from macOS 13 to 14.
- **Storage paths.** `SnapshotStore` and `PlannerArchive` default to Application Support. On Android the app should pass its own `filesDir` rather than rely on Foundation's mapping.
- **Background refresh.** WorkManager periodic work has a 15 minute floor and Samsung's battery optimization delays or drops it. The evening-before summary may need an exact alarm (`SCHEDULE_EXACT_ALARM`) to arrive at its set time.

## Phases

| Phase | Scope | Status |
|---|---|---|
| 0 | Spike: build `NotchlineCore` and its tests for Android and run them on an emulator | Done 2026-10-25 |
| 1 | Build setup: core as an Android library, Gradle project, Swift to Kotlin bridge, CI build | Not started |
| 2 | Conditions: location picker, current conditions and avalanche danger on an app screen | Not started |
| 3 | Planner: scores, best windows and confidence, with a Google Maps directions button per day | Not started |
| 4 | Background and notifications: periodic refresh, evening-before summaries, ratings | Not started |
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

### Phase 2 - conditions

- Location picker from the bundled `locations.json`.
- Current conditions, forecast, and avalanche danger, in the same units rules as the Mac (`UnitPreference`, per-location defaults).
- Snapshot cache through `SnapshotStore` in the app's files directory, with the Mac's stale and offline behavior.

### Phase 3 - planner

- Planning without departures in the core. `SkiDayPlanner.plan` always runs `DeparturePlanner` today, so `travel` becomes optional and nil skips departures, with no "no route" warning on each day. Tested on the Mac like the rest of the planner.
- Planner section: groomed and ungroomed scores, best windows and confidence, matching the Mac's day picker, with the lift time for the best window.
- A "Directions" button on each day that opens Google Maps driving directions to the location. Maps uses the phone's current location as the start, so the app needs no home address. Fall back to the browser when Google Maps isn't installed.

### Phase 4 - background and notifications

- Periodic refresh and replanning with WorkManager.
- Evening-before summaries from `PlannerNotifications`, delivered through `NotificationManager`. Tapping one opens Google Maps directions for that day's location. With no departure, the summary gives the score and lift time without "leave at".
- Day ratings after last chair, stored with the day's plan in `PlannerArchive`.
- Check delivery on a Samsung device with default battery settings, and tell the user how to exempt the app if summaries arrive late.

### Phase 5 - widget

- Glance widget for the selected location: headline score, the other terrain's score and the best window's lift time, updated after each background refresh. Tapping it opens the app; a directions action opens Google Maps.

### Phase 6 - release

- Release signing and a sideloadable APK built by the same script as Phase 1.
- Decide whether a Play Store listing is worth it. It needs a developer account, a privacy policy and target API upkeep.
