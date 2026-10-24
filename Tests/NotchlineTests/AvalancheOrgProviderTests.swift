import Foundation
import Testing
@testable import NotchlineCore

struct AvalancheOrgProviderTests {
    @Test(arguments: [
        ("mt-baker", "West Slopes North"),
        ("stevens-pass", "Stevens Pass"),
        ("snoqualmie", "Snoqualmie Pass"),
        ("crystal", "West Slopes South"),
    ])
    func washingtonLocationsResolveToZones(id: String, zone: String) throws {
        let mapLayer = try AvalancheOrgProvider.parseMapLayer(Fixture.data("avalanche_map_layer_nwac_offseason"))
        let location = try catalogLocation(id)
        #expect(try AvalancheOrgProvider.zone(containing: location, in: mapLayer).name == zone)
        let matches = mapLayer.features.filter { $0.geometry.contains(latitude: location.latitude, longitude: location.longitude) }
        #expect(matches.count == 1)
    }

    @Test func offSeasonIsNoRatingWithoutBands() async throws {
        let http = StubHTTPClient([
            ("map-layer/NWAC", .success(try Fixture.data("avalanche_map_layer_nwac_offseason"))),
            ("product?", .success(try Fixture.data("avalanche_product_wsn_offseason"))),
        ])
        let summary = try await AvalancheOrgProvider(http: http).fetch(for: catalogLocation("mt-baker"), now: date("2026-10-24T20:00:00Z"))
        #expect(summary.zoneName == "West Slopes North")
        #expect(summary.overall == .noRating)
        #expect(summary.upper == nil)
        #expect(summary.forecastURL?.absoluteString == "https://nwac.us/forecasts/avalanche/west-slopes-north")
        #expect(summary.validUntil == date("2026-11-21T02:30:00Z"))
    }

    @Test func inSeasonProductFillsBands() throws {
        var summary = DangerSummary(zoneName: "West Slopes Central", overall: .low)
        try AvalancheOrgProvider.applyBands(
            from: Fixture.data("avalanche_product_wsc_2026-02-10"), to: &summary, now: date("2026-02-10T12:00:00Z"))
        #expect(summary.upper == .moderate)
        #expect(summary.middle == .low)
        #expect(summary.lower == .low)
        #expect(summary.overall == .moderate)
        #expect(summary.validUntil == date("2026-02-11T02:00:00Z"))
    }

    @Test func expiredProductHasNoRatingUnderTheSharedRule() throws {
        var summary = DangerSummary(zoneName: "West Slopes Central", overall: .low)
        let now = date("2026-02-12T12:00:00Z")
        try AvalancheOrgProvider.applyBands(from: Fixture.data("avalanche_product_wsc_2026-02-10"), to: &summary, now: now)
        #expect(summary.validUntil == date("2026-02-11T02:00:00Z"))
        #expect(summary.current(at: now).overall == .noRating)
        #expect(summary.current(at: now).upper == nil)
    }

    @Test func inSeasonMapLayerRatingWithoutProduct() async throws {
        // Live map layer with West Slopes North edited to Considerable, and the product endpoint down.
        let mapLayer = try Fixture.edited("avalanche_map_layer_nwac_offseason") { json in
            var root = json as! [String: Any]
            var features = root["features"] as! [[String: Any]]
            for i in features.indices where features[i]["id"] as? Int == 3021 {
                var properties = features[i]["properties"] as! [String: Any]
                properties["danger_level"] = 3
                properties["danger"] = "considerable"
                features[i]["properties"] = properties
            }
            root["features"] = features
            json = root
        }
        let http = StubHTTPClient([("map-layer/NWAC", .success(mapLayer))])
        let summary = try await AvalancheOrgProvider(http: http).fetch(for: catalogLocation("mt-baker"), now: date("2026-12-15T20:00:00Z"))
        #expect(summary.overall == .considerable)
        #expect(summary.upper == nil)
    }

    @Test func dangerLevelMapsAPIValues() {
        #expect(DangerLevel(apiValue: -1) == .noRating)
        #expect(DangerLevel(apiValue: 0) == .noRating)
        #expect(DangerLevel(apiValue: nil) == .noRating)
        #expect(DangerLevel(apiValue: 4) == .high)
        #expect(DangerLevel(apiValue: 9) == .noRating)
    }

    @Test func pointOnSharedBorderBelongsToOneZone() {
        // Two unit squares sharing the edge x = 1.
        let west = ZoneGeometry(polygons: [[[[0, 0], [1, 0], [1, 1], [0, 1], [0, 0]]]])
        let east = ZoneGeometry(polygons: [[[[1, 0], [2, 0], [2, 1], [1, 1], [1, 0]]]])
        for y in [0.25, 0.5, 0.75] {
            let hits = [west, east].filter { $0.contains(latitude: y, longitude: 1) }.count
            #expect(hits == 1)
        }
    }

    @Test func multiPolygonWithHole() throws {
        let json = """
        {"type":"MultiPolygon","coordinates":[
          [[[0,0],[4,0],[4,4],[0,4],[0,0]],[[1,1],[3,1],[3,3],[1,3],[1,1]]],
          [[[10,10],[11,10],[11,11],[10,11],[10,10]]]
        ]}
        """
        let geometry = try JSONDecoder().decode(ZoneGeometry.self, from: Data(json.utf8))
        #expect(geometry.contains(latitude: 0.5, longitude: 0.5))
        #expect(!geometry.contains(latitude: 2, longitude: 2))  // in the hole
        #expect(geometry.contains(latitude: 10.5, longitude: 10.5))
        #expect(!geometry.contains(latitude: 5, longitude: 5))
    }
}
