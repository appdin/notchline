import Foundation
import Testing
@testable import NotchlineCore

struct PlannerSummaryTests {
    let location: Location
    let en = Locale(identifier: "en_US")

    init() throws {
        location = try catalogLocation("mt-baker")
    }

    /// Four clear, calm, cold days at Mt. Baker from local midnight on Tuesday 2027-01-12: about
    /// 77 groomed and 35 ungroomed each day.
    private func snapshot() -> ConditionsSnapshot {
        let start = date("2027-01-12T08:00:00Z")
        let hours = stride(from: start, to: start.addingTimeInterval(4 * 86400), by: 3600).map { start in
            ForecastHour(
                start: start, tempF: 22, snowfallInches: 0, precipitationInches: 0, rainInches: 0, precipitationProbability: 0,
                freezingLevelFt: 2000, visibilityMiles: 20, skyCoverPercent: 0, wind: Wind(sustainedMph: 5, gustMph: 10))
        }
        let forecast = SnowForecast(next24hInches: 0, issuedAt: start, gridElevationFt: nil, sourceName: "test", hourly: HourlyForecast(hours: hours))
        return ConditionsSnapshot(locationID: location.id, forecast: forecast, fetchedAt: start)
    }

    private func plan(travel: TravelTimeProvider?, home: Bool, now: Date) async throws -> SkiDayPlan {
        var settings = PlannerSettings.default
        if home { settings.home = Home(address: "Bellingham, WA", latitude: 48.75, longitude: -122.48) }
        let planner = SkiDayPlanner(travel: travel, roadWeather: nil, modelForecasts: nil, table: nil)
        return try #require(await planner.plan(snapshot(), location: location, settings: settings, now: now))
    }

    @Test func withoutTravelThereAreScoresButNoDeparturesOrHomePrompt() async throws {
        let result = try await plan(travel: nil, home: false, now: date("2027-01-12T08:00:00Z"))
        #expect(result.days.count == 4)
        #expect(result.days.allSatisfy { $0.groomed == nil && $0.ungroomed == nil && $0.score.groomed != nil })
        #expect(!result.needsHome)
        #expect(!result.warnings.contains { $0.contains("home") || $0.contains("drive time") })
        #expect(result.days[0].score.confidence?.groomed.percent == 90)
    }

    @Test func summaryWithoutDepartures() async throws {
        let now = date("2027-01-12T08:00:00Z")
        let result = try await plan(travel: nil, home: false, now: now)
        let summary = PlannerSummary(plan: result, location: location, now: now, locale: en)
        #expect(summary.days.map(\.title) == ["Today", "Tomorrow", "Thu", "Fri"])
        let today = try #require(summary.days.first)
        #expect(today.scores.map(\.terrain) == [.groomed, .ungroomed])
        #expect(today.scores.map(\.isHeadline) == [true, false])
        #expect(today.confidence == "Confidence 90%")
        #expect(today.confidenceNotes.first == "Estimated from how far ahead the day is.")
        #expect(today.rows.allSatisfy { $0.advice == nil && $0.details.isEmpty })
        let start = try #require(result.days[0].score.groomed?.interval.start)
        #expect(today.liftTime == PlannerFormat.time(start, timeZone: location.calendar.timeZone, locale: en))
        #expect(today.noScoreReason == nil)
    }

    @Test func summaryWithDeparturesAndClosedLifts() async throws {
        let morning = date("2027-01-12T08:00:00Z")
        let withTravel = PlannerSummary(plan: try await plan(travel: StubTravel { _ in 90 * 60 }, home: true, now: morning), location: location, now: morning, locale: en)
        let row = try #require(withTravel.days.first?.rows.first)
        #expect(row.advice?.hasPrefix("Leave at") == true)
        #expect(row.details.first == "90 min drive +10 min icy roads")

        // 17:00 PST, after last chair.
        let evening = date("2027-01-13T01:00:00Z")
        let closed = PlannerSummary(plan: try await plan(travel: nil, home: false, now: evening), location: location, now: evening, locale: en)
        #expect(closed.days.first?.noScoreReason == "The lifts have closed for the day.")
        #expect(closed.days.first?.liftTime == nil)
    }
}
