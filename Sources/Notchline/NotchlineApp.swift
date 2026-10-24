import SwiftUI
import NotchlineCore

// Menu bar agent. AppState also puts the conditions beside the notch when pinned.
@main
struct NotchlineApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(appState: appState, model: appState.model)
        } label: {
            MenuBarLabel(model: appState.model, style: appState.menuBarTitle)
        }
        .menuBarExtraStyle(.window)
    }
}
