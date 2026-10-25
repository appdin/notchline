# Roadmap

- **Ski day planner**: score groomed and ungroomed skiing for today through +3 days and say when to leave home to be on the lift for the best of it, with Mac notifications. See [dev_planning/ski-day-planner.md](dev_planning/ski-day-planner.md).

- **NWAC station data**: ask NWAC for API access to its telemetry, which sits closer to the Washington base areas than SNOTEL and has ridge-top wind. It has no public API, so this starts with a request to NWAC. See [data-sources.md](data-sources.md).
- **Open-Meteo model choice**: compare Open-Meteo models against observed snowfall in the first weeks of the season and pin one per region with the `models` parameter.
- **BC observed snow**: Revelstoke and Sun Peaks show modeled depth. Revisit if a closer station starts reporting depth or Avalanche Canada opens up its station data.
