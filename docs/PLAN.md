# Notchline: Implementation Plan

A lightweight native macOS menu bar app that shows mountain conditions in the MacBook notch, in the style of MenuScores. It starts with snow and avalanche conditions at ski areas in Washington and British Columbia, and is designed so other locations and condition types can be added later.

## Goal

For the selected location, at a glance in the notch:

| Metric | Meaning |
|---|---|
| Base | Current observed snow depth at a station near the ski area base |
| Last 24h | Observed new snow in the last 24 hours |
| Next 24h | Forecast snowfall for the next 24 hours |
| Avalanche | Current backcountry avalanche danger for the forecast zone containing the location |

Compact notch view example: `❄ 61" · +8" / +12" · ⚠ 3`
Expanded view: each metric with label, units, data age and source, danger by elevation band, and links to the full avalanche forecast and station page.

The user picks the location from a list. Mt. Baker is the default and the first one built end to end.

## Launch locations

| ID | Name | Region | Avalanche center |
|---|---|---|---|
| `mt-baker` | Mt. Baker Ski Area | WA | NWAC (avalanche.org) |
| `stevens-pass` | Stevens Pass | WA | NWAC (avalanche.org) |
| `snoqualmie` | The Summit at Snoqualmie | WA | NWAC (avalanche.org) |
| `crystal` | Crystal Mountain | WA | NWAC (avalanche.org) |
| `whistler` | Whistler Blackcomb | BC | Avalanche Canada |
| `revelstoke` | Revelstoke Mountain Resort | BC | Avalanche Canada |
| `sun-peaks` | Sun Peaks Resort | BC | Avalanche Canada |

Mt. Baker ships first (Phases 1 to 3). The other WA locations reuse the same data sources and mostly need configuration. BC locations need different sources (see below) and come in Phase 5.

## Non-goals (v1)

- Showing more than one location at a time
- Locations outside WA and BC
- Widgets, iOS, notifications beyond a simple "new snow" alert
- Resort-reported snow reports (only updated in season and published inconsistently). Observed data comes from public weather stations instead, which run year-round.

## Tech stack

- Swift 5.9+, SwiftUI, Swift Concurrency (async/await)
- macOS 13+ (DynamicNotchKit's minimum)
- [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit) via Swift Package Manager (MIT license)
- No third-party networking or JSON libraries. `URLSession` + `Codable` only.
- Swift Package Manager only, no Xcode project. Built and tested from the command line with `swift build` / `swift test`; any editor works.
  - `NotchlineCore` library target: models, providers, service, cache. No UI imports, so it is unit tested on its own.
  - `Notchline` executable target: SwiftUI app, menu bar, notch.
  - `NotchlineTests` test target for `NotchlineCore`.
- A `Makefile` (or `scripts/bundle.sh`) assembles `Notchline.app` from the release binary: copies it into `Contents/MacOS`, adds `Info.plist` (`LSUIElement`, bundle ID, version) and resources, and signs it with the existing Apple Development certificate in the login keychain (`codesign --force --options runtime --timestamp -s "$SIGN_IDENTITY"`). `SIGN_IDENTITY` defaults to that certificate's name and can be overridden from the environment. A real, signed bundle is needed for `LSUIElement` and for `SMAppService` launch at login to persist across rebuilds.
- An Apple Development certificate covers running on this Mac. Distributing to other Macs (Homebrew cask, downloads) would need a Developer ID Application certificate plus notarization (`notarytool`), added as a `make release` step only if that becomes a goal.
- An Xcode app target is added only if something forces it later (for example notarized distribution that is easier with Xcode archives). Nothing in v1 requires one.

Why Swift rather than Rust: the notch UI is the hard part, and DynamicNotchKit (SwiftUI) already handles the notch-shaped panel, positioning per display, hover tracking and the expand/collapse animation. Rust has no equivalent. A Rust version would mean hand-building a borderless `NSPanel` above the menu bar via `objc2`, plus a UI toolkit (Tauri webview, egui or iced) that is awkward for transparent, animated, notch-hugging windows. The data layer is small (a few HTTP + JSON sources), so a Rust core behind UniFFI would add a cross-language build without much payoff.

## Architecture

```
Package.swift
Makefile                             // build, test, app (bundle + sign), run, fetch
Resources/Info.plist                 // LSUIElement, bundle ID and version filled in by make
Sources/
├── NotchlineCore/                   // no UI imports
│   ├── Location.swift               // Location model
│   ├── LocationCatalog.swift        // loads bundled locations.json
│   ├── Resources/locations.json     // the launch list above, with coordinates and source config
│   ├── Models.swift                 // ConditionsSnapshot, ObservedSnow, SnowForecast, DangerSummary
│   ├── Providers.swift              // provider protocols, HTTPClient, per-location lookup cache
│   ├── Geo.swift                    // GeoJSON Polygon / MultiPolygon point-in-polygon
│   ├── US/
│   │   ├── SnotelProvider.swift
│   │   ├── NWSForecastProvider.swift
│   │   └── AvalancheOrgProvider.swift
│   ├── Canada/                      // Phase 5
│   │   ├── BCObservedSnowProvider.swift
│   │   └── AvalancheCanadaProvider.swift
│   ├── Global/                      // Phase 5
│   │   └── OpenMeteoProvider.swift  // forecast for BC, fallback forecast and modeled depth anywhere
│   ├── ProviderFactory.swift        // picks providers for a Location
│   ├── ConditionsService.swift      // fetches all metrics concurrently, merges with the previous snapshot
│   └── SnapshotStore.swift          // last good snapshot per location, JSON in App Support
├── Notchline/                       // the app
│   ├── NotchlineApp.swift           // @main, MenuBarExtra (placeholder until Phase 2)
│   ├── AppState.swift               // Phase 2: @MainActor ObservableObject, selected location, refresh loop
│   ├── Notch/                       // Phase 3: NotchController, compact and expanded views
│   ├── Menu/MenuContentView.swift   // Phase 2: summary, location picker, refresh, settings, quit
│   └── Settings/SettingsView.swift  // Phase 6
└── notchline-fetch/main.swift       // debug command: live snapshot for one location
Tests/NotchlineTests/
├── Fixtures/                        // saved responses from every source
└── *Tests.swift                     // Swift Testing
```

### Location model

Locations are data, not code. Adding a ski area should mean adding an entry to `locations.json` and, at most, a station ID. See `Sources/NotchlineCore/Location.swift` for the full model. The parts that matter for sources:

```swift
let avalancheCenter: String?          // avalanche.org center ID, "NWAC"; nil outside avalanche.org
let observedSnow: ObservedSnowSource? // nil until configured

enum ObservedSnowSource: Codable, Hashable {
    case snotel(stations: [SnotelStation])   // tried in order; later ones are fallbacks
    case modeledOnly                         // no usable station; Open-Meteo modeled depth, labeled as modeled
}
// SnotelStation: triplet ("909:WA:SNTL"), name, elevationFt, utcOffsetHours
```

BC sources get their own case once Phase 5 discovery picks them.

Avalanche zones are not hardcoded. They are resolved at runtime from the location's coordinates (see Avalanche below), so a new location gets the right zone automatically.

### Provider protocols

```swift
protocol ObservedSnowProvider: Sendable {
    func fetch(for location: Location, now: Date) async throws -> ObservedSnow
}
protocol SnowForecastProvider: Sendable {
    func fetch(for location: Location, now: Date) async throws -> SnowForecast
}
protocol AvalancheProvider: Sendable {
    func fetch(for location: Location, now: Date) async throws -> DangerSummary
}
```

Providers take an `HTTPClient` so tests can serve fixtures, and `now` so time windows are testable.

`ProviderFactory` picks implementations by country:

| Metric | US (WA) | Canada (BC) | Fallback |
|---|---|---|---|
| Observed snow | SNOTEL | BC source from Phase 5 discovery | Open-Meteo modeled snow depth, labeled "modeled" |
| Forecast | NWS gridpoint | Open-Meteo | Open-Meteo |
| Avalanche | avalanche.org | Avalanche Canada | none (show "unavailable") |

### Core model

```swift
struct ConditionsSnapshot: Codable, Equatable {
    let locationID: String
    var observed: ObservedSnow?       // depthInches, snow24hInches?, observedAt, stationName, stationElevationFt, isModeled
    var forecast: SnowForecast?       // next24hInches, issuedAt, gridElevationFt, sourceName
    var danger: DangerSummary?        // zoneName, overall, upper/middle/lower, issuedAt, validUntil, forecastURL
    var staleMetrics: Set<Metric>     // failed this refresh; value carried over from the previous snapshot
    var fetchedAt: Date
}

enum DangerLevel: Int, Codable {
    case noRating = 0, low = 1, moderate = 2, considerable = 3, high = 4, extreme = 5
}
```

Every metric is optional so one failing source never blanks the whole display. Each source fails independently, and the UI shows the last good value with an age indicator.

## Data sources

### US: NWS forecast (documented, stable)

1. `GET https://api.weather.gov/points/{lat},{lon}`
   Returns `properties.forecastGridData` (for example `https://api.weather.gov/gridpoints/SEW/<x>,<y>`). Cache the gridpoint URL per location.
2. `GET <forecastGridData>`
   Read `properties.snowfallAmount.values`: an array of `{ validTime: "2026-11-02T18:00:00+00:00/PT6H", value: <mm> }`.
3. Parse each `validTime` as an ISO 8601 start plus duration. Sum values overlapping `[now, now + 24h]`, prorating intervals that straddle either edge. Convert mm to inches.

Notes:
- NWS requires a `User-Agent` header identifying the app and a contact, for example `Notchline/1.0 (you@example.com)`.
- Read `properties.elevation` from the gridpoint and show it in the expanded view, since the grid cell elevation may differ from the station.
- Treat `null` values as zero, but flag the forecast as missing if the array is empty.

### US: avalanche.org danger (public, no key)

- `GET https://api.avalanche.org/v2/public/products/map-layer/NWAC`
  GeoJSON `FeatureCollection` of NWAC zones with polygons. Find the zone containing the location's coordinates with a point-in-polygon test (handle both `Polygon` and `MultiPolygon`). Cache the resulting zone ID per location. Read `danger_level`, `danger`, `color`, `link`, `start_date`, `end_date` from the feature properties.
- Elevation bands: `GET https://api.avalanche.org/v2/public/product?type=forecast&center_id=NWAC&zone_id=<id>`
  Read the `danger` array, take the entry for the current day (`valid_day == "current"`), and map `upper` / `middle` / `lower`.
- Off-season and early season: expect `danger_level` of `-1` or `0`, or no current forecast. Map to `.noRating` and show "No rating", not an error. This is the normal state until NWAC starts daily forecasts, typically late November or December.
- Confirm both response shapes against live data in Phase 1 and save them as fixtures. The map-layer endpoint is well established. Confirm the product endpoint's shape before relying on it.

### US: observed snow from SNOTEL

USDA NRCS SNOTEL via the AWDB REST API (`https://wcc.sc.egov.usda.gov/awdbRestApi`), element `SNWD`, hourly, from the SNOTEL stations nearest each location, with a fallback station where one is close enough. Request shape, station choices and processing rules are in `docs/data-sources.md`.

Gotchas:
- SNOTEL timestamps stay on Pacific Standard Time year-round. Parse as fixed UTC-8, not `America/Los_Angeles`.
- Depth sensors produce spikes and dropouts. Ignore readings that jump more than 12 in/hour, and use the median of the last 3 valid hourly readings.
- 24h snow is the depth change over 24 hours, floored at 0. Settling makes it read low during and after storms.

NWAC telemetry was the original choice because its stations sit closer to the base areas (Heather Meadows at Baker, for example). It has no documented API: the station pages embed the data and an access token for NWAC's own client, which Notchline should not reuse. Using NWAC would mean asking NWAC for API access, then adding an `ObservedSnowSource.nwac` case. See `docs/data-sources.md`.

### Canada: Avalanche Canada danger (public, no key)

Avalanche Canada publishes forecasts for all Canadian regions through a public API with point-based lookup, so the location's coordinates resolve directly to a forecast region (expected: Sea to Sky for Whistler; confirm the regions for Revelstoke and Sun Peaks during discovery).

Phase 5 discovery task: confirm the current point-lookup endpoint and response shape (danger ratings by day and by alpine / treeline / below treeline), including the off-season response. Save fixtures. Map Avalanche Canada's elevation bands onto `upper` / `middle` / `lower` and its ratings onto the same 1 to 5 `DangerLevel` scale (both use the North American Public Avalanche Danger Scale).

### Canada: forecast (Open-Meteo)

NWS does not cover BC. Use Open-Meteo, which is free with no API key for non-commercial use and requests attribution.

- `GET https://api.open-meteo.com/v1/forecast?latitude=..&longitude=..&elevation=<forecastElevationM>&hourly=snowfall,snow_depth&timezone=UTC&forecast_days=2`
- Sum `hourly.snowfall` (cm) over the next 24 hours.
- Pass `elevation` explicitly so the downscaling targets the ski area, not the grid cell average.
- Open-Meteo can be pinned to specific models (for example the Canadian GEM/HRDPS models) via the `models` parameter. Compare a few models against observed snowfall in the first weeks of the season and pick one per region.

Open-Meteo is also the forecast fallback for US locations if NWS is down.

### Canada: observed snow (needs discovery)

There is no single equivalent of SNOTEL for BC ski areas. Phase 5 discovery task, in order of preference:
1. Avalanche Canada's map includes a weather station layer. Check whether those stations expose snow depth through an accessible endpoint.
2. BC Ministry of Environment automated snow weather stations (snow pillows), if one is near a given location.
3. Environment and Climate Change Canada hourly observations (MSC GeoMet / api.weather.gc.ca), if a station near the location reports snow depth.
4. If none work for a location, set its source to `.modeledOnly` and show Open-Meteo's modeled `snow_depth`, clearly labeled "modeled" in the UI, with 24h computed from the modeled depth change.

Document the choice per location in `docs/data-sources.md`.

## DynamicNotchKit integration

The README shows the minimal form:

```swift
let notch = DynamicNotch {
    ExpandedView(snapshot: snapshot)
}
await notch.expand()
```

The current API also supports separate compact leading and trailing content, hover behavior, and `.notch` / `.floating` styles (floating is used automatically on Macs without a notch). Confirm the exact initializer against the package's doc comments and unit tests for the resolved version, then pin that version.

`NotchController` responsibilities:
- Own one `DynamicNotch` instance for the app lifetime.
- If "Pin to notch" is enabled, show the compact state on launch:
  - Compact leading: snowflake SF Symbol + base depth (`61"`)
  - Compact trailing: danger badge in the standard danger scale colors (1 green, 2 yellow, 3 orange, 4 red, 5 black), or a gray dash for no rating
- Expand to `ExpandedView` on hover, return to compact on hover exit.
- Optional alert: when a refresh shows new 24h snow over a threshold (default 6"), auto expand for a few seconds, then return to compact.
- Feed views from `AppState` via `@ObservedObject`, so refreshes and location changes update the notch without rebuilding it.

`ExpandedView` layout (roughly 360 x 150 pt):
```
Mt. Baker Ski Area                              updated 12 min ago
  Base         Last 24h       Next 24h
  61"           +8"           +12"
  Heather Meadows 4,210'       NWS grid 4,350'
  Avalanche · West Slopes North: Considerable (3)
    Above TL 3 · Near TL 3 · Below TL 2           [Forecast ↗]
```
Show a small "modeled" tag next to Base when `baseDepthIsModeled` is true.

## Menu bar

`MenuBarExtra` (macOS 13+) is the always-available fallback and control surface:
- Title: short name plus compact data (`Baker 61" ⚠3`) or just an SF Symbol, user configurable
- Dropdown:
  - Same content as the expanded notch
  - **Location picker**: a submenu listing locations grouped by region (Washington, British Columbia), with a checkmark on the current one
  - "Refresh now", "Pin to notch" toggle, "Open avalanche forecast", "Settings…", "Quit"
- `LSUIElement = YES` in Info.plist so there is no Dock icon

## Location selection behavior

- Selected location ID stored in `UserDefaults` (`@AppStorage("selectedLocationID")`), default `mt-baker`.
- On change: immediately show that location's cached snapshot if one exists (dimmed until fresh), then trigger a refresh.
- Cache snapshots per location, so switching back and forth is instant.
- Only the selected location is refreshed on the timer. No background polling of the others.
- If a stored ID no longer exists in the catalog (after an app update), fall back to `mt-baker`.

## Refresh strategy

- Default interval: 30 minutes. Stations update hourly and forecasts every few hours, so faster refresh adds nothing.
- Fetch the three metrics concurrently with `async let` in `ConditionsService`.
- Refresh on wake from sleep (`NSWorkspace.didWakeNotification`), when the network returns (`NWPathMonitor`), and on location change.
- Persist the last good snapshot per location to `~/Library/Application Support/Notchline/snapshots/<locationID>.json` and load on launch.
- Values older than 3 hours are shown dimmed with their age.
- 15 second timeout per request. Exponential backoff on repeated failures, capped at the normal interval.
- Cache derived lookups (NWS gridpoint URL, avalanche zone ID) per location for a day.

## Settings (v1)

- Location (same list as the menu picker)
- Refresh interval (15 / 30 / 60 minutes)
- Units: inches / cm. Default by the selected location's country (inches for US, cm for Canada), with an override.
- Pin to notch on launch (on / off)
- New snow alert threshold (off / 3" / 6" / 12", or 10 / 15 / 30 cm)
- Launch at login (`SMAppService.mainApp`)

## Build phases

### Phase 1: Data layer for Mt. Baker (no UI)
- Create the Swift package (`NotchlineCore`, `Notchline`, `NotchlineTests` targets), add DynamicNotchKit, platform macOS 13, and the `Makefile` that bundles `Notchline.app` with `LSUIElement` and signs it with the Apple Development certificate.
- Add `Location`, `LocationCatalog` and `locations.json` with all seven launch entries (non-Baker entries can have placeholder station config).
- Do the observed snow discovery (NWAC, then SNOTEL) and record station IDs for all four WA locations.
- Capture live fixtures for SNOTEL, NWS and avalanche.org, including an off-season avalanche response.
- Implement the US providers, `ProviderFactory` and `ConditionsService` with unit tests.
- Add a debug command (a small `notchline-fetch` executable target) that fetches a live snapshot for a given location ID and prints it.

Done when: tests pass on fixtures, and a live fetch for `mt-baker` prints sensible values (or explicit "no rating" / "no data") for all four metrics.

### Phase 2: Menu bar
- `AppState`, refresh loop, per-location cache, `MenuBarExtra` with summary, location picker and actions.

Done when: the app runs as a menu bar agent, refreshes on schedule and on wake, survives a network outage showing cached data, and switching locations works (other WA locations may show partial data until Phase 4).

### Phase 3: Notch
- `NotchController`, compact and expanded views, hover behavior, pin toggle, location name in the expanded view.
- Test on a notched MacBook and on an external display or non-notch Mac (floating style).

Done when: the compact view sits cleanly beside the notch, expands on hover, and updates live after a refresh or location change.

### Phase 4: Remaining Washington locations
- Check the SNOTEL station config for Stevens Pass, Snoqualmie and Crystal against in-season data (Stevens Pass has no fallback station). Confirm avalanche zones resolve correctly from coordinates (verify against the NWAC zone map) and NWS gridpoints resolve.
- Add fixtures and tests for each.

Done when: all four WA locations show live data for all four metrics.

### Phase 5: British Columbia
- Avalanche Canada discovery and provider.
- Open-Meteo provider (also wire it in as the US forecast fallback).
- BC observed snow discovery; implement the chosen source(s) or mark locations `.modeledOnly`.
- Unit defaults by country.

Done when: Whistler, Revelstoke and Sun Peaks show live avalanche danger and forecast, plus observed or clearly labeled modeled base depth.

### Phase 6: Polish
- Settings window, launch at login, new snow alert, units.
- App icon, About panel with data attribution.
- Optional: GitHub Actions build, Homebrew cask for personal install. A cask installed on other Macs needs Developer ID signing and notarization (see Tech stack).

## Testing

- Unit tests per provider using saved fixtures, including: off-season avalanche data (both centers), empty NWS snowfall array, SNOTEL sensor spike and dropout, PST timestamp parsing across the November DST change.
- Point-in-polygon tests: each launch location resolves to the expected avalanche zone, including a point on a zone border.
- 24h prorating tests for NWS intervals that straddle the window edges.
- Location switching: cached snapshot shown immediately, refresh replaces it, unknown stored ID falls back to Mt. Baker.
- Manual matrix: notched MacBook, external display only, sleep and wake, airplane mode.

## Attribution and etiquette

- Show data sources for the current location in the expanded view footer or About panel, with links: USDA NRCS SNOTEL, NWS, avalanche.org (NWAC forecasts), Avalanche Canada, Open-Meteo (attribution requested), and any BC station source.
- 30 minute default refresh, aggressive caching, a descriptive `User-Agent`, and only the selected location polled.
- NWAC and Avalanche Canada are nonprofits funded partly by donations. Consider linking their donate pages from the About panel.
- Avalanche danger is a summary only. The expanded view always links to the full forecast, and the app should not present itself as a substitute for reading it.

## Open questions

1. Whether to ask NWAC for API access, for station data closer to the base areas than SNOTEL (Phase 1 found no public API).
2. Exact DynamicNotchKit initializer for compact leading/trailing in the pinned version (Phase 3).
3. For locations with two stations (like Baker), show the lower station as "base" by default, or the higher one, or both in the expanded view? Start with the lower station as base and the upper station in the expanded view.
4. Best observed snow source per BC location (Phase 5).
5. Which Open-Meteo model to use for BC forecasts (Phase 5, after comparing against observations).
