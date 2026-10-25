import Foundation

/// Next-24h snowfall, temperature, wind and the hourly planner series from the National Weather Service gridpoint forecast.
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
        return try Self.parseGridpoint(try await http.get(gridURL), now: now, calendar: location.calendar)
    }

    static func parsePoint(_ data: Data) throws -> URL {
        struct Point: Decodable {
            struct Properties: Decodable { let forecastGridData: URL }
            let properties: Properties
        }
        return try JSONDecoder().decode(Point.self, from: data).properties.forecastGridData
    }

    static func parseGridpoint(_ data: Data, now: Date, calendar: Calendar) throws -> SnowForecast {
        let grid = try JSONDecoder().decode(Gridpoint.self, from: data).properties
        guard let snowfall = grid.snowfallAmount else {
            throw ProviderError.noData("snowfallAmount in NWS gridpoint")
        }
        guard UnitCheck.matches(snowfall.uom, "wmoUnit:mm", field: "NWS snowfall") else {
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
            elevation.value.flatMap { meters in
                UnitCheck.matches(elevation.unitCode, "wmoUnit:m", field: "NWS grid elevation")
                    ? Int(Convert.feet(fromM: meters).rounded()) : nil
            }
        }
        let fahrenheit = { Convert.fahrenheit(fromC: $0) }
        let mph = { Convert.mph(fromKMH: $0) }
        let temperature = series(grid.temperature, "temperature", unit: "wmoUnit:degC", convert: fahrenheit)
        let windSpeed = series(grid.windSpeed, "windSpeed", unit: "wmoUnit:km_h-1", convert: mph)
        let windGust = series(grid.windGust, "windGust", unit: "wmoUnit:km_h-1", convert: mph)
        let windDirection = series(grid.windDirection, "windDirection", unit: "wmoUnit:degree_(angle)")
        let hourlySeries = HourlySeries(
            temperature: temperature,
            snowfall: series(snowfall, "snowfallAmount", unit: "wmoUnit:mm", convert: Convert.inches(fromMM:)),
            precipitation: series(grid.quantitativePrecipitation, "quantitativePrecipitation", unit: "wmoUnit:mm", convert: Convert.inches(fromMM:)),
            precipitationProbability: series(grid.probabilityOfPrecipitation, "probabilityOfPrecipitation", unit: "wmoUnit:percent"),
            snowLevel: series(grid.snowLevel, "snowLevel", unit: "wmoUnit:m", convert: Convert.feet(fromM:)),
            visibility: series(grid.visibility, "visibility", unit: "wmoUnit:m", convert: Convert.miles(fromM:)),
            skyCover: series(grid.skyCover, "skyCover", unit: "wmoUnit:percent"),
            windSpeed: windSpeed, windGust: windGust, windDirection: windDirection,
            weather: weatherSeries(grid.weather))
        return SnowForecast(
            next24hInches: Convert.inches(fromMM: totalMM),
            issuedAt: grid.updateTime.flatMap(parseISODate),
            gridElevationFt: elevationFt,
            sourceName: "NWS",
            tempNowF: value(in: temperature, at: now),
            high: notEnded(series(grid.maxTemperature, "maxTemperature", unit: "wmoUnit:degC", convert: fahrenheit), now: now),
            low: notEnded(series(grid.minTemperature, "minTemperature", unit: "wmoUnit:degC", convert: fahrenheit), now: now),
            windNow: value(in: windSpeed, at: now).map {
                Wind(sustainedMph: $0, gustMph: value(in: windGust, at: now), directionDegrees: value(in: windDirection, at: now))
            },
            windPeak24h: peak(in: windSpeed, window: window).map { sustained in
                Wind(
                    sustainedMph: sustained.value,
                    gustMph: peak(in: windGust, window: window)?.value,
                    directionDegrees: value(in: windDirection, at: max(now, sustained.interval.start)))
            },
            hourly: HourlyForecast.build(now: now, calendar: calendar, source: "NWS") { hourlySeries.hour(starting: $0) }
        )
    }

    /// Gridpoint layers converted to the model's units, sampled hour by hour for `HourlyForecast`.
    struct HourlySeries {
        let temperature, snowfall, precipitation, precipitationProbability, snowLevel, visibility, skyCover: [TimedValue]?
        let windSpeed, windGust, windDirection: [TimedValue]?
        let weather: [(interval: DateInterval, types: Set<PrecipitationType>)]

        /// Amounts are prorated from the intervals overlapping the hour; other values are the
        /// interval containing the hour's start.
        func hour(starting start: Date) -> ForecastHour {
            let hour = DateInterval(start: start, duration: 3600)
            func at(_ series: [TimedValue]?) -> Double? { NWSForecastProvider.value(in: series, at: start) }
            return ForecastHour(
                start: start,
                tempF: at(temperature),
                snowfallInches: NWSForecastProvider.amount(in: snowfall, over: hour),
                precipitationInches: NWSForecastProvider.amount(in: precipitation, over: hour),
                precipitationProbability: at(precipitationProbability),
                snowLevelFt: at(snowLevel),
                visibilityMiles: at(visibility),
                skyCoverPercent: at(skyCover),
                wind: at(windSpeed).map { Wind(sustainedMph: $0, gustMph: at(windGust), directionDegrees: at(windDirection)) },
                precipitationTypes: weather.first { $0.interval.start <= start && start < $0.interval.end }?.types ?? [])
        }
    }

    /// Sum of the prorated amounts overlapping `window`. nil when no interval overlaps it.
    static func amount(in series: [TimedValue]?, over window: DateInterval) -> Double? {
        let overlapping = series?.filter { overlapFraction($0.interval, window) > 0 } ?? []
        guard !overlapping.isEmpty else { return nil }
        return overlapping.reduce(0) { $0 + $1.value * overlapFraction($1.interval, window) }
    }

    /// NWS weather types mapped to precipitation types. Types that are not precipitation (fog,
    /// haze, smoke and the like) are left out by design.
    static let precipitationTypes: [String: PrecipitationType] = [
        "snow": .snow, "snow_showers": .snow,
        "rain": .rain, "rain_showers": .rain, "drizzle": .rain,
        "freezing_rain": .freezingRain, "freezing_drizzle": .freezingRain,
        "sleet": .sleet,
    ]

    static func weatherSeries(_ layer: Gridpoint.WeatherLayer?) -> [(interval: DateInterval, types: Set<PrecipitationType>)] {
        (layer?.values ?? []).compactMap { entry in
            guard let interval = parseValidTime(entry.validTime) else { return nil }
            return (interval, Set((entry.value ?? []).compactMap { $0.weather.flatMap { precipitationTypes[$0] } }))
        }
    }

    /// A gridpoint layer's values with parsed intervals. nil when the layer is missing, empty or in another unit,
    /// which leaves that field blank rather than failing the snowfall forecast. A unit mismatch is recorded.
    static func series(_ layer: Gridpoint.Layer?, _ name: String, unit: String, convert: (Double) -> Double = { $0 }) -> [TimedValue]? {
        guard let layer, UnitCheck.matches(layer.uom, unit, field: "NWS \(name)") else { return nil }
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
            let snowLevel: Layer?
            let visibility: Layer?
            let skyCover: Layer?
            let probabilityOfPrecipitation: Layer?
            let quantitativePrecipitation: Layer?
            let weather: WeatherLayer?
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
        /// The weather layer has no unit; each value lists the conditions forecast for its interval.
        struct WeatherLayer: Decodable {
            let values: [WeatherEntry]
        }
        struct WeatherEntry: Decodable {
            let validTime: String
            let value: [WeatherCondition]?
        }
        struct WeatherCondition: Decodable {
            /// For example "snow_showers" or "rain". null when nothing is forecast.
            let weather: String?
        }
        let properties: Properties
    }
}
