import AppKit
import CoreLocation
import Network
import NotchlineCore
import os
import ServiceManagement

/// Owns the conditions model and decides when to refresh it: on a timer, on wake from sleep,
/// when the network comes back, and on location change. Plans ski days after each refresh and
/// schedules the planner's notifications. Also owns the notch window.
@MainActor
final class AppState: ObservableObject {
    static let selectedLocationKey = "selectedLocationID"
    static let pinToNotchKey = "pinToNotch"
    static let refreshMinutesKey = "refreshMinutes"
    static let unitsKey = "units"
    static let snowAlertKey = "snowAlert"
    static let lastSnowAlertKey = "lastSnowAlert"
    static let menuBarTitleKey = "menuBarTitle"
    static let plannerKey = "planner"

    static let refreshMinuteOptions = [15, 30, 60]

    let model: ConditionsModel
    let plannerModel: PlannerModel
    let plannerActions = PlannerActions()

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

    @Published var planner: PlannerSettings {
        didSet {
            do {
                defaults.set(try JSONEncoder().encode(planner), forKey: Self.plannerKey)
            } catch {
                logger.error("Could not save the planner settings: \(error, privacy: .public)")
            }
            if planner != oldValue { replanSoon() }
        }
    }

    /// Progress or failure of the last home address lookup, shown under the address field.
    @Published private(set) var homeLookupNote: String?

    /// Mirrors the login item's registration, which the system owns. The user can also remove it in System Settings.
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Set when macOS wants the login item approved in System Settings, or registering failed.
    @Published private(set) var launchAtLoginNote: String?

    private let notch: NotchController
    private let settingsWindow = SettingsWindowController()
    private let ratingWindow = RatingWindowController()
    private let notifier = PlannerNotifier()
    private var replanTask: Task<Void, Never>?
    private var travelLogTask: Task<Void, Never>?

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
        let archive: PlannerArchive?
        do {
            archive = try PlannerArchive.applicationSupport()
        } catch {
            archive = nil
            Logger(subsystem: "com.appdin.notchline", category: "planner").error("Planner archive unavailable: \(error)")
        }
        plannerModel = PlannerModel(planner: .live(), archive: archive)
        notch = NotchController(model: model, planner: plannerModel, actions: plannerActions)
        isPinned = defaults.object(forKey: Self.pinToNotchKey) as? Bool ?? true
        let minutes = defaults.integer(forKey: Self.refreshMinutesKey)
        refreshMinutes = Self.refreshMinuteOptions.contains(minutes) ? minutes : 30
        units = defaults.string(forKey: Self.unitsKey).flatMap(UnitPreference.init) ?? .automatic
        snowAlert = defaults.string(forKey: Self.snowAlertKey).flatMap(SnowAlertLevel.init) ?? .default
        menuBarTitle = defaults.string(forKey: Self.menuBarTitleKey).flatMap(MenuBarTitleStyle.init) ?? .conditions
        do {
            planner = try PlannerSettings.load(defaults.data(forKey: Self.plannerKey))
        } catch {
            planner = .default
            Logger(subsystem: "com.appdin.notchline", category: "refresh").error("Planner settings unreadable, using defaults: \(error, privacy: .public)")
        }
        schedule.interval = TimeInterval(refreshMinutes * 60)
        model.unitPreference = units
        notch.setPinned(isPinned)
        updateLaunchAtLoginNote()
        plannerActions.appState = self
        notifier.onOpen = { [weak self] kind, locationID, day in self?.openNotification(kind, locationID: locationID, day: day) }

        observeWake()
        observeNetwork()
        refreshNow()
    }

    func select(_ locationID: String) {
        guard locationID != model.location.id else { return }
        model.select(locationID)
        defaults.set(model.location.id, forKey: Self.selectedLocationKey)
        plannerModel.clear()
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

    /// Opens the rating window for a day the planner scored.
    func showRating(_ record: PlannerDayRecord) {
        guard let location = model.catalog.location(id: record.locationID) else { return }
        ratingWindow.show(record: record, location: location) { [weak self] rating in
            self?.saveRating(rating, for: record, location: location)
        }
    }

    /// "No" to "Did you ski today?", which stops the planner asking about that day.
    func dismissRating(_ record: PlannerDayRecord) {
        guard let location = model.catalog.location(id: record.locationID) else { return }
        saveRating(.didNotSki(at: Date()), for: record, location: location)
    }

    private func saveRating(_ rating: DayRating, for record: PlannerDayRecord, location: Location) {
        do {
            try plannerModel.rate(record, rating, location: location)
            logger.info("\(record.locationID, privacy: .public) rated: skied \(rating.skied), groomed \(rating.groomed ?? 0), ungroomed \(rating.ungroomed ?? 0)")
        } catch {
            logger.error("Could not save the rating: \(error, privacy: .public)")
        }
        // The rating question for that day is no longer needed.
        replanSoon()
    }

    private func openNotification(_ kind: PlannerNotification.Kind, locationID: String, day: Date) {
        switch kind {
        case .rating:
            guard let location = model.catalog.location(id: locationID) else { return }
            do {
                guard let record = try plannerModel.record(location: location, day: day), record.rating == nil else { return }
                showRating(record)
            } catch {
                logger.error("Could not read the day to rate: \(error, privacy: .public)")
            }
        case .summary, .departure:
            if locationID != model.location.id { select(locationID) }
            notch.showAlert()
        }
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

    /// Geocodes `address` with Apple's geocoder and stores it as home. An empty address clears home.
    func setHome(address: String) {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            planner.home = nil
            homeLookupNote = nil
            return
        }
        guard address != planner.home?.address else { return }
        homeLookupNote = "Looking up address…"
        Task {
            do {
                planner.home = try await HomeGeocoder.geocode(address)
                homeLookupNote = nil
            } catch {
                logger.notice("Home address lookup failed: \(error, privacy: .public)")
                homeLookupNote = "Could not find that address. Home is unchanged."
            }
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
        await replan()
    }

    /// Replans shortly after a settings change, so stepping through values plans once.
    private func replanSoon() {
        replanTask?.cancel()
        replanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.replan()
        }
    }

    /// Plans the selected location from its snapshot and replaces the pending notifications.
    private func replan() async {
        let location = model.location
        scheduleTravelLog()
        guard planner.isEnabled else {
            plannerModel.clear()
            await notifier.removeAll()
            return
        }
        guard let snapshot = model.snapshot, snapshot.locationID == location.id else { return }
        guard let plan = await plannerModel.update(snapshot: snapshot, location: location, settings: planner) else {
            if snapshot.forecast?.hourly == nil {
                logger.notice("\(location.id, privacy: .public) planner: no hourly forecast to plan from")
            }
            return
        }
        for warning in plan.warnings {
            logger.info("\(location.id, privacy: .public) planner warning: \(warning, privacy: .public)")
        }
        let now = Date()
        var today: PlannerDayRecord?
        do {
            today = try plannerModel.todayRecord(location: location, now: now)
        } catch {
            logger.error("Could not read today's plan record: \(error, privacy: .public)")
        }
        await notifier.replace(with: PlannerNotifications.schedule(plan, today: today, location: location, settings: planner, now: now))
    }

    /// Wakes at the next quarter hour of the selected location's morning to log Apple's live drive
    /// time. Rescheduled by every replan, so a location or settings change takes effect. Sleep
    /// skips samples; the first wakeup after it samples if the morning is still on.
    private func scheduleTravelLog() {
        travelLogTask?.cancel()
        guard planner.isEnabled, planner.home != nil else { return }
        let location = model.location
        guard let next = TravelLogRules.nextSample(after: Date(), location: location) else { return }
        travelLogTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            await self?.logTravelTime()
        }
    }

    private func logTravelTime() async {
        let location = model.location
        do {
            if let sample = try await plannerModel.logTravelTime(location: location, settings: planner) {
                logger.info("\(location.id, privacy: .public) drive time now: \(Int(sample.driveTime / 60)) min")
            }
        } catch {
            logger.notice("\(location.id, privacy: .public) travel-time log: \(error, privacy: .public)")
        }
        scheduleTravelLog()
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

/// What the notch's planner section can ask of the app. The notch is built before AppState
/// finishes initializing, so it reaches AppState through this.
@MainActor
final class PlannerActions {
    weak var appState: AppState?

    func rate(_ record: PlannerDayRecord) {
        appState?.showRating(record)
    }

    func didNotSki(_ record: PlannerDayRecord) {
        appState?.dismissRating(record)
    }

    func showSettings() {
        appState?.showSettings()
    }
}

/// Forward geocoding through CLGeocoder, which sends the address to Apple. Needs no location permission.
enum HomeGeocoder {
    static func geocode(_ address: String) async throws -> Home {
        try await withCheckedThrowingContinuation { continuation in
            CLGeocoder().geocodeAddressString(address) { placemarks, error in
                guard let placemark = placemarks?.first, let coordinate = placemark.location?.coordinate else {
                    continuation.resume(throwing: error ?? CLError(.geocodeFoundNoResult))
                    return
                }
                let matched = [placemark.name, placemark.locality, placemark.administrativeArea]
                    .compactMap { $0 }
                    .reduce(into: [String]()) { parts, part in if !parts.contains(part) { parts.append(part) } }
                    .joined(separator: ", ")
                continuation.resume(returning: Home(
                    address: address,
                    matchedName: matched.isEmpty ? nil : matched,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude))
            }
        }
    }
}
