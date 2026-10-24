import Foundation

/// Observed snow depth from USDA NRCS SNOTEL stations via the AWDB REST API.
/// https://wcc.sc.egov.usda.gov/awdbRestApi/swagger-ui/index.html
public struct SnotelProvider: ObservedSnowProvider {
    static let baseURL = URL(string: "https://wcc.sc.egov.usda.gov/awdbRestApi/services/v1/data")!

    /// Readings older than this are treated as a station outage and the next station is tried.
    /// If every station is older, the most recent reading is used anyway.
    static let maxReadingAge: TimeInterval = 6 * 60 * 60
    /// Depth changes faster than this are treated as sensor spikes or dropouts.
    static let maxInchesPerHour = 12.0

    private let http: HTTPClient

    public init(http: HTTPClient) {
        self.http = http
    }

    public func fetch(for location: Location, now: Date) async throws -> ObservedSnow {
        guard case .snotel(let stations)? = location.observedSnow, !stations.isEmpty else {
            throw ProviderError.notConfigured("SNOTEL stations for \(location.id)")
        }
        var lastError: Error = ProviderError.noData("SNOTEL")
        var freshestOutdated: ObservedSnow?
        for station in stations {
            do {
                let data = try await http.get(Self.requestURL(station: station, now: now))
                let observed = try Self.parse(data, station: station, now: now)
                if now.timeIntervalSince(observed.observedAt) <= Self.maxReadingAge {
                    return observed
                }
                if observed.observedAt > freshestOutdated?.observedAt ?? .distantPast {
                    freshestOutdated = observed
                }
            } catch {
                lastError = error
            }
        }
        // No station is current (some report depth only sporadically off-season). An old reading,
        // shown dimmed with its age, beats no value.
        if let freshestOutdated { return freshestOutdated }
        throw lastError
    }

    static func requestURL(station: SnotelStation, now: Date) -> URL {
        let formatter = stationDateFormatter(station)
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "stationTriplets", value: station.triplet),
            URLQueryItem(name: "elements", value: "SNWD"),
            URLQueryItem(name: "duration", value: "HOURLY"),
            URLQueryItem(name: "beginDate", value: formatter.string(from: now.addingTimeInterval(-30 * 60 * 60))),
            URLQueryItem(name: "endDate", value: formatter.string(from: now.addingTimeInterval(60 * 60))),
            URLQueryItem(name: "returnFlags", value: "true"),
        ]
        return components.url!
    }

    static func parse(_ data: Data, station: SnotelStation, now: Date) throws -> ObservedSnow {
        let response = try JSONDecoder().decode([StationData].self, from: data)
        guard let values = response.first?.data.first(where: { $0.stationElement.elementCode == "SNWD" })?.values else {
            throw ProviderError.noData("SNWD for \(station.triplet)")
        }
        let formatter = stationDateFormatter(station)
        let readings = values.compactMap { value -> Reading? in
            guard let inches = value.value, inches >= 0, value.qcFlag != "S",
                  let date = formatter.date(from: value.date),
                  date <= now.addingTimeInterval(60 * 60) else { return nil }
            return Reading(date: date, inches: inches)
        }
        let clean = removeSpikes(readings.sorted { $0.date < $1.date })
        guard let latest = clean.last else {
            throw ProviderError.noData("valid SNWD readings for \(station.triplet)")
        }
        let depth = median(of: clean.suffix(3).map(\.inches))
        let snow24h = depth24hAgo(clean, latest: latest.date).map { max(0, depth - $0) }
        return ObservedSnow(
            depthInches: depth,
            snow24hInches: snow24h,
            observedAt: latest.date,
            stationName: station.name,
            stationElevationFt: station.elevationFt
        )
    }

    struct Reading: Equatable {
        let date: Date
        let inches: Double
    }

    /// Drops readings that jump from the last accepted reading faster than `maxInchesPerHour`.
    /// Three consecutive rejected readings that agree with each other become the new baseline,
    /// so a bad first reading or a real step change cannot reject everything after it.
    static func removeSpikes(_ readings: [Reading]) -> [Reading] {
        func plausible(_ a: Reading, _ b: Reading) -> Bool {
            let hours = max(1, abs(b.date.timeIntervalSince(a.date)) / 3600)
            return abs(b.inches - a.inches) <= maxInchesPerHour * hours
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
        return median(of: nearby.map(\.inches))
    }

    static func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// AWDB dates are "yyyy-MM-dd HH:mm" in the station's fixed standard time offset, with no DST.
    static func stationDateFormatter(_ station: SnotelStation) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: station.utcOffsetHours * 3600)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }

    struct StationData: Decodable {
        let stationTriplet: String
        let data: [ElementData]
    }

    struct ElementData: Decodable {
        let stationElement: StationElement
        let values: [Value]
    }

    struct StationElement: Decodable {
        let elementCode: String
    }

    struct Value: Decodable {
        let date: String
        let value: Double?
        let qcFlag: String?
    }
}
