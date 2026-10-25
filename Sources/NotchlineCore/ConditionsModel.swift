#if canImport(Combine)
import Combine
import Foundation

/// Conditions for the selected location, backed by a per-location snapshot cache. Free of UI and
/// timers so location switching and refresh merging are unit tested; the app schedules refreshes.
@MainActor
public final class ConditionsModel: ObservableObject {
    public let catalog: LocationCatalog
    @Published public private(set) var location: Location
    @Published public private(set) var snapshot: ConditionsSnapshot?
    /// Why each metric failed in the selected location's most recent refresh this session.
    @Published public private(set) var errors: [Metric: String] = [:]
    /// Problems worked around in the selected location's most recent refresh, per metric.
    @Published public private(set) var warnings: [Metric: [String]] = [:]
    /// True while `snapshot` comes from the cache and the location has not been refreshed this session.
    @Published public private(set) var isShowingCached = false
    @Published public private(set) var isRefreshing = false
    /// Units picked in Settings. Views read `units`, which resolves automatic for the selected location.
    @Published public var unitPreference: UnitPreference = .automatic

    public var units: UnitSystem { unitPreference.resolve(for: location) }

    /// The selected location's conditions as one value, for `ConditionsSummary`.
    public var conditions: LocationConditions {
        LocationConditions(snapshot: snapshot, errors: errors, warnings: warnings, isShowingCached: isShowingCached, isRefreshing: isRefreshing)
    }

    private let service: ConditionsService
    private var cache: ConditionsCache

    public init(catalog: LocationCatalog, selectedID: String?, service: ConditionsService = ConditionsService(), store: SnapshotStore? = nil) {
        self.catalog = catalog
        self.service = service
        cache = ConditionsCache(store: store)
        location = catalog.resolve(id: selectedID)
        showSelected()
    }

    /// Switches to another location and shows its cached snapshot, if any. Unknown IDs are ignored.
    public func select(_ id: String) {
        guard id != location.id, let next = catalog.location(id: id) else { return }
        location = next
        showSelected()
    }

    /// Refreshes the selected location and saves the result. Returns nil without fetching when a
    /// refresh for that location is already running.
    @discardableResult
    public func refresh(now: Date = Date()) async -> ConditionsResult? {
        let location = location
        guard cache.beginRefresh(location.id) else { return nil }
        isRefreshing = true

        let result = await service.refresh(location, previous: cache.snapshot(for: location.id), now: now)
        cache.finishRefresh(result)
        if location.id == self.location.id {
            showSelected()
        }
        return result
    }

    private func showSelected() {
        let conditions = cache.conditions(for: location.id)
        snapshot = conditions.snapshot
        errors = conditions.errors
        warnings = conditions.warnings
        isShowingCached = conditions.isShowingCached
        isRefreshing = conditions.isRefreshing
    }
}
#endif
