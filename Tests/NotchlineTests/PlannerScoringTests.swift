import Foundation
import Testing
@testable import NotchlineCore

/// Real days at Mt. Baker from Open-Meteo's archived forecasts, scored as the planner would.
struct ScoredDayFixtureTests {
    let gust = PlannerSettings.default.gustThresholdMph

    /// Scores a fixture covering `first` through `last` (local days) and returns `day`'s score.
    private func scoredDay(_ fixture: String, from first: String, through last: String, gustThresholdMph: Double? = nil,
                           edit: (inout HourlyForecast) -> Void = { _ in }) throws -> DayScore {
        let location = try catalogLocation("mt-baker")
        let start = date("\(first)T08:00:00Z")
        let end = date("\(last)T08:00:00Z").addingTimeInterval(24 * 3600)
        let response = try OpenMeteoProvider.parse(Fixture.data(fixture))
        var hourly = try #require(OpenMeteoProvider.hourlyForecast(from: response, calendar: location.calendar, starts: Array(stride(from: start, to: end, by: 3600))))
        edit(&hourly)
        let scores = SkiDayScorer.score(hourly, location: location, now: start, gustThresholdMph: gustThresholdMph ?? gust)
        return try #require(scores.days.last)
    }

    @Test func powderDayFavorsUngroomedEarly() throws {
        let day = try scoredDay("open_meteo_history_baker_powder_2025-02-25", from: "2025-02-24", through: "2025-02-25")
        #expect(day.day == date("2025-02-25T08:00:00Z"))
        #expect(day.newSnowInches > 8)
        #expect(day.drawsCrowd)
        #expect(day.hours.allSatisfy { $0.veto == nil })
        #expect(day.best == .ungroomed)
        let ungroomed = try #require(day.ungroomed)
        #expect(ungroomed.averageScore >= 75)
        #expect(ungroomed.interval.start == day.liftHours.start)
        let groomed = try #require(day.groomed)
        #expect(ungroomed.averageScore > groomed.averageScore)
        // The new snow gets tracked out through the day.
        #expect(day.hours.first!.ungroomed > day.hours.last!.ungroomed)
        #expect(day.hours.first!.freshSnowInches > day.hours.last!.freshSnowInches)
    }

    @Test func rainDayHasNoWindow() throws {
        let day = try scoredDay("open_meteo_history_baker_rain_2026-03-18", from: "2026-03-17", through: "2026-03-18")
        #expect(!day.hours.isEmpty)
        #expect(day.hours.allSatisfy { $0.veto == .rain && $0.groomed == 0 && $0.ungroomed == 0 })
        #expect(day.groomed == nil)
        #expect(day.ungroomed == nil)
        #expect(day.best == nil)
        #expect(day.newSnowInches == 0)
    }

    @Test func windHoldVetoesGustyHoursAndFollowsTheThreshold() throws {
        let day = try scoredDay("open_meteo_history_baker_wind_2024-12-14", from: "2024-12-13", through: "2024-12-14")
        #expect(day.isBusy)  // Saturday
        let held = day.hours.filter { $0.veto == .wind }
        #expect(held.count >= 3)
        #expect(held.allSatisfy { $0.groomed == 0 && $0.ungroomed == 0 })
        // Windows skip the held hours.
        let window = try #require(day.ungroomed)
        #expect(!held.contains { window.interval.intersection(with: $0.interval).map { $0.duration > 0 } ?? false })
        let tolerant = try scoredDay("open_meteo_history_baker_wind_2024-12-14", from: "2024-12-13", through: "2024-12-14", gustThresholdMph: 60)
        #expect(tolerant.hours.filter { $0.veto == .wind }.count < held.count)
    }

    @Test func refrozenCrustLowersGroomed() throws {
        let fixture = "open_meteo_history_baker_crust_2024-12-19"
        let crust = try scoredDay(fixture, from: "2024-12-16", through: "2024-12-19")
        #expect(crust.hours.allSatisfy { $0.isIcy })
        #expect(crust.hours.allSatisfy { $0.veto == nil })
        // The same day with the earlier rain taken out has no crust.
        let dry = try scoredDay(fixture, from: "2024-12-16", through: "2024-12-19") { hourly in
            for index in hourly.hours.indices where hourly.hours[index].start < date("2024-12-19T08:00:00Z") {
                hourly.hours[index].rainInches = 0
                hourly.hours[index].precipitationInches = 0
                hourly.hours[index].precipitationProbability = 0
            }
        }
        #expect(dry.hours.allSatisfy { !$0.isIcy })
        let crustGroomed = try #require(crust.groomed).averageScore
        let dryGroomed = try #require(dry.groomed).averageScore
        #expect(crustGroomed + 10 <= dryGroomed)
        #expect(crust.best == .groomed)
    }

    @Test func coldModelRainIsSnowAtTheForecastElevation() throws {
        // Open-Meteo reports rain on the powder day at -4 °C, split at the model grid's elevation.
        let location = try catalogLocation("mt-baker")
        let response = try OpenMeteoProvider.parse(Fixture.data("open_meteo_history_baker_powder_2025-02-25"))
        #expect(response.hourly.rain?.contains { ($0 ?? 0) > 0 } == true)
        let starts = Array(stride(from: date("2025-02-24T08:00:00Z"), to: date("2025-02-26T08:00:00Z"), by: 3600))
        let hourly = try #require(OpenMeteoProvider.hourlyForecast(from: response, calendar: location.calendar, starts: starts))
        for hour in hourly.hours where (hour.tempF ?? 99) < 32 {
            #expect((hour.rainInches ?? 0) == 0)
            #expect(!hour.precipitationTypes.contains(.rain))
        }
        #expect(OpenMeteoProvider.rainShare(atC: 0) == 0)
        #expect(OpenMeteoProvider.rainShare(atC: 1.5) == 0.5)
        #expect(OpenMeteoProvider.rainShare(atC: 4) == 1)
    }
}

/// Behavior of the rules on built-up hours, one rule at a time.
struct ScoringRuleTests {
    let gust = 45.0

    /// Clear, cold and calm hours for `days` local days at Mt. Baker from `first`, edited by `edit`.
    private func hourly(from first: String = "2027-01-12", days: Int = 1, _ edit: (Date, inout ForecastHour) -> Void = { _, _ in }) -> HourlyForecast {
        let start = date("\(first)T08:00:00Z")
        let hours = stride(from: start, to: start.addingTimeInterval(Double(days) * 24 * 3600), by: 3600).map { start in
            var hour = ForecastHour(
                start: start, tempF: 22, snowfallInches: 0, precipitationInches: 0, rainInches: 0, precipitationProbability: 0,
                freezingLevelFt: 2000, visibilityMiles: 20, skyCoverPercent: 0, wind: Wind(sustainedMph: 5, gustMph: 10))
            edit(start, &hour)
            return hour
        }
        return HourlyForecast(hours: hours)
    }

    private func score(_ hourly: HourlyForecast, now: String = "2027-01-12T08:00:00Z", prior: Double = 0) throws -> PlannerScores {
        SkiDayScorer.score(hourly, location: try catalogLocation("mt-baker"), now: date(now), gustThresholdMph: gust, priorSnowInches: prior)
    }

    @Test func handTunedWeightsSumToOne() {
        for terrain in Terrain.allCases {
            #expect(abs(ScoreWeights.handTuned(terrain).total - 1) < 0.0001)
        }
    }

    @Test func clearDayWithoutNewSnowFavorsGroomed() throws {
        let day = try #require(try score(hourly()).days.first)
        #expect(day.liftHours == DateInterval(start: date("2027-01-12T17:00:00Z"), end: date("2027-01-12T23:30:00Z")))
        #expect(day.hours.count == 7)
        #expect(day.hours.last?.interval.duration == 1800)
        #expect(day.best == .groomed)
        #expect(day.groomed?.averageScore == 77)
        #expect(try #require(day.ungroomed).averageScore <= 40)
        #expect(day.groomed?.interval == day.liftHours)
    }

    @Test func freshSnowDecaysFasterOnBusyDays() throws {
        func overnightSnow(_ first: String) -> HourlyForecast {
            hourly(from: first) { start, hour in
                if start < date("\(first)T14:00:00Z") { hour.snowfallInches = 1 }  // 6" before dawn
            }
        }
        let tuesday = try #require(try score(overnightSnow("2027-01-12")).days.first)
        let saturday = try #require(try score(overnightSnow("2027-01-16"), now: "2027-01-16T08:00:00Z").days.first)
        #expect(tuesday.newSnowInches == 6)
        #expect(!tuesday.isBusy && saturday.isBusy)
        #expect(tuesday.drawsCrowd && saturday.drawsCrowd)
        #expect(tuesday.hours[0].freshSnowInches == 6)
        #expect(saturday.hours[0].freshSnowInches == 6)
        #expect(saturday.hours[3].freshSnowInches < tuesday.hours[3].freshSnowInches)
        // The window shrinks toward first chair as the snow goes.
        let saturdayWindow = try #require(saturday.ungroomed)
        let tuesdayWindow = try #require(tuesday.ungroomed)
        #expect(saturdayWindow.interval.duration < tuesdayWindow.interval.duration)
        #expect(saturday.ungroomed?.interval.start == saturday.liftHours.start)
    }

    @Test func snowCountsSinceTheLastSkiableDay() throws {
        // 1" an hour through Tuesday's lift hours and 1" an hour from 6 PM to midnight.
        let forecast = hourly(days: 2) { start, hour in
            let tuesday = date("2027-01-12T17:00:00Z")...date("2027-01-12T23:00:00Z")
            let evening = date("2027-01-13T02:00:00Z")...date("2027-01-13T07:00:00Z")
            if tuesday.contains(start) || evening.contains(start) { hour.snowfallInches = 1 }
        }
        let days = try score(forecast).days
        #expect(days.count == 2)
        #expect(days[1].newSnowInches == 6)
    }

    @Test func snowCarriesOverAWindHold() throws {
        let forecast = hourly(days: 2) { start, hour in
            if start < date("2027-01-12T17:00:00Z") { hour.snowfallInches = 1 }  // 9" before Tuesday's first chair
            if start < date("2027-01-13T08:00:00Z") { hour.wind = Wind(sustainedMph: 35, gustMph: 60) }
        }
        let days = try score(forecast).days
        #expect(days[0].hours.allSatisfy { $0.veto == .wind })
        #expect(days[0].ungroomed == nil)
        #expect(days[1].newSnowInches == 9)
    }

    @Test func rainWashesOutNewSnow() throws {
        let forecast = hourly { start, hour in
            if start < date("2027-01-12T12:00:00Z") { hour.snowfallInches = 2 }
            if start == date("2027-01-12T13:00:00Z") {
                hour.tempF = 36
                hour.rainInches = 0.1
                hour.precipitationInches = 0.1
            }
        }
        let day = try #require(try score(forecast).days.first)
        #expect(day.newSnowInches == 0)
        #expect(day.hours.allSatisfy { $0.veto == nil && $0.freshSnowInches == 0 })
    }

    @Test func rainThenFreezeIsIcyUntilCovered() throws {
        let forecast = hourly(days: 2) { start, hour in
            if start == date("2027-01-12T09:00:00Z") {
                hour.tempF = 35
                hour.rainInches = 0.2
                hour.precipitationInches = 0.2
            }
            // 3" on Wednesday morning buries the crust.
            if start >= date("2027-01-13T10:00:00Z") && start < date("2027-01-13T13:00:00Z") { hour.snowfallInches = 1 }
        }
        let days = try score(forecast).days
        #expect(days[0].hours.allSatisfy { $0.isIcy })
        #expect(days[1].hours.allSatisfy { !$0.isIcy })
    }

    @Test func rainNeedsLikelyPrecipitationAndAWarmLevel() {
        let elevation = 4500.0
        func hour(_ edit: (inout ForecastHour) -> Void) -> ForecastHour {
            var hour = ForecastHour(start: date("2027-01-12T18:00:00Z"))
            edit(&hour)
            return hour
        }
        // Open-Meteo's rain amount decides on its own.
        #expect(SkiDayScorer.isRaining(hour { $0.rainInches = 0.05 }, elevationFt: elevation))
        #expect(!SkiDayScorer.isRaining(hour { $0.rainInches = 0; $0.precipitationInches = 0.1; $0.snowfallInches = 1 }, elevationFt: elevation))
        // NWS: a chance of rain is not rain; likely rain is.
        #expect(!SkiDayScorer.isRaining(hour { $0.precipitationTypes = [.rain]; $0.precipitationProbability = 30 }, elevationFt: elevation))
        #expect(SkiDayScorer.isRaining(hour { $0.precipitationTypes = [.rain]; $0.precipitationProbability = 70 }, elevationFt: elevation))
        #expect(SkiDayScorer.isRaining(hour { $0.precipitationTypes = [.freezingRain]; $0.precipitationProbability = 70 }, elevationFt: elevation))
        // Mixed types follow the snow level.
        #expect(SkiDayScorer.isRaining(hour { $0.precipitationTypes = [.rain, .snow]; $0.precipitationProbability = 70; $0.snowLevelFt = 5000 }, elevationFt: elevation))
        #expect(!SkiDayScorer.isRaining(hour { $0.precipitationTypes = [.rain, .snow]; $0.precipitationProbability = 70; $0.snowLevelFt = 3500 }, elevationFt: elevation))
        #expect(SkiDayScorer.isRaining(hour { $0.precipitationTypes = [.rain, .snow]; $0.precipitationProbability = 70 }, elevationFt: elevation))
        // Freezing level, less the usual gap, when that is all there is.
        #expect(SkiDayScorer.isRaining(hour { $0.precipitationInches = 0.05; $0.freezingLevelFt = 6000 }, elevationFt: elevation))
        #expect(!SkiDayScorer.isRaining(hour { $0.precipitationInches = 0.05; $0.freezingLevelFt = 5200 }, elevationFt: elevation))
    }

    @Test func gustsAndFogVetoHours() {
        let start = date("2027-01-12T18:00:00Z")
        #expect(SkiDayScorer.veto(ForecastHour(start: start, wind: Wind(sustainedMph: 20, gustMph: 46)), raining: false, gustThresholdMph: 45) == .wind)
        #expect(SkiDayScorer.veto(ForecastHour(start: start, wind: Wind(sustainedMph: 20, gustMph: 45)), raining: false, gustThresholdMph: 45) == nil)
        #expect(SkiDayScorer.veto(ForecastHour(start: start, visibilityMiles: 0.05), raining: false, gustThresholdMph: 45) == .visibility)
        #expect(SkiDayScorer.veto(ForecastHour(start: start, wind: Wind(sustainedMph: 20, gustMph: 60)), raining: true, gustThresholdMph: 45) == .rain)
    }

    @Test func factorsFollowTheirRulesOfThumb() {
        #expect(SkiDayScorer.freshSnowFactor(0) == 0)
        #expect(SkiDayScorer.freshSnowFactor(3) < SkiDayScorer.freshSnowFactor(6))
        #expect(SkiDayScorer.freshSnowFactor(24) > 0.99)
        #expect(SkiDayScorer.snowQualityFactor(20) == 1)
        #expect(SkiDayScorer.snowQualityFactor(32) < SkiDayScorer.snowQualityFactor(28))
        #expect(SkiDayScorer.snowQualityFactor(38) < SkiDayScorer.snowQualityFactor(32))
        #expect(SkiDayScorer.snowQualityFactor(-15) < 1)
        #expect(SkiDayScorer.snowQualityFactor(nil) == 0.5)
        #expect(SkiDayScorer.windFactor(Wind(sustainedMph: 5, gustMph: 10), gustThresholdMph: 45) == 1)
        #expect(SkiDayScorer.windFactor(Wind(sustainedMph: 5, gustMph: 44), gustThresholdMph: 45) < 0.5)
        #expect(abs(SkiDayScorer.windFactor(Wind(sustainedMph: 30), gustThresholdMph: 45) - 0.3) < 0.0001)
        let clear = ForecastHour(start: Date(), visibilityMiles: 20, skyCoverPercent: 0)
        let flat = ForecastHour(start: Date(), snowfallInches: 1, visibilityMiles: 0.5, skyCoverPercent: 100)
        #expect(SkiDayScorer.lightFactor(clear, sensitivity: 0.5) == 1)
        #expect(SkiDayScorer.lightFactor(flat, sensitivity: 0.5) < SkiDayScorer.lightFactor(flat, sensitivity: 0.3))
    }

    @Test func windowIsTheContiguousStretchNearThePeak() {
        func hours(_ scores: [Int], gapAfter: Int? = nil) -> [HourScore] {
            var start = date("2027-01-12T17:00:00Z")
            return scores.enumerated().map { index, score in
                defer { start = start.addingTimeInterval(index == gapAfter ? 7200 : 3600) }
                return HourScore(interval: DateInterval(start: start, duration: 3600), groomed: score, ungroomed: score, veto: nil, freshSnowInches: 0, isIcy: false)
            }
        }
        let window = SkiDayScorer.bestWindow(hours([50, 80, 90, 85, 60, 88]), .ungroomed)
        #expect(window?.interval == DateInterval(start: date("2027-01-12T18:00:00Z"), duration: 3 * 3600))
        #expect(window?.averageScore == 85)
        #expect(window?.peakScore == 90)
        // Ties keep the earlier stretch.
        #expect(SkiDayScorer.bestWindow(hours([90, 0, 90]), .groomed)?.interval.start == date("2027-01-12T17:00:00Z"))
        // A gap in the hours ends a stretch.
        #expect(SkiDayScorer.bestWindow(hours([88, 90, 90], gapAfter: 0), .groomed)?.interval.start == date("2027-01-12T19:00:00Z"))
        #expect(SkiDayScorer.bestWindow(hours([0, 0]), .groomed) == nil)
        #expect(SkiDayScorer.bestWindow([], .groomed) == nil)
    }

    @Test func todayOnlyLooksAhead() throws {
        let scores = try score(hourly(days: 2), now: "2027-01-12T21:30:00Z")
        let today = try #require(scores.days.first)
        #expect(today.hours.count == 7)
        #expect(today.groomed?.interval.start == date("2027-01-12T21:00:00Z"))
        // Once the lifts close, today has no window, but tomorrow does.
        let evening = try score(hourly(days: 2), now: "2027-01-13T01:00:00Z")
        #expect(evening.days.first?.groomed == nil)
        #expect(evening.days.last?.groomed != nil)
    }

    @Test func gapsAreWarningsNotSilentDrops() throws {
        var forecast = hourly { start, hour in
            if start == date("2027-01-12T18:00:00Z") { hour.tempF = nil }
        }
        forecast.hours.removeAll { $0.start == date("2027-01-12T20:00:00Z") }
        let scores = try score(forecast)
        #expect(scores.days.first?.hours.count == 6)
        #expect(scores.warnings == [
            "2027-01-12: no forecast for 1 lift hour, left out",
            "2027-01-12: no temperature for 1 lift hour, scored as neutral",
        ])
    }

    @Test func locationsWithoutLiftHoursHaveNoScores() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try catalogLocation("mt-baker"))) as! [String: Any]
        json["liftHours"] = nil
        let location = try JSONDecoder().decode(Location.self, from: JSONSerialization.data(withJSONObject: json))
        let scores = SkiDayScorer.score(hourly(), location: location, now: date("2027-01-12T08:00:00Z"), gustThresholdMph: gust)
        #expect(scores.days.isEmpty)
        #expect(scores.warnings == ["Mt. Baker Ski Area has no lift hours, so it has no ski day scores"])
    }

    @Test func priorSnowIsWhatTheSeriesHasNotCounted() {
        let forecast = hourly { start, hour in
            if start < date("2027-01-12T12:00:00Z") { hour.snowfallInches = 0.5 }  // 2" counted by 04:00
        }
        let observed = ObservedSnow(depthInches: 80, snow24hInches: 10, observedAt: date("2027-01-12T14:00:00Z"), stationName: "Wells Creek", stationElevationFt: 4040)
        #expect(SkiDayScorer.priorSnowInches(observed: observed, hourly: forecast) == 8)
        #expect(SkiDayScorer.priorSnowInches(observed: nil, hourly: forecast) == 0)
    }
}

struct BusyDayTests {
    @Test(arguments: [
        ("2026-11-26", Country.us), ("2026-11-27", .us), ("2027-01-18", .us), ("2027-02-15", .us),
        ("2026-12-24", .us), ("2027-01-01", .ca), ("2027-02-15", .ca), ("2027-03-26", .ca), ("2027-03-29", .ca),
    ])
    func holidays(day: String, country: Country) {
        #expect(BusyDays.isHoliday(date("\(day)T20:00:00Z"), country: country, calendar: pacific))
    }

    @Test(arguments: [("2027-01-19", Country.us), ("2027-01-18", .ca), ("2026-11-26", .ca), ("2027-03-26", .us)])
    func ordinaryDays(day: String, country: Country) {
        #expect(!BusyDays.isHoliday(date("\(day)T20:00:00Z"), country: country, calendar: pacific))
    }

    @Test func weekendsAreBusy() {
        #expect(BusyDays.isBusy(date("2027-01-16T20:00:00Z"), country: .us, calendar: pacific))
        #expect(!BusyDays.isBusy(date("2027-01-12T20:00:00Z"), country: .us, calendar: pacific))
    }

    @Test func easter() {
        #expect(BusyDays.easterSunday(year: 2027, calendar: pacific) == date("2027-03-28T07:00:00Z"))
        #expect(BusyDays.easterSunday(year: 2026, calendar: pacific) == date("2026-04-05T07:00:00Z"))
    }
}
