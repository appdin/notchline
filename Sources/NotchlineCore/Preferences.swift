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
