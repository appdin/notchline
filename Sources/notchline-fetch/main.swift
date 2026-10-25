import Foundation
import NotchlineCore

// Debug command: fetch a live snapshot for one location and print it.
// Usage: notchline-fetch [location-id] [--json] [--home lat,lon]
//        notchline-fetch [location-id] --score-history yyyy-MM-dd yyyy-MM-dd
//        notchline-fetch --backtest-confidence [--out path] [--cache dir]
// --score-history scores every day in the range from Open-Meteo's archived forecasts and prints
// one tab-separated line per day, for checking the planner against known storm days.
// --home adds departure times from that point, with Apple Maps drive times and default settings.
// --backtest-confidence measures how often scores held at each location with a station and writes
// the confidence table, see scripts/backtest-confidence.sh. --cache keeps responses on disk.

let args = CommandLine.arguments.dropFirst()
let wantsJSON = args.contains("--json")
let catalog = try LocationCatalog.bundled()

if args.contains("--list") {
    for location in catalog.locations {
        print("\(location.id)\t\(location.name) (\(location.region))")
    }
    exit(0)
}

func value(after flag: String) -> String? {
    args.firstIndex(of: flag).flatMap { args.index(after: $0) < args.endIndex ? args[args.index(after: $0)] : nil }
}

/// Keeps responses on disk by URL, so rerunning the backtest does not spend Open-Meteo's daily quota again.
struct DiskCachedHTTPClient: HTTPClient {
    let inner: HTTPClient
    let directory: URL

    func get(_ url: URL) async throws -> Data {
        // FNV-1a, stable across runs unlike Hasher.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.absoluteString.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let file = directory.appendingPathComponent(String(hash, radix: 16))
        if let data = try? Data(contentsOf: file) { return data }
        let data = try await inner.get(url)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file)
        return data
    }
}

if args.contains("--backtest-confidence") {
    var http: HTTPClient = RetryingHTTPClient(URLSessionHTTPClient(timeout: 300), retries: 2)
    if let cache = value(after: "--cache") { http = DiskCachedHTTPClient(inner: http, directory: URL(fileURLWithPath: cache)) }
    let openMeteo = OpenMeteoProvider(http: http)
    // Previous Runs starts in January 2024, so the first season starts a week in, once runs from
    // 3 days ahead exist. Seasons run December through mid-April.
    let seasons = [("2024-01-08", "2024-04-15"), ("2024-12-01", "2025-04-15"), ("2025-12-01", "2026-04-15")]
    let gust = PlannerSettings.default.gustThresholdMph
    var samples: [ConfidenceBacktest.Sample] = []
    func log(_ line: String) { FileHandle.standardError.write(Data("\(line)\n".utf8)) }
    for location in catalog.locations where location.liftHours != nil {
        let calendar = location.calendar
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let ranges = seasons.map { (formatter.date(from: $0.0)!, formatter.date(from: $0.1)!) }
        let start = calendar.date(byAdding: .day, value: -1, to: ranges.first!.0)!
        let end = calendar.date(byAdding: .day, value: 2, to: ranges.last!.1)!
        let history: StationHistory
        switch location.observedSnow {
        case .snotel(let stations)? where !stations.isEmpty:
            history = try await SnotelProvider(http: http).history(station: stations[0], from: start, through: end)
        case .bcSnowStations(let stations)? where !stations.isEmpty:
            history = try await BCSnowStationProvider(http: http).archiveHistory(station: stations[0], from: start, through: end)
        default:
            log("\(location.id): no station, uses every location's figures")
            continue
        }
        var covered = 0
        for (first, last) in ranges {
            func score(_ hourly: HourlyForecast) -> PlannerScores {
                SkiDayScorer.score(hourly, location: location, now: first, gustThresholdMph: gust)
            }
            var observed: (scores: PlannerScores, days: Set<Date>)?
            for lead in 0...3 {
                let runs = try await openMeteo.previousRuns(for: location, from: first, through: last, lead: lead)
                if observed == nil {
                    let record = ConfidenceBacktest.observed(runs.forecast, station: history, location: location)
                    // The first day has no snow from before the range.
                    observed = (score(record.hourly), record.coveredDays.filter { $0 > calendar.startOfDay(for: first) })
                    covered += observed!.days.count
                }
                samples += ConfidenceBacktest.samples(
                    location: location, lead: lead, forecast: score(runs.forecast), models: runs.models.values.map(score),
                    observed: observed!.scores, coveredDays: observed!.days)
            }
        }
        log("\(location.id): \(covered) days with \(history.stationName) readings")
    }
    let table = ConfidenceBacktest.table(samples, seasons: seasons.map { "\($0.0)...\($0.1)" })
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let json = try encoder.encode(table)
    if let out = value(after: "--out") {
        try json.write(to: URL(fileURLWithPath: out))
    } else {
        print(String(decoding: json, as: UTF8.self))
    }
    log("location\tterrain\tlead\tagreement\tdays\theld\tmeanError")
    for cell in table.cells {
        log([cell.location ?? "all", cell.terrain.rawValue, "+\(cell.lead)", cell.agreement?.rawValue ?? "any", "\(cell.days)",
             "\(Int((100 * Double(cell.held) / Double(cell.days)).rounded()))%", String(format: "%.1f", cell.meanError)].joined(separator: "\t"))
    }
    exit(0)
}

let homeArgument = value(after: "--home")
let positional = args.filter { !$0.hasPrefix("--") && $0 != homeArgument }
let requestedID = positional.first ?? LocationCatalog.defaultLocationID
guard let location = catalog.location(id: requestedID) else {
    FileHandle.standardError.write(Data("Unknown location '\(requestedID)'. Use --list to see IDs.\n".utf8))
    exit(1)
}

if args.contains("--score-history") {
    let dayFormatter = DateFormatter()
    dayFormatter.locale = Locale(identifier: "en_US_POSIX")
    dayFormatter.timeZone = location.calendar.timeZone
    dayFormatter.dateFormat = "yyyy-MM-dd"
    guard positional.count == 3, let first = dayFormatter.date(from: positional[1]), let last = dayFormatter.date(from: positional[2]) else {
        FileHandle.standardError.write(Data("Usage: notchline-fetch <location-id> --score-history yyyy-MM-dd yyyy-MM-dd\n".utf8))
        exit(1)
    }
    let hourly = try await OpenMeteoProvider(http: RetryingHTTPClient(URLSessionHTTPClient(timeout: 60)))
        .historicalHourly(for: location, from: first, through: last)
    let scores = SkiDayScorer.score(hourly, location: location, now: first, gustThresholdMph: PlannerSettings.default.gustThresholdMph)
    print("day\tweekday\tnewSnowIn\tgroomed\tungroomed\trainHours\twindHours\tvisibilityHours\ticyHours")
    for day in scores.days {
        let vetoes = { (veto: Veto) in day.hours.filter { $0.veto == veto }.count }
        let weekday = location.calendar.component(.weekday, from: day.day)
        print([dayFormatter.string(from: day.day), dayFormatter.shortWeekdaySymbols[weekday - 1], String(format: "%.1f", day.newSnowInches),
               day.groomed.map { "\($0.averageScore)" } ?? "-", day.ungroomed.map { "\($0.averageScore)" } ?? "-",
               "\(vetoes(.rain))", "\(vetoes(.wind))", "\(vetoes(.visibility))", "\(day.hours.filter(\.isIcy).count)"].joined(separator: "\t"))
    }
    for warning in scores.warnings { FileHandle.standardError.write(Data("! \(warning)\n".utf8)) }
    exit(0)
}

let result = await ConditionsService().refresh(location)
let snapshot = result.snapshot

if wantsJSON {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(snapshot), as: UTF8.self))
    exit(0)
}

let units = location.defaultUnits

func age(_ date: Date?) -> String {
    guard let date else { return "" }
    let minutes = Int(Date().timeIntervalSince(date) / 60)
    return minutes < 120 ? "\(minutes) min ago" : "\(minutes / 60) h ago"
}

func failure(_ metric: Metric) -> String {
    result.errors[metric].map { "unavailable (\($0))" } ?? "unavailable"
}

print(location.name)
if let observed = snapshot.observed {
    let modeled = observed.isModeled ? " (modeled)" : ""
    print("  Base       \(ConditionsFormat.snow(observed.depthInches, units))\(modeled)  \(observed.stationName) \(ConditionsFormat.elevation(observed.stationElevationFt, units)), \(age(observed.observedAt))")
    print("  Last 24h   \(observed.snow24hInches.map { ConditionsFormat.newSnow($0, units) } ?? "no reading 24h ago")")
} else {
    print("  Base       \(failure(.observed))")
    print("  Last 24h   \(failure(.observed))")
}
if let forecast = snapshot.forecast {
    let grid = forecast.gridElevationFt.map { (forecast.sourceName == "NWS" ? " grid " : " ") + ConditionsFormat.elevation($0, units) } ?? ""
    let issued = forecast.issuedAt.map { ", issued \(age($0))" } ?? ""
    print("  Next 24h   \(ConditionsFormat.newSnow(forecast.next24hInches, units))  \(forecast.sourceName)\(grid)\(issued)")
} else {
    print("  Next 24h   \(failure(.forecast))")
}
if let current = snapshot.currentTemp(now: Date()) {
    let source = current.isForecast ? "\(snapshot.forecast?.sourceName ?? "") forecast" : snapshot.observed?.stationName ?? ""
    print("  Temp now   \(ConditionsFormat.degrees(current.tempF, units))\(ConditionsFormat.temperatureScale(units))  \(source)")
} else {
    print("  Temp now   unavailable")
}
if let forecast = snapshot.forecast {
    let high = forecast.high.map { (ConditionsFormat.highIsTomorrow($0, now: Date(), calendar: location.calendar) ? "tomorrow " : "") + ConditionsFormat.degrees($0.tempF, units) } ?? "-"
    print("  High/Low   \(high) / \(forecast.low.map { ConditionsFormat.degrees($0.tempF, units) } ?? "-")")
    if let wind = forecast.windNow {
        let direction = wind.directionDegrees.map { " from " + ConditionsFormat.compass($0) } ?? ""
        let unit = ConditionsFormat.windUnit(units)
        let peak = forecast.windPeak24h.map { ", next 24h peak \(ConditionsFormat.wind($0, units)) \(unit)" } ?? ""
        print("  Wind       \(ConditionsFormat.wind(wind, units)) \(unit)\(direction)\(peak)")
    } else {
        print("  Wind       unavailable")
    }
    if let hours = forecast.hourly?.hours, let first = hours.first, let last = hours.last {
        let formatter = DateFormatter()
        formatter.timeZone = location.calendar.timeZone
        formatter.dateFormat = "EEE HH:mm"
        print("  Hourly     \(hours.count) hours, \(formatter.string(from: first.start)) to \(formatter.string(from: last.start))")
    } else {
        print("  Hourly     unavailable")
    }
    if forecast.hourly != nil {
        var settings = PlannerSettings.default
        if let homeArgument {
            let parts = homeArgument.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 2 else {
                FileHandle.standardError.write(Data("--home takes lat,lon, for example 47.6062,-122.3321\n".utf8))
                exit(1)
            }
            settings.home = Home(address: homeArgument, latitude: parts[0], longitude: parts[1])
        }
        let now = Date()
        let plan = await SkiDayPlanner.live().plan(snapshot, location: location, settings: settings, now: now)!
        let dayFormatter = DateFormatter()
        dayFormatter.timeZone = location.calendar.timeZone
        dayFormatter.dateFormat = "EEE"
        let timeFormatter = DateFormatter()
        timeFormatter.timeZone = location.calendar.timeZone
        timeFormatter.dateFormat = "HH:mm"
        func describe(_ window: ScoreWindow?) -> String {
            window.map { "\($0.averageScore) (\(timeFormatter.string(from: $0.interval.start))-\(timeFormatter.string(from: $0.interval.end)))" } ?? "-"
        }
        for (index, day) in plan.days.map(\.score).enumerated() {
            let label = index == 0 ? "  Scores     " : "             "
            let vetoes = Set(day.hours.compactMap(\.veto)).map(\.rawValue).sorted()
            let held = vetoes.isEmpty ? "" : "  vetoed: \(vetoes.joined(separator: ", "))"
            let confidence = day.confidence.map { confidence in
                let spread = confidence.ungroomed.modelSpread.map { ", models within \($0)" } ?? ""
                return "  confidence \(confidence.groomed.percent)%/\(confidence.ungroomed.percent)%\(confidence.ungroomed.isMeasured ? "" : " (rule)")\(spread)"
            } ?? ""
            print("\(label)\(dayFormatter.string(from: day.day))  groomed \(describe(day.groomed))  ungroomed \(describe(day.ungroomed))  new \(ConditionsFormat.snow(day.newSnowInches, units))\(held)\(confidence)")
        }
        for (index, day) in plan.days.enumerated() {
            for terrain in Terrain.allCases {
                guard let departure = day.departure(terrain) else { continue }
                let label = index == 0 && terrain == .groomed ? "  Depart     " : "             "
                let overnight = departure.overnight.map { "; " + PlannerFormat.overnight($0, now: now, timeZone: location.calendar.timeZone) } ?? ""
                print("\(label)\(dayFormatter.string(from: day.score.day)) \(terrain.rawValue): \(PlannerFormat.advice(departure.advice(now: now), timeZone: location.calendar.timeZone)) for \(timeFormatter.string(from: departure.liftTime)) on the lift, \(PlannerFormat.drive(departure.drive))\(overnight)")
            }
        }
        let plannerWarnings = plan.warnings
        for warning in plannerWarnings { print("  ! planner: \(warning)") }
    }
    if let hours = location.liftInterval(on: Date()) {
        let formatter = DateFormatter()
        formatter.timeZone = location.calendar.timeZone
        formatter.timeStyle = .short
        print("  Lifts      \(formatter.string(from: hours.start)) to \(formatter.string(from: hours.end)) today (typical)")
    }
}
if let danger = snapshot.danger(at: Date()) {
    let rating = danger.isExpired(at: Date()) ? "forecast expired"
        : danger.overall == .noRating ? danger.overall.label : "\(danger.overall.label) (\(danger.overall.rawValue))"
    print("  Avalanche  \(danger.zoneName): \(rating)")
    if let upper = danger.upper, let middle = danger.middle, let lower = danger.lower {
        print("             Above TL \(upper.rawValue) · Near TL \(middle.rawValue) · Below TL \(lower.rawValue)")
    }
    if let url = danger.forecastURL { print("             \(url.absoluteString)") }
} else {
    print("  Avalanche  \(failure(.avalanche))")
}

let warningLines = Metric.allCases.flatMap { metric in (result.warnings[metric] ?? []).map { "  ! \(metric.rawValue): \($0)" } }
if !warningLines.isEmpty {
    print(warningLines.joined(separator: "\n"))
}
