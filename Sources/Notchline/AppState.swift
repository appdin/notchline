import AppKit
import Network
import NotchlineCore
import os
import ServiceManagement

/// Owns the conditions model and decides when to refresh it: on a timer, on wake from sleep,
/// when the network comes back, and on location change. Also owns the notch window.
@MainActor
final class AppState: ObservableObject {
    static let selectedLocationKey = "selectedLocationID"
    static let pinToNotchKey = "pinToNotch"
    static let refreshMinutesKey = "refreshMinutes"
    static let unitsKey = "units"
    static let snowAlertKey = "snowAlert"
    static let lastSnowAlertKey = "lastSnowAlert"
    static let menuBarTitleKey = "menuBarTitle"

    static let refreshMinuteOptions = [15, 30, 60]

    let model: ConditionsModel

    /// Show the compact conditions beside the notch. On by default.
    @Published var isPinned: Bool {
        didSet {
            defaults.set(isPinned, forKey: Self.pinToNotchKey)
            notch.setPinned(isPinned)
        }
    }

    @Published var refreshMinutes: Int {
        didSet {
            defaults.set(refreshMinutes, forKey: Self.refreshMinutesKey)
            schedule.interval = TimeInterval(refreshMinutes * 60)
            scheduleNext()
        }
    }

    @Published var units: UnitPreference {
        didSet {
            defaults.set(units.rawValue, forKey: Self.unitsKey)
            model.unitPreference = units
        }
    }

    @Published var snowAlert: SnowAlertLevel {
        didSet { defaults.set(snowAlert.rawValue, forKey: Self.snowAlertKey) }
    }

    @Published var menuBarTitle: MenuBarTitleStyle {
        didSet { defaults.set(menuBarTitle.rawValue, forKey: Self.menuBarTitleKey) }
    }

    /// Mirrors the login item's registration, which the system owns. The user can also remove it in System Settings.
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Set when macOS wants the login item approved in System Settings, or registering failed.
    @Published private(set) var launchAtLoginNote: String?

    private let notch: NotchController
    private let settingsWindow = SettingsWindowController()

    private var schedule = RefreshSchedule()
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
        let minutes = defaults.integer(forKey: Self.refreshMinutesKey)
        refreshMinutes = Self.refreshMinuteOptions.contains(minutes) ? minutes : 30
        units = defaults.string(forKey: Self.unitsKey).flatMap(UnitPreference.init) ?? .automatic
        snowAlert = defaults.string(forKey: Self.snowAlertKey).flatMap(SnowAlertLevel.init) ?? .default
        menuBarTitle = defaults.string(forKey: Self.menuBarTitleKey).flatMap(MenuBarTitleStyle.init) ?? .conditions
        schedule.interval = TimeInterval(refreshMinutes * 60)
        model.unitPreference = units
        notch.setPinned(isPinned)
        updateLaunchAtLoginNote()

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

    func showSettings() {
        settingsWindow.show(appState: self)
    }

    func showAbout() {
        AboutPanel.show()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            updateLaunchAtLoginNote()
        } catch {
            logger.error("Launch at login \(enabled ? "register" : "unregister", privacy: .public) failed: \(error, privacy: .public)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchAtLoginNote = "Could not change launch at login: \(error.localizedDescription)"
        }
    }

    private func updateLaunchAtLoginNote() {
        launchAtLoginNote = SMAppService.mainApp.status == .requiresApproval
            ? "Approve Notchline in System Settings > General > Login Items."
            : nil
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
        alertOnNewSnow(result.snapshot)
        scheduleNext()
    }

    /// Expands the notch for a few seconds when new snow passes the alert threshold.
    private func alertOnNewSnow(_ snapshot: ConditionsSnapshot) {
        guard snapshot.locationID == model.location.id else { return }
        let last = defaults.data(forKey: Self.lastSnowAlertKey).flatMap { try? JSONDecoder().decode(SnowAlert.self, from: $0) }
        guard let alert = SnowAlert.check(snapshot, thresholdInches: snowAlert.thresholdInches(model.units), last: last, now: Date()) else { return }
        do {
            defaults.set(try JSONEncoder().encode(alert), forKey: Self.lastSnowAlertKey)
        } catch {
            logger.error("Could not save the snow alert: \(error, privacy: .public)")
        }
        logger.info("\(snapshot.locationID, privacy: .public) new snow alert: \(alert.snow24hInches) in")
        notch.showAlert()
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
