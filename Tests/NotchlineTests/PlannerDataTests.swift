import Foundation
import Testing
@testable import NotchlineCore

struct HourlyForecastTests {
    // Both fixtures were captured at about 01:30 PDT on 2026-10-25.
    let now = date("2026-10-25T08:30:00Z")
    /// 09:00 PDT on 2026-10-25.
    let firstChair = date("2026-10-25T16:00:00Z")

    @Test func plannerHoursRunFromMidnightThroughTheThirdDayAfter() {
        let hours = LocalTime.plannerHours(from: now, calendar: pacific)
        #expect(hours.count == 96)
        #expect(hours.first == date("2026-10-25T07:00:00Z"))
        #expect(hours.last == date("2026-10-29T06:00:00Z"))
    }

    @Test func plannerHoursFollowDaylightSaving() {
        // Daylight saving ends on 2026-11-01, which has 25 hours.
        let hours = LocalTime.plannerHours(from: date("2026-11-01T15:00:00Z"), calendar: pacific)
        #expect(hours.count == 97)
        #expect(hours.first == date("2026-11-01T07:00:00Z"))
        #expect(hours.last == date("2026-11-05T07:00:00Z"))
    }

    @Test func nwsHourlyFromFixture() throws {
        let forecast = try NWSForecastProvider.parseGridpoint(Fixture.data("nws_gridpoint_sew_157_123_2026-10-25"), now: now, calendar: pacific)
        let hourly = try #require(forecast.hourly)
        #expect(hourly.hours.count == 96)
        #expect(hourly.hours(on: now, calendar: pacific).count == 24)
        let hour = try #require(hourly.hours.first { $0.start == firstChair })
        #expect(try #require(hour.tempF).rounded() == 36)
        #expect(abs(try #require(hour.snowLevelFt) - 4882) < 1)
        #expect(abs(try #require(hour.visibilityMiles) - 2.16) < 0.01)
        #expect(hour.skyCoverPercent == 80)
        #expect(hour.precipitationProbability == 40)
        // A sixth of the 12Z to 18Z amount.
        #expect(abs(try #require(hour.precipitationInches) - 0.762 / 6 / 25.4) < 0.00001)
        #expect(hour.snowfallInches == 0)
        #expect(hour.rainInches == nil)
        #expect(hour.freezingLevelFt == nil)
        #expect(abs(try #require(hour.wind?.sustainedMph) - 12.66) < 0.01)
        #expect(abs(try #require(hour.wind?.gustMph) - 23.02) < 0.01)
        #expect(hour.precipitationTypes == [.rain, .snow])
    }

    @Test func nwsWarnsWhenTheSeriesEndsEarly() async throws {
        let json: [String: Any] = ["properties": [
            "snowfallAmount": ["uom": "wmoUnit:mm", "values": [["validTime": "2026-10-25T07:00:00+00:00/P1D", "value": 10.0]]],
        ]]
        let data = try JSONSerialization.data(withJSONObject: json)
        let (forecast, warnings) = await ProviderWarnings.collecting {
            try? NWSForecastProvider.parseGridpoint(data, now: now, calendar: pacific)
        }
        #expect(forecast?.hourly?.hours.count == 24)
        #expect(warnings == ["NWS hourly forecast ends 2026-10-26T06:00:00Z, short of the last day"])
    }

    @Test func nwsWeatherMapsPrecipitationTypes() throws {
        let json: [String: Any] = ["properties": [
            "snowfallAmount": ["uom": "wmoUnit:mm", "values": [["validTime": "2026-10-25T07:00:00+00:00/P4D", "value": 0.0]]],
            "weather": ["values": [
                ["validTime": "2026-10-25T07:00:00+00:00/PT2H", "value": [
                    ["coverage": "likely", "weather": "snow_showers"], ["coverage": "chance", "weather": "freezing_drizzle"],
                    ["coverage": "patchy", "weather": "fog"],
                ]],
                ["validTime": "2026-10-25T09:00:00+00:00/PT1H", "value": [["coverage": NSNull(), "weather": NSNull()]]],
            ]],
        ]]
        let forecast = try NWSForecastProvider.parseGridpoint(try JSONSerialization.data(withJSONObject: json), now: now, calendar: pacific)
        let hours = try #require(forecast.hourly?.hours)
        #expect(hours[0].precipitationTypes == [.snow, .freezingRain])
        #expect(hours[1].precipitationTypes == [.snow, .freezingRain])
        #expect(hours[2].precipitationTypes == [])
    }

    @Test func openMeteoHourlyFromFixture() throws {
        let response = try OpenMeteoProvider.parse(Fixture.data("open_meteo_baker_2026-10-25"))
        let forecast = try OpenMeteoProvider.forecast(from: response, location: catalogLocation("mt-baker"), now: now)
        let hourly = try #require(forecast.hourly)
        #expect(hourly.hours.count == 96)
        #expect(hourly.hours.first?.start == date("2026-10-25T07:00:00Z"))
        let hour = try #require(hourly.hours.first { $0.start == firstChair })
        // Instantaneous values from 09:00, amounts and gusts from the 10:00 value covering 09:00 to 10:00.
        #expect(abs(try #require(hour.tempF) - 34.52) < 0.001)
        #expect(abs(try #require(hour.freezingLevelFt) - 6003.94) < 0.01)
        #expect(abs(try #require(hour.visibilityMiles) - 8.513) < 0.001)
        #expect(hour.skyCoverPercent == 100)
        #expect(hour.precipitationProbability == 57)
        #expect(abs(try #require(hour.precipitationInches) - 1.4 / 25.4) < 0.00001)
        // 1.65 °C over the hour, so a little over half the model's rain stays rain.
        #expect(abs(try #require(hour.rainInches) - 1.3 * OpenMeteoProvider.rainShare(atC: 1.65) / 25.4) < 0.00001)
        #expect(abs(try #require(hour.snowfallInches) - 0.07 / 2.54) < 0.00001)
        #expect(hour.snowLevelFt == nil)
        #expect(abs(try #require(hour.wind?.sustainedMph) - 6.773) < 0.001)
        #expect(abs(try #require(hour.wind?.gustMph) - 22.121) < 0.001)
        #expect(hour.wind?.directionDegrees == 157)
        #expect(hour.precipitationTypes == [.rain, .snow])
        // The 23:00 hour on the last day has no following value, so it has no amounts.
        let last = try #require(hourly.hours.last)
        #expect(last.start == date("2026-10-29T06:00:00Z"))
        #expect(last.tempF != nil)
        #expect(last.snowfallInches == nil)
    }

    @Test func openMeteoWithoutPlannerFieldsStillForecasts() throws {
        // The Whistler fixture predates the planner fields.
        let response = try OpenMeteoProvider.parse(Fixture.data("open_meteo_whistler_2026-10-24"))
        let forecast = try OpenMeteoProvider.forecast(from: response, location: catalogLocation("whistler"), now: date("2026-10-24T22:30:00Z"))
        let hours = try #require(forecast.hourly?.hours)
        #expect(!hours.isEmpty)
        #expect(hours.allSatisfy { $0.freezingLevelFt == nil && $0.visibilityMiles == nil && $0.rainInches == nil })
        #expect(hours.contains { $0.tempF != nil })
    }

    @Test func openMeteoRequestCoversThePlannerDaysInLocalTime() throws {
        let url = OpenMeteoProvider.requestURL(for: try catalogLocation("mt-baker"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        #expect(query["forecast_days"] == "4")
        #expect(query["timezone"] == "America/Los_Angeles")
        let fields = Set(try #require(query["hourly"]).split(separator: ",").map(String.init))
        #expect(fields.isSuperset(of: ["freezing_level_height", "rain", "showers", "visibility", "cloud_cover", "precipitation_probability"]))
    }

    @Test func fallbackForecastCarriesTheHourlySeries() async throws {
        let http = StubHTTPClient([
            ("api.weather.gov", .failure(.http(status: 503, url: URL(string: "https://api.weather.gov")!))),
            ("open-meteo", .success(try Fixture.data("open_meteo_baker_2026-10-25"))),
        ])
        let forecast = try await ProviderFactory(http: http).providers(for: catalogLocation("mt-baker")).forecast?
            .fetch(for: catalogLocation("mt-baker"), now: now)
        #expect(forecast?.sourceName == "Open-Meteo")
        #expect(forecast?.hourly?.hours.count == 96)
    }

    @Test func snapshotsWithoutHourlyStillDecode() throws {
        let json = #"{"next24hInches":2,"sourceName":"NWS"}"#
        let forecast = try JSONDecoder().decode(SnowForecast.self, from: Data(json.utf8))
        #expect(forecast.hourly == nil)
    }
}

struct LiftHoursTests {
    @Test func everySkiAreaHasLiftHours() throws {
        for location in try LocationCatalog.bundled().locations where location.kind == .skiArea {
            let hours = try #require(location.liftHours, "\(location.id) has no lift hours")
            #expect(hours.weekday.firstChair < hours.weekday.lastChair)
            #expect(hours.weekend.firstChair < hours.weekend.lastChair)
        }
    }

    @Test func weekendsUseWeekendHoursInLocalTime() throws {
        let crystal = try catalogLocation("crystal")
        // Monday 2026-10-26 and Saturday 2026-10-31, both PDT.
        #expect(crystal.liftInterval(on: date("2026-10-26T20:00:00Z")) == DateInterval(start: date("2026-10-26T16:00:00Z"), end: date("2026-10-26T23:00:00Z")))
        #expect(crystal.liftInterval(on: date("2026-10-31T20:00:00Z"))?.start == date("2026-10-31T15:30:00Z"))
        // Late evening UTC is still the same local day.
        #expect(crystal.liftInterval(on: date("2026-10-27T05:00:00Z"))?.start == date("2026-10-26T16:00:00Z"))
    }

    @Test func clockTimesParseOnlyHHmm() {
        #expect(ClockTime("08:30") == ClockTime(hour: 8, minute: 30))
        #expect(ClockTime("8:30") == nil)
        #expect(ClockTime("24:00") == nil)
        #expect(ClockTime("09:60") == nil)
        #expect(ClockTime("0900") == nil)
        #expect(ClockTime(hour: 19, minute: 5)?.description == "19:05")
    }

    @Test func invalidLiftHoursFailToLoad() {
        let json = #"{"weekday":{"firstChair":"9:00","lastChair":"15:30"},"weekend":{"firstChair":"09:00","lastChair":"15:30"}}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(LiftHours.self, from: Data(json.utf8)) }
    }
}

struct PlannerSettingsTests {
    @Test func defaultsMatchThePlan() {
        let settings = PlannerSettings.default
        #expect(settings.isEnabled)
        #expect(settings.home == nil)
        #expect(settings.gustThresholdMph == 45)
        #expect(settings.eveningSummaryTime == ClockTime(hour: 19, minute: 0))
        #expect(settings.departureReminderLeadMinutes == 30)
        #expect(settings.notificationScoreThreshold == 80)
        #expect(settings.settings(for: "mt-baker") == LocationPlannerSettings(arrivalToLiftMinutes: 20, overnightParkingAllowed: false))
    }

    @Test func missingPreferencesGiveDefaults() throws {
        #expect(try PlannerSettings.load(nil) == .default)
        #expect(try PlannerSettings.load(Data("{}".utf8)) == .default)
        #expect(throws: DecodingError.self) { try PlannerSettings.load(Data("not json".utf8)) }
    }

    @Test func partialPreferencesKeepTheirValuesAndDefaultTheRest() throws {
        let json = #"{"gustThresholdMph":55,"eveningSummaryTime":"20:30","locations":{"crystal":{"overnightParkingAllowed":true}}}"#
        let settings = try PlannerSettings.load(Data(json.utf8))
        #expect(settings.gustThresholdMph == 55)
        #expect(settings.eveningSummaryTime == ClockTime(hour: 20, minute: 30))
        #expect(settings.notificationScoreThreshold == 80)
        #expect(settings.settings(for: "crystal") == LocationPlannerSettings(arrivalToLiftMinutes: 20, overnightParkingAllowed: true))
    }

    @Test func roundTripsWithHomeAndPerLocationSettings() throws {
        var settings = PlannerSettings.default
        settings.home = Home(address: "Bellingham, WA", matchedName: "Bellingham, WA", latitude: 48.7519, longitude: -122.4787)
        settings.update("mt-baker") { $0.arrivalToLiftMinutes = 45 }
        settings.isEnabled = false
        #expect(try PlannerSettings.load(JSONEncoder().encode(settings)) == settings)
        #expect(settings.settings(for: "mt-baker").arrivalToLiftMinutes == 45)
        #expect(settings.settings(for: "mt-baker").overnightParkingAllowed == false)
        #expect(settings.settings(for: "crystal") == .default)
    }
}
