import Foundation
import Testing
@testable import NotchlineCore

/// Phase 6: the travel-time log, weights fit to ratings, and buffers tuned from drives.
@MainActor
struct PlannerLearningTests {
    let location: Location
    let archive: PlannerArchive
    let home = Home(address: "Bellingham, WA", latitude: 48.75, longitude: -122.48)

    init() throws {
        location = try catalogLocation("mt-baker")
        archive = PlannerArchive(directory: FileManager.default.temporaryDirectory.appending(path: "notchline-tests-\(UUID().uuidString)"))
    }

    /// Clear, calm, cold hours at Mt. Baker for one day from local midnight on `day`, edited by `edit`.
    private func snapshot(day: String = "2027-01-12", _ edit: (inout ForecastHour) -> Void = { _ in }) -> ConditionsSnapshot {
        let start = date("\(day)T08:00:00Z")
        let hours = stride(from: start, to: start.addingTimeInterval(86400), by: 3600).map { start in
            var hour = ForecastHour(
                start: start, tempF: 22, snowfallInches: 0, precipitationInches: 0, rainInches: 0, precipitationProbability: 0,
                freezingLevelFt: 2000, visibilityMiles: 20, skyCoverPercent: 0, wind: Wind(sustainedMph: 5, gustMph: 10))
            edit(&hour)
            return hour
        }
        let forecast = SnowForecast(next24hInches: 0, issuedAt: start, gridElevationFt: nil, sourceName: "test", hourly: HourlyForecast(hours: hours))
        return ConditionsSnapshot(locationID: location.id, forecast: forecast, fetchedAt: start)
    }

    private func settings(home: Bool = true) -> PlannerSettings {
        var settings = PlannerSettings.default
        if home { settings.home = self.home }
        return settings
    }

    private func planner(minutes: Double = 90) -> SkiDayPlanner {
        SkiDayPlanner(travel: StubTravel { _ in minutes * 60 }, roadWeather: nil, modelForecasts: nil, table: nil)
    }

    /// Plans `day` at 6 AM and stores it as the morning plan.
    private func recordMorning(day: String = "2027-01-12", _ edit: (inout ForecastHour) -> Void = { _ in }) async throws -> PlannerDayRecord {
        let snapshot = snapshot(day: day, edit)
        let now = date("\(day)T14:00:00Z")
        let plan = try #require(await planner().plan(snapshot, location: location, settings: settings(), now: now))
        try archive.record(plan, hourly: snapshot.forecast!.hourly!, location: location, now: now)
        return try #require(try archive.load(locationID: location.id, day: date("\(day)T08:00:00Z"), calendar: pacific))
    }

    // MARK: Travel-time log

    @Test func logsOnTheQuarterHourThroughTheMorning() throws {
        // First chair at Baker is 9:00 AM, so mornings run 5:00 to 11:00 AM (13:00 to 19:00 UTC).
        #expect(TravelLogRules.window(on: date("2027-01-12T20:00:00Z"), location: location)
            == DateInterval(start: date("2027-01-12T13:00:00Z"), end: date("2027-01-12T19:00:00Z")))
        #expect(TravelLogRules.nextSample(after: date("2027-01-12T09:00:00Z"), location: location) == date("2027-01-12T13:00:00Z"))
        #expect(TravelLogRules.nextSample(after: date("2027-01-12T14:07:00Z"), location: location) == date("2027-01-12T14:15:00Z"))
        #expect(TravelLogRules.nextSample(after: date("2027-01-12T14:15:00Z"), location: location) == date("2027-01-12T14:30:00Z"))
        #expect(TravelLogRules.nextSample(after: date("2027-01-12T19:00:00Z"), location: location) == date("2027-01-13T13:00:00Z"))

        #expect(TravelLogRules.isDue(now: date("2027-01-12T14:15:00Z"), location: location, last: nil))
        #expect(TravelLogRules.isDue(now: date("2027-01-12T14:15:00Z"), location: location, last: date("2027-01-12T14:00:00Z")))
        #expect(!TravelLogRules.isDue(now: date("2027-01-12T14:15:00Z"), location: location, last: date("2027-01-12T14:08:00Z")))
        #expect(!TravelLogRules.isDue(now: date("2027-01-12T20:00:00Z"), location: location, last: nil))
    }

    @Test func modelLogsLiveDriveTimesWithTheDaysRecord() async throws {
        let model = PlannerModel(planner: planner(minutes: 85), archive: archive)
        let sample = try await model.logTravelTime(location: location, settings: settings(), now: date("2027-01-12T14:00:00Z"))
        #expect(sample == TravelSample(at: date("2027-01-12T14:00:00Z"), home: home.coordinate, driveTime: 85 * 60))
        // Too soon after the last sample, outside the morning, and without a home: nothing.
        #expect(try await model.logTravelTime(location: location, settings: settings(), now: date("2027-01-12T14:05:00Z")) == nil)
        #expect(try await model.logTravelTime(location: location, settings: settings(), now: date("2027-01-12T21:00:00Z")) == nil)
        #expect(try await model.logTravelTime(location: location, settings: settings(home: false), now: date("2027-01-12T14:30:00Z")) == nil)
        try await model.logTravelTime(location: location, settings: settings(), now: date("2027-01-12T14:15:00Z"))

        // The morning plan made afterwards keeps the samples, and a log-only day asks for no rating.
        let record = try await recordMorning()
        #expect(record.travelTimes.map(\.at) == [date("2027-01-12T14:00:00Z"), date("2027-01-12T14:15:00Z")])
        #expect(record.morning != nil)
        try await model.logTravelTime(location: location, settings: settings(), now: date("2027-01-13T14:00:00Z"))
        #expect(try archive.pendingRating(location: location, now: date("2027-01-14T01:00:00Z")) == nil)
    }

    @Test func recordsFromBeforeTheLogStillRead() throws {
        let json = #"{"locationID":"mt-baker","day":"2027-01-12T08:00:00Z","earlier":[]}"#
        let folder = archive.directory.appending(path: "mt-baker")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: folder.appending(path: "2027-01-12.json"))
        try Data("not json".utf8).write(to: folder.appending(path: "2027-01-13.json"))
        #expect(try archive.load(locationID: "mt-baker", day: date("2027-01-12T08:00:00Z"), calendar: pacific)?.travelTimes == [])
        let all = try archive.allRecords()
        #expect(all.records.map(\.day) == [date("2027-01-12T08:00:00Z")])
        #expect(all.warnings.count == 1)
        #expect(try PlannerArchive(directory: archive.directory.appending(path: "missing")).allRecords().records.isEmpty)
    }

    // MARK: Weights

    @Test func ratedDaysUseTheMorningWindowsFactors() async throws {
        var record = try await recordMorning()
        record.rating = DayRating(skied: true, groomed: 4, ratedAt: date("2027-01-13T01:00:00Z"))
        let groomed = WeightLearning.ratedDays([record], terrain: .groomed, gustThresholdMph: 45)
        // No new snow; cold, firm, calm and clear otherwise.
        #expect(groomed.map(\.factors) == [[0, 1, 1, 1, 1]])
        #expect(groomed.first?.rating == 4)
        #expect(WeightLearning.ratedDays([record], terrain: .ungroomed, gustThresholdMph: 45).isEmpty)

        record.rating = DayRating(skied: false, ratedAt: date("2027-01-13T01:00:00Z"))
        #expect(WeightLearning.ratedDays([record], terrain: .groomed, gustThresholdMph: 45).isEmpty)
    }

    @Test func projectsOntoWeightsThatSumToOne() {
        #expect(WeightLearning.projectToSimplex([0.2, 0.2, 0.2, 0.2, 0.2]) == [0.2, 0.2, 0.2, 0.2, 0.2])
        let projected = WeightLearning.projectToSimplex([0.9, 0.5, -0.3, 0.1, 0.1])
        #expect(abs(projected.reduce(0, +) - 1) < 1e-9)
        #expect(projected.allSatisfy { $0 >= 0 })
        #expect(projected[2] == 0)
    }

    /// Days whose factors vary pseudo-randomly, rated by `rate`.
    private func days(_ count: Int, rate: ([Double]) -> Double) -> [RatedDay] {
        var seed: UInt64 = 42
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        return (0..<count).map { index in
            let factors = (0..<5).map { _ in next() }
            let rating = Int(min(5, max(1, rate(factors).rounded())))
            return RatedDay(locationID: "mt-baker", day: date("2027-01-12T08:00:00Z").addingTimeInterval(Double(index) * 86400), factors: factors, rating: rating)
        }
    }

    @Test func learnsWeightsThatPredictTheUsersRatings() {
        // This user rates groomed days by the light alone.
        let rated = days(30) { 1 + 4 * $0[4] }
        let fit = WeightLearning.fit(rated, terrain: .groomed)
        #expect(fit.isLearned)
        #expect(fit.weights == fit.candidate)
        #expect(fit.learnedError! < fit.handTunedError!)
        let learned = fit.weights.factorWeights
        #expect(learned[4] > ScoreWeights.groomed.light + 0.1)
        #expect(abs(learned.reduce(0, +) - 1) < 0.01)
        // What learning leaves alone.
        #expect(fit.weights.ceiling == 85 && fit.weights.icySurface == ScoreWeights.groomed.icySurface)
    }

    @Test func keepsHandTunedWeightsWithoutEnoughDaysOrSignal() {
        let few = WeightLearning.fit(days(19) { 1 + 4 * $0[4] }, terrain: .groomed)
        #expect(!few.isLearned && few.candidate == nil && few.weights == .groomed && few.ratedDays == 19)

        // Ratings that follow the hand-tuned weights: learning can't do better.
        let prior = ScoreWeights.ungroomed.factorWeights
        let agreeing = WeightLearning.fit(days(30) { 1 + 4 * WeightLearning.dot(prior, $0) }, terrain: .ungroomed)
        #expect(!agreeing.isLearned)
        #expect(agreeing.weights == .ungroomed)
        #expect(agreeing.candidate != nil)
    }

    // MARK: Buffers

    @Test func observesReportedThenLoggedDrives() async throws {
        var record = try await recordMorning()
        // The planned groomed departure is 7:00 AM (15:00 UTC): 90 min drive, 10 min icy roads.
        record.travelTimes = [
            TravelSample(at: date("2027-01-12T14:30:00Z"), home: home.coordinate, driveTime: 95 * 60),
            TravelSample(at: date("2027-01-12T15:00:00Z"), home: home.coordinate, driveTime: 100 * 60),
        ]
        let logged = BufferTuning.observations([record], settings: settings())
        #expect(logged == [DriveObservation(
            locationID: location.id, day: record.day, condition: .freezing, drawsCrowd: false, isBusy: false,
            predicted: 90 * 60, observed: 100 * 60, source: .logged)])

        // Left at 7:00, on the lift at 9:00, less 20 min lot to lift: a 100 min drive.
        record.rating = DayRating(skied: true, groomed: 4, leftHomeAt: date("2027-01-12T15:00:00Z"), onLiftAt: date("2027-01-12T17:00:00Z"), ratedAt: date("2027-01-13T01:00:00Z"))
        record.travelTimes = []
        #expect(BufferTuning.observations([record], settings: settings()).map(\.source) == [.reported])
        // A reported drive that can't be right is ignored.
        record.rating?.onLiftAt = date("2027-01-12T22:00:00Z")
        #expect(BufferTuning.observations([record], settings: settings()).isEmpty)
    }

    private func drive(_ condition: RoadCondition, crowd: Bool = false, busy: Bool = false, excessMinutes: Double) -> DriveObservation {
        DriveObservation(locationID: "mt-baker", day: date("2027-01-12T08:00:00Z"), condition: condition, drawsCrowd: crowd, isBusy: busy,
                         predicted: 100 * 60, observed: (100 + excessMinutes) * 60, source: .logged)
    }

    @Test func tunesBuffersToMostObservedDrives() {
        let snowDays = [10.0, 20, 30, 40, 50].map { drive(.snow, excessMinutes: $0) }
        let crowdDays = [5.0, 10, 15, 20, 25].map { drive(.clear, crowd: true, excessMinutes: $0) }
        let fewIcy = [30.0, 30, 30, 30].map { drive(.freezing, excessMinutes: $0) }
        let tuned = BufferTuning.tune(snowDays + crowdDays + fewIcy)
        // The 75th percentile: 40 of 100 minutes on snow days, 20 minutes extra for crowds.
        #expect(tuned.buffers.snow == 0.4)
        #expect(tuned.buffers.crowd == 20 * 60)
        #expect(tuned.tuned == ["snow", "crowds"])
        // Four icy days aren't enough; weekend crowds have none.
        #expect(tuned.buffers.freezing == DriveBuffers.rule.freezing)
        #expect(tuned.buffers.busyCrowd == DriveBuffers.rule.busyCrowd)

        // A crowd day in snow counts only what the snow buffer doesn't cover.
        let snowyCrowds = [45.0, 50, 55, 60, 65].map { drive(.snow, crowd: true, busy: true, excessMinutes: $0) }
        #expect(BufferTuning.tune(snowDays + snowyCrowds).buffers.busyCrowd == 20 * 60)
        // Drives faster than Apple's estimate don't make a negative buffer.
        #expect(BufferTuning.tune([-10.0, -5, -5, -5, -1].map { drive(.heavySnow, excessMinutes: $0) }).buffers.heavySnow == 0)

        let groups = BufferTuning.groups(snowDays + crowdDays)
        #expect(groups.map(\.name) == ["snow", "crowd, weekday"])
        #expect(groups.map(\.medianExcess) == [30 * 60, 15 * 60])
    }

    // MARK: Planner

    @Test func plansWithLearnedWeightsAndBuffers() async throws {
        var learning = PlannerLearning.none
        learning.groomed.weights = ScoreWeights.groomed.replacingFactorWeights([0.5, 0.125, 0.125, 0.125, 0.125])
        learning.buffers.buffers.freezing = 0.3
        let plan = try #require(await planner().plan(snapshot(), location: location, settings: settings(), now: date("2027-01-12T14:00:00Z"), learning: learning))
        let day = try #require(plan.days.first)
        // No new snow now costs half the groomed score: 85 × 0.5.
        #expect(day.score.groomed?.averageScore == 43)
        #expect(day.score.ungroomed?.averageScore == 35)
        #expect(day.groomed?.drive.roadBuffer == TimeInterval(30 * 60))
    }

    @Test func modelRelearnsAfterARating() async throws {
        let model = PlannerModel(planner: planner(), archive: archive)
        let now = date("2027-01-12T14:00:00Z")
        try await model.update(snapshot: snapshot(), location: location, settings: settings(), now: now)
        #expect(model.learning.groomed.ratedDays == 0)
        let record = try #require(try archive.load(locationID: location.id, day: date("2027-01-12T08:00:00Z"), calendar: pacific))
        try model.rate(record, DayRating(skied: true, groomed: 4, ratedAt: now), location: location, now: now)
        try await model.update(snapshot: snapshot(), location: location, settings: settings(), now: now)
        #expect(model.learning.groomed.ratedDays == 1)
        #expect(model.learning.ungroomed.ratedDays == 0)
    }

    @Test func describesWhatHasBeenLearned() {
        var learning = PlannerLearning.none
        learning.groomed = WeightFit(terrain: .groomed, ratedDays: 24, weights: .groomed, isLearned: true)
        learning.ungroomed.ratedDays = 12
        learning.buffers.tuned = ["snow", "crowds"]
        learning.buffers.observations = Array(repeating: drive(.snow, excessMinutes: 0), count: 31)
        #expect(PlannerFormat.learning(learning) == "Groomed scores use weights learned from your 24 rated days. Ungroomed scores use the default weights until you've rated 20 days (12 so far). Drive buffers for snow and crowds are tuned from 31 drives.")
    }
}
