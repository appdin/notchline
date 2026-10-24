import Foundation
import Testing
@testable import NotchlineCore

struct SnotelProviderTests {
    let wellsCreek = SnotelStation(triplet: "909:WA:SNTL", name: "Wells Creek", elevationFt: 4040, utcOffsetHours: -8)

    @Test func stormFixtureGivesDepthAnd24hGain() throws {
        // Latest reading is 2026-01-07 09:00 PST.
        let observed = try SnotelProvider.parse(
            Fixture.data("snotel_909_storm_2026-01-07"), station: wellsCreek, now: date("2026-01-07T17:30:00Z"))
        #expect(observed.depthInches == 41)  // median of 40, 41, 42
        #expect(observed.snow24hInches == 12)  // 41 minus median of 29, 29, 30 around 01-06 09:00
        #expect(observed.observedAt == date("2026-01-07T17:00:00Z"))
        #expect(observed.stationName == "Wells Creek")
        #expect(!observed.isModeled)
    }

    @Test func offSeasonFixtureIsZero() throws {
        let observed = try SnotelProvider.parse(
            Fixture.data("snotel_909_offseason_2026-10-24"), station: wellsCreek, now: date("2026-10-24T20:30:00Z"))
        #expect(observed.depthInches == 0)
        #expect(observed.snow24hInches == 0)
    }

    @Test func staleReadingsThrow() throws {
        #expect(throws: ProviderError.self) {
            try SnotelProvider.parse(
                Fixture.data("snotel_909_storm_2026-01-07"), station: wellsCreek, now: date("2026-01-08T12:00:00Z"))
        }
    }

    @Test func timestampsUseFixedStandardTimeAcrossDSTChange() throws {
        let formatter = SnotelProvider.stationDateFormatter(wellsCreek)
        // DST ends 2026-11-01 at 02:00 local. SNOTEL stays on PST, so 01:00 is unambiguous.
        #expect(formatter.date(from: "2026-11-01 01:00") == date("2026-11-01T09:00:00Z"))
        #expect(formatter.date(from: "2026-11-01 02:00") == date("2026-11-01T10:00:00Z"))
        // 2026-03-08 02:30 does not exist in America/Los_Angeles but does in fixed PST.
        #expect(formatter.date(from: "2026-03-08 02:30") == date("2026-03-08T10:30:00Z"))
        #expect(formatter.date(from: "2026-07-01 12:00") == date("2026-07-01T20:00:00Z"))
    }

    @Test func spikesAndDropoutsAreIgnored() {
        let start = date("2026-01-07T00:00:00Z")
        let values: [Double] = [40, 41, 0, 42, 90, 43, 44]
        let readings = values.enumerated().map {
            SnotelProvider.Reading(date: start.addingTimeInterval(Double($0.offset) * 3600), inches: $0.element)
        }
        #expect(SnotelProvider.removeSpikes(readings).map(\.inches) == [40, 41, 42, 43, 44])
    }

    @Test func badFirstReadingDoesNotRejectEverything() {
        let start = date("2026-01-07T00:00:00Z")
        let values: [Double] = [0, 40, 41, 41, 42]
        let readings = values.enumerated().map {
            SnotelProvider.Reading(date: start.addingTimeInterval(Double($0.offset) * 3600), inches: $0.element)
        }
        #expect(SnotelProvider.removeSpikes(readings).map(\.inches) == [40, 41, 41, 42])
    }

    @Test func suspectAndMissingValuesAreSkipped() throws {
        let json = """
        [{"stationTriplet":"909:WA:SNTL","data":[{"stationElement":{"elementCode":"SNWD"},"values":[
          {"date":"2026-01-07 06:00","value":40,"qcFlag":"V"},
          {"date":"2026-01-07 07:00","value":null,"qcFlag":"V"},
          {"date":"2026-01-07 08:00","value":55,"qcFlag":"S"},
          {"date":"2026-01-07 09:00","value":41,"qcFlag":"E"}
        ]}]}]
        """
        let observed = try SnotelProvider.parse(Data(json.utf8), station: wellsCreek, now: date("2026-01-07T17:30:00Z"))
        #expect(observed.depthInches == 40.5)
        #expect(observed.snow24hInches == nil)
    }

    @Test func fallsBackToSecondStation() async throws {
        let location = try catalogLocation("mt-baker")
        let http = StubHTTPClient([
            ("909:WA:SNTL", .failure(.http(status: 500, url: SnotelProvider.baseURL))),
            ("999", .success(try Fixture.data("snotel_909_storm_2026-01-07"))),
        ])
        let observed = try await SnotelProvider(http: http).fetch(for: location, now: date("2026-01-07T17:30:00Z"))
        #expect(observed.stationName == "Marten Ridge")
        #expect(observed.depthInches == 41)
    }

    @Test func requestUsesStationLocalTimeWindow() {
        let url = SnotelProvider.requestURL(station: wellsCreek, now: date("2026-01-07T17:30:00Z"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        #expect(query["beginDate"] == "2026-01-06 03:30")
        #expect(query["endDate"] == "2026-01-07 10:30")
        #expect(query["elements"] == "SNWD")
    }
}
