import Combine
import Foundation

/// The selected location's ski day plan, the day waiting for a rating, what the planner has
/// learned, and the morning travel-time log. Free of UI and notifications so it can be tested;
/// the app decides when to plan and when to log.
@MainActor
public final class PlannerModel: ObservableObject {
    @Published public private(set) var plan: SkiDayPlan?
    /// The location `plan` is for.
    @Published public private(set) var locationID: String?
    @Published public private(set) var isPlanning = false
    /// The day to ask "Did you ski?" about, if any.
    @Published public private(set) var pendingRating: PlannerDayRecord?
    /// Weights and buffers learned from the archive, relearned once a day, after a rating, and when settings change.
    @Published public private(set) var learning = PlannerLearning.none

    private let planner: SkiDayPlanner
    private let archive: PlannerArchive?
    /// Bumped by each update and clear, so a slow plan never replaces a newer one.
    private var generation = 0
    /// What `learning` was learned for; nil to relearn on the next plan.
    private var learnedFor: LearningKey?
    /// Bumped by each rating, so a relearn that started before it doesn't count as current.
    private var ratingsSaved = 0

    private struct LearningKey: Equatable {
        var day: Date
        var settings: PlannerSettings
    }

    public init(planner: SkiDayPlanner, archive: PlannerArchive?) {
        self.planner = planner
        self.archive = archive
    }

    /// Plans from `snapshot` and records the result in the archive. Returns nil when the snapshot
    /// has no hourly forecast or a newer update or clear superseded this one. A failure to record
    /// becomes a warning on the plan.
    @discardableResult
    public func update(snapshot: ConditionsSnapshot, location: Location, settings: PlannerSettings, now: Date = Date()) async -> SkiDayPlan? {
        generation += 1
        let current = generation
        if locationID != location.id {
            plan = nil
            locationID = location.id
        }
        isPlanning = true
        await relearnIfStale(settings: settings, now: now)
        guard current == generation else { return nil }
        var result = await planner.plan(snapshot, location: location, settings: settings, now: now, learning: learning)
        guard current == generation else { return nil }
        if let plan = result, let hourly = snapshot.forecast?.hourly {
            do {
                try archive?.record(plan, hourly: hourly, location: location, now: now)
            } catch {
                result?.warnings.append("Could not save the plan for ratings (\(error))")
            }
        }
        isPlanning = false
        plan = result
        do {
            try refreshPendingRating(location: location, now: now)
        } catch {
            result?.warnings.append("Could not read the day to rate (\(error))")
            plan = result
        }
        return result
    }

    /// Drops the plan, for a location change or the planner being turned off.
    public func clear() {
        generation += 1
        plan = nil
        locationID = nil
        isPlanning = false
        pendingRating = nil
    }

    /// Clears the question when the record can't be read, then throws.
    public func refreshPendingRating(location: Location, now: Date = Date()) throws {
        pendingRating = nil
        pendingRating = try archive?.pendingRating(location: location, now: now)
    }

    /// Today's stored record for the location, which the rating notification goes by.
    public func todayRecord(location: Location, now: Date = Date()) throws -> PlannerDayRecord? {
        try archive?.load(locationID: location.id, day: location.calendar.startOfDay(for: now), calendar: location.calendar)
    }

    public func record(location: Location, day: Date) throws -> PlannerDayRecord? {
        try archive?.load(locationID: location.id, day: day, calendar: location.calendar)
    }

    public func rate(_ record: PlannerDayRecord, _ rating: DayRating, location: Location, now: Date = Date()) throws {
        try archive?.rate(record, rating, calendar: location.calendar)
        learnedFor = nil
        ratingsSaved += 1
        try refreshPendingRating(location: location, now: now)
    }

    /// Samples Apple's live drive time from home when the morning log is due and stores it with
    /// the day's record. Returns the sample, or nil when none was due.
    @discardableResult
    public func logTravelTime(location: Location, settings: PlannerSettings, now: Date = Date()) async throws -> TravelSample? {
        guard settings.isEnabled, let home = settings.home, let archive else { return nil }
        let today = location.calendar.startOfDay(for: now)
        let last = try archive.load(locationID: location.id, day: today, calendar: location.calendar)?.travelTimes.last?.at
        guard TravelLogRules.isDue(now: now, location: location, last: last) else { return nil }
        let driveTime = try await planner.travel.travelTime(from: home.coordinate, to: location.coordinate, departingAt: now)
        let sample = TravelSample(at: now, home: home.coordinate, driveTime: driveTime)
        try archive.log(sample, location: location)
        return sample
    }

    /// Relearns from every stored record, off the main actor, when the day or settings changed
    /// or a rating came in since the last time.
    private func relearnIfStale(settings: PlannerSettings, now: Date) async {
        let key = LearningKey(day: Calendar.current.startOfDay(for: now), settings: settings)
        guard let archive, learnedFor != key else { return }
        let started = ratingsSaved
        learning = await Task.detached(priority: .utility) {
            do {
                let (records, warnings) = try archive.allRecords()
                var learned = PlannerLearning.learn(records, settings: settings)
                learned.warnings = warnings
                return learned
            } catch {
                var learned = PlannerLearning.none
                learned.warnings = ["Could not read rated days (\(error)); scores and buffers use the defaults"]
                return learned
            }
        }.value
        if ratingsSaved == started { learnedFor = key }
    }
}
