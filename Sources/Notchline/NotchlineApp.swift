import SwiftUI
import NotchlineCore

// Placeholder shell so the bundle, signing and LSUIElement setup can be verified.
// The real menu bar UI arrives in Phase 2 and the notch in Phase 3.
@main
struct NotchlineApp: App {
    var body: some Scene {
        MenuBarExtra("Notchline", systemImage: "snowflake") {
            Text("Notchline \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
