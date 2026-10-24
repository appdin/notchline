import Foundation
import Testing
@testable import NotchlineCore

struct AvalancheCanadaProviderTests {
    let vancouver = try! catalogLocation("whistler").calendar

    @Test func offSeasonIsNoRatingWithoutBands() throws {
        let summary = try AvalancheCanadaProvider.parse(
            Fixture.data("avalanche_canada_point_whistler_offseason"), calendar: vancouver, now: date("2026-10-24T22:30:00Z"))
        #expect(summary.zoneName == "Avalanche Canada")
        #expect(summary.overall == .noRating)
        #expect(summary.upper == nil)
        #expect(summary.validUntil == date("2026-11-26T00:00:00Z"))
        #expect(summary.forecastURL?.host == "avalanche.ca")
    }

    @Test func inSeasonUsesTodaysBands() throws {
        // Tuesday 2026-02-10, 10:00 PST. The first day's date is 2026-02-11T00:00Z, Tuesday afternoon local.
        let summary = try AvalancheCanadaProvider.parse(
            Fixture.data("avalanche_canada_product_whistler_2026-02-10"), calendar: vancouver, now: date("2026-02-10T18:00:00Z"))
        #expect(summary.overall == .considerable)
        #expect(summary.upper == .considerable)
        #expect(summary.middle == .moderate)
        #expect(summary.lower == .low)
        #expect(summary.issuedAt == date("2026-02-10T00:00:00Z"))
    }

    @Test func forecastPublishedTheEveningBeforeCountsAsCurrent() throws {
        // Monday 18:00 PST, after the forecast for Tuesday was issued at 16:00.
        let summary = try AvalancheCanadaProvider.parse(
            Fixture.data("avalanche_canada_product_whistler_2026-02-10"), calendar: vancouver, now: date("2026-02-10T02:00:00Z"))
        #expect(summary.overall == .considerable)
    }

    @Test func laterDayUsesItsOwnBands() throws {
        // Wednesday 10:00 PST: the product's second day, alpine moderate.
        let summary = try AvalancheCanadaProvider.parse(
            Fixture.data("avalanche_canada_product_whistler_2026-02-10"), calendar: vancouver, now: date("2026-02-11T18:00:00Z"))
        #expect(summary.overall == .moderate)
        #expect(summary.upper == .moderate)
    }

    @Test func ratingValues() {
        #expect(AvalancheCanadaProvider.level("considerable") == .considerable)
        #expect(AvalancheCanadaProvider.level("extreme") == .extreme)
        #expect(AvalancheCanadaProvider.level("earlyseason") == .noRating)
        #expect(AvalancheCanadaProvider.level("norating") == .noRating)
        #expect(AvalancheCanadaProvider.level(nil) == .noRating)
    }

    @Test(arguments: ["whistler", "revelstoke", "sun-peaks"])
    func requestUsesPointLookup(id: String) throws {
        let url = AvalancheCanadaProvider.requestURL(for: try catalogLocation(id))
        #expect(url.absoluteString.hasPrefix("https://api.avalanche.ca/forecasts/en/products/point?lat="))
    }
}

struct BCSnowStationProviderTests {
    let callaghan = BCSnowStation(id: "3A20P", name: "Callaghan Creek", elevationFt: 3337)

    @Test func currentFilesGiveDepthAndTemperature() async throws {
        // The files end in CRLF and the latest rows are still blank for Callaghan Creek.
        let http = StubHTTPClient([
            ("SD.csv", .success(try Fixture.data("bc_asws_sd_2026-10-24", ext: "csv"))),
            ("TA.csv", .success(try Fixture.data("bc_asws_ta_2026-10-24", ext: "csv"))),
        ])
        let observed = try await BCSnowStationProvider(http: http).fetch(for: catalogLocation("whistler"), now: date("2026-10-24T22:30:00Z"))
        #expect(observed.stationName == "Callaghan Creek")
        #expect(observed.depthInches == 0)
        #expect(observed.snow24hInches == 0)
        #expect(observed.observedAt == date("2026-10-24T19:00:00Z"))
        #expect(abs(try #require(observed.airTempF) - 33.98) < 0.001)
        #expect(observed.airTempObservedAt == date("2026-10-24T19:00:00Z"))
    }

    @Test func stormGivesDepthAnd24hGainInInches() throws {
        let data = try Fixture.data("bc_asws_sd_2025-03-09", ext: "csv")
        let table = try BCSnowStationProvider.parseTable(header: data, tail: data)
        let observed = try BCSnowStationProvider.observation(
            station: callaghan, depth: table, temperature: nil, now: date("2025-03-09T05:30:00Z"))
        #expect(abs(observed.depthInches - 170 / 2.54) < 0.0001)  // median of 168, 170, 171 cm
        #expect(abs(try #require(observed.snow24hInches) - 70 / 2.54) < 0.0001)  // from 100 cm
        #expect(observed.airTempF == nil)
    }

    @Test func tailStartingMidRowDropsThePartialLine() throws {
        let header = Data("DATE(UTC),3A20P Callaghan Creek,3A25P Squamish River Upper\r\n2026-01-07 00:00,10,20\r\n".utf8)
        let tail = Data("0,20\r\n2026-01-07 01:00,11,21\r\n2026-01-07 02:00,,22\r\n".utf8)
        let table = try BCSnowStationProvider.parseTable(header: header, tail: tail)
        #expect(try table.readings(station: "3A20P").map(\.value) == [11])
        #expect(try table.readings(station: "3A25P").map(\.value) == [21, 22])
        #expect(throws: ProviderError.self) { try table.readings(station: "9Z99P") }
    }

    @Test func headerWithoutALineEndIsRejected() {
        #expect(throws: ProviderError.self) {
            try BCSnowStationProvider.parseTable(header: Data("DATE(UTC),3A20P Callag".utf8), tail: Data())
        }
    }

    @Test func requestsOnlyHeaderAndTail() async throws {
        let recorder = RangeRecorder(StubHTTPClient([
            ("SD.csv", .success(try Fixture.data("bc_asws_sd_2026-10-24", ext: "csv"))),
            ("TA.csv", .success(try Fixture.data("bc_asws_ta_2026-10-24", ext: "csv"))),
        ]))
        _ = try await BCSnowStationProvider(http: recorder).fetch(for: catalogLocation("whistler"), now: date("2026-10-24T22:30:00Z"))
        #expect(await recorder.ranges.sorted() == ["bytes=-49152", "bytes=-49152", "bytes=0-16383", "bytes=0-16383"])
        #expect(await recorder.unrangedCount == 0)
    }
}

struct OpenMeteoProviderTests {
    // The fixture was captured at about 15:20 PDT on 2026-10-24.
    let now = date("2026-10-24T22:30:00Z")

    private func response() throws -> OpenMeteoProvider.Response {
        try OpenMeteoProvider.parse(Fixture.data("open_meteo_whistler_2026-10-24"))
    }

    @Test func forecastFromFixture() throws {
        let forecast = try OpenMeteoProvider.forecast(from: response(), location: catalogLocation("whistler"), now: now)
        #expect(abs(forecast.next24hInches - 5.88 / 2.54) < 0.0001)
        #expect(forecast.sourceName == "Open-Meteo")
        #expect(forecast.gridElevationFt == 5500)
        #expect(forecast.issuedAt == nil)
        #expect(forecast.tempNowF == 32)
        // Today's 07:00 to 19:00 PDT high and tonight's low.
        #expect(forecast.high?.tempF == 32)
        #expect(forecast.high?.period.start == date("2026-10-24T14:00:00Z"))
        #expect(abs(try #require(forecast.low?.tempF) - 26.24) < 0.0001)
        #expect(forecast.low?.period.start == date("2026-10-25T02:00:00Z"))
        let windNow = try #require(forecast.windNow)
        #expect(abs(windNow.sustainedMph - 4.101) < 0.001)
        #expect(windNow.directionDegrees == 97)
        let peak = try #require(forecast.windPeak24h)
        #expect(abs(peak.sustainedMph - 15.534) < 0.001)
        #expect(abs(try #require(peak.gustMph) - 33.305) < 0.001)
        #expect(peak.directionDegrees == 131)
    }

    @Test func modeledSnowIsLabeled() throws {
        let observed = try OpenMeteoProvider.modeledSnow(from: response(), location: catalogLocation("revelstoke"), now: now)
        #expect(observed.isModeled)
        #expect(observed.depthInches == 0)
        #expect(observed.snow24hInches == 0)
        #expect(observed.observedAt == date("2026-10-24T22:00:00Z"))
        #expect(observed.airTempF == nil)
    }

    @Test func temperatureInAnUnexpectedUnitIsLeftOutWithAWarning() async throws {
        var json = try JSONSerialization.jsonObject(with: Fixture.data("open_meteo_whistler_2026-10-24")) as! [String: Any]
        var units = json["hourly_units"] as! [String: String]
        units["temperature_2m"] = "°F"
        json["hourly_units"] = units
        let response = try OpenMeteoProvider.parse(JSONSerialization.data(withJSONObject: json))
        let location = try catalogLocation("whistler")
        let (forecast, warnings) = await ProviderWarnings.collecting {
            try? OpenMeteoProvider.forecast(from: response, location: location, now: now)
        }
        #expect(forecast?.tempNowF == nil)
        #expect(forecast?.high == nil)
        #expect(forecast?.windNow != nil)
        #expect(warnings == ["Open-Meteo temperature_2m is in °F, expected °C; left out"])
    }

    @Test func snowfallInAnUnexpectedUnitFails() throws {
        var json = try JSONSerialization.jsonObject(with: Fixture.data("open_meteo_whistler_2026-10-24")) as! [String: Any]
        json["hourly_units"] = ["snowfall": "inch"]
        let response = try OpenMeteoProvider.parse(JSONSerialization.data(withJSONObject: json))
        #expect(throws: ProviderError.self) {
            try OpenMeteoProvider.forecast(from: response, location: catalogLocation("whistler"), now: now)
        }
    }

    @Test func mismatchedSeriesAreRejected() {
        let json = """
        {"hourly":{"time":[0,3600],"snowfall":[0],"snow_depth":[0,0],"temperature_2m":[0,0],
         "wind_speed_10m":[0,0],"wind_gusts_10m":[0,0],"wind_direction_10m":[0,0]}}
        """
        #expect(throws: ProviderError.self) { try OpenMeteoProvider.parse(Data(json.utf8)) }
    }

    @Test func requestUsesForecastElevationInMeters() throws {
        let url = OpenMeteoProvider.requestURL(for: try catalogLocation("whistler"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        #expect(query["elevation"] == "1676")
        #expect(query["timeformat"] == "unixtime")
        #expect(query["past_days"] == "1")
    }
}

/// Records the Range header of each request.
actor RangeRecorder: HTTPClient {
    private let inner: HTTPClient
    private(set) var ranges: [String] = []
    private(set) var unrangedCount = 0

    init(_ inner: HTTPClient) {
        self.inner = inner
    }

    func get(_ url: URL) async throws -> Data {
        unrangedCount += 1
        return try await inner.get(url)
    }

    func get(_ url: URL, range: String) async throws -> Data {
        ranges.append(range)
        return try await inner.get(url)
    }
}
