import Foundation

public struct LocationCatalog: Sendable {
    public static let defaultLocationID = "mt-baker"

    public let locations: [Location]

    public init(locations: [Location]) {
        self.locations = locations
    }

    /// Loads the bundled `locations.json`. Inside Notchline.app the file lives in Contents/Resources;
    /// from `swift run` and tests it comes from the SwiftPM resource bundle.
    public static func bundled() throws -> LocationCatalog {
        let url = Bundle.main.url(forResource: "locations", withExtension: "json")
            ?? Bundle.module.url(forResource: "locations", withExtension: "json")
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        return try load(from: Data(contentsOf: url))
    }

    public static func load(from data: Data) throws -> LocationCatalog {
        LocationCatalog(locations: try JSONDecoder().decode([Location].self, from: data))
    }

    public func location(id: String) -> Location? {
        locations.first { $0.id == id }
    }

    /// The location for a stored ID, falling back to the default when the ID is unknown.
    public func resolve(id: String?) -> Location {
        if let id, let location = location(id: id) { return location }
        return location(id: Self.defaultLocationID) ?? locations[0]
    }

    /// Locations grouped by region, in catalog order.
    public var byRegion: [(region: String, locations: [Location])] {
        var order: [String] = []
        var groups: [String: [Location]] = [:]
        for location in locations {
            if groups[location.region] == nil { order.append(location.region) }
            groups[location.region, default: []].append(location)
        }
        return order.map { ($0, groups[$0]!) }
    }
}
