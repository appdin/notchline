import Foundation
import NotchlineCore

// Debug command: fetch a live snapshot for one location and print it.
// Usage: notchline-fetch [location-id] [--json]
//        notchline-fetch [location-id] --score-history yyyy-MM-dd yyyy-MM-dd
// --score-history scores every day in the range from Open-Meteo's archived forecasts and prints
// one tab-separated line per day, for checking the planner against known storm days.

let args = CommandLine.arguments.dropFirst()
let wantsJSON = args.contains("--json")
let catalog = try LocationCatalog.bundled()

if args.contains("--list") {
    for location in catalog.locations {
        print("\(location.id)\t\(location.name) (\(location.region))")
    }
    exit(0)
}

let positional = args.filter { !$0.hasPrefix("--") }
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
    if let hourly = forecast.hourly {
        let scores = SkiDayScorer.score(
            hourly, location: location, now: Date(), gustThresholdMph: PlannerSettings.default.gustThresholdMph,
            priorSnowInches: SkiDayScorer.priorSnowInches(observed: snapshot.observed, hourly: hourly))
        let dayFormatter = DateFormatter()
        dayFormatter.timeZone = location.calendar.timeZone
        dayFormatter.dateFormat = "EEE"
        let timeFormatter = DateFormatter()
        timeFormatter.timeZone = location.calendar.timeZone
        timeFormatter.dateFormat = "HH:mm"
        func describe(_ window: ScoreWindow?) -> String {
            window.map { "\($0.averageScore) (\(timeFormatter.string(from: $0.interval.start))-\(timeFormatter.string(from: $0.interval.end)))" } ?? "-"
        }
        for (index, day) in scores.days.enumerated() {
            let label = index == 0 ? "  Scores     " : "             "
            let vetoes = Set(day.hours.compactMap(\.veto)).map(\.rawValue).sorted()
            let held = vetoes.isEmpty ? "" : "  vetoed: \(vetoes.joined(separator: ", "))"
            print("\(label)\(dayFormatter.string(from: day.day))  groomed \(describe(day.groomed))  ungroomed \(describe(day.ungroomed))  new \(ConditionsFormat.snow(day.newSnowInches, units))\(held)")
        }
        for warning in scores.warnings { print("  ! planner: \(warning)") }
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
