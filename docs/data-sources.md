# Where the data comes from

Every number Notchline shows comes from a free public source. None of them need an API key. This page explains which source feeds each metric, how Notchline turns the raw data into what you see, and what to keep in mind when reading it.

| Metric | Washington | British Columbia |
|---|---|---|
| Base depth and last 24h | SNOTEL stations | BC ENV snow station (Whistler), Open-Meteo model (Revelstoke, Sun Peaks) |
| Next 24h snow | NWS forecast | Open-Meteo forecast |
| Temperature | SNOTEL station, else NWS forecast | BC ENV station (Whistler), else Open-Meteo forecast |
| Wind | NWS forecast | Open-Meteo forecast |
| Avalanche danger | NWAC, via avalanche.org | Avalanche Canada |

If NWS is down, Washington locations fall back to the Open-Meteo forecast, and the expanded view names whichever source was used.

## Snow depth and temperature in Washington: SNOTEL

[SNOTEL](https://www.nrcs.usda.gov/wps/portal/wcc/home/) is a network of automated snow stations run by the USDA Natural Resources Conservation Service, mostly for water supply forecasting. Each station measures snow depth and air temperature every hour. Notchline reads them through the [AWDB REST API](https://wcc.sc.egov.usda.gov/awdbRestApi/swagger-ui/index.html).

SNOTEL stations sit in forest clearings chosen for consistent measurement, not at ski areas, so they stand in for the base area rather than measuring it directly. Each location uses the closest station at a similar elevation, with a second station as a backup where a good one exists:

| Location | Station | Backup | Notes |
|---|---|---|---|
| Mt. Baker | [Wells Creek](https://wcc.sc.egov.usda.gov/nwcc/site?sitenum=909), 4,040 ft, 9 km west | Marten Ridge, 3,520 ft | Both sit below the base area at Heather Meadows (about 4,200 ft), so depth reads somewhat low |
| Stevens Pass | [Stevens Pass](https://wcc.sc.egov.usda.gov/nwcc/site?sitenum=791), 3,940 ft, at the pass | none | The nearby alternatives are east of the crest and get much less snow |
| Snoqualmie | [Olallie Meadows](https://wcc.sc.egov.usda.gov/nwcc/site?sitenum=672), 4,010 ft, 6 km south | Tinkham Creek, 3,000 ft | |
| Crystal | [Morse Lake](https://wcc.sc.egov.usda.gov/nwcc/site?sitenum=642), 5,400 ft, 3 km away | Cayuse Pass, 5,260 ft | The backup usually reads 10 to 15 in lower |

How Notchline turns the readings into numbers:

- Readings the station flags as suspect, and jumps of more than 12 in of depth (or 15 °F) in an hour, are treated as sensor glitches and dropped.
- **Base depth** is the median of the last three readings, which smooths out the normal hour-to-hour jitter of depth sensors.
- **Last 24h** is the base depth minus the depth about 24 hours earlier, floored at zero since settling and melt can make it negative. It measures how much deeper the snow got, so it can understate a storm whose new snow compacts quickly.
- If the main station has not reported in 6 hours, the backup is used. If neither has, the most recent reading from either is shown, dimmed with its age.
- **Temperature** comes from the same station when its reading is under 2 hours old, otherwise from the forecast for the current hour.

Things to know:

- Readings usually arrive 30 to 90 minutes after the hour they cover.
- Out of season some stations log depth only every few hours, so an old, dimmed depth in summer and fall is normal.
- Stations sometimes drop readings during heavy snow. The backup station covers most of those gaps.

## Snow depth and temperature in BC: BC ENV snow stations

The BC Ministry of Environment runs [automated snow weather stations](https://www2.gov.bc.ca/gov/content/environment/air-land-water/water/water-science-data/water-data-tools/snow-survey-data/automated-snow-weather-station-data) across the province and publishes their hourly data as CSV files, one per measurement (snow depth in cm, air temperature in °C), each covering every station since October 1. The files grow to several megabytes by spring, so Notchline downloads only the start and end of each.

Only Whistler has a suitable station:

| Location | Source | Why |
|---|---|---|
| Whistler | Callaghan Creek (3A20P), 1,017 m, 11 km away | Reports hourly and reliably through the season |
| Revelstoke | Open-Meteo model | The nearest station, on Mount Revelstoke, has no depth sensor |
| Sun Peaks | Open-Meteo model | The nearest station is 20 km away and new, with no track record yet |

Readings are cleaned and summarized the same way as SNOTEL readings. The newest hours in the files are often blank for a while, so the depth may be a few hours old even when the station is working.

## Modeled snow depth: Open-Meteo

Where there is no usable station, Notchline shows the snow depth from [Open-Meteo](https://open-meteo.com)'s weather model at the location's coordinates and a representative ski area elevation. Last 24h is the change in modeled depth over the past day. The app labels these values as modeled. A model's snowpack can drift well away from reality over a season, so treat it as a rough guide.

## Forecasts: NWS and Open-Meteo

For Washington, the forecast comes from the [National Weather Service](https://www.weather.gov/documentation/services-web-api) gridpoint forecast, the same data behind the forecasts on weather.gov. NWS forecasts for a grid of 2.5 km cells, and Notchline uses the cell containing the ski area:

| Location | Grid cell elevation |
|---|---|
| Mt. Baker | 4,265 ft |
| Stevens Pass | 4,879 ft |
| Snoqualmie | 3,087 ft |
| Crystal | 5,233 ft |

For BC, and for Washington when NWS is unavailable, the forecast comes from Open-Meteo's hourly model output at the location's representative elevation. Open-Meteo is free for non-commercial use and asks for attribution, which the About panel provides.

From either source:

- **Next 24h** is the forecast snowfall for the 24 hours starting now.
- **High and low** are the forecast high for today (tomorrow, once today's daytime has passed) and the forecast low for tonight.
- **Wind** is the forecast sustained wind, gust and direction for the current hour, plus the strongest sustained wind and gust expected in the next 24 hours. SNOTEL wind sensors are rare and sit in sheltered spots, so the forecast is a better guide to wind on the hill.
- **Hourly series** for the ski day planner, from midnight today through the end of the third day after: temperature, snowfall, total precipitation, chance of precipitation, visibility, cloud cover and wind for every hour. The two sources differ in a few fields:
  - NWS gives the **snow level**, where rain turns to snow. Open-Meteo gives the **freezing level** instead, which is usually several hundred feet higher.
  - NWS names the precipitation types it expects (snow, rain, freezing rain, sleet) at any coverage, from "slight chance" up. Open-Meteo gives rain and snowfall amounts, and the types come from whichever is above zero.
  - NWS visibility covers only about the next 16 hours. Later hours have none.
  - Open-Meteo splits rain from snow at its model grid's elevation, which is lower than the ski area. It can report rain at Mt. Baker well below freezing. Temperature is adjusted to the requested elevation, so Notchline keeps Open-Meteo's rain only in the share of each hour warm enough for it: none at or below 0.5°C, all of it from 2.5°C. Its snowfall amounts run about half of what SNOTEL depth gains on storm days.

## Forecast confidence: Open-Meteo models and history

The planner's confidence for each day depends on two things: how many days out the day is, and how closely three forecast models agree on its score. Those models are GFS (US), ICON (Germany) and GEM (Canada), all fetched from Open-Meteo in one request. ECMWF is left out because Open-Meteo has no snowfall for it at these points.

The percentages come from a table that ships with the app. It's built by `scripts/backtest-confidence.sh` from two kinds of data:

- Open-Meteo's [Previous Runs API](https://open-meteo.com/en/docs/previous-runs-api), which archives forecasts as they stood 1 to 7 days ahead, from January 2024.
- The station readings described above. For Washington that's the SNOTEL hourly history. For Whistler it's BC ENV's archive files (`SD_Archive.csv` and `TA_Archive.csv`, over 100 MB together).

Revelstoke and Sun Peaks have no station, so they use the figures for every location together.

## Lift hours

Each ski area in `locations.json` has typical weekday and weekend first and last chair times, taken from the resort's published hours. They don't track season dates, holidays, night skiing or day-to-day changes, so the planner presents them as typical. Where hours change through the season (Whistler closes at 3:00 PM early in the season and 4:00 PM by spring), the entry uses the early-season hours.

## Drive times: Apple Maps

The ski day planner gets drive times from Apple Maps through MapKit, which is free and needs no key. Each request asks for the drive that arrives at the lot by a given time, with Apple's predicted traffic for that time. The route's halfway point gives a second place to check road weather, from Open-Meteo at that point's own elevation. Home is sent only to Apple, as the start of the route.

Apple gives one estimate per request, with no optimistic or pessimistic range, and applies current road closures. A closed access road gives no drive time rather than a wrong one, and the planner says so.

## Avalanche danger: NWAC and Avalanche Canada

Avalanche danger comes straight from the regional avalanche center's forecast. Notchline only picks the right zone and day. Always read the full forecast before heading into avalanche terrain.

**Washington.** The [Northwest Avalanche Center](https://nwac.us) publishes its forecasts through the [avalanche.org](https://avalanche.org) public API, which covers most US avalanche centers. Notchline finds the forecast zone that contains the ski area and shows its rating for the upper, middle and lower elevation bands:

| Location | Zone |
|---|---|
| Mt. Baker | West Slopes North |
| Stevens Pass | Stevens Pass |
| Snoqualmie | Snoqualmie Pass |
| Crystal | West Slopes South |

**British Columbia.** [Avalanche Canada](https://avalanche.ca) lets you look up the forecast for any point. Notchline shows today's ratings for the alpine, treeline and below treeline bands. Avalanche Canada regroups its subregions into different forecast areas from day to day, so there is no fixed zone name per resort. Notchline labels the zone "Avalanche Canada", and the forecast link shows the full area.

Neither center issues danger ratings out of season.

Both NWAC and Avalanche Canada are nonprofits funded partly by donations.

## Sources considered but not used

- **NWAC weather stations.** NWAC runs telemetry stations at or near most Washington ski areas, closer to the base areas than SNOTEL (notably at Baker). There is no public API, and Notchline does not scrape the website. If NWAC offers API access, these stations would be a good addition.
- **Environment and Climate Change Canada** real-time observations. None of the stations near the BC resorts report snow depth.
