import Foundation

/// Observed snow depth and air temperature from USDA NRCS SNOTEL stations via the AWDB REST API.
/// https://wcc.sc.egov.usda.gov/awdbRestApi/swagger-ui/index.html
public struct SnotelProvider: ObservedSnowProvider {
    static let baseURL = URL(string: "https://wcc.sc.egov.usda.gov/awdbRestApi/services/v1/data")!

    private let http: HTTPClient

    public init(http: HTTPClient) {
        self.http = http
    }

    public func fetch(for location: Location, now: Date) async throws -> ObservedSnow {
        guard case .snotel(let stations)? = location.observedSnow, !stations.isEmpty else {
            throw ProviderError.notConfigured("SNOTEL stations for \(location.id)")
        }
        return try await StationReadings.firstCurrent(stations, now: now) { station in
            try Self.parse(try await http.get(Self.requestURL(station: station, now: now)), station: station, now: now)
        }
    }

    /// Hourly depth and temperature from `start` through `end`, for the confidence backtest.
    public func history(station: SnotelStation, from start: Date, through end: Date) async throws -> StationHistory {
        let (depth, temps) = try Self.readings(try await http.get(Self.requestURL(station: station, from: start, through: end)), station: station, latest: end)
        return StationHistory(
            stationName: station.name, elevationFt: station.elevationFt,
            depthInches: Dictionary(depth.map { ($0.date, $0.value) }, uniquingKeysWith: { first, _ in first }),
            tempF: Dictionary(temps.map { ($0.date, $0.value) }, uniquingKeysWith: { first, _ in first }))
    }

    static func requestURL(station: SnotelStation, now: Date) -> URL {
        requestURL(station: station, from: now.addingTimeInterval(-30 * 60 * 60), through: now.addingTimeInterval(60 * 60))
    }

    static func requestURL(station: SnotelStation, from start: Date, through end: Date) -> URL {
        let formatter = stationDateFormatter(station)
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "stationTriplets", value: station.triplet),
            URLQueryItem(name: "elements", value: "SNWD,TOBS"),
            URLQueryItem(name: "duration", value: "HOURLY"),
            URLQueryItem(name: "beginDate", value: formatter.string(from: start)),
            URLQueryItem(name: "endDate", value: formatter.string(from: end)),
            URLQueryItem(name: "returnFlags", value: "true"),
        ]
        return components.url!
    }

    static func parse(_ data: Data, station: SnotelStation, now: Date) throws -> ObservedSnow {
        let (depth, temps) = try readings(data, station: station, latest: now.addingTimeInterval(60 * 60))
        return try StationReadings.observation(
            depth: depth,
            airTemp: temps,
            stationName: station.name,
            stationElevationFt: station.elevationFt,
            stationID: station.triplet)
    }

    /// Depth and temperature readings no later than `latest`, without suspect values.
    static func readings(_ data: Data, station: SnotelStation, latest: Date) throws -> (depth: [StationReadings.Reading], temps: [StationReadings.Reading]) {
        let response = try JSONDecoder().decode([StationData].self, from: data)
        let elements = response.first?.data ?? []
        guard let depthValues = elements.first(where: { $0.stationElement.elementCode == "SNWD" })?.values else {
            throw ProviderError.noData("SNWD for \(station.triplet)")
        }
        let formatter = stationDateFormatter(station)
        func readings(_ values: [Value], allowNegative: Bool) -> [StationReadings.Reading] {
            values.compactMap { value in
                guard let number = value.value, allowNegative || number >= 0, value.qcFlag != "S",
                      let date = formatter.date(from: value.date),
                      date <= latest else { return nil }
                return StationReadings.Reading(date: date, value: number)
            }
        }
        let temps = elements.first(where: { $0.stationElement.elementCode == "TOBS" }).map { readings($0.values, allowNegative: true) }
        return (readings(depthValues, allowNegative: false), temps ?? [])
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
