import Foundation
import Testing
@testable import NotchlineCore

struct LocalTimeTests {
    let pacific = try! catalogLocation("mt-baker").calendar

    @Test func daytimeAndOvernightFollowTheLocation() {
        // 10:00 PDT: today's daytime, and tonight's low.
        let morning = date("2026-10-24T17:00:00Z")
        #expect(LocalTime.daytime(containingOrAfter: morning, calendar: pacific).start == date("2026-10-24T14:00:00Z"))
        #expect(LocalTime.overnight(containingOrAfter: morning, calendar: pacific).start == date("2026-10-25T02:00:00Z"))
        // 20:00 PDT: tomorrow's high, the night in progress.
        let evening = date("2026-10-25T03:00:00Z")
        #expect(LocalTime.daytime(containingOrAfter: evening, calendar: pacific).start == date("2026-10-25T14:00:00Z"))
        #expect(LocalTime.overnight(containingOrAfter: evening, calendar: pacific).start == date("2026-10-25T02:00:00Z"))
        // 03:00 PDT: still last night.
        #expect(LocalTime.overnight(containingOrAfter: date("2026-10-24T10:00:00Z"), calendar: pacific).start == date("2026-10-24T02:00:00Z"))
    }

    @Test func periodsFollowDaylightSavingChanges() {
        // DST ends 2026-11-01 at 02:00 PDT. On the evening of 10-31, tomorrow's daytime starts at 07:00 PST.
        let evening = date("2026-11-01T03:00:00Z")  // 20:00 PDT on 10-31
        let daytime = LocalTime.daytime(containingOrAfter: evening, calendar: pacific)
        #expect(daytime.start == date("2026-11-01T15:00:00Z"))
        #expect(daytime.end == date("2026-11-02T03:00:00Z"))
        // That night runs 19:00 PDT to 07:00 PST, 13 hours.
        let night = LocalTime.overnight(containingOrAfter: evening, calendar: pacific)
        #expect(night.start == date("2026-11-01T02:00:00Z"))
        #expect(night.end == date("2026-11-01T15:00:00Z"))
    }

    @Test func tomorrowIsDecidedInTheLocationsTimeZone() {
        // 23:30 PDT on 10-24 is already 10-25 in UTC and in Europe, but not at the location.
        let late = date("2026-10-25T06:30:00Z")
        var london = Calendar(identifier: .gregorian)
        london.timeZone = TimeZone(identifier: "Europe/London")!
        let nextMorning = date("2026-10-25T14:00:00Z")
        #expect(LocalTime.isLaterDay(nextMorning, than: late, calendar: pacific))
        #expect(!LocalTime.isLaterDay(nextMorning, than: late, calendar: london))
    }

    @Test func everyLocationHasAValidTimeZone() throws {
        for location in try LocationCatalog.bundled().locations {
            #expect(TimeZone(identifier: location.timeZone) != nil, "\(location.id)")
        }
    }
}

struct ForecastExpiryTests {
    let summary = DangerSummary(
        zoneName: "West Slopes North", overall: .considerable, upper: .considerable, middle: .moderate, lower: .low,
        validUntil: date("2026-02-11T01:00:00Z"))

    @Test func validForecastIsUnchanged() {
        #expect(summary.current(at: date("2026-02-10T18:00:00Z")) == summary)
        #expect(!summary.isExpired(at: date("2026-02-10T18:00:00Z")))
    }

    @Test func expiredForecastHasNoRating() {
        let now = date("2026-02-11T02:00:00Z")
        let current = summary.current(at: now)
        #expect(summary.isExpired(at: now))
        #expect(current.overall == .noRating)
        #expect(current.upper == nil && current.middle == nil && current.lower == nil)
        #expect(current.zoneName == "West Slopes North")
    }

    @Test func snapshotsApplyTheRule() {
        let snapshot = ConditionsSnapshot(locationID: "mt-baker", danger: summary, fetchedAt: date("2026-02-10T18:00:00Z"))
        #expect(snapshot.danger(at: date("2026-02-11T02:00:00Z"))?.overall == .noRating)
        #expect(snapshot.danger(at: date("2026-02-10T18:00:00Z"))?.overall == .considerable)
    }

    @Test func bothCentersExpireTheSameWay() throws {
        // Avalanche Canada's in-season product is valid until 2026-02-11T00:00Z. An hour later
        // the provider still picks Tuesday's rating, and the shared rule retires it.
        let now = date("2026-02-11T01:00:00Z")
        let canada = try AvalancheCanadaProvider.parse(
            Fixture.data("avalanche_canada_product_whistler_2026-02-10"), calendar: catalogLocation("whistler").calendar, now: now)
        #expect(canada.overall == .considerable)
        #expect(canada.current(at: now).overall == .noRating)
        // avalanche.org's in-season product expires 2026-02-11T02:00Z; its bands are still applied
        // and retired by the same rule afterwards.
        var nwac = DangerSummary(zoneName: "West Slopes Central", overall: .low)
        try AvalancheOrgProvider.applyBands(
            from: Fixture.data("avalanche_product_wsc_2026-02-10"), to: &nwac, now: date("2026-02-11T03:00:00Z"))
        #expect(nwac.upper == .moderate)
        #expect(nwac.current(at: date("2026-02-11T03:00:00Z")).overall == .noRating)
    }
}

struct UnitConversionTests {
    @Test func roundTrips() {
        #expect(Convert.inches(fromCM: 2.54) == 1)
        #expect(Convert.inches(fromMM: 25.4) == 1)
        #expect(abs(Convert.inches(fromM: 1) - 39.3701) < 0.0001)
        #expect(abs(Convert.feet(fromM: Convert.meters(fromFeet: 5500)) - 5500) < 0.0001)
        #expect(Convert.fahrenheit(fromC: -40) == -40)
        #expect(Convert.celsius(fromF: 212) == 100)
        #expect(abs(Convert.mph(fromKMH: Convert.kmh(fromMPH: 15)) - 15) < 0.0001)
    }

    @Test func mismatchedUnitRecordsAWarning() async {
        let (matched, warnings) = await ProviderWarnings.collecting {
            UnitCheck.matches("wmoUnit:degF", "wmoUnit:degC", field: "NWS temperature")
        }
        #expect(!matched)
        #expect(warnings == ["NWS temperature is in wmoUnit:degF, expected wmoUnit:degC; left out"])
    }

    /// Conversion factors live only in UnitConversion.swift.
    @Test func noInlineConversionFactors() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources")
        let factors = ["2.54", "25.4", "3.28084", "0.3048", "1.609344", "9 / 5", "5 / 9"]
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "UnitConversion.swift" }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for factor in factors where text.contains(factor) {
                Issue.record("\(file.lastPathComponent) has the conversion factor \(factor); use Convert")
            }
        }
    }
}

struct ProviderWarningsTests {
    @Test func fallbackForecastSaysWhyItWasUsed() async throws {
        let routes: [(String, Result<Data, ProviderError>)] = [
            ("awdbRestApi", .success(try Fixture.data("snotel_909_offseason_2026-10-24"))),
            ("/points/", .failure(.http(status: 503, url: URL(string: "https://api.weather.gov")!))),
            ("open-meteo", .success(try Fixture.data("open_meteo_whistler_2026-10-24"))),
            ("map-layer/NWAC", .success(try Fixture.data("avalanche_map_layer_nwac_offseason"))),
            ("product?", .failure(.http(status: 500, url: URL(string: "https://api.avalanche.org")!))),
        ]
        let result = await ConditionsService(factory: ProviderFactory(http: StubHTTPClient(routes)))
            .refresh(try catalogLocation("mt-baker"), now: date("2026-10-24T22:30:00Z"))
        #expect(result.errors.isEmpty)
        #expect(result.warnings[.forecast]?.first?.hasPrefix("Primary forecast failed (HTTP 503") == true)
        #expect(result.warnings[.avalanche]?.first?.hasPrefix("Elevation bands unavailable: HTTP 500") == true)
        #expect(result.warnings[.observed] == nil)
    }

    @Test func stationFallbackIsExplained() async throws {
        let http = StubHTTPClient([
            ("642:WA:SNTL", .success(try Fixture.data("snotel_642_gap_2026-01-05"))),
            ("1085:WA:SNTL", .success(try Fixture.data("snotel_1085_2026-01-05"))),
        ])
        let location = try catalogLocation("crystal")
        let (observed, warnings) = await ProviderWarnings.collecting {
            try? await SnotelProvider(http: http).fetch(for: location, now: date("2026-01-05T21:30:00Z"))
        }
        #expect(observed?.stationName == "Cayuse Pass")
        #expect(warnings == ["Using Cayuse Pass: Morse Lake has no reading in the last 6 h"])
    }

    @Test func missingStationTemperatureIsAWarningNotAFailure() async throws {
        let http = StubHTTPClient([("SD.csv", .success(try Fixture.data("bc_asws_sd_2026-10-24", ext: "csv")))])
        let location = try catalogLocation("whistler")
        let (observed, warnings) = await ProviderWarnings.collecting {
            try? await BCSnowStationProvider(http: http).fetch(for: location, now: date("2026-10-24T22:30:00Z"))
        }
        #expect(observed?.depthInches == 0)
        #expect(observed?.airTempF == nil)
        #expect(warnings.first?.hasPrefix("Station air temperature unavailable") == true)
    }

    /// Errors are recorded or thrown, never dropped with try? inside NotchlineCore.
    @Test func noSilentlyDroppedErrors() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/NotchlineCore")
        // The snapshot cache is best effort by design: an unreadable file just means no cache.
        let allowed = ["SnapshotStore.swift", "ConditionsModel.swift"]
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !allowed.contains($0.lastPathComponent) }
        for file in files where try String(contentsOf: file, encoding: .utf8).contains("try?") {
            Issue.record("\(file.lastPathComponent) uses try?; record a ProviderWarnings message or throw")
        }
    }
}

struct RetryAndSharingTests {
    @Test func transientFailureIsRetriedOnceWithAWarning() async throws {
        let flaky = FlakyHTTPClient(failures: [.http(status: 502, url: URL(string: "https://api.open-meteo.com")!)])
        let client = RetryingHTTPClient(flaky, delay: .zero)
        let (data, warnings) = await ProviderWarnings.collecting {
            try? await client.get(URL(string: "https://api.open-meteo.com/v1/forecast")!)
        }
        #expect(data == Data("ok".utf8))
        #expect(await flaky.calls == 2)
        #expect(warnings == ["Retried api.open-meteo.com after HTTP 502"])
    }

    @Test func clientErrorsAndRepeatedFailuresAreNotRetriedForever() async throws {
        let notFound = FlakyHTTPClient(failures: [.http(status: 404, url: URL(string: "https://x")!)])
        await #expect(throws: ProviderError.self) { try await RetryingHTTPClient(notFound, delay: .zero).get(URL(string: "https://x")!) }
        #expect(await notFound.calls == 1)
        let down = FlakyHTTPClient(failures: Array(repeating: .http(status: 503, url: URL(string: "https://x")!), count: 5))
        await #expect(throws: ProviderError.self) { try await RetryingHTTPClient(down, delay: .zero).get(URL(string: "https://x")!) }
        #expect(await down.calls == 2)
    }

    @Test func timeoutsAreTransient() {
        #expect(RetryingHTTPClient.isTransient(URLError(.timedOut)))
        #expect(RetryingHTTPClient.isTransient(ProviderError.http(status: 429, url: URL(string: "https://x")!)))
        #expect(!RetryingHTTPClient.isTransient(URLError(.notConnectedToInternet)))
        #expect(!RetryingHTTPClient.isTransient(ProviderError.noData("x")))
    }

    @Test func concurrentLookupsShareOneLoad() async throws {
        let cache = LookupCache<Int>()
        let loads = Counter()
        let now = Date()
        async let a = cache.value(for: "k", now: now) { await loads.increment(); try await Task.sleep(for: .milliseconds(50)); return 1 }
        async let b = cache.value(for: "k", now: now) { await loads.increment(); return 2 }
        #expect(try await [a, b] == [1, 1])
        #expect(await loads.value == 1)
    }

    @Test func failedLoadsAreNotKept() async throws {
        let cache = LookupCache<Int>()
        let now = Date()
        await #expect(throws: ProviderError.self) {
            try await cache.value(for: "k", now: now) { throw ProviderError.noData("x") }
        }
        #expect(try await cache.value(for: "k", now: now) { 3 } == 3)
    }

    @Test func concurrentNWSRefreshesResolveTheGridpointOnce() async throws {
        let counter = RequestCounter(StubHTTPClient([
            ("/points/", .success(try Fixture.data("nws_points_baker"))),
            ("/gridpoints/", .success(try Fixture.data("nws_gridpoint_sew_157_123_offseason"))),
        ]))
        let provider = NWSForecastProvider(http: counter)
        let location = try catalogLocation("mt-baker")
        let now = date("2026-10-24T20:00:00Z")
        async let first = provider.fetch(for: location, now: now)
        async let second = provider.fetch(for: location, now: now)
        _ = try await (first, second)
        #expect(await counter.count(matching: "/points/") == 1)
    }

    @Test func bcHeaderIsCachedAndRefetchedWhenColumnsChange() async throws {
        let old = "DATE(UTC),3A20P Callaghan Creek\r\n"
        let new = "DATE(UTC),3A20P Callaghan Creek,9Z99P New Station\r\n"
        let rows = "2026-10-24 18:00,0.0,5\r\n2026-10-24 19:00,0.0,6\r\n"
        let server = ChangingCSVServer(header: old, rows: "2026-10-24 18:00,0.0\r\n2026-10-24 19:00,0.0\r\n")
        let provider = BCSnowStationProvider(http: server)
        let location = try catalogLocation("whistler")
        let now = date("2026-10-24T20:00:00Z")
        _ = try await provider.fetch(for: location, now: now)
        _ = try await provider.fetch(for: location, now: now)
        #expect(await server.headerRequests == 2)  // SD and TA once each, then cached
        await server.change(header: new, rows: rows)
        let observed = try await provider.fetch(for: location, now: now)
        #expect(observed.depthInches == 0)
        #expect(await server.headerRequests == 4)  // both refetched after the rows grew a column
    }
}

actor FlakyHTTPClient: HTTPClient {
    private var failures: [ProviderError]
    private(set) var calls = 0

    init(failures: [ProviderError]) {
        self.failures = failures
    }

    func get(_ url: URL) async throws -> Data {
        calls += 1
        if !failures.isEmpty { throw failures.removeFirst() }
        return Data("ok".utf8)
    }
}

actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// Serves a BC-style CSV whose header can change, counting header range requests.
actor ChangingCSVServer: HTTPClient {
    private var header: String
    private var rows: String
    private(set) var headerRequests = 0

    init(header: String, rows: String) {
        self.header = header
        self.rows = rows
    }

    func change(header: String, rows: String) {
        self.header = header
        self.rows = rows
    }

    func get(_ url: URL) async throws -> Data {
        Data((header + rows).utf8)
    }

    func get(_ url: URL, range: String) async throws -> Data {
        if range.hasPrefix("bytes=0-") {
            headerRequests += 1
            return Data(header.utf8)
        }
        return Data(("partial row\r\n" + rows).utf8)
    }
}
