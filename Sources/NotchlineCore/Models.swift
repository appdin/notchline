import Foundation

/// Everything shown for one location. Each metric is optional so one failing source never blanks the display.
public struct ConditionsSnapshot: Codable, Equatable, Sendable {
    public let locationID: String
    public var observed: ObservedSnow?
    public var forecast: SnowForecast?
    public var danger: DangerSummary?
    /// Metrics whose most recent fetch failed. Their values, if any, are carried over from an earlier snapshot.
    public var staleMetrics: Set<Metric>
    /// When each metric's value was last fetched successfully. Older than `fetchedAt` for stale metrics.
    public var updatedAt: [Metric: Date]
    public var fetchedAt: Date

    public init(
        locationID: String,
        observed: ObservedSnow? = nil,
        forecast: SnowForecast? = nil,
        danger: DangerSummary? = nil,
        staleMetrics: Set<Metric> = [],
        updatedAt: [Metric: Date] = [:],
        fetchedAt: Date
    ) {
        self.locationID = locationID
        self.observed = observed
        self.forecast = forecast
        self.danger = danger
        self.staleMetrics = staleMetrics
        self.updatedAt = updatedAt
        self.fetchedAt = fetchedAt
    }

    /// Values older than this are shown dimmed with their age.
    public static let outdatedAfter: TimeInterval = 3 * 60 * 60

    /// When a metric's value describes: the station reading time for observed snow, otherwise when it was last fetched.
    public func valueDate(for metric: Metric) -> Date? {
        switch metric {
        case .observed: observed?.observedAt
        case .forecast: forecast == nil ? nil : updatedAt[.forecast] ?? fetchedAt
        case .avalanche: danger == nil ? nil : updatedAt[.avalanche] ?? fetchedAt
        }
    }

    public func isOutdated(_ metric: Metric, now: Date) -> Bool {
        guard let date = valueDate(for: metric) else { return false }
        return now.timeIntervalSince(date) > Self.outdatedAfter
    }

    /// Station temperatures older than this give way to the forecast hour.
    public static let stationTempMaxAge: TimeInterval = 2 * 60 * 60

    public func currentTemp(now: Date) -> CurrentTemp? {
        if let observed, let tempF = observed.airTempF, let at = observed.airTempObservedAt,
           now.timeIntervalSince(at) <= Self.stationTempMaxAge {
            return CurrentTemp(tempF: tempF, isForecast: false)
        }
        return forecast?.tempNowF.map { CurrentTemp(tempF: $0, isForecast: true) }
    }

    /// Most recent successful fetch of any metric.
    public var lastUpdated: Date? {
        updatedAt.values.max()
    }
}

public enum Metric: String, Codable, CodingKeyRepresentable, Hashable, Sendable, CaseIterable {
    case observed, forecast, avalanche
}

public struct ObservedSnow: Codable, Equatable, Sendable {
    public var depthInches: Double
    /// Depth change over the last 24 hours, floored at zero. nil when there is no reading near 24 hours ago.
    public var snow24hInches: Double?
    public var observedAt: Date
    public var stationName: String
    public var stationElevationFt: Int
    public var isModeled: Bool
    /// Air temperature at the same station, with its own reading time. nil where the station has no sensor.
    public var airTempF: Double?
    public var airTempObservedAt: Date?

    public init(depthInches: Double, snow24hInches: Double?, observedAt: Date, stationName: String, stationElevationFt: Int, isModeled: Bool = false, airTempF: Double? = nil, airTempObservedAt: Date? = nil) {
        self.depthInches = depthInches
        self.snow24hInches = snow24hInches
        self.observedAt = observedAt
        self.stationName = stationName
        self.stationElevationFt = stationElevationFt
        self.isModeled = isModeled
        self.airTempF = airTempF
        self.airTempObservedAt = airTempObservedAt
    }
}

public struct SnowForecast: Codable, Equatable, Sendable {
    public var next24hInches: Double
    public var issuedAt: Date?
    public var gridElevationFt: Int?
    public var sourceName: String
    /// Forecast temperature for the hour the forecast was fetched. Used when there is no current station reading.
    public var tempNowF: Double?
    /// The daytime high that had not ended when fetched: today's, or tomorrow's in the evening.
    public var high: ForecastTemp?
    /// The overnight low that had not ended when fetched.
    public var low: ForecastTemp?
    public var windNow: Wind?
    /// Peak sustained speed and peak gust over the next 24 hours, each taken independently.
    public var windPeak24h: Wind?

    public init(next24hInches: Double, issuedAt: Date?, gridElevationFt: Int?, sourceName: String, tempNowF: Double? = nil, high: ForecastTemp? = nil, low: ForecastTemp? = nil, windNow: Wind? = nil, windPeak24h: Wind? = nil) {
        self.next24hInches = next24hInches
        self.issuedAt = issuedAt
        self.gridElevationFt = gridElevationFt
        self.sourceName = sourceName
        self.tempNowF = tempNowF
        self.high = high
        self.low = low
        self.windNow = windNow
        self.windPeak24h = windPeak24h
    }
}

/// A forecast high or low and the period it covers.
public struct ForecastTemp: Codable, Equatable, Sendable {
    public var tempF: Double
    public var period: DateInterval

    public init(tempF: Double, period: DateInterval) {
        self.tempF = tempF
        self.period = period
    }
}

public struct Wind: Codable, Equatable, Sendable {
    public var sustainedMph: Double
    public var gustMph: Double?
    /// Direction the wind blows from, in degrees clockwise from north.
    public var directionDegrees: Double?

    public init(sustainedMph: Double, gustMph: Double? = nil, directionDegrees: Double? = nil) {
        self.sustainedMph = sustainedMph
        self.gustMph = gustMph
        self.directionDegrees = directionDegrees
    }
}

/// Current temperature for display: a station reading when one is recent, otherwise the forecast hour.
public struct CurrentTemp: Equatable, Sendable {
    public var tempF: Double
    public var isForecast: Bool
}

public struct DangerSummary: Codable, Equatable, Sendable {
    public var zoneName: String
    /// Highest of the elevation bands, or the zone rating when bands are unavailable.
    public var overall: DangerLevel
    /// Alpine / above treeline.
    public var upper: DangerLevel?
    /// Treeline.
    public var middle: DangerLevel?
    /// Below treeline.
    public var lower: DangerLevel?
    public var issuedAt: Date?
    public var validUntil: Date?
    public var forecastURL: URL?

    public init(zoneName: String, overall: DangerLevel, upper: DangerLevel? = nil, middle: DangerLevel? = nil, lower: DangerLevel? = nil, issuedAt: Date? = nil, validUntil: Date? = nil, forecastURL: URL? = nil) {
        self.zoneName = zoneName
        self.overall = overall
        self.upper = upper
        self.middle = middle
        self.lower = lower
        self.issuedAt = issuedAt
        self.validUntil = validUntil
        self.forecastURL = forecastURL
    }
}

extension DangerSummary {
    /// The one expiry rule for every avalanche center: once `validUntil` has passed and no newer
    /// forecast has replaced it, the rating no longer describes current conditions.
    public func isExpired(at now: Date) -> Bool {
        validUntil.map { now > $0 } ?? false
    }

    /// This summary as it applies at `now`: unchanged while valid, no rating once expired. Zone,
    /// dates and forecast link are kept so the UI can say which forecast expired.
    public func current(at now: Date) -> DangerSummary {
        guard isExpired(at: now) else { return self }
        var summary = self
        summary.overall = .noRating
        summary.upper = nil
        summary.middle = nil
        summary.lower = nil
        return summary
    }
}

extension ConditionsSnapshot {
    /// The avalanche danger with the expiry rule applied. Views read this rather than `danger`,
    /// so a cached snapshot never shows an expired rating as current.
    public func danger(at now: Date) -> DangerSummary? {
        danger?.current(at: now)
    }
}

/// North American Public Avalanche Danger Scale.
public enum DangerLevel: Int, Codable, Comparable, Sendable {
    case noRating = 0, low = 1, moderate = 2, considerable = 3, high = 4, extreme = 5

    /// Maps an API rating, where -1, 0 and out of range values mean no rating.
    public init(apiValue: Int?) {
        self = apiValue.flatMap(DangerLevel.init(rawValue:)) ?? .noRating
    }

    public var label: String {
        switch self {
        case .noRating: "No rating"
        case .low: "Low"
        case .moderate: "Moderate"
        case .considerable: "Considerable"
        case .high: "High"
        case .extreme: "Extreme"
        }
    }

    public static func < (lhs: DangerLevel, rhs: DangerLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
