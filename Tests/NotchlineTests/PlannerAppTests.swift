import Foundation
import Testing
@testable import NotchlineCore

/// Phase 5: the whole planner, the archive behind ratings, and the notification schedule.
@MainActor
struct PlannerAppTests {
    let location: Location
    let archive: PlannerArchive

    init() throws {
        location = try catalogLocation("mt-baker")
        archive = PlannerArchive(directory: FileManager.default.temporaryDirectory.appending(path: "notchline-tests-\(UUID().uuidString)"))
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

    private func settings(home: Bool = true, threshold: Int = 70) -> PlannerSettings {
        var settings = PlannerSettings.default
        if home { settings.home = Home(address: "Bellingham, WA", latitude: 48.75, longitude: -122.48) }
        settings.notificationScoreThreshold = threshold
        return settings
    }

    private func planner(models: SkiDayPlanner.ModelForecasts? = nil) -> SkiDayPlanner {
        SkiDayPlanner(travel: StubTravel { _ in 90 * 60 }, roadWeather: nil, modelForecasts: models, table: nil)
    }

    private func plan(now: String, settings: PlannerSettings? = nil) async throws -> SkiDayPlan {
        try #require(await planner().plan(snapshot(), location: location, settings: settings ?? self.settings(), now: date(now)))
    }

    // MARK: Planner

    @Test func plansScoresConfidenceAndDepartures() async throws {
        let failing: SkiDayPlanner.ModelForecasts = { _, _ in throw ProviderError.notConfigured("models") }
        let result = try #require(await planner(models: failing).plan(snapshot(), location: location, settings: settings(), now: date("2027-01-12T08:00:00Z")))
        #expect(result.days.count == 4)
        let today = try #require(result.days.first)
        #expect(today.score.best == .groomed)
        #expect(today.groomed?.drive.leaveAt == date("2027-01-12T15:00:00Z"))
        // No models: confidence by the rule from lead alone.
        #expect(today.score.confidence?.groomed == Confidence(percent: 90, lead: 0, modelSpread: nil, isMeasured: false))
        #expect(result.warnings.contains { $0.hasPrefix("No comparison models") })
        #expect(!result.needsHome)
        #expect(PlannerFormat.scores(today.score) == "77 groomed, 35 ungroomed")
        #expect(PlannerFormat.drive(today.groomed!.drive) == "90 min drive +10 min icy roads")
    }

    @Test func withoutHomeThereAreScoresButNoDepartures() async throws {
        let result = try await plan(now: "2027-01-12T08:00:00Z", settings: settings(home: false))
        #expect(result.needsHome)
        #expect(result.days.allSatisfy { $0.groomed == nil && $0.ungroomed == nil && $0.score.groomed != nil })
    }

    @Test func noHourlyForecastNoPlan() async {
        let empty = ConditionsSnapshot(locationID: location.id, fetchedAt: date("2027-01-12T08:00:00Z"))
        #expect(await planner().plan(empty, location: location, settings: settings(), now: date("2027-01-12T08:00:00Z")) == nil)
    }

    @Test func dayNames() {
        let now = date("2027-01-12T20:00:00Z")
        let names = (0..<4).map { PlannerFormat.dayName(date("2027-01-12T08:00:00Z").addingTimeInterval(Double($0) * 86400), now: now, calendar: pacific, locale: Locale(identifier: "en_US")) }
        #expect(names == ["Today", "Tomorrow", "Thu", "Fri"])
    }

    // MARK: Archive

    @Test func keepsTheMorningPlanAndEarlierLeads() async throws {
        let dawn = try await plan(now: "2027-01-12T14:00:00Z")  // 6:00 AM
        try archive.record(dawn, hourly: snapshot().forecast!.hourly!, location: location, now: date("2027-01-12T14:00:00Z"))
        let midday = try await plan(now: "2027-01-12T20:00:00Z")  // noon, after first chair
        try archive.record(midday, hourly: snapshot().forecast!.hourly!, location: location, now: date("2027-01-12T20:00:00Z"))

        let today = try #require(try archive.load(locationID: location.id, day: date("2027-01-12T08:00:00Z"), calendar: pacific))
        #expect(today.morning?.plannedAt == date("2027-01-12T14:00:00Z"))
        #expect(today.morning?.forecast.count == 24)
        #expect(today.morningScore == 77)

        let tomorrow = try #require(try archive.load(locationID: location.id, day: date("2027-01-13T08:00:00Z"), calendar: pacific))
        #expect(tomorrow.morning == nil)
        #expect(tomorrow.earlier.map(\.lead) == [1])
        #expect(tomorrow.earlier.first?.plannedAt == date("2027-01-12T20:00:00Z"))
        #expect(tomorrow.earlier.first?.groomed == 77)
        #expect(try archive.load(locationID: location.id, day: date("2027-01-14T08:00:00Z"), calendar: pacific)?.earlier.map(\.lead) == [2])
        // +3 is not kept.
        #expect(try archive.load(locationID: location.id, day: date("2027-01-15T08:00:00Z"), calendar: pacific) == nil)
    }

    @Test func ratingKeepsTheMorningPlanAndReplacesAnEarlierRating() async throws {
        let morning = try await plan(now: "2027-01-12T14:00:00Z")
        try archive.record(morning, hourly: snapshot().forecast!.hourly!, location: location, now: date("2027-01-12T14:00:00Z"))
        let record = try #require(try archive.load(locationID: location.id, day: date("2027-01-12T08:00:00Z"), calendar: pacific))

        try archive.rate(record, DayRating(skied: true, groomed: 4, ratedAt: date("2027-01-13T02:00:00Z")), calendar: pacific)
        try archive.rate(record, DayRating(skied: true, ungroomed: 2, ratedAt: date("2027-01-13T03:00:00Z")), calendar: pacific)
        let stored = try #require(try archive.load(locationID: location.id, day: record.day, calendar: pacific))
        #expect(stored.rating?.groomed == nil && stored.rating?.ungroomed == 2)
        #expect(stored.morning != nil)
    }

    // MARK: Model

    #if canImport(Combine)
    @Test func modelPlansRecordsAndRates() async throws {
        let model = PlannerModel(planner: planner(), archive: archive)
        let now = date("2027-01-12T14:00:00Z")
        let result = await model.update(snapshot: snapshot(), location: location, settings: settings(), now: now)
        #expect(result?.days.count == 4)
        #expect(model.plan == result)
        #expect(model.locationID == location.id)
        #expect(!model.isPlanning)

        let days = try model.recentDays(location: location, now: now)
        #expect(days.count == PlannerArchive.ratableDayCount)
        let today = try #require(days.first)
        #expect(today.morning != nil)
        try model.rate(today, DayRating(skied: true, ungroomed: 2, ratedAt: now), location: location)
        #expect(try model.recentDays(location: location, now: now).first?.rating?.ungroomed == 2)

        model.clear()
        #expect(model.plan == nil && model.locationID == nil)
    }
    #endif

    // MARK: Notifications

    @Test func summariesTheEveningBeforeAndNoDepartureReminders() async throws {
        let now = date("2027-01-12T14:00:00Z")  // Tuesday 6:00 AM
        let result = try await plan(now: "2027-01-12T14:00:00Z")
        let notifications = PlannerNotifications.schedule(
            result, location: location, settings: settings(), now: now, userCalendar: pacific, locale: Locale(identifier: "en_US"))

        let summaries = notifications.filter { $0.kind == .summary }
        // 7 PM Tuesday, Wednesday and Thursday, for the next day each.
        #expect(summaries.map(\.fireAt) == [date("2027-01-13T03:00:00Z"), date("2027-01-14T03:00:00Z"), date("2027-01-15T03:00:00Z")])
        let first = try #require(summaries.first)
        #expect(first.id == "planner.summary.mt-baker.2027-01-13")
        #expect(first.title == "Tomorrow at Mt. Baker Ski Area: 77 groomed, 35 ungroomed")
        #expect(first.body == "Leave at 7:00\u{202F}AM. Confidence 85%.")

        // A good score doesn't mean the user is going, so nothing fires before a departure.
        #expect(notifications.count == summaries.count)
        #expect(notifications.allSatisfy { $0.fireAt > now && $0.id.hasPrefix(PlannerNotifications.idPrefix) })

        // Below the threshold, or with the planner off, nothing.
        #expect(PlannerNotifications.schedule(result, location: location, settings: settings(threshold: 80), now: now, userCalendar: pacific).isEmpty)
        var off = settings()
        off.isEnabled = false
        #expect(PlannerNotifications.schedule(result, location: location, settings: off, now: now, userCalendar: pacific).isEmpty)
    }

    @Test func summaryWithoutADepartureGivesTheLiftTime() async throws {
        let now = date("2027-01-12T14:00:00Z")
        let result = try await plan(now: "2027-01-12T14:00:00Z", settings: settings(home: false))
        let summary = try #require(PlannerNotifications.schedule(
            result, location: location, settings: settings(home: false), now: now, userCalendar: pacific, locale: Locale(identifier: "en_US"))
            .first { $0.kind == .summary })
        #expect(summary.body == "Be on the lift by 9:00\u{202F}AM. Confidence 85%.")
    }

    @Test func pastTimesAreLeftOut() async throws {
        // 7:30 PM Tuesday: tonight's summary has passed.
        let result = try await plan(now: "2027-01-13T03:30:00Z")
        let notifications = PlannerNotifications.schedule(
            result, location: location, settings: settings(), now: date("2027-01-13T03:30:00Z"), userCalendar: pacific)
        #expect(notifications.filter { $0.kind == .summary }.map(\.day) == [date("2027-01-14T08:00:00Z"), date("2027-01-15T08:00:00Z")])
    }

    @Test func recentDaysIncludeUnplannedOnesNewestFirst() async throws {
        let now = date("2027-01-13T20:00:00Z")  // Wednesday noon
        let result = try await plan(now: "2027-01-12T14:00:00Z")
        try archive.record(result, hourly: snapshot().forecast!.hourly!, location: location, now: date("2027-01-12T14:00:00Z"))

        let days = try archive.recentDays(location: location, now: now, count: 3)
        // Wednesday was recorded at lead 1, Tuesday has its morning plan, Monday was never planned.
        #expect(days.map(\.day) == [date("2027-01-13T08:00:00Z"), date("2027-01-12T08:00:00Z"), date("2027-01-11T08:00:00Z")])
        #expect(days[0].morning == nil && days[0].earlier.count == 1)
        #expect(days[1].morning != nil)
        #expect(days[2] == PlannerDayRecord(locationID: location.id, day: date("2027-01-11T08:00:00Z")))
    }

    @Test func nothingAsksForARating() async throws {
        let now = date("2027-01-12T14:00:00Z")
        let result = try await plan(now: "2027-01-12T14:00:00Z")
        let notifications = PlannerNotifications.schedule(result, location: location, settings: settings(), now: now, userCalendar: pacific)
        #expect(Set(notifications.map(\.kind)) == [.summary])
    }

    @Test func ratingPromptStrings() async throws {
        let now = date("2027-01-12T14:00:00Z")
        let result = try await plan(now: "2027-01-12T14:00:00Z")
        try archive.record(result, hourly: snapshot().forecast!.hourly!, location: location, now: now)
        let record = try #require(try archive.load(locationID: location.id, day: date("2027-01-12T08:00:00Z"), calendar: pacific))
        let en = Locale(identifier: "en_US")

        let prompt = RatingPrompt(record, location: location, now: now, locale: en)
        #expect(prompt.day == record.day)
        #expect(prompt.dayLabel == "Today")
        #expect(prompt.title == "How was Mt. Baker Ski Area on Tuesday, Jan 12?")
        #expect(prompt.note == "The planner forecast 77 groomed, 35 ungroomed. Rate only what you skied, 1 for poor to 5 for great.")
        #expect(RatingPrompt(record, location: location, now: now.addingTimeInterval(86400), locale: en).dayLabel == "Yesterday")
        #expect(RatingPrompt(record, location: location, now: now.addingTimeInterval(3 * 86400), locale: en).dayLabel == "Tue")

        let unplanned = RatingPrompt(PlannerDayRecord(locationID: location.id, day: date("2027-01-11T08:00:00Z")), location: location, now: now, locale: en)
        #expect(unplanned.note == "Rate only what you skied, 1 for poor to 5 for great.")
    }
}
