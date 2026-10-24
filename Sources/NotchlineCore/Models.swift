import Foundation

/// Everything shown for one location. Each metric is optional so one failing source never blanks the display.
public struct ConditionsSnapshot: Codable, Equatable, Sendable {
    public let locationID: String
    public var observed: ObservedSnow?
    public var forecast: SnowForecast?
    public var danger: DangerSummary?
    /// Metrics whose most recent fetch failed. Their values, if any, are carried over from an earlier snapshot.
    public var staleMetrics: Set<Metric>
    public var fetchedAt: Date

    public init(
        locationID: String,
        observed: ObservedSnow? = nil,
        forecast: SnowForecast? = nil,
        danger: DangerSummary? = nil,
        staleMetrics: Set<Metric> = [],
        fetchedAt: Date
    ) {
        self.locationID = locationID
        self.observed = observed
        self.forecast = forecast
        self.danger = danger
        self.staleMetrics = staleMetrics
        self.fetchedAt = fetchedAt
    }
}

public enum Metric: String, Codable, Hashable, Sendable, CaseIterable {
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

    public init(depthInches: Double, snow24hInches: Double?, observedAt: Date, stationName: String, stationElevationFt: Int, isModeled: Bool = false) {
        self.depthInches = depthInches
        self.snow24hInches = snow24hInches
        self.observedAt = observedAt
        self.stationName = stationName
        self.stationElevationFt = stationElevationFt
        self.isModeled = isModeled
    }
}

public struct SnowForecast: Codable, Equatable, Sendable {
    public var next24hInches: Double
    public var issuedAt: Date?
    public var gridElevationFt: Int?
    public var sourceName: String

    public init(next24hInches: Double, issuedAt: Date?, gridElevationFt: Int?, sourceName: String) {
        self.next24hInches = next24hInches
        self.issuedAt = issuedAt
        self.gridElevationFt = gridElevationFt
        self.sourceName = sourceName
    }
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
