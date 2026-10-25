# Ski day planner - plan & tracking

For the selected location, score how good skiing will be, separately for groomed and ungroomed terrain, for today and the next three days. Then say when to leave home to be on the lift for the best of it:

> **Today: 92 ungroomed, 74 groomed.** Leave in 30 min.
> **Tomorrow: 80 ungroomed.** Leave at 7:00 AM. Confidence 60%.

## Decisions locked

2026-10-25:

- **For any user.** Home is a setting, entered as an address and geocoded on the Mac. It is stored in local preferences and sent only to Apple Maps for routing.
- **Two scores: groomed and ungroomed.** Both cover terrain inside the ski area boundary. Each gets its own score and best window. The headline shows the better of the two, with the other beside it. Backcountry is out of scope, so avalanche danger plays no part in either score. The planner doesn't change the existing avalanche danger display. It stays in the compact and expanded views as it is today, so users can make their own backcountry call.
- **Arrival to lift is a per-location setting, default 20 minutes.** It covers parking, gearing up, the walk, and getting onto the first chair. A user who knows their resort takes an hour sets an hour. No parking model in v1.
- **Optimize time in great conditions first, drive time second.** Among departures that give the same time in great conditions, pick the one with the shortest drive.
- **Crowds matter through how fast fresh snow gets used up and through road conditions, not through traffic counts.** Both are modeled generically (Phase 3), not from a single highway's counters.
- **No vehicle or chain handling in v1.** The planner assumes the car can make the drive.
- **Every day is a candidate.** No weekday or time-of-day limits. Users who don't want to see it on a Monday turn it off.
- **Mac notifications are in scope.**
- **Free data only.** Apple MapKit for travel time, plus the forecast sources Notchline already uses. See "What staying free gives up".

Later the same day:

- **Overnight option.** A per-location "overnight parking allowed" setting, off by default. When it's on and the departure is before 6 AM, the planner adds "or drive up tonight".
- **Notification times are settings.** Both the evening-before summary time and how long before departure the reminder fires.
- **Ratings are 1 to 5, given for groomed and ungroomed separately.** A day spent only on groomers gets one rating, and a mixed day can get two. Ratings are per day, not per run.

## Deferred (day 2)

- **Parking lot status** (for example Mt. Baker's daily lot updates). There is no archive of them, and each resort posts them differently.
- **Hourly traffic counts.** They're specific to each highway (WSDOT has none confirmed on SR 542), so they don't generalize. Phase 6 logs travel times instead, which works anywhere.
- **Jurisdiction road reports** (WSDOT highway alerts, DriveBC, Caltrans). Each is its own provider, and WSDOT needs an access code. v1 estimates road slowdowns from the forecast instead (Phase 3).
- **Lot fill-time prediction.** Needs the parking status history above.

## What staying free gives up

| Free (MapKit) | Paid (Google Routes API) |
|---|---|
| One traffic-aware estimate for a given departure or "arrive by" time (`MKDirections.Request.departureDate` / `arrivalDate`, macOS 10.9+) | Best guess, optimistic and pessimistic estimates (`trafficModel`), which give a real range for the safety margin |
| No published quota; Apple throttles heavy use without saying where the limit is | 5,000 free traffic-aware requests a month, then $10 per 1,000 |
| Nothing to set up | Every user needs their own API key and a Google Cloud billing account |

Neither one provides historical travel times to train on, and neither knows a storm will draw a crowd. So paying would mainly buy a pessimistic estimate, which a fixed buffer can stand in for. Staying free costs little.

## How it works

### Hourly scores (Phase 2)

For each hour the lifts run, on each day from today through +3, the groomed and ungroomed scores each get a 0 to 100 value:

- **Vetoes (score 0):** lifts closed that hour; rain at the forecast elevation (the snow level or freezing level is above it, or the precipitation type is rain); gusts above a lift-closure threshold (a setting, default 45 mph); visibility near zero.
- **Weighted factors** (weights tuned by hand at first, then learned in Phase 6):
  - New snow since the last skiable day and snow falling during the session. Ungroomed weights this heavily. Groomed weights it lightly, since grooming flattens it.
  - Snow quality from temperature: cold, dry snow beats warm, heavy snow. A rain then freeze since the last snowfall means a hard, icy surface, which lowers the groomed score.
  - Wind: sustained wind and gusts below the veto threshold.
  - Visibility and cloud cover: flat light hurts ungroomed more.
- **Fresh snow gets used up.** New snow is worth less with each hour after the lifts open. The decay is faster on weekends, holidays, and days the forecast looked good one or two days earlier, since that forecast is what draws the crowd. This is how the crowd hypothesis gets into v1 without traffic data.

The forecast needs hourly series out to +3 days with fields Notchline doesn't fetch today. From NWS gridpoints: `snowLevel`, `visibility`, `skyCover`, `probabilityOfPrecipitation`, `quantitativePrecipitation`, `weather`. From Open-Meteo: `freezing_level_height`, `rain`, `showers`, `visibility`, `cloud_cover`, `precipitation_probability`, with `forecast_days` raised to 4.

### Departure time (Phase 3)

1. Choose the best window for each score: the stretch of lift hours with the highest total score, with fresh-snow decay included. Ties go to the shorter drive.
2. Target lift time = the window's start. Arrival at the lot = target minus the location's arrival-to-lift time.
3. MapKit `calculateETA` with `arrivalDate` set to the arrival at the lot gives the drive time with predicted traffic.
4. Add a road buffer when the forecast has snow falling or temperatures below freezing during the drive, sampled at the resort and at a lower point on the route. Add a crowd buffer on days the forecast looked good. Both are fixed rules in v1. Phase 6 data can tune them later.
5. Departure = arrival at the lot minus drive time minus buffers. Shown as "leave in 30 min" when it's soon, otherwise as a clock time. Shown as "leave now" or "go anyway, first chair has passed" when it's already late.
6. If the location allows overnight parking and the departure is before 6 AM, add "or drive up tonight", with a departure that evening.

### Confidence (Phase 4)

How likely the forecast is to hold, as a percentage. It drops as the day gets further out and as forecast models disagree (the Open-Meteo ensemble API is free and live). v1 uses a rule. Phase 4 replaces the rule with numbers measured from history: archived forecasts from Open-Meteo's Previous Runs API (forecasts made 1 to 7 days ahead, from January 2024), compared against what SNOTEL and BC stations actually recorded at each location. That can be measured for any location with a station, by a script in `scripts/` that writes a small table the app ships with.

## Phases

| Phase | Scope | Status |
|---|---|---|
| 1 | Settings and data: home address, per-location arrival to lift and overnight parking, typical lift hours in `locations.json`, hourly forecast series out to +3 days | Done 2026-10-25 |
| 2 | Scoring: vetoes and weighted hourly groomed and ungroomed scores, best windows, fresh-snow decay, with fixture tests in `NotchlineCore` | Done 2026-10-25 |
| 3 | Departure: MapKit ETA, road and crowd buffers, departure time for each score and day, overnight option | Done 2026-10-25 |
| 4 | Confidence: rule-based in the app, then measured from history by a backtest script | Done 2026-10-25 |
| 5 | UI, notifications and ratings: planner section in the expanded notch, day picker, evening-before and leave-soon notifications, day ratings | Done 2026-10-25 |
| 6 | Learning: travel-time logging, then weights learned from ratings once there are enough | Not started |

### Phase 1 - settings and data

- `Preferences`: home (address text plus geocoded coordinate), per-location arrival-to-lift minutes (default 20), per-location overnight parking allowed (default off), planner on/off, gust threshold, evening-before notification time (default 7 PM), departure reminder lead (default 30 minutes), notification score threshold (default 80).
- `locations.json`: typical lift hours per location (weekday and weekend, first and last chair). Season dates and daily operations are out of scope; the planner says hours are typical.
- Providers return an hourly series model alongside `SnowForecast`, with the fields listed under "Hourly scores". Both NWS and Open-Meteo fill it, so the NWS-to-Open-Meteo fallback still works.

As built:

- `PlannerSettings` in `Preferences.swift` holds every planner setting, stored as one JSON value under the `planner` defaults key so settings added later decode with their defaults. Per-location settings are keyed by location ID. The gust threshold is stored in mph. Planner is on by default.
- Home is geocoded with `CLGeocoder` when the user presses Return in Settings. The entered text, the geocoder's matched name and the coordinate are stored. A failed lookup leaves the previous home in place.
- The Settings window has a Ski day planner section. Arrival to lift and overnight parking apply to the selected location.
- `liftHours` in `locations.json` (`ClockTime` values, "HH:mm"), with `Location.liftInterval(on:)` choosing weekday or weekend hours in the location's calendar. Weekend means Saturday and Sunday; holidays use weekday hours. Values are from 2025-26 published hours: Revelstoke's 8:30 to 4:00 is unconfirmed, Sun Peaks uses its main lifts' 9:00 to 4:00, and night skiing at Stevens and Snoqualmie is left out.
- `SnowForecast.hourly` (`HourlyForecast` of `ForecastHour`) covers `LocalTime.plannerHours`: local midnight today through the end of +3, 23 or 25 hours on daylight saving days. Hours with no values are left out, and a series that ends before the last day's daytime records a warning.
- NWS amounts are prorated from overlapping intervals; other values come from the interval containing the hour's start. Open-Meteo amounts, gusts and precipitation chance cover the preceding hour, so the hour starting at t reads them from t + 1h.
- Open-Meteo now sends `timezone` so `forecast_days=4` ends at local midnight after +3 rather than UTC midnight. It also returns `precipitation` (total liquid), to match NWS `quantitativePrecipitation`.
- Snow level (NWS) and freezing level (Open-Meteo) are separate fields, since they differ by several hundred feet. Phase 2 needs a rule for the Open-Meteo case.
- `notchline-fetch` prints the hourly range and today's typical lift hours.

### Phase 2 - scoring

Pure functions in `NotchlineCore`, no I/O, same rules as the existing providers (shared unit and local-time helpers, warnings instead of silent drops). Fixture-driven tests cover a powder day, a rain day, a wind-hold day, and a refrozen-crust day.

Before tuning weights, run the score over the last two Mt. Baker seasons using the Historical Forecast API and check the top-scoring days against known storm days, as a sanity check.

As built (`Sources/NotchlineCore/Planner/`):

- `SkiDayScorer.score` takes an `HourlyForecast`, the location, `now`, the gust threshold and new snow from before the series, and scores every lift hour of every day from today to the end of the series. Earlier hours still count toward new snow and crust, so the same call scores a whole season from archived forecasts.
- Only lift hours are scored, which covers the lifts-closed veto. A partly open hour, such as 3:00 to 3:30 at Baker, counts for the part the lifts run.
- Vetoes: rain, gusts over the threshold, visibility under 0.1 mile. Rain needs a 50% chance or a measurable amount (0.01"). It's decided by Open-Meteo's rain amount, then a rain-only NWS type, then the snow level, then the freezing level less 1,000 ft. Mixed rain and snow with no level to decide by counts as rain.
- Factors, each 0 to 1: fresh snow (`1 - e^(-in/4)`), snow quality by temperature (best from 10 to 25°F), surface (refrozen crust), wind (the worse of sustained and gusts nearing the threshold), and light (the worst of cloud, fog and falling snow). Weights are in `ScoreWeights`, which Phase 6 replaces with learned ones. Groomed scores top out at 85, so that the best corduroy day ranks below a deep powder day. A clear, calm day with no new snow scores about 77 groomed and 35 ungroomed.
- New snow counts from the last chair of the last day with an unvetoed lift hour, so snow during a wind hold carries over. Rain wipes it out. Each inch decays from first chair, or from when it fell if later, with a 3 hour half-life. That halves on weekends and holidays (`BusyDays`: US and BC school and federal holidays, Christmas week, no spring breaks) and drops by a third on days with 6" or more new.
- "Forecast looked good one or two days earlier" uses the day's own forecast as a stand-in, since earlier forecasts aren't stored yet. Phase 5 stores scores and could supply the real ones.
- Rain then a freeze at 30°F or below makes a crust until 2" of new snow covers it. It lowers both scores, groomed more.
- Best window: the contiguous stretch where each hour adds its score less (peak - 15), the maximum subarray. Hours well below the peak end it. Ties keep the earlier window. Today's window only looks at hours that haven't ended. The headline terrain is the one whose window averages higher, ties to ungroomed.
- Gaps become warnings: missing lift hours are left out, and missing temperature, wind, snowfall, cloud or precipitation is scored as neutral.
- `notchline-fetch` prints each day's windows, and `--score-history` scores a date range from the Historical Forecast API.

Sanity check, Mt. Baker 2024-25 and 2025-26, 218 days with 30" or more at Wells Creek, against SNOTEL daily depth gains:

- The first run found that Open-Meteo splits rain from snow at its grid's elevation rather than the one we request. On the biggest storm days it reported rain at -4°C, so those days scored as rain days. The provider now keeps rain only in the share of the hour warmer than 0.5°C at the forecast elevation (all rain from 2.5°C). After that fix, the correlation between model new snow and the observed gain rose from 0.12 to 0.54, and 6 of the 10 biggest observed storms rank in the top 22 days.
- Open-Meteo's snowfall comes in at about half the observed gain on storm days (4.6" vs 8.8" on 12 days of 6" or more). Re-deriving snow from total precipitation and temperature got the amount right but tracked storms less well, so amounts are kept as given. As a result, Open-Meteo scores rarely pass 80: 3 days in two seasons. NWS is the live source for Washington, so check its amounts against SNOTEL early this season before raising the 80 notification threshold.
- The first weights let groomed outscore ungroomed on the best powder day (78 vs 74). After rebalancing, ungroomed leads on 9 of the 10 days with 5" or more of model snow. The exception is a wind-hold day.
- Gusts at 45 mph held lifts on only one day in two seasons. Open-Meteo's 10 m gusts likely run low for ridge-top lifts. Revisit with NWS gusts and ratings.

### Phase 3 - departure

MapKit sits behind a protocol so the scoring tests never call it. Cache ETAs per (day, target arrival), since MapKit's throttling isn't published.

As built (`Sources/NotchlineCore/Planner/`):

- `TravelTimeProvider` gives a drive time for an arrival and the route's halfway point. `MapKitTravelTimes` uses `MKDirections` `calculateETA` with `arrivalDate`, and `calculate` for the route. `CachedTravelTimes` keeps ETAs per (home, location, arrival) for an hour and midpoints for a day.
- Destinations are the locations' existing coordinates. Apple's own map points for all seven resorts sit within about 200 m of them, so no separate parking coordinate was needed.
- Road buffer: the worst condition over the drive's hours, sampled at the resort's hourly series and at the route midpoint. The midpoint comes from Open-Meteo at the terrain's own elevation (`RoadWeatherProvider`). The buffer is a share of the drive time, rounded up to 5 minutes:

  | Condition | Buffer |
  |---|---|
  | Below freezing | 10% |
  | Snow (0.1"/h, or likely snow) | 30% |
  | Heavy snow (1"/h) | 50% |
  | Freezing rain | 50% |

- Crowd buffer: 20 minutes on days that draw a crowd (6" or more new), 30 on a busy day.
- Tied best windows (`SkiDayScorer.bestWindows`) go to the shorter drive, then the earlier window.
- Late: when the best window's departure is more than 5 minutes past, the planner finds the earliest lift time still reachable by leaving now, scores what's left of the day from there, and marks the departure with the missed lift time.
- `Departure.advice(now:)`: "leave at" a clock time, "leave in N min" within an hour (rounded down to 5), "leave now" within 5 minutes either side, and "go anyway" once it has passed. `PlannerFormat` turns these into text. Departures round down to 5 minutes, and late lift times round up.
- Overnight: with overnight parking on and a departure before 6 AM, a second drive reaches the lot by 9 PM the evening before, with no crowd buffer. It's dropped once that departure has passed. When that evening is before the forecast series starts (planning tomorrow from midnight on), the evening drive has no road weather.
- Without a home there are scores but no departures, and one warning. A route Apple won't give (for example a road closure) is one warning per location, not one per day.
- `notchline-fetch <id> --home lat,lon` prints each day's departures from live Apple Maps times.

Found while building: Apple applies current closures to the route. On 2026-10-25 it refused Crystal ("current road conditions"). For Mt. Baker it first gave no ETA and a 6.7 hour detour on unpaved roads ending in a walk, then an ordinary 82 minutes later the same morning. Off-season closures will show up as missing departures with a warning. Absurd detours aren't detected yet; Phase 6's ETA log could flag them against the usual time.

### Phase 4 - confidence

See "Confidence" above. The backtest script runs on demand, not in the app, and its output table is committed.

As built (`Sources/NotchlineCore/Planner/Confidence.swift`, `ConfidenceBacktest.swift`):

- Model disagreement comes from three models on Open-Meteo (GFS, ICON, GEM) rather than the ensemble API, because Previous Runs archives each model at every lead and the ensemble API keeps no comparable history. That makes disagreement measurable in the backtest. ECMWF has no snowfall there. One extra request per refresh (`OpenMeteoProvider.modelForecasts`) fetches all three. Each model gets the same scoring as the main forecast. The spread is the gap between the highest and lowest model's best-window average: under 10 points means the models agree, 10 to 24 that they differ, and 25 or more that they disagree.
- The models are compared on the fields all three have at every lead. Rain comes from total precipitation and temperature, since ICON has no rain or precipitation chance at longer leads. Freezing level and visibility are left out, since Previous Runs has neither beyond the latest run.
- `ForecastConfidence.apply` sets `DayScore.confidence` (lead, spread, percent, and whether the figure was measured) for each terrain. The percent comes from the bundled `confidence.json`. A location's own rate is blended with every location's rate, weighted as 20 days of the pooled rate. A level of agreement with fewer than 20 pooled days falls back to the rate for any agreement. Without the table, a rule applies: 90/85/80/80% by lead, less 15 when the models differ and 30 when they disagree. The rule's numbers are rounded from the backtest.
- The backtest (`scripts/backtest-confidence.sh`, which runs `notchline-fetch --backtest-confidence`) covers 2024-01-08 to 2024-04-15, 2024-12-01 to 2025-04-15 and 2025-12-01 to 2026-04-15. For each day and each lead from 0 to 3, it scores the best-match forecast and the three models from runs made that far ahead. Then it compares the forecast score with a score of what happened. A day "holds" when the two are within 15 points, the same margin as the best window.
- What happened is built from the latest run, with the station's readings swapped in for snow and temperature. Snow is the depth gained from last chair to first chair and during lift hours, using the median depth within 2 hours of each time. It's spread over that stretch's hours the way the forecast spread its snow. Temperature is moved up to the forecast elevation at 3.5°F per 1,000 ft. Where the station saw no new snow, rain follows the station's temperature. A day counts only when the station covers the last chair before it, its first and last chair, and half its lift hours. The first day of each range is skipped.
- Responses are cached on disk (`--cache`), so reruns cost no Open-Meteo quota. A first run takes about 12 minutes.
- `notchline-fetch` prints each day's groomed and ungroomed confidence and the ungroomed model spread.

Backtest results, 5 locations with stations, about 1,200 days per lead (all locations together, share of days held):

| | +0 | +1 | +2 | +3 |
|---|---|---|---|---|
| Ungroomed, any agreement | 84% | 81% | 78% | 78% |
| Ungroomed, models agree | 93% | 92% | 90% | 90% |
| Ungroomed, models disagree | 64% | 60% | 52% | 49% |
| Groomed, any agreement | 94% | 91% | 89% | 89% |
| Groomed, models disagree | 87% | 73% | 60% | 67% |

- Disagreement predicts misses far better than lead time does. Ungroomed confidence falls only 6 points from today to +3, but it falls by about 30 to 40 points when the models disagree. The fallback rule was set from these numbers.
- Most days are quiet, with no new snow and similar scores, so high overall rates mostly reflect easy days. Confidence on storm days is what matters, and it shows up as disagreement.
- Lead 0 is flattered: what happened borrows the latest run's wind, cloud and precipitation, so at lead 0 only snow and temperature can miss.
- The forecast measured is Open-Meteo's best match. Washington runs on NWS live, which has no comparable archive, so its confidence assumes NWS misses about as often as Open-Meteo.
- Stevens Pass and Snoqualmie have about 135 covered days, against 300 or more elsewhere. The cause isn't checked yet. Gaps in the stations' hourly depth are the likely reason.
- Callaghan Creek, Whistler's station, is 2,200 ft below the forecast elevation, so its rain and snow line may differ from the hill's.
- The measured rates don't yet separate storm days from quiet ones, or tell the forecast's direction of error. Ratings in Phase 5 and 6 can show whether a user's misses are mostly storms coming in smaller than forecast.

### Phase 5 - UI, notifications and ratings

- Expanded notch: a planner section with the day picker (Today / Tomorrow / +2 / +3), both scores, the departure, and confidence.
- Notifications (`UNUserNotificationCenter`), at the times set in Settings: an evening-before summary when the next day crosses the score threshold, and a reminder ahead of the recommended departure.
- Rating: after a day the planner scored, the app asks "Did you ski [location] today?" The user rates groomed, ungroomed, or both from 1 to 5, depending on what they skied, and can optionally give actual departure and lift times. Ratings are stored locally with the forecast and scores as they were that morning, which is the training data for Phase 6.

As built:

- `SkiDayPlanner` (`Sources/NotchlineCore/Planner/SkiDayPlanner.swift`) runs the whole pipeline from a snapshot: scores, comparison models and confidence, then departures. The app and `notchline-fetch` both use it. `SkiDayPlan.needsHome` marks a plan with scores but no departures.
- `PlannerModel` holds the selected location's plan. `AppState` replans after every refresh and half a second after a planner setting changes, and clears the plan on a location change or when the planner is turned off. A slower plan never replaces a newer one.
- The planner section sits under the conditions in both the expanded notch and the menu bar dropdown, since without a notched display the menu is the only view. The day picker reads Today, Tomorrow, then weekdays. Each day shows both scores with the better one first, confidence (its tooltip says whether it was measured, the model spread, and that lift hours are typical), and a row per terrain with the best window, the departure advice, the drive with its buffers, and the overnight option. When both terrains share a window and departure, one "Both" row shows it. A day with no window says why: the lifts have closed, or rain, wind holds or no visibility. Without a home, a link opens Settings.
- Notifications (`PlannerNotifications`, delivered by `PlannerNotifier` through `UNUserNotificationCenter`) are for the selected location only. Each plan replaces every pending planner notification, so a day that drops below the threshold loses its summary. Permission is asked the first time there is something to deliver. Banners show even though a menu bar app counts as frontmost.
  - Evening summary: at the summary time on the Mac's clock the evening before each day whose headline score reaches the threshold, for example "Tomorrow at Mt. Baker Ski Area: 92 ungroomed, 74 groomed" with "Leave at 6:15 AM. Confidence 60%." Days further out get theirs scheduled too and are updated by later plans.
  - Departure reminder: the reminder lead before the headline terrain's departure on days at or over the threshold, with a sound. Not for late plans that already missed the best window.
  - Rating question: an hour after last chair on a day whose morning score reached the threshold.
  - Clicking a summary or reminder expands the notch on that location; clicking the rating question opens the rating window.
- `PlannerArchive` keeps one JSON record per location and day in `~/Library/Application Support/Notchline/planner/<location>/<yyyy-MM-dd>.json`. It holds the morning plan (the latest made before first chair, or the first of the day when the app first planned later) with that day's forecast hours, the headline scores and confidence from one and two days ahead, and the rating. The earlier scores are what Phase 2's crowd stand-in and Phase 6's travel-time log need; nothing reads them yet.
- Rating prompt: "Did you ski Baker today?" appears in the planner section once a day with a morning plan has passed last chair, and asks about yesterday until today's last chair. "No" records that the user didn't ski, which stops it asking. "Rate…" opens a window with 1 to 5 (or "Didn't ski") for groomed and ungroomed, optional left-home and on-the-lift times in the location's time zone, and the morning forecast for reference. Save needs at least one rating.
- Every scored day is asked about, in season or not. The prompt is passive in the notch, and only days over the threshold get a notification. If the daily question proves noisy, limit it to days with a skiable window or to days the user looked at the plan.

### Phase 6 - learning

- **Travel-time logging.** On mornings with the planner on, record the live MapKit ETA from home to the location every 15 minutes while the Mac is awake, alongside that day's score and the forecast from one and two days earlier. This tests the crowd hypothesis anywhere, without traffic counters.
- **Learned weights.** Once a user has enough rated days (start at about 20), fit the factor weights for the groomed and ungroomed scores to that user's ratings on the Mac, with a linear or logistic model in Swift. Fall back to the hand-tuned weights until there's enough data.
- **Tuned buffers.** Fit the road and crowd buffers from logged ETAs and reported actual drive times.
