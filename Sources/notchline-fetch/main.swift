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

func inches(_ value: Double?) -> String {
    value.map { String(format: "%.1f\"", $0) } ?? "-"
}

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
    print("  Base       \(inches(observed.depthInches))  \(observed.stationName) \(observed.stationElevationFt)', \(age(observed.observedAt))")
    print("  Last 24h   \(observed.snow24hInches.map { "+" + inches($0) } ?? "no reading 24h ago")")
} else {
    print("  Base       \(failure(.observed))")
    print("  Last 24h   \(failure(.observed))")
}
if let forecast = snapshot.forecast {
    let grid = forecast.gridElevationFt.map { " grid \($0)'" } ?? ""
    print("  Next 24h   +\(inches(forecast.next24hInches))  \(forecast.sourceName)\(grid), issued \(age(forecast.issuedAt))")
} else {
    print("  Next 24h   \(failure(.forecast))")
}
if let danger = snapshot.danger {
    let rating = danger.overall == .noRating ? danger.overall.label : "\(danger.overall.label) (\(danger.overall.rawValue))"
    print("  Avalanche  \(danger.zoneName): \(rating)")
    if let upper = danger.upper, let middle = danger.middle, let lower = danger.lower {
        print("             Above TL \(upper.rawValue) · Near TL \(middle.rawValue) · Below TL \(lower.rawValue)")
    }
    if let url = danger.forecastURL { print("             \(url.absoluteString)") }
} else {
    print("  Avalanche  \(failure(.avalanche))")
}
