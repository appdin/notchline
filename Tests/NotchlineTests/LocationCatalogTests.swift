import Foundation
import Testing
@testable import NotchlineCore

struct LocationCatalogTests {
    @Test func bundledCatalogHasLaunchLocations() throws {
        let catalog = try LocationCatalog.bundled()
        #expect(catalog.locations.map(\.id) == [
            "mt-baker", "stevens-pass", "snoqualmie", "crystal", "whistler", "revelstoke", "sun-peaks",
        ])
        #expect(Set(catalog.locations.map(\.id)).count == catalog.locations.count)
    }

    @Test func washingtonLocationsHaveSnotelStations() throws {
        let catalog = try LocationCatalog.bundled()
        for location in catalog.locations where location.region == "WA" {
            guard case .snotel(let stations)? = location.observedSnow else {
                Issue.record("\(location.id) has no SNOTEL stations")
                continue
            }
            #expect(!stations.isEmpty)
            #expect(location.avalancheCenter == "NWAC")
        }
    }

    @Test func unknownStoredIDFallsBackToBaker() throws {
        let catalog = try LocationCatalog.bundled()
        #expect(catalog.resolve(id: "gone-ski-area").id == "mt-baker")
        #expect(catalog.resolve(id: nil).id == "mt-baker")
        #expect(catalog.resolve(id: "crystal").id == "crystal")
    }

    @Test func groupsByRegionInCatalogOrder() throws {
        let groups = try LocationCatalog.bundled().byRegion
        #expect(groups.map(\.region) == ["WA", "BC"])
        #expect(groups[0].locations.count == 4)
        #expect(groups[1].locations.count == 3)
    }
}
