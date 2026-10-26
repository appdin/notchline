#if canImport(Combine)
import Combine
import Foundation

/// The selected location's ski day plan and the archive behind ratings. Free of UI and
/// notifications so it can be tested; the app decides when to plan.
@MainActor
public final class PlannerModel: ObservableObject {
    @Published public private(set) var plan: SkiDayPlan?
    /// The location `plan` is for.
    @Published public private(set) var locationID: String?
    @Published public private(set) var isPlanning = false

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
                result?.warnings.append("Could not save the forecast scores for ratings (\(error))")
            }
        }
        isPlanning = false
        plan = result
        return result
    }

    /// Drops the plan, for a location change or the planner being turned off.
    public func clear() {
        generation += 1
        plan = nil
        locationID = nil
        isPlanning = false
    }

    /// Today and the days before it at the location, newest first, for the user to pick one to rate.
    /// Empty without an archive.
    public func recentDays(location: Location, now: Date = Date()) throws -> [PlannerDayRecord] {
        try archive?.recentDays(location: location, now: now) ?? []
    }

    /// Stores the rating on the day's record, replacing any rating already there.
    public func rate(_ record: PlannerDayRecord, _ rating: DayRating, location: Location) throws {
        try archive?.rate(record, rating, calendar: location.calendar)
    }
}
#endif
