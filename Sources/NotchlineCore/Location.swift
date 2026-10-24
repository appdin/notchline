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
    /// IANA time zone ID, for example "America/Los_Angeles". Every local-day decision (today's
    /// avalanche rating, daytime high, overnight low) uses this rather than the Mac's time zone.
    public let timeZone: String
    /// avalanche.org center ID (for example "NWAC"), or nil where avalanche.org does not apply.
    public let avalancheCenter: String?
    /// nil until a source is configured for this location.
    public let observedSnow: ObservedSnowSource?
    public let links: [NamedLink]
}

public enum Country: String, Codable, Sendable {
    case us, ca
}

public enum UnitSystem: String, Codable, Sendable {
    /// Inches, feet, °F, mph
    case imperial
    /// Centimetres, metres, °C, km/h
    case metric
}

extension Location {
    /// Gregorian calendar in the location's time zone.
    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        return calendar
    }

    /// Imperial in the US, metric in Canada. `UnitPreference` can override this.
    public var defaultUnits: UnitSystem {
        country == .us ? .imperial : .metric
    }
}

public enum Kind: String, Codable, Sendable {
    case skiArea, pass, peak, trailhead
}

public enum ObservedSnowSource: Codable, Hashable, Sendable {
    /// USDA NRCS SNOTEL stations, tried in order. Later stations are fallbacks when earlier ones have no recent data.
    case snotel(stations: [SnotelStation])
    /// BC Ministry of Environment automated snow weather stations, tried in order.
    case bcSnowStations(stations: [BCSnowStation])
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

public struct BCSnowStation: Codable, Hashable, Sendable {
    /// Location ID as used in the data file headers, for example "3A20P".
    public let id: String
    public let name: String
    public let elevationFt: Int

    public init(id: String, name: String, elevationFt: Int) {
        self.id = id
        self.name = name
        self.elevationFt = elevationFt
    }
}

public struct NamedLink: Codable, Hashable, Sendable {
    public let title: String
    public let url: URL
}
