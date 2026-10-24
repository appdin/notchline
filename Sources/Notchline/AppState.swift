import AppKit
import Network
import NotchlineCore
import os

/// Owns the conditions model and decides when to refresh it: on a timer, on wake from sleep,
/// when the network comes back, and on location change. Also owns the notch window.
@MainActor
final class AppState: ObservableObject {
    static let selectedLocationKey = "selectedLocationID"
    static let pinToNotchKey = "pinToNotch"

    let model: ConditionsModel

    /// Show the compact conditions beside the notch. On by default.
    @Published var isPinned: Bool {
        didSet {
            defaults.set(isPinned, forKey: Self.pinToNotchKey)
            notch.setPinned(isPinned)
        }
    }

    private let notch: NotchController

    private let schedule = RefreshSchedule()
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.appdin.notchline", category: "refresh")
    private var consecutiveFailures = 0
    private var timer: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private var networkWasDown = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let catalog: LocationCatalog
        do {
            catalog = try LocationCatalog.bundled()
        } catch {
            fatalError("locations.json is missing from the app bundle: \(error)")
        }
        let store: SnapshotStore?
        do {
            store = try SnapshotStore.applicationSupport()
        } catch {
            store = nil
            Logger(subsystem: "com.appdin.notchline", category: "refresh").error("Snapshot cache unavailable: \(error)")
        }
        model = ConditionsModel(catalog: catalog, selectedID: defaults.string(forKey: Self.selectedLocationKey), store: store)
        notch = NotchController(model: model)
        isPinned = defaults.object(forKey: Self.pinToNotchKey) as? Bool ?? true
        notch.setPinned(isPinned)

        observeWake()
        observeNetwork()
        refreshNow()
    }

    func select(_ locationID: String) {
        guard locationID != model.location.id else { return }
        model.select(locationID)
        defaults.set(model.location.id, forKey: Self.selectedLocationKey)
        consecutiveFailures = 0
        refreshNow()
    }

    func refreshNow() {
        Task { await refresh() }
    }

    private func refresh() async {
        // nil means a refresh for this location is already running; it schedules the next one.
        guard let result = await model.refresh() else { return }
        for (metric, error) in result.errors.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            logger.notice("\(result.snapshot.locationID, privacy: .public) \(metric.rawValue, privacy: .public): \(error, privacy: .public)")
        }
        for (metric, messages) in result.warnings.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            for message in messages {
                logger.info("\(result.snapshot.locationID, privacy: .public) \(metric.rawValue, privacy: .public) warning: \(message, privacy: .public)")
            }
        }
        consecutiveFailures = result.failedMetrics.isEmpty ? 0 : consecutiveFailures + 1
        scheduleNext()
    }

    private func scheduleNext() {
        timer?.cancel()
        let delay = schedule.delay(afterConsecutiveFailures: consecutiveFailures)
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
    }

    private func observeNetwork() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(satisfied: satisfied) }
        }
        pathMonitor.start(queue: .main)
    }

    private func networkChanged(satisfied: Bool) {
        if satisfied && networkWasDown {
            consecutiveFailures = 0
            refreshNow()
        }
        networkWasDown = !satisfied
    }
}
