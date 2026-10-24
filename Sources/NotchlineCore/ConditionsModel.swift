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

    private let service: ConditionsService
    private let store: SnapshotStore?
    private var snapshots: [String: ConditionsSnapshot] = [:]
    private var errorsByLocation: [String: [Metric: String]] = [:]
    private var warningsByLocation: [String: [Metric: [String]]] = [:]
    private var refreshed: Set<String> = []
    private var inFlight: Set<String> = []

    public init(catalog: LocationCatalog, selectedID: String?, service: ConditionsService = ConditionsService(), store: SnapshotStore? = nil) {
        self.catalog = catalog
        self.service = service
        self.store = store
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
        guard !inFlight.contains(location.id) else { return nil }
        inFlight.insert(location.id)
        isRefreshing = true

        let result = await service.refresh(location, previous: cached(location.id), now: now)
        inFlight.remove(location.id)
        snapshots[location.id] = result.snapshot
        errorsByLocation[location.id] = result.errors
        warningsByLocation[location.id] = result.warnings
        refreshed.insert(location.id)
        try? store?.save(result.snapshot)
        if location.id == self.location.id {
            showSelected()
        }
        return result
    }

    private func cached(_ id: String) -> ConditionsSnapshot? {
        if let snapshot = snapshots[id] { return snapshot }
        let loaded = store?.load(locationID: id)
        snapshots[id] = loaded
        return loaded
    }

    private func showSelected() {
        snapshot = cached(location.id)
        errors = errorsByLocation[location.id] ?? [:]
        warnings = warningsByLocation[location.id] ?? [:]
        isShowingCached = snapshot != nil && !refreshed.contains(location.id)
        isRefreshing = inFlight.contains(location.id)
    }
}
