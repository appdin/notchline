# Data sources

Findings from Phase 1 discovery (2026-10-24). Fixtures captured on that date live in `Tests/NotchlineTests/Fixtures/`.

All requests send `User-Agent: Notchline/0.1 (https://github.com/appdin/notchline)`.

## Observed snow: USDA NRCS SNOTEL (AWDB REST API)

Public, documented, no key. Swagger: https://wcc.sc.egov.usda.gov/awdbRestApi/swagger-ui/index.html

```
GET https://wcc.sc.egov.usda.gov/awdbRestApi/services/v1/data
    ?stationTriplets=909:WA:SNTL&elements=SNWD&duration=HOURLY
    &beginDate=2026-10-23 14:30&endDate=2026-10-24 21:30&returnFlags=true
```

Response: `[{ stationTriplet, data: [{ stationElement: { elementCode: "SNWD", storedUnitCode: "in", ... }, values: [{ date: "2026-10-24 12:00", value: 0, qcFlag: "V", qaFlag: "R" }] }] }]`

- `date` and the `beginDate` / `endDate` parameters are in the station's fixed standard time offset (`dataTimeZone` in station metadata, -8 for every WA station used). No DST. Parsed as fixed UTC-8.
- Missing hours are omitted rather than returned as null. `value` can also be null.
- `qcFlag`: `V` valid, `E` estimated, `S` suspect. Suspect values are dropped.
- Readings typically lag real time by 30 to 90 minutes.
- Station metadata (name, elevation, coordinates, `dataTimeZone`): `GET .../services/v1/stations?stateCds=WA&networkCds=SNTL&activeOnly=true`.

Processing (in `SnotelProvider`): drop suspect, null, negative and future readings, drop jumps over 12 in/hour, base depth is the median of the last 3 readings, 24h is that minus the median of the readings within 2 hours of 24 hours earlier, floored at 0. A station whose latest reading is over 6 hours old is treated as down and the next station for the location is tried. If no station has a reading within 6 hours, the most recent reading from any of them is used (the request window limits this to about 30 hours), and the UI dims it with its age.

The AWDB API returns occasional HTTP 500s that succeed on retry. The refresh backoff covers these.

### Stations per location

| Location | Primary | Fallback | Notes |
|---|---|---|---|
| mt-baker | Wells Creek `909:WA:SNTL`, 4,040 ft, 9 km W | Marten Ridge `999:WA:SNTL`, 3,520 ft | Both below the base area (~4,200 ft at Heather Meadows), so depth reads somewhat low |
| stevens-pass | Stevens Pass `791:WA:SNTL`, 3,940 ft, 0.3 km | none | See below |
| snoqualmie | Olallie Meadows `672:WA:SNTL`, 4,010 ft, 6 km S | Tinkham Creek `899:WA:SNTL`, 3,000 ft | |
| crystal | Morse Lake `642:WA:SNTL`, 5,400 ft, 3 km | Cayuse Pass `1085:WA:SNTL`, 5,260 ft | Fallback reads 10 to 15 in lower |

### In-season check (Phase 4)

Hourly SNWD for 2026-01-01 to 2026-02-28, replayed through the provider rules hour by hour from 2026-01-03:

| Location | Primary current | Fallback used | No current reading |
|---|---|---|---|
| stevens-pass | 1,367 of 1,367 h | n/a | 0 h |
| snoqualmie | 1,367 of 1,367 h | 0 h | 0 h |
| crystal | 1,291 of 1,367 h | 70 h | 6 h |

No readings were rejected as spikes in that period.

- **Stevens Pass**: 791 reported every hour all winter. Off-season it logs depth only every few hours (temperature stays hourly), which is why it looked down on 2026-10-24. The off-season reading is shown with its age rather than blanked. Candidate fallbacks were rejected: Fish Lake `478:WA:SNTL` (3,440 ft, 23 km) is east of the crest and read about two thirds of Stevens Pass depth, and Icicle Creek `1338:WA:SNTL` has no depth sensor.
- **Crystal**: both stations drop hours during heavy snow, Morse Lake most in early January (some days had one reading, with QC flag `K`). Cayuse Pass covered most of those gaps.

## Observed snow: NWAC telemetry (not used)

NWAC has no documented public API. Station pages at `https://nwac.us/weather/stations/<slug>` (for example `mt-baker-ski-area`) are server-rendered Next.js pages. The table data is embedded in the page payload and the site's client uses an access token embedded in the page to call its data backend. NWAC station IDs (`stid`) are small integers (Mt. Baker ski area is `5`).

Notchline does not scrape the page or reuse the embedded token. If NWAC data is wanted (it sits closer to the base areas than SNOTEL at Baker), ask NWAC for API access and add an `ObservedSnowSource.nwac` case.

Station page slugs seen: alpental, mt-baker-ski-area, stevens-pass-brooks, stevens-pass-schmidt-haus, stevens-ski-area, snoqualmie-pass, crystal-mt-ski-area, crystal-mt-green-valley, and others.

## Forecast: NWS gridpoints

1. `GET https://api.weather.gov/points/{lat},{lon}` returns `properties.forecastGridData`. Memoized per location for a day.
2. `GET <forecastGridData>` returns `properties.snowfallAmount` with `uom: "wmoUnit:mm"` and `values: [{ validTime: "2026-10-24T12:00:00+00:00/PT6H", value: 0 }]`. Also `properties.elevation` (`wmoUnit:m`) and `properties.updateTime`.

The full gridpoint response is about 200 KB. The fixture is trimmed to the fields Notchline reads. The avalanche product fixtures are trimmed the same way, dropping forecast text, photos and author names.

| Location | Gridpoint | Grid elevation |
|---|---|---|
| mt-baker | SEW/157,123 | 4,265 ft |
| stevens-pass | SEW/165,67 | 4,879 ft |
| snoqualmie | SEW/152,54 | 3,087 ft |
| crystal | SEW/145,31 | 5,233 ft |

## Avalanche danger: avalanche.org

- `GET https://api.avalanche.org/v2/public/products/map-layer/NWAC`: GeoJSON `FeatureCollection`, one `Polygon` feature per zone (feature `id` such as `3021`). Properties used: `name`, `danger_level` (-1 off-season), `link`, `start_date`, `end_date` (UTC with no offset suffix). Also `off_season`, `danger`, `color`, `travel_advice`.
- `GET https://api.avalanche.org/v2/public/product?type=forecast&center_id=NWAC&zone_id=<feature id>`: current product for the zone. Off-season it is `product_type: "summary"` with `danger: []`. In season it is `product_type: "forecast"` with `danger: [{ valid_day: "current", upper, middle, lower }, { valid_day: "tomorrow", ... }]`, plus `published_time` and `expires_time`.
- Archived products: `GET .../v2/public/products?avalanche_center_id=NWAC&date_start=2026-02-10&date_end=2026-02-11` lists them, and `GET .../v2/public/product/<id>` fetches one. The in-season fixture (product 180047, West Slopes Central, 2026-02-10) came from here.

Zones resolved from coordinates by point-in-polygon on 2026-10-24:

| Location | Zone | Feature id |
|---|---|---|
| mt-baker | West Slopes North | 3021 |
| stevens-pass | Stevens Pass | 3024 |
| snoqualmie | Snoqualmie Pass | 3028 |
| crystal | West Slopes South | 3023 |

On 2026-10-24 every NWAC zone was off-season (`danger_level: -1`), with the early season statement valid until 2026-11-21.

## British Columbia (Phase 5)

Not yet investigated. The SNOTEL station list includes some BC sites (for example `1D17P:BC:MSNT`, Chilliwack River, a manual snow course), which may be worth checking alongside the options in the plan.
