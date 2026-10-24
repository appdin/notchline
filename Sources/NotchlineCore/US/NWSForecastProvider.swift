import Foundation

/// Next-24h snowfall, temperature and wind from the National Weather Service gridpoint forecast.
/// https://www.weather.gov/documentation/services-web-api
public struct NWSForecastProvider: SnowForecastProvider {
    private let http: HTTPClient
    private let gridURLs = LookupCache<URL>()

    public init(http: HTTPClient) {
        self.http = http
    }

    public func fetch(for location: Location, now: Date) async throws -> SnowForecast {
        let http = self.http
        let gridURL = try await gridURLs.value(for: location.id, now: now) {
            let pointURL = URL(string: String(format: "https://api.weather.gov/points/%.4f,%.4f", location.latitude, location.longitude))!
            return try Self.parsePoint(try await http.get(pointURL))
        }
        return try Self.parseGridpoint(try await http.get(gridURL), now: now)
    }

    static func parsePoint(_ data: Data) throws -> URL {
        struct Point: Decodable {
            struct Properties: Decodable { let forecastGridData: URL }
            let properties: Properties
        }
        return try JSONDecoder().decode(Point.self, from: data).properties.forecastGridData
    }

    static func parseGridpoint(_ data: Data, now: Date) throws -> SnowForecast {
        let grid = try JSONDecoder().decode(Gridpoint.self, from: data).properties
        guard let snowfall = grid.snowfallAmount else {
            throw ProviderError.noData("snowfallAmount in NWS gridpoint")
        }
        guard snowfall.uom == "wmoUnit:mm" else {
            throw ProviderError.unexpectedResponse("snowfallAmount unit \(snowfall.uom)")
        }
        guard !snowfall.values.isEmpty else {
            throw ProviderError.noData("NWS snowfall forecast is empty")
        }
        let window = DateInterval(start: now, duration: 24 * 60 * 60)
        var totalMM = 0.0
        for entry in snowfall.values {
            guard let interval = parseValidTime(entry.validTime) else {
                throw ProviderError.unexpectedResponse("validTime \(entry.validTime)")
            }
            totalMM += (entry.value ?? 0) * overlapFraction(interval, window)
        }
        let elevationFt = grid.elevation.flatMap { elevation in
            elevation.value.map { Int((elevation.unitCode == "wmoUnit:m" ? $0 * 3.28084 : $0).rounded()) }
        }
        let temperature = series(grid.temperature, unit: "wmoUnit:degC", convert: fahrenheit)
        let windSpeed = series(grid.windSpeed, unit: "wmoUnit:km_h-1", convert: mph)
        let windGust = series(grid.windGust, unit: "wmoUnit:km_h-1", convert: mph)
        let windDirection = series(grid.windDirection, unit: "wmoUnit:degree_(angle)")
        return SnowForecast(
            next24hInches: totalMM / 25.4,
            issuedAt: grid.updateTime.flatMap(parseISODate),
            gridElevationFt: elevationFt,
            sourceName: "NWS",
            tempNowF: value(in: temperature, at: now),
            high: notEnded(series(grid.maxTemperature, unit: "wmoUnit:degC", convert: fahrenheit), now: now),
            low: notEnded(series(grid.minTemperature, unit: "wmoUnit:degC", convert: fahrenheit), now: now),
            windNow: value(in: windSpeed, at: now).map {
                Wind(sustainedMph: $0, gustMph: value(in: windGust, at: now), directionDegrees: value(in: windDirection, at: now))
            },
            windPeak24h: peak(in: windSpeed, window: window).map { sustained in
                Wind(
                    sustainedMph: sustained.value,
                    gustMph: peak(in: windGust, window: window)?.value,
                    directionDegrees: value(in: windDirection, at: max(now, sustained.interval.start)))
            }
        )
    }

    /// A gridpoint layer's values with parsed intervals. nil when the layer is missing, empty or in another unit,
    /// which leaves that field blank rather than failing the snowfall forecast.
    static func series(_ layer: Gridpoint.Layer?, unit: String, convert: (Double) -> Double = { $0 }) -> [TimedValue]? {
        guard let layer, layer.uom == unit else { return nil }
        let values = layer.values.compactMap { entry -> TimedValue? in
            guard let value = entry.value, let interval = parseValidTime(entry.validTime) else { return nil }
            return TimedValue(interval: interval, value: convert(value))
        }
        return values.isEmpty ? nil : values
    }

    static func value(in series: [TimedValue]?, at date: Date) -> Double? {
        series?.first { $0.interval.start <= date && date < $0.interval.end }?.value
    }

    /// Highest value among intervals overlapping `window`.
    static func peak(in series: [TimedValue]?, window: DateInterval) -> TimedValue? {
        series?.filter { overlapFraction($0.interval, window) > 0 }.max { $0.value < $1.value }
    }

    /// The first daily high or low period that has not ended, so the current one or the next.
    static func notEnded(_ series: [TimedValue]?, now: Date) -> ForecastTemp? {
        series?.first { $0.interval.end > now }.map { ForecastTemp(tempF: $0.value, period: $0.interval) }
    }

    static func fahrenheit(_ celsius: Double) -> Double { celsius * 9 / 5 + 32 }
    static func mph(_ kmh: Double) -> Double { kmh / 1.609344 }

    struct TimedValue: Equatable {
        let interval: DateInterval
        let value: Double
    }

    /// Fraction of `interval` that falls inside `window`, for prorating amounts that straddle its edges.
    static func overlapFraction(_ interval: DateInterval, _ window: DateInterval) -> Double {
        guard interval.duration > 0, let overlap = interval.intersection(with: window) else { return 0 }
        return overlap.duration / interval.duration
    }

    /// Parses NWS valid times like "2026-11-02T18:00:00+00:00/PT6H" or ".../P1DT12H".
    static func parseValidTime(_ string: String) -> DateInterval? {
        let parts = string.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let start = parseISODate(parts[0]), let duration = parseISODuration(parts[1]) else {
            return nil
        }
        return DateInterval(start: start, duration: duration)
    }

    static func parseISODate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// Parses the day, hour and minute parts of an ISO 8601 duration such as "PT6H" or "P1DT12H".
    static func parseISODuration(_ string: String) -> TimeInterval? {
        guard string.hasPrefix("P") else { return nil }
        var seconds = 0.0
        var number = ""
        var inTime = false
        for char in string.dropFirst() {
            switch char {
            case "T": inTime = true
            case "0"..."9", ".": number.append(char)
            case "D", "H", "M", "S", "W":
                guard let value = Double(number) else { return nil }
                number = ""
                switch (char, inTime) {
                case ("W", false): seconds += value * 7 * 86400
                case ("D", false): seconds += value * 86400
                case ("H", true): seconds += value * 3600
                case ("M", true): seconds += value * 60
                case ("S", true): seconds += value
                default: return nil
                }
            default: return nil
            }
        }
        return number.isEmpty && seconds > 0 ? seconds : nil
    }

    struct Gridpoint: Decodable {
        struct Properties: Decodable {
            let updateTime: String?
            let elevation: Measurement?
            let snowfallAmount: Layer?
            let temperature: Layer?
            let maxTemperature: Layer?
            let minTemperature: Layer?
            let windSpeed: Layer?
            let windGust: Layer?
            let windDirection: Layer?
        }
        struct Measurement: Decodable {
            let unitCode: String
            let value: Double?
        }
        struct Layer: Decodable {
            let uom: String
            let values: [Entry]
        }
        struct Entry: Decodable {
            let validTime: String
            let value: Double?
        }
        let properties: Properties
    }
}
