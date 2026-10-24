import Foundation

/// A place Notchline can show conditions for. Locations are data loaded from `locations.json`.
public struct Location: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    /// Used in the compact notch view and the menu bar title.
    public let shortName: String
    public let country: Country
    public let region: String
    public let kind: Kind
    /// Point used for the forecast and avalanche zone lookup.
    public let latitude: Double
    public let longitude: Double
    /// Elevation the snowfall forecast should represent.
    public let forecastElevationFt: Int
    /// avalanche.org center ID (for example "NWAC"), or nil where avalanche.org does not apply.
    public let avalancheCenter: String?
    /// nil until a source is configured for this location.
    public let observedSnow: ObservedSnowSource?
    public let links: [NamedLink]
}

public enum Country: String, Codable, Sendable {
    case us, ca
}

public enum Kind: String, Codable, Sendable {
    case skiArea, pass, peak, trailhead
}

public enum ObservedSnowSource: Codable, Hashable, Sendable {
    /// USDA NRCS SNOTEL stations, tried in order. Later stations are fallbacks when earlier ones have no recent data.
    case snotel(stations: [SnotelStation])
    /// No usable station; use modeled snow depth, labeled as modeled.
    case modeledOnly
}

public struct SnotelStation: Codable, Hashable, Sendable {
    /// AWDB station triplet, for example "909:WA:SNTL".
    public let triplet: String
    public let name: String
    public let elevationFt: Int
    /// SNOTEL reports in local standard time all year. -8 for the Pacific Northwest.
    public let utcOffsetHours: Int

    public init(triplet: String, name: String, elevationFt: Int, utcOffsetHours: Int) {
        self.triplet = triplet
        self.name = name
        self.elevationFt = elevationFt
        self.utcOffsetHours = utcOffsetHours
    }
}

public struct NamedLink: Codable, Hashable, Sendable {
    public let title: String
    public let url: URL
}
