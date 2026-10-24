import SwiftUI
import NotchlineCore

// Menu bar agent. The notch arrives in Phase 3.
@main
struct NotchlineApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(appState: appState, model: appState.model)
        } label: {
            MenuBarLabel(model: appState.model)
        }
        .menuBarExtraStyle(.window)
    }
}
