import Foundation
import NotchlineCore

// Debug command: fetch a live snapshot for one location and print it.
// Usage: notchline-fetch [location-id] [--json]

let args = CommandLine.arguments.dropFirst()
let wantsJSON = args.contains("--json")
let catalog = try LocationCatalog.bundled()

if args.contains("--list") {
    for location in catalog.locations {
        print("\(location.id)\t\(location.name) (\(location.region))")
    }
    exit(0)
}

let requestedID = args.first { !$0.hasPrefix("--") } ?? LocationCatalog.defaultLocationID
guard let location = catalog.location(id: requestedID) else {
    FileHandle.standardError.write(Data("Unknown location '\(requestedID)'. Use --list to see IDs.\n".utf8))
    exit(1)
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
