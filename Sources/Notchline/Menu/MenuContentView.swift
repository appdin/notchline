import NotchlineCore
import SwiftUI

/// The menu bar dropdown: conditions summary, location picker and actions.
struct MenuContentView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var model: ConditionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                ConditionsSummaryView(model: model, now: context.date)
            }
            Divider()
            locationPicker
            pinToggle
            actions
        }
        .padding(14)
        .frame(width: 360)
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
        .pickerStyle(.menu)
    }

    private var pinToggle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Pin to notch", isOn: $appState.isPinned)
            if appState.isPinned && !NotchController.hasNotchedScreen {
                Text("No display with a notch is connected. Conditions stay in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actions: some View {
        HStack {
            Button {
                appState.refreshNow()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRefreshing)
            .keyboardShortcut("r")

            if let url = model.snapshot?.danger?.forecastURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Avalanche forecast", systemImage: "arrow.up.right.square")
                }
            }

            Spacer()

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

/// Menu bar title: short name plus base depth and danger, for example `Baker 61" 3`.
struct MenuBarLabel: View {
    @ObservedObject var model: ConditionsModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "snowflake")
            Text(title)
        }
    }

    private var title: String {
        var parts = [model.location.shortName]
        if let depth = model.snapshot?.observed?.depthInches {
            parts.append(ConditionsFormat.snow(depth, model.location.defaultUnits))
        }
        if let danger = model.snapshot?.danger(at: Date())?.overall, danger != .noRating {
            parts.append("⚠\(danger.rawValue)")
        }
        return parts.joined(separator: " ")
    }
}
