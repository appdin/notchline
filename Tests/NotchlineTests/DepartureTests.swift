import Foundation
#if canImport(MapKit)
import MapKit
#endif
import Testing
@testable import NotchlineCore

/// Drive times from a rule on the requested arrival, recording each request.
actor StubTravel: TravelTimeProvider {
    private let rule: @Sendable (Date) throws -> TimeInterval
    private let midpointResult: Result<Coordinate, TravelError>
    private(set) var arrivals: [Date] = []

    init(midpoint: Result<Coordinate, TravelError> = .success(Coordinate(latitude: 48.8, longitude: -122.1)),
         _ rule: @escaping @Sendable (Date) throws -> TimeInterval) {
        self.rule = rule
        midpointResult = midpoint
    }

    func travelTime(from origin: Coordinate, to destination: Coordinate, arrivingBy arrival: Date) async throws -> TimeInterval {
        arrivals.append(arrival)
        return try rule(arrival)
    }

    func routeMidpoint(from origin: Coordinate, to destination: Coordinate) async throws -> Coordinate {
        try midpointResult.get()
    }
}

struct StubRoadWeather: RoadWeatherProvider {
    var result: Result<HourlyForecast, ProviderError>

    func hourly(at coordinate: Coordinate, calendar: Calendar, now: Date) async throws -> HourlyForecast {
        try result.get()
    }
}

struct DeparturePlannerTests {
    let minutes: (Double) -> TimeInterval = { $0 * 60 }

    /// Clear, calm hours at Mt. Baker from local midnight on `first`, at `tempF`, edited by `edit`.
    private func hourly(from first: String = "2027-01-12", days: Int = 1, tempF: Double = 22, _ edit: (Date, inout ForecastHour) -> Void = { _, _ in }) -> HourlyForecast {
        let start = date("\(first)T08:00:00Z")
        return HourlyForecast(hours: stride(from: start, to: start.addingTimeInterval(Double(days) * 86400), by: 3600).map { start in
            var hour = ForecastHour(
                start: start, tempF: tempF, snowfallInches: 0, precipitationInches: 0, rainInches: 0, precipitationProbability: 0,
                freezingLevelFt: 2000, visibilityMiles: 20, skyCoverPercent: 0, wind: Wind(sustainedMph: 5, gustMph: 10))
            edit(start, &hour)
            return hour
        })
    }

    private func settings(overnight: Bool = false, home: Bool = true) -> PlannerSettings {
        var settings = PlannerSettings.default
        if home { settings.home = Home(address: "Bellingham, WA", latitude: 48.75, longitude: -122.48) }
        settings.update("mt-baker") { $0.overnightParkingAllowed = overnight }
        return settings
    }

    private func plan(_ hourly: HourlyForecast, now: String = "2027-01-12T08:00:00Z", settings: PlannerSettings? = nil,
                      travel: StubTravel, road: HourlyForecast? = nil) async throws -> SkiDayPlan {
        let location = try catalogLocation("mt-baker")
        let now = date(now)
        let scores = SkiDayScorer.score(hourly, location: location, now: now, gustThresholdMph: 45)
        let planner = DeparturePlanner(travel: travel, roadWeather: StubRoadWeather(result: .success(road ?? self.hourly(tempF: 40))))
        return await planner.plan(scores, hourly: hourly, location: location, settings: settings ?? self.settings(), now: now)
    }

    @Test func leavesForFirstChairWithARoadBufferWhenFreezing() async throws {
        let travel = StubTravel { _ in 90 * 60 }
        let result = try await plan(hourly(), travel: travel)
        let departure = try #require(result.days.first?.groomed)
        #expect(departure.liftTime == date("2027-01-12T17:00:00Z"))  // 9:00 AM first chair
        #expect(departure.drive.lotArrival == date("2027-01-12T16:40:00Z"))  // 20 minutes lot to lift
        #expect(departure.drive.roadCondition == .freezing)
        #expect(departure.drive.roadBuffer == minutes(10))  // 10% of 90, rounded up to 5
        #expect(departure.drive.crowdBuffer == 0)
        #expect(departure.drive.leaveAt == date("2027-01-12T15:00:00Z"))
        #expect(departure.overnight == nil)
        #expect(departure.missedLiftTime == nil)
        #expect(result.warnings.isEmpty)
        // Both terrains aim for 9:00, so Apple Maps is asked about the same arrival.
        #expect(await travel.arrivals.allSatisfy { $0 == date("2027-01-12T16:40:00Z") })
    }

    @Test func roadSnowAndCrowdsAddTime() async throws {
        // 6" before dawn draws a crowd; snow keeps falling at the midpoint during the drive.
        let forecast = hourly { start, hour in
            if start < date("2027-01-12T14:00:00Z") { hour.snowfallInches = 1 }
        }
        let road = hourly(tempF: 30) { _, hour in hour.snowfallInches = 0.3 }
        let result = try await plan(forecast, travel: StubTravel { _ in 90 * 60 }, road: road)
        let drive = try #require(result.days.first?.ungroomed?.drive)
        #expect(drive.roadCondition == .snow)
        #expect(drive.roadBuffer == minutes(30))  // 30% of 90
        #expect(drive.crowdBuffer == minutes(20))
        #expect(drive.leaveAt == date("2027-01-12T14:20:00Z"))

        let saturday = try await plan(hourly(from: "2027-01-16") { start, hour in
            if start < date("2027-01-16T14:00:00Z") { hour.snowfallInches = 1 }
        }, now: "2027-01-16T08:00:00Z", travel: StubTravel { _ in 90 * 60 }, road: hourly(from: "2027-01-16", tempF: 40))
        #expect(saturday.days.first?.ungroomed?.drive.crowdBuffer == minutes(30))
    }

    @Test func tiedWindowsGoToTheShorterDrive() async throws {
        let location = try catalogLocation("mt-baker")
        let start = date("2027-01-12T17:00:00Z")
        let hours = [90, 0, 90, 0].enumerated().map { index, score in
            HourScore(interval: DateInterval(start: start.addingTimeInterval(Double(index) * 3600), duration: 3600),
                      groomed: score, ungroomed: score, veto: nil, freshSnowInches: 0, isIcy: false)
        }
        let day = DayScore(day: date("2027-01-12T08:00:00Z"), liftHours: location.liftInterval(on: start)!, hours: hours,
                           groomed: nil, ungroomed: nil, newSnowInches: 0, isBusy: false, drawsCrowd: false)
        // Morning traffic: arriving before 10:00 takes two hours, later one.
        let travel = StubTravel { arrival in arrival < date("2027-01-12T18:00:00Z") ? 120 * 60 : 60 * 60 }
        let planner = DeparturePlanner(travel: travel, roadWeather: nil)
        let result = await planner.plan(PlannerScores(days: [day], warnings: []), hourly: hourly(tempF: 40), location: location,
                                        settings: settings(), now: date("2027-01-12T08:00:00Z"))
        let departure = try #require(result.days.first?.groomed)
        #expect(departure.liftTime == date("2027-01-12T19:00:00Z"))
        #expect(departure.drive.driveTime == 60 * 60)
    }

    @Test func lateTodayLeavesNowForWhatIsLeft() async throws {
        // 8:30 AM with a 90 minute drive: first chair is out of reach.
        let now = date("2027-01-12T16:30:00Z")
        let result = try await plan(hourly(), now: "2027-01-12T16:30:00Z", travel: StubTravel { _ in 90 * 60 })
        let departure = try #require(result.days.first?.groomed)
        #expect(departure.missedLiftTime == date("2027-01-12T17:00:00Z"))
        // Now + 90 drive + 10 buffer + 20 lot to lift.
        #expect(departure.liftTime == date("2027-01-12T18:30:00Z"))
        #expect(departure.drive.leaveAt == now)
        #expect(departure.advice(now: now) == .goAnyway(firstChairPassed: true))
        #expect(PlannerFormat.advice(departure.advice(now: now), timeZone: pacific.timeZone) == "Go anyway, first chair has passed")

        // After last chair there is nothing to leave for.
        let evening = try await plan(hourly(), now: "2027-01-12T23:00:00Z", travel: StubTravel { _ in 90 * 60 })
        #expect(evening.days.first?.groomed == nil)
    }

    @Test func adviceFollowsTheClock() async throws {
        let result = try await plan(hourly(), travel: StubTravel { _ in 90 * 60 })
        let departure = try #require(result.days.first?.groomed)
        let leave = departure.drive.leaveAt
        #expect(departure.advice(now: leave.addingTimeInterval(-3 * 3600)) == .leaveAt(leave))
        #expect(departure.advice(now: leave.addingTimeInterval(-minutes(32))) == .leaveIn(minutes: 30))
        #expect(departure.advice(now: leave.addingTimeInterval(-minutes(7))) == .leaveIn(minutes: 5))
        #expect(departure.advice(now: leave.addingTimeInterval(-minutes(3))) == .leaveNow)
        #expect(departure.advice(now: leave.addingTimeInterval(minutes(4))) == .leaveNow)
        #expect(departure.advice(now: leave.addingTimeInterval(minutes(20))) == .goAnyway(firstChairPassed: true))
        let us = Locale(identifier: "en_US")
        #expect(PlannerFormat.advice(.leaveAt(leave), timeZone: pacific.timeZone, locale: us) == "Leave at 7:00\u{202F}AM")
        #expect(PlannerFormat.advice(.leaveIn(minutes: 30), timeZone: pacific.timeZone) == "Leave in 30 min")
        #expect(PlannerFormat.advice(.goAnyway(firstChairPassed: false), timeZone: pacific.timeZone) == "Go anyway, the best of it has started")
    }

    @Test func earlyDeparturesOfferDrivingUpTheNightBefore() async throws {
        let long = StubTravel { _ in 4 * 3600 }
        let now = "2027-01-11T20:00:00Z"  // noon the day before
        let result = try await plan(hourly(), now: now, settings: settings(overnight: true), travel: long)
        let departure = try #require(result.days.first?.groomed)
        // 8:40 lot arrival less 4 h and a 25 min freezing buffer is 4:15 AM.
        #expect(departure.drive.leaveAt == date("2027-01-12T12:15:00Z"))
        let overnight = try #require(departure.overnight)
        #expect(overnight.lotArrival == date("2027-01-12T05:00:00Z"))  // 9 PM the evening before
        #expect(overnight.crowdBuffer == 0)
        // The test forecast starts at midnight, so the evening drive has no weather and no buffer.
        #expect(overnight.roadCondition == .clear)
        #expect(overnight.leaveAt == overnight.lotArrival.addingTimeInterval(-4 * 3600))
        #expect(PlannerFormat.overnight(overnight, now: date(now), timeZone: pacific.timeZone, locale: Locale(identifier: "en_US"))
            == "or drive up tonight, leave at 5:00\u{202F}PM")

        let notAllowed = try await plan(hourly(), now: now, settings: settings(overnight: false), travel: long)
        #expect(notAllowed.days.first?.groomed?.overnight == nil)
        let short = try await plan(hourly(), now: now, settings: settings(overnight: true), travel: StubTravel { _ in 90 * 60 })
        #expect(short.days.first?.groomed?.overnight == nil)
    }

    @Test func noHomeMeansNoDepartures() async throws {
        let result = try await plan(hourly(), settings: settings(home: false), travel: StubTravel { _ in 90 * 60 })
        #expect(result.days.count == 1)
        #expect(result.days[0].groomed == nil && result.days[0].ungroomed == nil)
        #expect(result.days[0].score.groomed != nil)
        #expect(result.warnings == ["Set a home address in Settings to get departure times"])
    }

    @Test func aClosedRoadIsOneWarning() async throws {
        let closed = StubTravel(midpoint: .failure(.noRoute("current road conditions"))) { _ in throw TravelError.noRoute("current road conditions") }
        let result = try await plan(hourly(days: 2), travel: closed)
        #expect(result.days.allSatisfy { $0.groomed == nil && $0.ungroomed == nil })
        #expect(result.warnings == [
            "No road weather along the drive (no route: current road conditions); road buffers use the resort's weather only",
            "No drive time to Mt. Baker Ski Area from Apple Maps (no route: current road conditions)",
        ])
    }

    @Test func roadConditionsTakeTheWorstHour() {
        func hour(_ edit: (inout ForecastHour) -> Void) -> ForecastHour {
            var hour = ForecastHour(start: date("2027-01-12T15:00:00Z"), tempF: 40)
            edit(&hour)
            return hour
        }
        #expect(DeparturePlanner.roadCondition(hour { _ in }) == .clear)
        #expect(DeparturePlanner.roadCondition(hour { $0.tempF = 30 }) == .freezing)
        #expect(DeparturePlanner.roadCondition(hour { $0.snowfallInches = 0.2 }) == .snow)
        #expect(DeparturePlanner.roadCondition(hour { $0.precipitationTypes = [.snow]; $0.precipitationProbability = 60 }) == .snow)
        #expect(DeparturePlanner.roadCondition(hour { $0.precipitationTypes = [.snow]; $0.precipitationProbability = 20 }) == .clear)
        #expect(DeparturePlanner.roadCondition(hour { $0.snowfallInches = 1.5 }) == .heavySnow)
        #expect(DeparturePlanner.roadCondition(hour { $0.tempF = 31; $0.rainInches = 0.05 }) == .freezingRain)
        #expect(DeparturePlanner.roadCondition(hour { $0.precipitationTypes = [.freezingRain]; $0.precipitationProbability = 70 }) == .freezingRain)

        // Only hours overlapping the drive count.
        let samples = [HourlyForecast(hours: [
            ForecastHour(start: date("2027-01-12T13:00:00Z"), tempF: 40, snowfallInches: 2),
            ForecastHour(start: date("2027-01-12T14:00:00Z"), tempF: 30),
        ])]
        #expect(DeparturePlanner.roadCondition(during: DateInterval(start: date("2027-01-12T14:00:00Z"), duration: 3600), samples: samples) == .freezing)
        #expect(DeparturePlanner.roadBuffer(driveTime: 90 * 60, condition: .snow) == 30 * 60)
        #expect(DeparturePlanner.roadBuffer(driveTime: 90 * 60, condition: .clear) == 0)
    }

    @Test func etasAreCachedPerArrival() async throws {
        let inner = StubTravel { _ in 3600 }
        let cached = CachedTravelTimes(inner)
        let home = Coordinate(latitude: 48.75, longitude: -122.48)
        let baker = Coordinate(latitude: 48.863, longitude: -121.678)
        _ = try await cached.travelTime(from: home, to: baker, arrivingBy: date("2027-01-12T16:40:00Z"))
        _ = try await cached.travelTime(from: home, to: baker, arrivingBy: date("2027-01-12T16:40:00Z"))
        _ = try await cached.travelTime(from: home, to: baker, arrivingBy: date("2027-01-13T16:40:00Z"))
        #expect(await inner.arrivals.count == 2)
    }

    @Test func tiedWindowsAreAllReturned() {
        let start = date("2027-01-12T17:00:00Z")
        let hours = [90, 0, 90].enumerated().map { index, score in
            HourScore(interval: DateInterval(start: start.addingTimeInterval(Double(index) * 3600), duration: 3600),
                      groomed: score, ungroomed: score, veto: nil, freshSnowInches: 0, isIcy: false)
        }
        #expect(SkiDayScorer.bestWindows(hours, .groomed).map(\.interval.start) == [start, start.addingTimeInterval(7200)])
    }

    #if canImport(MapKit)
    @Test func routeMidpointIsHalfwayByDistance() {
        var points = [CLLocationCoordinate2D(latitude: 48.0, longitude: -122), CLLocationCoordinate2D(latitude: 48.1, longitude: -122),
                      CLLocationCoordinate2D(latitude: 48.4, longitude: -122)]
        let midpoint = MapKitTravelTimes.midpoint(of: MKPolyline(coordinates: &points, count: points.count))
        #expect(abs(midpoint.latitude - 48.2) < 0.01)
        #expect(abs(midpoint.longitude + 122) < 0.0001)
    }
    #endif
}
