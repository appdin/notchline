import Foundation

/// Hourly forecast and modeled snow depth from Open-Meteo, at the location's forecast elevation.
/// https://open-meteo.com/en/docs (free for non-commercial use, attribution requested)
///
/// One request serves both the forecast and the modeled snow depth. The response is shared
/// between them for a few minutes so a refresh does not ask twice.
public struct OpenMeteoProvider: Sendable {
    static let baseURL = URL(string: "https://api.open-meteo.com/v1/forecast")!
    public static let sourceName = "Open-Meteo"

    private let http: HTTPClient
    /// Shared by the forecast and modeled depth, which a refresh requests at the same time.
    private let responses = LookupCache<Data>(ttl: 10 * 60)

    public init(http: HTTPClient) {
        self.http = http
    }

    public var forecast: SnowForecastProvider { ForecastAdapter(provider: self) }
    public var modeledSnow: ObservedSnowProvider { ModeledSnowAdapter(provider: self) }

    func response(for location: Location, now: Date) async throws -> Response {
        let url = Self.requestURL(for: location)
        let http = self.http
        return try Self.parse(try await responses.value(for: url.absoluteString, now: now) { try await http.get(url) })
    }

    static func requestURL(for location: Location) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", location.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", location.longitude)),
            URLQueryItem(name: "elevation", value: String(Int(Convert.meters(fromFeet: Double(location.forecastElevationFt)).rounded()))),
            URLQueryItem(name: "hourly", value: "snowfall,snow_depth,temperature_2m,wind_speed_10m,wind_gusts_10m,wind_direction_10m"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "past_days", value: "1"),
            URLQueryItem(name: "forecast_days", value: "3"),
        ]
        return components.url!
    }

    struct Response: Decodable {
        struct Hourly: Decodable {
            let time: [TimeInterval]
            /// cm, summed over the preceding hour.
            let snowfall: [Double?]
            /// m
            let snow_depth: [Double?]
            /// °C
            let temperature_2m: [Double?]
            /// km/h
            let wind_speed_10m: [Double?]
            /// km/h, maximum over the preceding hour.
            let wind_gusts_10m: [Double?]
            /// Degrees, direction the wind blows from.
            let wind_direction_10m: [Double?]
        }
        let elevation: Double?
        /// Unit labels per hourly series, checked before converting.
        let hourly_units: [String: String]?
        let hourly: Hourly

        /// Expected units for each series. A series in any other unit is left out.
        static let expectedUnits = [
            "snowfall": "cm", "snow_depth": "m", "temperature_2m": "°C",
            "wind_speed_10m": "km/h", "wind_gusts_10m": "km/h", "wind_direction_10m": "°",
        ]

        /// The series values when its declared unit is the expected one, otherwise nil and a warning.
        func checked(_ name: String, _ values: [Double?]) -> [Double?]? {
            UnitCheck.matches(hourly_units?[name], Self.expectedUnits[name]!, field: "Open-Meteo \(name)") ? values : nil
        }

        func date(_ index: Int) -> Date { Date(timeIntervalSince1970: hourly.time[index]) }
    }

    static func parse(_ data: Data) throws -> Response {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let count = response.hourly.time.count
        let series = [response.hourly.snowfall.count, response.hourly.snow_depth.count, response.hourly.temperature_2m.count,
                      response.hourly.wind_speed_10m.count, response.hourly.wind_gusts_10m.count, response.hourly.wind_direction_10m.count]
        guard count > 0, series.allSatisfy({ $0 == count }) else {
            throw ProviderError.unexpectedResponse("Open-Meteo hourly series lengths")
        }
        return response
    }

    /// The elevation the values represent. Open-Meteo echoes the requested one in whole meters,
    /// so the location's own figure is used unless the response differs from it.
    static func elevationFt(_ response: Response, location: Location) -> Int {
        guard let meters = response.elevation,
              abs(meters - Convert.meters(fromFeet: Double(location.forecastElevationFt))) > 1 else { return location.forecastElevationFt }
        return Int(Convert.feet(fromM: meters).rounded())
    }

    static func forecast(from response: Response, location: Location, now: Date) throws -> SnowForecast {
        let hourly = response.hourly
        guard let snowfall = response.checked("snowfall", hourly.snowfall) else {
            throw ProviderError.unexpectedResponse("Open-Meteo snowfall unit \(response.hourly_units?["snowfall"] ?? "missing")")
        }
        let none = [Double?](repeating: nil, count: hourly.time.count)
        let temperature = response.checked("temperature_2m", hourly.temperature_2m) ?? none
        let windSpeed = response.checked("wind_speed_10m", hourly.wind_speed_10m) ?? none
        let windGusts = response.checked("wind_gusts_10m", hourly.wind_gusts_10m) ?? none
        let windDirection = response.checked("wind_direction_10m", hourly.wind_direction_10m) ?? none
        let window = DateInterval(start: now, duration: 24 * 60 * 60)
        var snowfallCM = 0.0
        for index in hourly.time.indices {
            // Each value covers the hour before its timestamp.
            let interval = DateInterval(start: response.date(index).addingTimeInterval(-3600), duration: 3600)
            snowfallCM += (snowfall[index] ?? 0) * NWSForecastProvider.overlapFraction(interval, window)
        }
        guard hourly.time.contains(where: { window.contains(Date(timeIntervalSince1970: $0)) }) else {
            throw ProviderError.noData("Open-Meteo forecast hours")
        }
        let current = nearestIndex(to: now, in: response)
        let inWindow = hourly.time.indices.filter { window.contains(response.date($0)) }
        let peakSpeed = inWindow.filter { windSpeed[$0] != nil }.max { windSpeed[$0]! < windSpeed[$1]! }
        let peakGust = inWindow.compactMap { windGusts[$0] }.max()
        return SnowForecast(
            next24hInches: Convert.inches(fromCM: snowfallCM),
            issuedAt: nil,
            gridElevationFt: elevationFt(response, location: location),
            sourceName: sourceName,
            tempNowF: current.flatMap { temperature[$0] }.map(Convert.fahrenheit(fromC:)),
            high: extreme(of: temperature, response, in: LocalTime.daytime(containingOrAfter: now, calendar: location.calendar), highest: true),
            low: extreme(of: temperature, response, in: LocalTime.overnight(containingOrAfter: now, calendar: location.calendar), highest: false),
            windNow: current.flatMap { index in
                windSpeed[index].map {
                    Wind(sustainedMph: Convert.mph(fromKMH: $0),
                         gustMph: windGusts[index].map(Convert.mph(fromKMH:)),
                         directionDegrees: windDirection[index])
                }
            },
            windPeak24h: peakSpeed.map { index in
                Wind(sustainedMph: Convert.mph(fromKMH: windSpeed[index]!),
                     gustMph: peakGust.map(Convert.mph(fromKMH:)),
                     directionDegrees: windDirection[index])
            }
        )
    }

    /// Modeled depth at the latest hour not after `now`, with the 24h change from the same hour yesterday.
    static func modeledSnow(from response: Response, location: Location, now: Date) throws -> ObservedSnow {
        let hourly = response.hourly
        guard let depths = response.checked("snow_depth", hourly.snow_depth) else {
            throw ProviderError.unexpectedResponse("Open-Meteo snow_depth unit \(response.hourly_units?["snow_depth"] ?? "missing")")
        }
        guard let index = hourly.time.indices.last(where: { response.date($0) <= now && depths[$0] != nil }) else {
            throw ProviderError.noData("Open-Meteo modeled snow depth")
        }
        let at = response.date(index)
        let depthInches = Convert.inches(fromM: depths[index]!)
        let dayAgo = hourly.time.indices.first { response.date($0) == at.addingTimeInterval(-24 * 60 * 60) }
        let snow24h = dayAgo.flatMap { depths[$0] }.map { max(0, depthInches - Convert.inches(fromM: $0)) }
        return ObservedSnow(
            depthInches: depthInches,
            snow24hInches: snow24h,
            observedAt: at,
            stationName: "\(sourceName) model",
            stationElevationFt: elevationFt(response, location: location),
            isModeled: true
        )
    }

    static func nearestIndex(to date: Date, in response: Response) -> Int? {
        response.hourly.time.indices
            .filter { abs(response.date($0).timeIntervalSince(date)) <= 60 * 60 }
            .min { abs(response.date($0).timeIntervalSince(date)) < abs(response.date($1).timeIntervalSince(date)) }
    }

    /// Highest or lowest hourly temperature (°C) in `period`. nil unless most of the period is covered.
    static func extreme(of temperature: [Double?], _ response: Response, in period: DateInterval, highest: Bool) -> ForecastTemp? {
        let values = response.hourly.time.indices
            .filter { response.date($0) >= period.start && response.date($0) <= period.end }
            .compactMap { temperature[$0] }
        guard Double(values.count) >= period.duration / 3600 / 2,
              let value = highest ? values.max() : values.min() else { return nil }
        return ForecastTemp(tempF: Convert.fahrenheit(fromC: value), period: period)
    }

    struct ForecastAdapter: SnowForecastProvider {
        let provider: OpenMeteoProvider

        func fetch(for location: Location, now: Date) async throws -> SnowForecast {
            try OpenMeteoProvider.forecast(from: try await provider.response(for: location, now: now), location: location, now: now)
        }
    }

    struct ModeledSnowAdapter: ObservedSnowProvider {
        let provider: OpenMeteoProvider

        func fetch(for location: Location, now: Date) async throws -> ObservedSnow {
            try OpenMeteoProvider.modeledSnow(from: try await provider.response(for: location, now: now), location: location, now: now)
        }
    }
}
