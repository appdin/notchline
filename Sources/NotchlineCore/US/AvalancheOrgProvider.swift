import Foundation

/// Avalanche danger from the avalanche.org public API, which covers US avalanche centers including NWAC.
public struct AvalancheOrgProvider: AvalancheProvider {
    static let baseURL = URL(string: "https://api.avalanche.org/v2/public/")!

    private let http: HTTPClient
    private let zones = LookupCache<Zone>()

    public init(http: HTTPClient) {
        self.http = http
    }

    public func fetch(for location: Location, now: Date) async throws -> DangerSummary {
        guard let center = location.avalancheCenter else {
            throw ProviderError.notConfigured("avalanche center for \(location.id)")
        }
        let http = self.http
        // The map layer carries the current zone rating as well as the polygons, so it is fetched
        // on every refresh. Only the zone match is memoized.
        let mapLayer = try Self.parseMapLayer(try await http.get(Self.mapLayerURL(center: center)))
        let zone = try await zones.value(for: location.id, now: now) {
            try Self.zone(containing: location, in: mapLayer)
        }
        guard let feature = mapLayer.features.first(where: { $0.id == zone.id }) else {
            throw ProviderError.noData("zone \(zone.id) in \(center) map layer")
        }
        var summary = Self.summary(from: feature)
        // Elevation bands are a refinement. Without them the zone rating still stands.
        do {
            try Self.applyBands(from: try await http.get(Self.productURL(center: center, zoneID: zone.id)), to: &summary, now: now)
        } catch {
            ProviderWarnings.record("Elevation bands unavailable: \(error)")
        }
        return summary
    }

    struct Zone: Sendable, Equatable {
        let id: Int
        let name: String
    }

    static func mapLayerURL(center: String) -> URL {
        baseURL.appending(path: "products/map-layer/\(center)")
    }

    static func productURL(center: String, zoneID: Int) -> URL {
        var components = URLComponents(url: baseURL.appending(path: "product"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "type", value: "forecast"),
            URLQueryItem(name: "center_id", value: center),
            URLQueryItem(name: "zone_id", value: String(zoneID)),
        ]
        return components.url!
    }

    static func parseMapLayer(_ data: Data) throws -> MapLayer {
        try JSONDecoder().decode(MapLayer.self, from: data)
    }

    static func zone(containing location: Location, in mapLayer: MapLayer) throws -> Zone {
        guard let feature = mapLayer.features.first(where: {
            $0.geometry.contains(latitude: location.latitude, longitude: location.longitude)
        }) else {
            throw ProviderError.noData("avalanche zone containing \(location.id)")
        }
        return Zone(id: feature.id, name: feature.properties.name)
    }

    static func summary(from feature: MapLayer.Feature) -> DangerSummary {
        let p = feature.properties
        return DangerSummary(
            zoneName: p.name,
            overall: DangerLevel(apiValue: p.danger_level),
            issuedAt: p.start_date.flatMap(parseZoneDate),
            validUntil: p.end_date.flatMap(parseZoneDate),
            forecastURL: p.link.flatMap(URL.init(string:))
        )
    }

    /// Fills elevation bands from the forecast product's "current" day. Off-season the product is a
    /// "summary" with no danger array, which leaves the summary unchanged.
    static func applyBands(from data: Data, to summary: inout DangerSummary, now: Date) throws {
        let product = try JSONDecoder().decode(Product.self, from: data)
        guard product.product_type == "forecast",
              let current = product.danger?.first(where: { $0.valid_day == "current" }) else { return }
        summary.upper = DangerLevel(apiValue: current.upper)
        summary.middle = DangerLevel(apiValue: current.middle)
        summary.lower = DangerLevel(apiValue: current.lower)
        summary.overall = max(summary.overall, summary.upper!, summary.middle!, summary.lower!)
        summary.issuedAt = product.published_time.flatMap(NWSForecastProvider.parseISODate) ?? summary.issuedAt
        summary.validUntil = product.expires_time.flatMap(NWSForecastProvider.parseISODate) ?? summary.validUntil
    }

    /// Map layer dates have no offset ("2026-11-21T02:30:00") and are UTC, matching the product's
    /// published and expires times.
    static func parseZoneDate(_ string: String) -> Date? {
        NWSForecastProvider.parseISODate(string) ?? NWSForecastProvider.parseISODate(string + "Z")
    }

    struct MapLayer: Decodable, Sendable {
        struct Feature: Decodable, Sendable {
            let id: Int
            let properties: Properties
            let geometry: ZoneGeometry
        }
        // Field names match the API.
        struct Properties: Decodable, Sendable {
            let name: String
            let danger_level: Int?
            let link: String?
            let start_date: String?
            let end_date: String?
        }
        let features: [Feature]
    }

    struct Product: Decodable {
        struct Danger: Decodable {
            let lower: Int?
            let middle: Int?
            let upper: Int?
            let valid_day: String
        }
        let product_type: String?
        let published_time: String?
        let expires_time: String?
        let danger: [Danger]?
    }
}
