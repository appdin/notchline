import AppKit
import NotchlineCore
import SwiftUI

/// The Settings window. Every setting applies immediately and persists in UserDefaults through AppState.
struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var model: ConditionsModel
    @ObservedObject var plannerModel: PlannerModel
    @State private var homeAddress = ""

    var body: some View {
        Form {
            Section {
                locationPicker
                Picker("Refresh every", selection: $appState.refreshMinutes) {
                    ForEach(AppState.refreshMinuteOptions, id: \.self) { Text("\($0) minutes").tag($0) }
                }
                Picker("Units", selection: $appState.units) {
                    Text("Automatic (\(unitsName(model.location.defaultUnits)))").tag(UnitPreference.automatic)
                    Text("Imperial (in, °F, mph)").tag(UnitPreference.imperial)
                    Text("Metric (cm, °C, km/h)").tag(UnitPreference.metric)
                }
            }
            Section {
                Toggle("Pin to notch", isOn: $appState.isPinned)
                Picker("New snow alert", selection: $appState.snowAlert) {
                    ForEach(SnowAlertLevel.allCases, id: \.self) { level in
                        Text(alertName(level)).tag(level)
                    }
                }
                Picker("Menu bar shows", selection: $appState.menuBarTitle) {
                    Text("Conditions").tag(MenuBarTitleStyle.conditions)
                    Text("Icon only").tag(MenuBarTitleStyle.iconOnly)
                }
            } footer: {
                Text("A new snow alert expands the notch for a few seconds when the last 24 hours of snow reach the amount.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            plannerSection
            Section {
                Toggle("Launch at login", isOn: Binding(get: { appState.launchAtLogin }, set: { appState.setLaunchAtLogin($0) }))
                if let note = appState.launchAtLoginNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { homeAddress = appState.planner.home?.address ?? "" }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var plannerSection: some View {
        Section {
            Toggle("Ski day planner", isOn: $appState.planner.isEnabled)
            if appState.planner.isEnabled {
                TextField("Home", text: $homeAddress, prompt: Text("Street address or town"))
                    .onSubmit { appState.setHome(address: homeAddress) }
                if let note = appState.homeLookupNote ?? appState.planner.home?.matchedName.map({ "Found: \($0)" }) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Stepper(value: locationSetting(\.arrivalToLiftMinutes), in: 5...120, step: 5) {
                    Text("Lot to lift at \(model.location.shortName): \(appState.planner.settings(for: model.location.id).arrivalToLiftMinutes) min")
                }
                Toggle("Overnight parking at \(model.location.shortName)", isOn: locationSetting(\.overnightParkingAllowed))
                Picker("Lifts close in gusts over", selection: $appState.planner.gustThresholdMph) {
                    ForEach(PlannerSettings.gustThresholdOptionsMph, id: \.self) { mph in
                        Text("\(ConditionsFormat.speed(mph, model.units)) \(ConditionsFormat.windUnit(model.units))").tag(mph)
                    }
                }
                Picker("Notify for days scoring", selection: $appState.planner.notificationScoreThreshold) {
                    ForEach(PlannerSettings.notificationScoreThresholdOptions, id: \.self) { Text("\($0) or more").tag($0) }
                }
                DatePicker("Evening summary at", selection: eveningSummaryTime, displayedComponents: .hourAndMinute)
                Picker("Remind me before leaving", selection: $appState.planner.departureReminderLeadMinutes) {
                    ForEach(PlannerSettings.departureReminderLeadOptions, id: \.self) { Text("\($0) minutes").tag($0) }
                }
            }
        } footer: {
            if appState.planner.isEnabled {
                Text("Press Return to look up home. It stays on this Mac and is sent only to Apple Maps. Lot to lift covers parking, gearing up and getting onto the first chair.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(PlannerFormat.learning(plannerModel.learning)) Each morning the planner logs Apple Maps' drive time from home every 15 minutes while this Mac is awake.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// A binding to one of the selected location's planner settings.
    private func locationSetting<Value>(_ keyPath: WritableKeyPath<LocationPlannerSettings, Value>) -> Binding<Value> {
        let id = model.location.id
        return Binding(
            get: { appState.planner.settings(for: id)[keyPath: keyPath] },
            set: { value in appState.planner.update(id) { $0[keyPath: keyPath] = value } })
    }

    /// The summary time as a Date today, which is what DatePicker edits.
    private var eveningSummaryTime: Binding<Date> {
        Binding(
            get: { appState.planner.eveningSummaryTime.date(on: Date(), calendar: .current) },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                if let time = ClockTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0) {
                    appState.planner.eveningSummaryTime = time
                }
            })
    }

    private var locationPicker: some View {
        let groups = model.catalog.byRegion
        return Picker("Location", selection: Binding(get: { model.location.id }, set: { appState.select($0) })) {
            ForEach(groups.indices, id: \.self) { index in
                Section(groups[index].region) {
                    ForEach(groups[index].locations) { location in
                        Text(location.name).tag(location.id)
                    }
                }
            }
        }
    }

    private func unitsName(_ units: UnitSystem) -> String {
        units == .metric ? "metric" : "imperial"
    }

    private func alertName(_ level: SnowAlertLevel) -> String {
        guard let inches = level.thresholdInches(model.units) else { return "Off" }
        return ConditionsFormat.snow(inches, model.units) + " in 24 hours"
    }
}

/// Hosts SettingsView in its own window. A menu bar agent has no Settings menu item, and SwiftUI's
/// Settings scene cannot be opened the same way on macOS 13 and 14, so the app manages the window.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(appState: AppState) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(appState: appState, model: appState.model, plannerModel: appState.plannerModel)))
            window.title = "Notchline Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
