import Foundation

/// Units picked in Settings. Automatic follows the selected location's country.
public enum UnitPreference: String, CaseIterable, Sendable {
    case automatic, imperial, metric

    public func resolve(for location: Location) -> UnitSystem {
        switch self {
        case .automatic: location.defaultUnits
        case .imperial: .imperial
        case .metric: .metric
        }
    }
}

/// What the menu bar item shows beside its snowflake.
public enum MenuBarTitleStyle: String, CaseIterable, Sendable {
    /// Short name, base depth and danger: `Baker 61" ⚠3`
    case conditions
    case iconOnly
}

/// New snow alert threshold. Stored as a level rather than an amount so it stays a round number
/// in either unit system: 3, 6 or 12 inches, or 10, 15 or 30 cm.
public enum SnowAlertLevel: String, CaseIterable, Sendable {
    case off, light, moderate, heavy

    public static let `default` = SnowAlertLevel.moderate

    public func thresholdInches(_ units: UnitSystem) -> Double? {
        switch (self, units) {
        case (.off, _): nil
        case (.light, .imperial): 3
        case (.moderate, .imperial): 6
        case (.heavy, .imperial): 12
        case (.light, .metric): Convert.inches(fromCM: 10)
        case (.moderate, .metric): Convert.inches(fromCM: 15)
        case (.heavy, .metric): Convert.inches(fromCM: 30)
        }
    }
}

/// Decides when new snow should expand the notch. One storm alerts once: after an alert, the same
/// location alerts again only when another threshold's worth has fallen or a day has passed.
public struct SnowAlert: Codable, Equatable, Sendable {
    public let locationID: String
    public let snow24hInches: Double
    public let at: Date

    public init(locationID: String, snow24hInches: Double, at: Date) {
        self.locationID = locationID
        self.snow24hInches = snow24hInches
        self.at = at
    }

    /// The alert to raise for a fresh snapshot, or nil. A stale observed metric never alerts,
    /// since its value was carried over from an earlier refresh.
    public static func check(_ snapshot: ConditionsSnapshot, thresholdInches: Double?, last: SnowAlert?, now: Date) -> SnowAlert? {
        guard let thresholdInches,
              !snapshot.staleMetrics.contains(.observed),
              let snow = snapshot.observed?.snow24hInches,
              snow >= thresholdInches
        else { return nil }
        if let last, last.locationID == snapshot.locationID,
           now.timeIntervalSince(last.at) < 24 * 3600,
           snow < last.snow24hInches + thresholdInches {
            return nil
        }
        return SnowAlert(locationID: snapshot.locationID, snow24hInches: snow, at: now)
    }
}

/// Where the user drives from, as entered and as geocoded on the Mac. Stored only in local
/// preferences and sent only to Apple for geocoding and routing.
public struct Home: Codable, Equatable, Sendable {
    /// The address as the user typed it.
    public var address: String
    /// The geocoder's description of what it matched, shown so the user can check it.
    public var matchedName: String?
    public var latitude: Double
    public var longitude: Double

    public init(address: String, matchedName: String? = nil, latitude: Double, longitude: Double) {
        self.address = address
        self.matchedName = matchedName
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// Ski day planner settings that differ by location.
public struct LocationPlannerSettings: Codable, Equatable, Sendable {
    /// Parking, gearing up, the walk and getting onto the first chair.
    public var arrivalToLiftMinutes: Int
    /// Whether the location allows parking overnight, which lets the planner suggest driving up the night before.
    public var overnightParkingAllowed: Bool

    public static let `default` = LocationPlannerSettings(arrivalToLiftMinutes: 20, overnightParkingAllowed: false)

    public init(arrivalToLiftMinutes: Int, overnightParkingAllowed: Bool) {
        self.arrivalToLiftMinutes = arrivalToLiftMinutes
        self.overnightParkingAllowed = overnightParkingAllowed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.default
        arrivalToLiftMinutes = try container.decodeIfPresent(Int.self, forKey: .arrivalToLiftMinutes) ?? defaults.arrivalToLiftMinutes
        overnightParkingAllowed = try container.decodeIfPresent(Bool.self, forKey: .overnightParkingAllowed) ?? defaults.overnightParkingAllowed
    }
}

/// Ski day planner settings, stored as one value so settings added later decode from older
/// preferences with their defaults.
public struct PlannerSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var home: Home?
    /// Gusts above this close lifts, in mph. Hours above it score zero.
    public var gustThresholdMph: Double
    /// When the evening-before summary notification fires.
    public var eveningSummaryTime: ClockTime
    /// How long before the recommended departure the reminder fires.
    public var departureReminderLeadMinutes: Int
    /// Days scoring at least this (0 to 100) get notifications.
    public var notificationScoreThreshold: Int
    /// Keyed by location ID. Locations without an entry use `LocationPlannerSettings.default`.
    public var locations: [String: LocationPlannerSettings]

    public static let gustThresholdOptionsMph: [Double] = [35, 40, 45, 50, 55, 60]
    public static let departureReminderLeadOptions = [15, 30, 45, 60]
    public static let notificationScoreThresholdOptions = [60, 70, 80, 90]

    public static let `default` = PlannerSettings(
        isEnabled: true,
        home: nil,
        gustThresholdMph: 45,
        eveningSummaryTime: ClockTime(hour: 19, minute: 0)!,
        departureReminderLeadMinutes: 30,
        notificationScoreThreshold: 80,
        locations: [:])

    public init(isEnabled: Bool, home: Home?, gustThresholdMph: Double, eveningSummaryTime: ClockTime, departureReminderLeadMinutes: Int, notificationScoreThreshold: Int, locations: [String: LocationPlannerSettings]) {
        self.isEnabled = isEnabled
        self.home = home
        self.gustThresholdMph = gustThresholdMph
        self.eveningSummaryTime = eveningSummaryTime
        self.departureReminderLeadMinutes = departureReminderLeadMinutes
        self.notificationScoreThreshold = notificationScoreThreshold
        self.locations = locations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.default
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        home = try container.decodeIfPresent(Home.self, forKey: .home)
        gustThresholdMph = try container.decodeIfPresent(Double.self, forKey: .gustThresholdMph) ?? defaults.gustThresholdMph
        eveningSummaryTime = try container.decodeIfPresent(ClockTime.self, forKey: .eveningSummaryTime) ?? defaults.eveningSummaryTime
        departureReminderLeadMinutes = try container.decodeIfPresent(Int.self, forKey: .departureReminderLeadMinutes) ?? defaults.departureReminderLeadMinutes
        notificationScoreThreshold = try container.decodeIfPresent(Int.self, forKey: .notificationScoreThreshold) ?? defaults.notificationScoreThreshold
        locations = try container.decodeIfPresent([String: LocationPlannerSettings].self, forKey: .locations) ?? defaults.locations
    }

    /// Stored preferences, or the defaults when there are none.
    public static func load(_ data: Data?) throws -> PlannerSettings {
        guard let data else { return .default }
        return try JSONDecoder().decode(PlannerSettings.self, from: data)
    }

    public func settings(for locationID: String) -> LocationPlannerSettings {
        locations[locationID] ?? .default
    }

    public mutating func update(_ locationID: String, _ change: (inout LocationPlannerSettings) -> Void) {
        var settings = settings(for: locationID)
        change(&settings)
        locations[locationID] = settings
    }
}
