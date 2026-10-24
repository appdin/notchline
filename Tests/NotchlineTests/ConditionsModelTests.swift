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
        let json = """
        {"id":"test","name":"Test","shortName":"Test","country":"us","region":"WA","kind":"peak",
         "latitude":48.8,"longitude":-121.7,"forecastElevationFt":4000,"timeZone":"America/Los_Angeles","avalancheCenter":null,"observedSnow":null,"links":[]}
        """
        let location = try JSONDecoder().decode(Location.self, from: Data(json.utf8))
        let service = ConditionsService(factory: ProviderFactory(http: StubHTTPClient([])))
        let result = await service.refresh(location, now: now)
        #expect(result.errors.count == 3)
        #expect(result.failedMetrics == [.forecast])
    }
}

struct ConditionsFormatTests {
    let now = date("2026-10-24T20:30:00Z")

    @Test func temperatureAndWind() {
        #expect(ConditionsFormat.degrees(27.6) == "28°")
        #expect(ConditionsFormat.degrees(-0.3) == "0°")
        #expect(ConditionsFormat.degrees(-4.4) == "-4°")
        #expect(ConditionsFormat.wind(Wind(sustainedMph: 14.6, gustMph: 30.2)) == "15 G30")
        #expect(ConditionsFormat.wind(Wind(sustainedMph: 5, gustMph: nil)) == "5")
        #expect(ConditionsFormat.wind(Wind(sustainedMph: 5, gustMph: 5.2)) == "5")
        #expect(ConditionsFormat.compass(225) == "SW")
        #expect(ConditionsFormat.compass(359) == "N")
        #expect(ConditionsFormat.compass(20) == "NNE")
    }

    @Test func metricUnits() {
        #expect(ConditionsFormat.snow(61, .metric) == "155 cm")
        #expect(ConditionsFormat.snow(0.2, .metric) == "0.5 cm")
        #expect(ConditionsFormat.newSnow(8, .metric) == "+20 cm")
        #expect(ConditionsFormat.newSnow(8) == "+8\"")
        #expect(ConditionsFormat.elevation(3337, .metric) == "1,017 m")
        #expect(ConditionsFormat.elevation(4040) == "4,040'")
        #expect(ConditionsFormat.degrees(28, .metric) == "-2°")
        #expect(ConditionsFormat.degrees(32.5, .metric) == "0°")
        #expect(ConditionsFormat.wind(Wind(sustainedMph: 15, gustMph: 30), .metric) == "24 G48")
        #expect(ConditionsFormat.windUnit(.metric) == "km/h")
        #expect(ConditionsFormat.temperatureScale(.metric) == "C")
    }

    @Test func unitsDefaultByCountry() throws {
        #expect(try catalogLocation("mt-baker").defaultUnits == .imperial)
        #expect(try catalogLocation("whistler").defaultUnits == .metric)
    }

    @Test func highIsTomorrowOnlyForALaterDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // 15:00Z is 08:00 PDT. now is 13:30 PDT on 10-24.
        let today = ForecastTemp(tempF: 40, period: DateInterval(start: date("2026-10-24T15:00:00Z"), duration: 13 * 3600))
        let tomorrow = ForecastTemp(tempF: 42, period: DateInterval(start: date("2026-10-25T15:00:00Z"), duration: 13 * 3600))
        #expect(!ConditionsFormat.highIsTomorrow(today, now: now, calendar: calendar))
        #expect(ConditionsFormat.highIsTomorrow(tomorrow, now: now, calendar: calendar))
    }

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

struct CurrentTempTests {
    let now = date("2026-01-07T18:00:00Z")

    private func snapshot(stationTempAt: Date?) -> ConditionsSnapshot {
        ConditionsSnapshot(
            locationID: "mt-baker",
            observed: ObservedSnow(
                depthInches: 40, snow24hInches: nil, observedAt: now, stationName: "Wells Creek", stationElevationFt: 4040,
                airTempF: stationTempAt == nil ? nil : 27, airTempObservedAt: stationTempAt),
            forecast: SnowForecast(next24hInches: 0, issuedAt: nil, gridElevationFt: nil, sourceName: "NWS", tempNowF: 30),
            fetchedAt: now)
    }

    @Test func prefersRecentStationReading() {
        #expect(snapshot(stationTempAt: now.addingTimeInterval(-3600)).currentTemp(now: now) == CurrentTemp(tempF: 27, isForecast: false))
    }

    @Test func fallsBackToForecastWhenStationIsOldOrMissing() {
        #expect(snapshot(stationTempAt: now.addingTimeInterval(-3 * 3600)).currentTemp(now: now) == CurrentTemp(tempF: 30, isForecast: true))
        #expect(snapshot(stationTempAt: nil).currentTemp(now: now) == CurrentTemp(tempF: 30, isForecast: true))
    }

    @Test func snapshotsSavedBeforeTemperatureStillDecode() throws {
        let json = """
        {"locationID":"mt-baker","staleMetrics":[],"updatedAt":{},"fetchedAt":0,
         "observed":{"depthInches":40,"observedAt":0,"stationName":"Wells Creek","stationElevationFt":4040,"isModeled":false},
         "forecast":{"next24hInches":2,"sourceName":"NWS"}}
        """
        let snapshot = try JSONDecoder().decode(ConditionsSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.observed?.airTempF == nil)
        #expect(snapshot.forecast?.windNow == nil)
    }
}
