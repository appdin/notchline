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

    @Test func airTemperatureFromSameStation() throws {
        // Captured with now = 2026-10-24 14:00 PST. Latest TOBS is 13:00 PST.
        let observed = try SnotelProvider.parse(
            Fixture.data("snotel_909_temp_2026-10-24"), station: wellsCreek, now: date("2026-10-24T22:00:00Z"))
        #expect(observed.depthInches == 0)
        #expect(observed.airTempF == 33.6)
        #expect(observed.airTempObservedAt == date("2026-10-24T21:00:00Z"))
    }

    @Test func stevensPassTemperatureStaysCurrentWhenDepthIsSporadic() async throws {
        let location = try catalogLocation("stevens-pass")
        let http = StubHTTPClient([("791:WA:SNTL", .success(try Fixture.data("snotel_791_temp_2026-10-24")))])
        let now = date("2026-10-24T22:00:00Z")
        let observed = try await SnotelProvider(http: http).fetch(for: location, now: now)
        #expect(observed.observedAt == date("2026-10-24T12:00:00Z"))
        #expect(observed.airTempF == 41.9)
        let snapshot = ConditionsSnapshot(locationID: location.id, observed: observed, fetchedAt: now)
        #expect(snapshot.currentTemp(now: now) == CurrentTemp(tempF: 41.9, isForecast: false))
    }

    @Test func temperatureGlitchesAreIgnored() {
        let start = date("2026-01-07T00:00:00Z")
        let values: [Double] = [28, 27, -40, 26, 25]
        let readings = values.enumerated().map {
            StationReadings.Reading(date: start.addingTimeInterval(Double($0.offset) * 3600), value: $0.element)
        }
        #expect(StationReadings.removeSpikes(readings, maxPerHour: StationReadings.maxDegreesPerHour).map(\.value) == [28, 27, 26, 25])
    }

    @Test func outdatedStationFallsBackToCurrentOne() async throws {
        // Morse Lake's latest reading is 2026-01-05 00:00 PST, 13.5 hours old. Cayuse Pass is current.
        let location = try catalogLocation("crystal")
        let http = StubHTTPClient([
            ("642:WA:SNTL", .success(try Fixture.data("snotel_642_gap_2026-01-05"))),
            ("1085:WA:SNTL", .success(try Fixture.data("snotel_1085_2026-01-05"))),
        ])
        let observed = try await SnotelProvider(http: http).fetch(for: location, now: date("2026-01-05T21:30:00Z"))
        #expect(observed.stationName == "Cayuse Pass")
        #expect(observed.depthInches == 30)
        #expect(observed.snow24hInches == 3)
    }

    @Test func usesFreshestOutdatedReadingWhenNoStationIsCurrent() async throws {
        let location = try catalogLocation("crystal")
        let http = StubHTTPClient([
            ("642:WA:SNTL", .success(try Fixture.data("snotel_642_gap_2026-01-05"))),
            ("1085:WA:SNTL", .failure(.http(status: 500, url: SnotelProvider.baseURL))),
        ])
        let observed = try await SnotelProvider(http: http).fetch(for: location, now: date("2026-01-05T21:30:00Z"))
        #expect(observed.stationName == "Morse Lake")
        #expect(observed.depthInches == 44)
        #expect(observed.observedAt == date("2026-01-05T08:00:00Z"))
        #expect(observed.snow24hInches == nil)
    }

    @Test func stevensPassOffSeasonUsesSporadicReading() async throws {
        // Off-season, 791 reports depth only every few hours. Latest is 2026-10-24 04:00 PST, 8.5 hours old.
        let location = try catalogLocation("stevens-pass")
        let http = StubHTTPClient([("791:WA:SNTL", .success(try Fixture.data("snotel_791_offseason_2026-10-24")))])
        let now = date("2026-10-24T20:30:00Z")
        let observed = try await SnotelProvider(http: http).fetch(for: location, now: now)
        #expect(observed.depthInches == 0)
        #expect(observed.observedAt == date("2026-10-24T12:00:00Z"))
        let snapshot = ConditionsSnapshot(locationID: location.id, observed: observed, fetchedAt: now)
        #expect(snapshot.isOutdated(.observed, now: now))
    }

    @Test(arguments: [
        // Location, station fixture, now (30 min after the latest reading), depth, 24h gain.
        ("stevens-pass", "snotel_791_storm_2026-01-07", "2026-01-07T18:30:00Z", 58.0, 18.0),
        ("snoqualmie", "snotel_672_storm_2026-01-06", "2026-01-07T07:30:00Z", 46.0, 12.0),
        ("crystal", "snotel_642_2026-01-10", "2026-01-10T21:30:00Z", 56.0, 0.0),
    ])
    func washingtonPrimaryStationsInSeason(id: String, fixture: String, now: String, depth: Double, gain: Double) async throws {
        let location = try catalogLocation(id)
        guard case .snotel(let stations)? = location.observedSnow else {
            Issue.record("\(id) has no SNOTEL stations")
            return
        }
        let http = StubHTTPClient([(stations[0].triplet, .success(try Fixture.data(fixture)))])
        let observed = try await SnotelProvider(http: http).fetch(for: location, now: date(now))
        #expect(observed.stationName == stations[0].name)
        #expect(observed.depthInches == depth)
        #expect(observed.snow24hInches == gain)
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
            StationReadings.Reading(date: start.addingTimeInterval(Double($0.offset) * 3600), value: $0.element)
        }
        #expect(StationReadings.removeSpikes(readings).map(\.value) == [40, 41, 42, 43, 44])
    }

    @Test func badFirstReadingDoesNotRejectEverything() {
        let start = date("2026-01-07T00:00:00Z")
        let values: [Double] = [0, 40, 41, 41, 42]
        let readings = values.enumerated().map {
            StationReadings.Reading(date: start.addingTimeInterval(Double($0.offset) * 3600), value: $0.element)
        }
        #expect(StationReadings.removeSpikes(readings).map(\.value) == [40, 41, 41, 42])
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
        #expect(query["elements"] == "SNWD,TOBS")
    }
}
