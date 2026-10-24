import Foundation
import Testing
@testable import NotchlineCore

struct ConditionsServiceTests {
    let now = date("2026-10-24T20:30:00Z")

    func routes(forecastDown: Bool = false) throws -> [(String, Result<Data, ProviderError>)] {
        [
            ("awdbRestApi", .success(try Fixture.data("snotel_909_offseason_2026-10-24"))),
            ("/points/", .success(try Fixture.data("nws_points_baker"))),
            ("/gridpoints/", forecastDown
                ? .failure(.http(status: 503, url: URL(string: "https://api.weather.gov")!))
                : .success(try Fixture.data("nws_gridpoint_sew_157_123_offseason"))),
            ("map-layer/NWAC", .success(try Fixture.data("avalanche_map_layer_nwac_offseason"))),
            ("product?", .success(try Fixture.data("avalanche_product_wsn_offseason"))),
        ]
    }

    @Test func fetchesAllMetricsForBaker() async throws {
        let service = ConditionsService(factory: ProviderFactory(http: StubHTTPClient(try routes())))
        let result = await service.refresh(try catalogLocation("mt-baker"), now: now)
        #expect(result.errors.isEmpty)
        #expect(result.snapshot.observed?.depthInches == 0)
        #expect(result.snapshot.forecast?.next24hInches == 0)
        #expect(result.snapshot.danger?.overall == .noRating)
        #expect(result.snapshot.staleMetrics.isEmpty)
        #expect(result.snapshot.fetchedAt == now)
    }

    @Test func failedMetricKeepsPreviousValueAndIsMarkedStale() async throws {
        let previousForecast = SnowForecast(next24hInches: 8, issuedAt: nil, gridElevationFt: 4265, sourceName: "NWS")
        let previous = ConditionsSnapshot(locationID: "mt-baker", forecast: previousForecast, fetchedAt: now.addingTimeInterval(-1800))
        let service = ConditionsService(factory: ProviderFactory(http: StubHTTPClient(try routes(forecastDown: true))))
        let result = await service.refresh(try catalogLocation("mt-baker"), previous: previous, now: now)
        #expect(result.snapshot.forecast == previousForecast)
        #expect(result.snapshot.staleMetrics == [.forecast])
        #expect(result.errors.keys.sorted { $0.rawValue < $1.rawValue } == [.forecast])
        #expect(result.snapshot.observed != nil)
        #expect(result.snapshot.danger != nil)
    }

    @Test func failedMetricWithoutPreviousIsNil() async throws {
        let service = ConditionsService(factory: ProviderFactory(http: StubHTTPClient(try routes(forecastDown: true))))
        let result = await service.refresh(try catalogLocation("mt-baker"), now: now)
        #expect(result.snapshot.forecast == nil)
        #expect(result.snapshot.staleMetrics.isEmpty)
        #expect(result.errors[.forecast] != nil)
    }

    @Test func previousSnapshotForAnotherLocationIsIgnored() async throws {
        let previous = ConditionsSnapshot(
            locationID: "crystal",
            forecast: SnowForecast(next24hInches: 8, issuedAt: nil, gridElevationFt: nil, sourceName: "NWS"),
            fetchedAt: now)
        let service = ConditionsService(factory: ProviderFactory(http: StubHTTPClient(try routes(forecastDown: true))))
        let result = await service.refresh(try catalogLocation("mt-baker"), previous: previous, now: now)
        #expect(result.snapshot.forecast == nil)
    }

    @Test func fetchesAllMetricsForWhistler() async throws {
        let http = StubHTTPClient([
            ("SD.csv", .success(try Fixture.data("bc_asws_sd_2026-10-24", ext: "csv"))),
            ("TA.csv", .success(try Fixture.data("bc_asws_ta_2026-10-24", ext: "csv"))),
            ("open-meteo", .success(try Fixture.data("open_meteo_whistler_2026-10-24"))),
            ("avalanche.ca", .success(try Fixture.data("avalanche_canada_point_whistler_offseason"))),
        ])
        let now = date("2026-10-24T22:30:00Z")
        let result = await ConditionsService(factory: ProviderFactory(http: http)).refresh(try catalogLocation("whistler"), now: now)
        #expect(result.errors.isEmpty)
        #expect(result.snapshot.observed?.stationName == "Callaghan Creek")
        #expect(result.snapshot.forecast?.sourceName == "Open-Meteo")
        #expect(result.snapshot.danger?.zoneName == "Avalanche Canada")
    }

    @Test func modeledLocationsShareOneOpenMeteoRequest() async throws {
        let counter = RequestCounter(StubHTTPClient([
            ("open-meteo", .success(try Fixture.data("open_meteo_whistler_2026-10-24"))),
            ("avalanche.ca", .success(try Fixture.data("avalanche_canada_point_whistler_offseason"))),
        ]))
        let now = date("2026-10-24T22:30:00Z")
        let result = await ConditionsService(factory: ProviderFactory(http: counter)).refresh(try catalogLocation("revelstoke"), now: now)
        #expect(result.errors.isEmpty)
        #expect(result.snapshot.observed?.isModeled == true)
        #expect(result.snapshot.observed?.stationName == "Open-Meteo model")
        #expect(await counter.count(matching: "open-meteo") == 1)
    }

    @Test func usForecastFallsBackToOpenMeteo() async throws {
        var routes = try routes(forecastDown: true)
        routes.append(("open-meteo", .success(try Fixture.data("open_meteo_whistler_2026-10-24"))))
        let result = await ConditionsService(factory: ProviderFactory(http: StubHTTPClient(routes)))
            .refresh(try catalogLocation("mt-baker"), now: date("2026-10-24T22:30:00Z"))
        #expect(result.errors[.forecast] == nil)
        #expect(result.snapshot.forecast?.sourceName == "Open-Meteo")
    }

    @Test func snapshotStoreRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "notchline-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(directory: directory)
        let snapshot = ConditionsSnapshot(
            locationID: "mt-baker",
            observed: ObservedSnow(depthInches: 61, snow24hInches: 8, observedAt: now, stationName: "Wells Creek", stationElevationFt: 4040),
            danger: DangerSummary(zoneName: "West Slopes North", overall: .considerable, upper: .considerable, middle: .considerable, lower: .moderate),
            staleMetrics: [.forecast],
            fetchedAt: now)
        #expect(store.load(locationID: "mt-baker") == nil)
        try store.save(snapshot)
        #expect(store.load(locationID: "mt-baker") == snapshot)
    }
}
