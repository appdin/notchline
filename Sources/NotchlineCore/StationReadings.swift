import Foundation

/// Turns hourly station readings into an `ObservedSnow`. Shared by every station source so they
/// clean and summarize readings the same way.
enum StationReadings {
    /// Readings older than this are treated as a station outage and the next station is tried.
    /// If every station is older, the most recent reading is used anyway.
    static let maxReadingAge: TimeInterval = 6 * 60 * 60
    /// Depth changes faster than this are treated as sensor spikes or dropouts.
    static let maxInchesPerHour = 12.0
    /// Air temperature changes faster than this are treated as sensor glitches.
    static let maxDegreesPerHour = 15.0

    struct Reading: Equatable {
        let date: Date
        let value: Double
    }

    /// Base depth is the median of the last 3 clean readings, 24h snow is the change from the
    /// readings near 24 hours earlier, floored at zero. Readings must be in inches and °F.
    static func observation(
        depth: [Reading], airTemp: [Reading], stationName: String, stationElevationFt: Int, stationID: String
    ) throws -> ObservedSnow {
        let clean = removeSpikes(depth.sorted { $0.date < $1.date }, maxPerHour: maxInchesPerHour)
        guard let latest = clean.last else {
            throw ProviderError.noData("valid snow depth readings for \(stationID)")
        }
        let depthInches = median(of: clean.suffix(3).map(\.value))
        let snow24h = depth24hAgo(clean, latest: latest.date).map { max(0, depthInches - $0) }
        let temps = removeSpikes(airTemp.sorted { $0.date < $1.date }, maxPerHour: maxDegreesPerHour)
        return ObservedSnow(
            depthInches: depthInches,
            snow24hInches: snow24h,
            observedAt: latest.date,
            stationName: stationName,
            stationElevationFt: stationElevationFt,
            airTempF: temps.last?.value,
            airTempObservedAt: temps.last?.date
        )
    }

    /// Tries stations in order and returns the first with a current reading. When none is current
    /// (some stations report depth only sporadically off-season), the freshest older reading is
    /// returned, since an old value shown dimmed with its age beats no value.
    static func firstCurrent<Station>(
        _ stations: [Station], now: Date, fetch: (Station) async throws -> ObservedSnow
    ) async throws -> ObservedSnow {
        var lastError: Error = ProviderError.noData("station readings")
        var freshestOutdated: ObservedSnow?
        var skipped: [String] = []
        for station in stations {
            do {
                let observed = try await fetch(station)
                if now.timeIntervalSince(observed.observedAt) <= maxReadingAge {
                    if !skipped.isEmpty {
                        ProviderWarnings.record("Using \(observed.stationName): \(skipped.joined(separator: "; "))")
                    }
                    return observed
                }
                skipped.append("\(observed.stationName) has no reading in the last \(Int(maxReadingAge / 3600)) h")
                if observed.observedAt > freshestOutdated?.observedAt ?? .distantPast {
                    freshestOutdated = observed
                }
            } catch {
                skipped.append("station failed: \(error)")
                lastError = error
            }
        }
        if let freshestOutdated {
            ProviderWarnings.record("No station has a current reading; showing the latest from \(freshestOutdated.stationName)")
            return freshestOutdated
        }
        throw lastError
    }

    /// Drops readings that jump from the last accepted reading faster than `maxPerHour`.
    /// Three consecutive rejected readings that agree with each other become the new baseline,
    /// so a bad first reading or a real step change cannot reject everything after it.
    static func removeSpikes(_ readings: [Reading], maxPerHour: Double = maxInchesPerHour) -> [Reading] {
        func plausible(_ a: Reading, _ b: Reading) -> Bool {
            let hours = max(1, abs(b.date.timeIntervalSince(a.date)) / 3600)
            return abs(b.value - a.value) <= maxPerHour * hours
        }
        var accepted: [Reading] = []
        var rejected: [Reading] = []
        for reading in readings {
            if let previous = accepted.last, !plausible(previous, reading) {
                if let last = rejected.last, !plausible(last, reading) { rejected = [] }
                rejected.append(reading)
                if rejected.count == 3 {
                    accepted = rejected
                    rejected = []
                }
                continue
            }
            rejected = []
            accepted.append(reading)
        }
        return accepted
    }

    /// Median of the readings within two hours of 24 hours before the latest one.
    static func depth24hAgo(_ readings: [Reading], latest: Date) -> Double? {
        let target = latest.addingTimeInterval(-24 * 60 * 60)
        let nearby = readings
            .filter { abs($0.date.timeIntervalSince(target)) <= 2 * 60 * 60 }
            .sorted { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) }
            .prefix(3)
        guard !nearby.isEmpty else { return nil }
        return median(of: nearby.map(\.value))
    }

    static func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
