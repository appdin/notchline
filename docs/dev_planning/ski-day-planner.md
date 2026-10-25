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
| 1 | Settings and data: home address, per-location arrival to lift and overnight parking, typical lift hours in `locations.json`, hourly forecast series out to +3 days | Not started |
| 2 | Scoring: vetoes and weighted hourly groomed and ungroomed scores, best windows, fresh-snow decay, with fixture tests in `NotchlineCore` | Not started |
| 3 | Departure: MapKit ETA, road and crowd buffers, departure time for each score and day, overnight option | Not started |
| 4 | Confidence: rule-based in the app, then measured from history by a backtest script | Not started |
| 5 | UI, notifications and ratings: planner section in the expanded notch, day picker, evening-before and leave-soon notifications, day ratings | Not started |
| 6 | Learning: travel-time logging, then weights learned from ratings once there are enough | Not started |

### Phase 1 - settings and data

- `Preferences`: home (address text plus geocoded coordinate), per-location arrival-to-lift minutes (default 20), per-location overnight parking allowed (default off), planner on/off, gust threshold, evening-before notification time (default 7 PM), departure reminder lead (default 30 minutes), notification score threshold (default 80).
- `locations.json`: typical lift hours per location (weekday and weekend, first and last chair). Season dates and daily operations are out of scope; the planner says hours are typical.
- Providers return an hourly series model alongside `SnowForecast`, with the fields listed under "Hourly scores". Both NWS and Open-Meteo fill it, so the NWS-to-Open-Meteo fallback still works.

### Phase 2 - scoring

Pure functions in `NotchlineCore`, no I/O, same rules as the existing providers (shared unit and local-time helpers, warnings instead of silent drops). Fixture-driven tests cover a powder day, a rain day, a wind-hold day, and a refrozen-crust day.

Before tuning weights, run the score over the last two Mt. Baker seasons using the Historical Forecast API and check the top-scoring days against known storm days, as a sanity check.

### Phase 3 - departure

MapKit sits behind a protocol so the scoring tests never call it. Cache ETAs per (day, target arrival), since MapKit's throttling isn't published.

### Phase 4 - confidence

See "Confidence" above. The backtest script runs on demand, not in the app, and its output table is committed.

### Phase 5 - UI, notifications and ratings

- Expanded notch: a planner section with the day picker (Today / Tomorrow / +2 / +3), both scores, the departure, and confidence.
- Notifications (`UNUserNotificationCenter`), at the times set in Settings: an evening-before summary when the next day crosses the score threshold, and a reminder ahead of the recommended departure.
- Rating: after a day the planner scored, the app asks "Did you ski [location] today?" The user rates groomed, ungroomed, or both from 1 to 5, depending on what they skied, and can optionally give actual departure and lift times. Ratings are stored locally with the forecast and scores as they were that morning, which is the training data for Phase 6.

### Phase 6 - learning

- **Travel-time logging.** On mornings with the planner on, record the live MapKit ETA from home to the location every 15 minutes while the Mac is awake, alongside that day's score and the forecast from one and two days earlier. This tests the crowd hypothesis anywhere, without traffic counters.
- **Learned weights.** Once a user has enough rated days (start at about 20), fit the factor weights for the groomed and ungroomed scores to that user's ratings on the Mac, with a linear or logistic model in Swift. Fall back to the hand-tuned weights until there's enough data.
- **Tuned buffers.** Fit the road and crowd buffers from logged ETAs and reported actual drive times.
