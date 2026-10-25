#if canImport(Combine)
import Combine
import Foundation

/// The selected location's ski day plan and the day waiting for a rating. Free of UI and
/// notifications so it can be tested; the app decides when to plan.
@MainActor
public final class PlannerModel: ObservableObject {
    @Published public private(set) var plan: SkiDayPlan?
    /// The location `plan` is for.
    @Published public private(set) var locationID: String?
    @Published public private(set) var isPlanning = false
    /// The day to ask "Did you ski?" about, if any.
    @Published public private(set) var pendingRating: PlannerDayRecord?

    private let planner: SkiDayPlanner
    private let archive: PlannerArchive?
    /// Bumped by each update and clear, so a slow plan never replaces a newer one.
    private var generation = 0

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
        var result = await planner.plan(snapshot, location: location, settings: settings, now: now)
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
        try refreshPendingRating(location: location, now: now)
    }
}
#endif
