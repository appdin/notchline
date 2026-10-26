# Notchline

Notchline is a small macOS menu bar app that shows mountain conditions in the MacBook notch. Pick a ski area and it shows, at a glance:

| Metric | What it is |
|---|---|
| Base | Observed snow depth at a station near the ski area (modeled where no usable station exists, and labeled as such) |
| Last 24h | New snow in the last 24 hours |
| Next 24h | Forecast snowfall for the next 24 hours |
| Temperature | Current temperature (station reading where available), plus the forecast high and low |
| Wind | Current sustained wind, gusts and direction, plus the 24 hour peak |
| Avalanche | Current backcountry avalanche danger for the forecast zone containing the ski area, by elevation band |

The compact view sits beside the notch with the base depth on one side and the temperature and avalanche danger on the other. Hover over it to expand the full conditions, with data age, sources and a link to the full avalanche forecast. On a Mac or display without a notch, the menu bar item shows the same information.

There is also an [Android app](#android) with the same conditions and scores, a home screen widget and evening summaries.

Notchline refreshes the selected location every 30 minutes, on wake and when the network returns. When a source is down it keeps showing the last good value, dimmed with its age.

**Avalanche danger in Notchline is a summary only.** Always read the full forecast from the avalanche center before going into avalanche terrain.

### Locations

| Washington | British Columbia |
|---|---|
| Mt. Baker Ski Area | Whistler Blackcomb |
| Stevens Pass | Revelstoke Mountain Resort |
| The Summit at Snoqualmie | Sun Peaks Resort |
| Crystal Mountain | |

Washington locations display in imperial units and British Columbia in metric, unless you pick units in Settings.

### Data sources

- [NWS](https://www.weather.gov) gridpoint forecasts (US snowfall, temperature, wind)
- [USDA NRCS SNOTEL](https://www.nrcs.usda.gov/wps/portal/wcc/home/) stations (US observed snow and temperature)
- [avalanche.org](https://avalanche.org) and the [Northwest Avalanche Center](https://nwac.us) (US avalanche danger)
- [Avalanche Canada](https://avalanche.ca) (BC avalanche danger)
- [Open-Meteo](https://open-meteo.com) (BC forecast, modeled snow depth, and the US fallback when NWS is down)
- [BC Ministry of Environment](https://www2.gov.bc.ca/gov/content/environment/air-land-water/water/water-science-data/water-data-tools/snow-survey-data) automated snow weather stations (BC observed snow)

NWAC and Avalanche Canada are nonprofits funded partly by donations. Details on each source, including the stations used per location, are in [docs/data-sources.md](docs/data-sources.md).

## Installing

Notchline needs macOS 13 (Ventura) or later.

### Homebrew

This repository is its own Homebrew tap:

```bash
brew tap appdin/notchline https://github.com/appdin/notchline
```

Then install the prebuilt app from the latest GitHub release:

```bash
brew install --cask appdin/notchline/notchline
```

Or build it from source on your Mac (needs Xcode 16 or later). This also installs the `notchline-fetch` command line tool:

```bash
brew install appdin/notchline/notchline
```

The source build installs `Notchline.app` into the Homebrew prefix. Its caveats show how to link it into `/Applications`.

### Download

Download `Notchline-<version>.zip` from [Releases](https://github.com/appdin/notchline/releases), unzip it, and move `Notchline.app` to `/Applications`.

If macOS says the app can't be opened because it isn't from an identified developer, that release wasn't notarized. Open **System Settings > Privacy & Security** and click **Open Anyway**, or clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/Notchline.app
```

### From source

You need Xcode 16 or later (Swift 6). Clone the repository, then:

```bash
make run
```

This builds `build/Notchline.app`, signs it with the first Apple Development certificate in your keychain and launches it. Without a certificate, sign it ad hoc:

```bash
make run SIGN_IDENTITY=-
```

## Using it

Notchline runs as a menu bar app with no Dock icon. From the menu bar item you can pick a location, refresh, open the avalanche forecast, and turn **Pin to notch** on or off.

**Settings…** (⌘,) has the rest:

- Location and refresh interval (15, 30 or 60 minutes)
- Units: automatic by country, imperial or metric
- New snow alert: expands the notch for a few seconds when the last 24 hours of snow reach 3, 6 or 12 inches (10, 15 or 30 cm). One storm alerts once.
- Whether the menu bar shows conditions or just the snowflake
- Launch at login

**About** credits the data sources, with links.

## Android

The Android app shows the same conditions, avalanche danger and snow condition scores as the Mac, on an app screen, a home screen widget and in notifications. It needs Android 9 or later on an arm64 phone.

### Installing on Android

Notchline isn't on the Play Store. Download `Notchline-<version>.apk` from [Releases](https://github.com/appdin/notchline/releases) on the phone and open it. Android asks you to allow installs from your browser or file manager the first time.

### Using the Android app

- **App screen**: pick a location, pull to refresh, and open the avalanche forecast. Values marked ⓘ have errors or warnings from the last refresh. Tap one to see them.
- **Scores**: groomed and ungroomed scores for each day, the best windows, confidence and when to be on the lift. **Directions** opens Google Maps with driving directions to the location, or the browser when Maps isn't installed. Google Maps gives the drive time, so the app doesn't need a home address.
- **Widget**: the selected location's headline score, the other terrain's score and the lift time, with a Directions button. It updates after each refresh.
- **Evening summaries**: the evening before a day whose score reaches the threshold, a notification gives the scores and lift time. Tapping it opens directions.
- **Ratings**: **Rate a day you skied** rates any of the last seven days at the selected location.

The **Settings** menu has units, the notification threshold (60 to 90, or off) and the summary time. The app refreshes the selected location every 30 minutes in the background. If summaries arrive late, set the app's battery use to **Unrestricted**. The app shows a note with a Settings button when battery optimization, notifications or exact alarms would get in the way.

## Adding a resort

Locations are data, not code. Each one is an entry in [`Sources/NotchlineCore/Resources/locations.json`](Sources/NotchlineCore/Resources/locations.json) with its coordinates, time zone, forecast elevation, and where its observed snow comes from. A new resort in a region Notchline already covers (Washington, British Columbia) usually needs only a new entry. A resort elsewhere may need new data providers.

1. **Find the avalanche forecast.** Determine which avalanche center forecasts for the resort's area and whether it publishes forecasts through an API. US centers on avalanche.org work with the existing provider (set `avalancheCenter` to the center's ID); the zone is found from the resort's coordinates at runtime. Avalanche Canada covers Canada the same way. Elsewhere, add an `AvalancheProvider` for that center's API.
2. **Find a weather forecast.** NWS covers US locations and Open-Meteo covers everywhere else, so this is usually already handled. Pick a `forecastElevationFt` that represents the ski area rather than the valley below it.
3. **Find observed snow depth.** Look for an automated station near the base area that reports snow depth hourly, at a similar elevation and in the same snow climate. SNOTEL covers the western US and BC ENV stations cover BC. Other networks need a new `ObservedSnowProvider` and a new `ObservedSnowSource` case. Check the station's data through a recent season before relying on it, since depth sensors can be noisy or go quiet. If there is no good station, use `"modeledOnly"`, and the app labels the modeled depth.
4. **Add the entry** to `locations.json`, with the resort's typical weekday and weekend lift hours (`liftHours`, first and last chair as local `HH:mm`) and links to the resort and the station page.
5. **Check it live** with the fetch tool, which prints every metric for one location along with any warnings from the providers:

   ```bash
   make fetch LOCATION=<location-id>
   ```

6. **Add tests.** Save a response from each new source as a fixture in `Tests/NotchlineTests/Fixtures/` and cover the new location or provider in the tests, then run `make test`.

New providers should follow the rules the existing ones do: route text parsing, unit conversion and local time handling through the shared helpers in `NotchlineCore`, and record a warning instead of silently discarding an error. `SharedBehaviorTests` enforces most of these.

## Development

| Command | What it does |
|---|---|
| `make test` | Runs the unit tests against saved fixtures |
| `make app` | Builds and signs `build/Notchline.app` |
| `make run` | Builds, signs, quits any running copy and launches the new build |
| `make fetch LOCATION=mt-baker` | Prints a live snapshot for one location (`swift run notchline-fetch --list` lists IDs) |
| `make release` | Builds a universal app and zips it into `build/` |
| `swift scripts/make-icon.swift` | Redraws `Resources/AppIcon.icns` |
| `make android` | Builds the core for Android and assembles the debug APK |
| `make android-test` | Runs the core's tests on the connected arm64 device or emulator |
| `make android-release` | Builds the signed release APK into `build/` and prints its SHA-256 |

The code is a Swift package with no Xcode project. `NotchlineCore` holds the models, data providers and refresh logic, with no UI. `Notchline` is the SwiftUI app, using [DynamicNotchKit](https://github.com/MrKai77/DynamicNotchKit) for the notch.

### Android build

The Android app uses the same `NotchlineCore`, compiled with the [Swift SDK for Android](https://www.swift.org/documentation/articles/swift-sdk-for-android-getting-started.html), so scoring and confidence exist once. The UI is Kotlin and Jetpack Compose in [`android/`](android).

- [`android/swift`](android/swift) is a second Swift package whose `NotchlineCore` and `NotchlineTests` are symlinks into the root package. It adds `NotchlineJNI`, a hand-written JNI bridge. Values cross it as UTF-8 JSON, since the core's models are `Codable`.
- The Swift runtime is linked statically into `libNotchlineJNI.so`. Only the device test runner links it dynamically, because Swift Testing ships only as shared libraries.
- The app is arm64-v8a only and has no drive times or departures. Google Maps handles the drive.
- Building needs [swiftly](https://www.swift.org/swiftly/) with the toolchain in `android/swift/.swift-version`, the matching Swift SDK for Android, and NDK r30. [`scripts/android.sh`](scripts/android.sh) lists the commands and the environment variables they read.
- The [Android workflow](.github/workflows/android.yml) builds the debug APK on pushes that touch the core or the app. The core's tests need an arm64 device, so they run locally.

### Releasing

Push a version tag:

```bash
git tag v0.2.0 && git push origin v0.2.0
```

The [release workflow](.github/workflows/release.yml) runs the tests, builds the universal app, publishes it as a GitHub release, and updates the Homebrew cask and formula in [`Casks/`](Casks) and [`Formula/`](Formula). With Developer ID signing secrets configured (listed at the top of the workflow) the app is also notarized. Without them it is signed ad hoc.

The Android APK is built and attached to the release by hand. `make android-release` signs it with a keystore kept outside the repo (`scripts/android.sh keystore` creates one). Every update must be signed with the same key, so back the keystore up. Without it, users would have to uninstall, losing their ratings, and install again.

## License

Apache 2.0. See [LICENSE](LICENSE).
