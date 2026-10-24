import Foundation
import Testing
@testable import NotchlineCore

@MainActor
struct ConditionsModelTests {
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

    func makeStore() -> SnapshotStore {
        SnapshotStore(directory: FileManager.default.temporaryDirectory.appending(path: "notchline-tests-\(UUID().uuidString)"))
    }

    func makeModel(selectedID: String?, store: SnapshotStore, forecastDown: Bool = false) throws -> ConditionsModel {
        let service = ConditionsService(factory: ProviderFactory(http: StubHTTPClient(try routes(forecastDown: forecastDown))))
        return ConditionsModel(catalog: try LocationCatalog.bundled(), selectedID: selectedID, service: service, store: store)
    }

    @Test func unknownStoredIDFallsBackToBaker() throws {
        let store = makeStore()
        #expect(try makeModel(selectedID: "closed-resort", store: store).location.id == "mt-baker")
        #expect(try makeModel(selectedID: nil, store: store).location.id == "mt-baker")
    }

    @Test func cachedSnapshotIsShownImmediatelyThenReplacedByRefresh() async throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let cached = ConditionsSnapshot(
            locationID: "mt-baker",
            observed: ObservedSnow(depthInches: 61, snow24hInches: 8, observedAt: now.addingTimeInterval(-86400), stationName: "Wells Creek", stationElevationFt: 4040),
            fetchedAt: now.addingTimeInterval(-86400))
        try store.save(cached)

        let model = try makeModel(selectedID: "mt-baker", store: store)
        #expect(model.snapshot == cached)
        #expect(model.isShowingCached)

        let result = try #require(await model.refresh(now: now))
        #expect(model.snapshot == result.snapshot)
        #expect(model.snapshot?.observed?.depthInches == 0)
        #expect(!model.isShowingCached)
        #expect(!model.isRefreshing)
        #expect(store.load(locationID: "mt-baker") == result.snapshot)
    }

    @Test func switchingLocationsShowsEachLocationsCache() async throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let crystal = ConditionsSnapshot(locationID: "crystal", fetchedAt: now)
        try store.save(crystal)

        let model = try makeModel(selectedID: "mt-baker", store: store)
        #expect(model.snapshot == nil)
        await model.refresh(now: now)
        let baker = model.snapshot

        model.select("crystal")
        #expect(model.location.id == "crystal")
        #expect(model.snapshot == crystal)
        #expect(model.isShowingCached)

        model.select("mt-baker")
        #expect(model.snapshot == baker)
        #expect(!model.isShowingCached)
    }

    @Test func selectingUnknownLocationIsIgnored() throws {
        let model = try makeModel(selectedID: "crystal", store: makeStore())
        model.select("closed-resort")
        #expect(model.location.id == "crystal")
    }

    @Test func outageKeepsPreviousValuesMarkedStale() async throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let model = try makeModel(selectedID: "mt-baker", store: store)
        await model.refresh(now: now)

        let later = now.addingTimeInterval(1800)
        let offline = ConditionsModel(
            catalog: try LocationCatalog.bundled(),
            selectedID: "mt-baker",
            service: ConditionsService(factory: ProviderFactory(http: StubHTTPClient([]))),
            store: store)
        let result = try #require(await offline.refresh(now: later))
        #expect(result.failedMetrics == Set(Metric.allCases))
        #expect(offline.snapshot?.forecast != nil && offline.snapshot?.danger != nil && offline.snapshot?.observed != nil)
        #expect(offline.snapshot?.staleMetrics == Set(Metric.allCases))
        #expect(offline.snapshot?.updatedAt[.forecast] == now)
        #expect(offline.errors.count == 3)
    }

    @Test func resultForPreviousLocationDoesNotReplaceSelection() async throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let model = try makeModel(selectedID: "mt-baker", store: store)
        let refresh = Task { await model.refresh(now: now) }
        while !model.isRefreshing { await Task.yield() }
        model.select("whistler")
        #expect(!model.isRefreshing)
        #expect(await refresh.value?.snapshot.locationID == "mt-baker")
        #expect(model.location.id == "whistler")
        #expect(model.snapshot == nil)
        #expect(store.load(locationID: "mt-baker") != nil)
    }
}

struct RefreshScheduleTests {
    @Test func backsOffExponentiallyCappedAtInterval() {
        let schedule = RefreshSchedule(interval: 1800, initialRetry: 60)
        #expect(schedule.delay(afterConsecutiveFailures: 0) == 1800)
        #expect(schedule.delay(afterConsecutiveFailures: 1) == 60)
        #expect(schedule.delay(afterConsecutiveFailures: 2) == 120)
        #expect(schedule.delay(afterConsecutiveFailures: 5) == 960)
        #expect(schedule.delay(afterConsecutiveFailures: 6) == 1800)
        #expect(schedule.delay(afterConsecutiveFailures: 500) == 1800)
    }
}

struct SnapshotFreshnessTests {
    let now = date("2026-10-24T20:30:00Z")

    @Test func observedAgeComesFromTheStationReading() {
        let snapshot = ConditionsSnapshot(
            locationID: "mt-baker",
            observed: ObservedSnow(depthInches: 61, snow24hInches: nil, observedAt: now.addingTimeInterval(-4 * 3600), stationName: "Wells Creek", stationElevationFt: 4040),
            forecast: SnowForecast(next24hInches: 2, issuedAt: nil, gridElevationFt: nil, sourceName: "NWS"),
            updatedAt: [.observed: now, .forecast: now.addingTimeInterval(-3600)],
            fetchedAt: now)
        #expect(snapshot.isOutdated(.observed, now: now))
        #expect(!snapshot.isOutdated(.forecast, now: now))
        #expect(!snapshot.isOutdated(.avalanche, now: now))
        #expect(snapshot.lastUpdated == now)
    }

    @Test func notConfiguredSourcesAreNotRetryable() async throws {
        let service = ConditionsService(factory: ProviderFactory(http: StubHTTPClient([])))
        let result = await service.refresh(try catalogLocation("whistler"), now: now)
        #expect(result.failedMetrics.isEmpty)
        #expect(result.errors.count == 3)
    }
}

struct ConditionsFormatTests {
    let now = date("2026-10-24T20:30:00Z")

    @Test func inches() {
        #expect(ConditionsFormat.inches(61) == "61\"")
        #expect(ConditionsFormat.inches(0) == "0\"")
        #expect(ConditionsFormat.inches(0.4) == "0.4\"")
        #expect(ConditionsFormat.inches(7.6) == "8\"")
        #expect(ConditionsFormat.newSnow(8) == "+8\"")
    }

    @Test func age() {
        #expect(ConditionsFormat.age(since: now.addingTimeInterval(-20), now: now) == "just now")
        #expect(ConditionsFormat.age(since: now.addingTimeInterval(-12 * 60), now: now) == "12 min ago")
        #expect(ConditionsFormat.age(since: now.addingTimeInterval(-3 * 3600), now: now) == "3 h ago")
        #expect(ConditionsFormat.age(since: now.addingTimeInterval(-3 * 86400), now: now) == "3 d ago")
    }
}
