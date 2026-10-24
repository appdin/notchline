import Foundation
import Testing
@testable import NotchlineCore

struct NWSForecastProviderTests {
    @Test func pointResolvesGridURL() throws {
        let url = try NWSForecastProvider.parsePoint(Fixture.data("nws_points_baker"))
        #expect(url.absoluteString == "https://api.weather.gov/gridpoints/SEW/157,123")
    }

    @Test func offSeasonGridpointIsZeroWithElevation() throws {
        let forecast = try NWSForecastProvider.parseGridpoint(
            Fixture.data("nws_gridpoint_sew_157_123_offseason"), now: date("2026-10-24T20:00:00Z"))
        #expect(forecast.next24hInches == 0)
        #expect(forecast.gridElevationFt == 4265)
        #expect(forecast.issuedAt == date("2026-10-24T18:26:50Z"))
        #expect(forecast.sourceName == "NWS")
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
        let forecast = try NWSForecastProvider.parseGridpoint(data, now: date("2026-11-02T03:00:00Z"))
        #expect(abs(forecast.next24hInches - (0.5 + 2 + 1 + 1)) < 0.0001)
    }

    @Test func nullValuesCountAsZero() throws {
        let data = gridpoint([
            ("2026-11-02T00:00:00+00:00/PT6H", nil),
            ("2026-11-02T06:00:00+00:00/PT6H", 25.4),
        ])
        let forecast = try NWSForecastProvider.parseGridpoint(data, now: date("2026-11-02T00:00:00Z"))
        #expect(abs(forecast.next24hInches - 1) < 0.0001)
    }

    @Test func emptySnowfallThrows() {
        #expect(throws: ProviderError.noData("NWS snowfall forecast is empty")) {
            try NWSForecastProvider.parseGridpoint(gridpoint([]), now: date("2026-11-02T00:00:00Z"))
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

    private func gridpoint(_ values: [(String, Double?)]) -> Data {
        let entries = values.map { ["validTime": $0.0, "value": $0.1 as Any? ?? NSNull()] }
        let json: [String: Any] = [
            "properties": [
                "updateTime": "2026-11-02T00:00:00+00:00",
                "elevation": ["unitCode": "wmoUnit:m", "value": 1300.0],
                "snowfallAmount": ["uom": "wmoUnit:mm", "values": entries],
            ],
        ]
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
