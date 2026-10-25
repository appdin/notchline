import Foundation
import Testing
@testable import NotchlineCore

struct NWSForecastProviderTests {
    @Test func pointResolvesGridURL() throws {
        let url = try NWSForecastProvider.parsePoint(Fixture.data("nws_points_baker"))
        #expect(url.absoluteString == "https://api.weather.gov/gridpoints/SEW/157,123")
    }

    @Test(arguments: [
        ("nws_points_stevens", "SEW/165,67"),
        ("nws_points_snoqualmie", "SEW/152,54"),
        ("nws_points_crystal", "SEW/145,31"),
    ])
    func washingtonPointsResolveGridURLs(fixture: String, gridpoint: String) throws {
        let url = try NWSForecastProvider.parsePoint(Fixture.data(fixture))
        #expect(url.absoluteString == "https://api.weather.gov/gridpoints/\(gridpoint)")
    }

    @Test func offSeasonGridpointIsZeroWithElevation() throws {
        let forecast = try NWSForecastProvider.parseGridpoint(
            Fixture.data("nws_gridpoint_sew_157_123_offseason"), now: date("2026-10-24T20:00:00Z"), calendar: pacific)
        #expect(forecast.next24hInches == 0)
        #expect(forecast.gridElevationFt == 4265)
        #expect(forecast.issuedAt == date("2026-10-24T18:26:50Z"))
        #expect(forecast.sourceName == "NWS")
    }

    @Test func offSeasonGridpointHasTemperatureAndWind() throws {
        let forecast = try NWSForecastProvider.parseGridpoint(
            Fixture.data("nws_gridpoint_sew_157_123_offseason"), now: date("2026-10-24T20:00:00Z"), calendar: pacific)
        #expect(try #require(forecast.tempNowF).rounded() == 37)
        let high = try #require(forecast.high)
        #expect(high.tempF.rounded() == 40)
        #expect(high.period.start == date("2026-10-24T15:00:00Z"))
        // The morning low (12Z to 17Z) has ended, so this is tonight's.
        let low = try #require(forecast.low)
        #expect(low.tempF.rounded() == 34)
        #expect(low.period.start == date("2026-10-25T03:00:00Z"))
        let now = try #require(forecast.windNow)
        #expect(abs(now.sustainedMph - 2.3) < 0.05)
        #expect(abs(try #require(now.gustMph) - 8.06) < 0.05)
        #expect(now.directionDegrees == 190)
        let peak = try #require(forecast.windPeak24h)
        #expect(abs(peak.sustainedMph - 12.66) < 0.05)
        #expect(abs(try #require(peak.gustMph) - 24.17) < 0.05)
        #expect(peak.directionDegrees == 180)
    }

    @Test func highRollsToTomorrowAfterDaytimeEnds() throws {
        let data = gridpoint([("2026-01-07T00:00:00+00:00/PT6H", 0)], extra: [
            "maxTemperature": ("wmoUnit:degC", [("2026-01-07T15:00:00+00:00/PT13H", -2.0), ("2026-01-08T15:00:00+00:00/PT13H", -5.0)]),
            "minTemperature": ("wmoUnit:degC", [("2026-01-07T03:00:00+00:00/PT14H", -8.0), ("2026-01-08T03:00:00+00:00/PT14H", -10.0)]),
        ])
        let evening = try NWSForecastProvider.parseGridpoint(data, now: date("2026-01-08T05:00:00Z"), calendar: pacific)
        #expect(evening.high?.tempF == 23)
        #expect(evening.high?.period.start == date("2026-01-08T15:00:00Z"))
        #expect(evening.low?.tempF == 14)
        let afternoon = try NWSForecastProvider.parseGridpoint(data, now: date("2026-01-07T22:00:00Z"), calendar: pacific)
        #expect(afternoon.high?.tempF.rounded() == 28)
        #expect(afternoon.low?.tempF == 14)
    }

    @Test func windPeakTakesSustainedAndGustSeparately() throws {
        let data = gridpoint([("2026-01-07T00:00:00+00:00/PT6H", 0)], extra: [
            "windSpeed": ("wmoUnit:km_h-1", [
                ("2026-01-07T00:00:00+00:00/PT6H", 16.09344),
                ("2026-01-07T06:00:00+00:00/PT6H", 40.2336),
                ("2026-01-07T12:00:00+00:00/PT6H", 32.18688),
                ("2026-01-08T06:00:00+00:00/PT6H", 160.9344),  // outside the 24h window
            ]),
            "windGust": ("wmoUnit:km_h-1", [
                ("2026-01-07T00:00:00+00:00/PT6H", 32.18688),
                ("2026-01-07T06:00:00+00:00/PT6H", 56.32704),
                ("2026-01-07T12:00:00+00:00/PT6H", 72.42048),
            ]),
            "windDirection": ("wmoUnit:degree_(angle)", [("2026-01-07T00:00:00+00:00/PT6H", 180), ("2026-01-07T06:00:00+00:00/PT12H", 225)]),
        ])
        let forecast = try NWSForecastProvider.parseGridpoint(data, now: date("2026-01-07T02:00:00Z"), calendar: pacific)
        #expect(forecast.windNow == Wind(sustainedMph: 10, gustMph: 20, directionDegrees: 180))
        let peak = try #require(forecast.windPeak24h)
        #expect(abs(peak.sustainedMph - 25) < 0.0001)
        #expect(abs(try #require(peak.gustMph) - 45) < 0.0001)
        #expect(peak.directionDegrees == 225)
    }

    @Test func missingTemperatureAndWindLeaveFieldsNil() throws {
        let data = gridpoint([("2026-01-07T00:00:00+00:00/PT6H", 25.4)], extra: [
            "windSpeed": ("wmoUnit:km_h-1", [("2026-01-07T00:00:00+00:00/PT6H", 16.09344)]),
            "windGust": ("wmoUnit:km_h-1", []),
            "temperature": ("wmoUnit:degF", [("2026-01-07T00:00:00+00:00/PT6H", 20.0)]),  // unexpected unit
        ])
        let forecast = try NWSForecastProvider.parseGridpoint(data, now: date("2026-01-07T00:00:00Z"), calendar: pacific)
        #expect(forecast.next24hInches == 1)
        #expect(forecast.tempNowF == nil)
        #expect(forecast.high == nil)
        #expect(forecast.windNow?.gustMph == nil)
        #expect(forecast.windPeak24h?.gustMph == nil)
    }

    @Test func prorates6hIntervalsAtWindowEdges() throws {
        // Window is 03:00Z to 03:00Z next day. 00-06 is half inside, 18-00 fully, 00-06 next day half.
        let data = gridpoint([
            ("2026-11-02T00:00:00+00:00/PT6H", 25.4),
            ("2026-11-02T06:00:00+00:00/PT12H", 50.8),
            ("2026-11-02T18:00:00+00:00/PT6H", 25.4),
            ("2026-11-03T00:00:00+00:00/PT6H", 50.8),
            ("2026-11-03T06:00:00+00:00/PT6H", 254),
        ])
        let forecast = try NWSForecastProvider.parseGridpoint(data, now: date("2026-11-02T03:00:00Z"), calendar: pacific)
        #expect(abs(forecast.next24hInches - (0.5 + 2 + 1 + 1)) < 0.0001)
    }

    @Test func nullValuesCountAsZero() throws {
        let data = gridpoint([
            ("2026-11-02T00:00:00+00:00/PT6H", nil),
            ("2026-11-02T06:00:00+00:00/PT6H", 25.4),
        ])
        let forecast = try NWSForecastProvider.parseGridpoint(data, now: date("2026-11-02T00:00:00Z"), calendar: pacific)
        #expect(abs(forecast.next24hInches - 1) < 0.0001)
    }

    @Test func emptySnowfallThrows() {
        #expect(throws: ProviderError.noData("NWS snowfall forecast is empty")) {
            try NWSForecastProvider.parseGridpoint(gridpoint([]), now: date("2026-11-02T00:00:00Z"), calendar: pacific)
        }
    }

    @Test func parsesDurations() {
        #expect(NWSForecastProvider.parseISODuration("PT6H") == TimeInterval(6 * 3600))
        #expect(NWSForecastProvider.parseISODuration("PT1H") == TimeInterval(3600))
        #expect(NWSForecastProvider.parseISODuration("P1DT12H") == TimeInterval(36 * 3600))
        #expect(NWSForecastProvider.parseISODuration("P2D") == TimeInterval(48 * 3600))
        #expect(NWSForecastProvider.parseISODuration("PT30M") == TimeInterval(1800))
        #expect(NWSForecastProvider.parseISODuration("P1M") == nil)  // months are ambiguous and unused
        #expect(NWSForecastProvider.parseISODuration("6H") == nil)
    }

    @Test func fetchCachesGridURL() async throws {
        let location = try catalogLocation("mt-baker")
        let counter = RequestCounter(StubHTTPClient([
            ("/points/", .success(try Fixture.data("nws_points_baker"))),
            ("/gridpoints/SEW/157,123", .success(try Fixture.data("nws_gridpoint_sew_157_123_offseason"))),
        ]))
        let provider = NWSForecastProvider(http: counter)
        _ = try await provider.fetch(for: location, now: date("2026-10-24T20:00:00Z"))
        _ = try await provider.fetch(for: location, now: date("2026-10-24T20:30:00Z"))
        #expect(await counter.count(matching: "/points/") == 1)
        #expect(await counter.count(matching: "/gridpoints/") == 2)
    }

    private func gridpoint(_ values: [(String, Double?)], extra: [String: (uom: String, values: [(String, Double)])] = [:]) -> Data {
        let entries = values.map { ["validTime": $0.0, "value": $0.1 as Any? ?? NSNull()] }
        var properties: [String: Any] = [
            "updateTime": "2026-11-02T00:00:00+00:00",
            "elevation": ["unitCode": "wmoUnit:m", "value": 1300.0],
            "snowfallAmount": ["uom": "wmoUnit:mm", "values": entries],
        ]
        for (name, layer) in extra {
            properties[name] = ["uom": layer.uom, "values": layer.values.map { ["validTime": $0.0, "value": $0.1] }]
        }
        let json: [String: Any] = ["properties": properties]
        return try! JSONSerialization.data(withJSONObject: json)
    }
}

actor RequestCounter: HTTPClient {
    private let inner: HTTPClient
    private var urls: [URL] = []

    init(_ inner: HTTPClient) {
        self.inner = inner
    }

    func get(_ url: URL) async throws -> Data {
        urls.append(url)
        return try await inner.get(url)
    }

    func count(matching substring: String) -> Int {
        urls.filter { $0.absoluteString.contains(substring) }.count
    }
}
