import Foundation

/// What the app shows for one location: its latest snapshot and how that snapshot came to be.
public struct LocationConditions: Equatable, Sendable {
    public var snapshot: ConditionsSnapshot?
    /// Why each metric failed in the location's most recent refresh this session.
    public var errors: [Metric: String]
    /// Problems worked around in the location's most recent refresh, per metric.
    public var warnings: [Metric: [String]]
    /// True while `snapshot` comes from the store and the location has not been refreshed this session.
    public var isShowingCached: Bool
    public var isRefreshing: Bool
}

/// Per-location snapshots for a session, backed by a `SnapshotStore`. Plain state with no
/// observation, so `ConditionsModel` on the Mac and the Android bridge share the cache rules.
public struct ConditionsCache: Sendable {
    private let store: SnapshotStore?
    private var snapshots: [String: ConditionsSnapshot] = [:]
    private var errors: [String: [Metric: String]] = [:]
    private var warnings: [String: [Metric: [String]]] = [:]
    private var refreshed: Set<String> = []
    private var inFlight: Set<String> = []

    public init(store: SnapshotStore?) {
        self.store = store
    }

    /// The location's snapshot from this session, or from the store when not yet loaded.
    public mutating func snapshot(for locationID: String) -> ConditionsSnapshot? {
        if let snapshot = snapshots[locationID] { return snapshot }
        let loaded = store?.load(locationID: locationID)
        snapshots[locationID] = loaded
        return loaded
    }

    public mutating func conditions(for locationID: String) -> LocationConditions {
        let snapshot = snapshot(for: locationID)
        return LocationConditions(
            snapshot: snapshot,
            errors: errors[locationID] ?? [:],
            warnings: warnings[locationID] ?? [:],
            isShowingCached: snapshot != nil && !refreshed.contains(locationID),
            isRefreshing: inFlight.contains(locationID))
    }

    /// Marks a refresh as running. Returns false when one is already running for the location,
    /// and the caller should not fetch.
    public mutating func beginRefresh(_ locationID: String) -> Bool {
        inFlight.insert(locationID).inserted
    }

    /// Records a finished refresh and saves its snapshot to the store.
    public mutating func finishRefresh(_ result: ConditionsResult) {
        let id = result.snapshot.locationID
        inFlight.remove(id)
        snapshots[id] = result.snapshot
        errors[id] = result.errors
        warnings[id] = result.warnings
        refreshed.insert(id)
        try? store?.save(result.snapshot)
    }
}
