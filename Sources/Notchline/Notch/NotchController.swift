import AppKit
import Combine
import DynamicNotchKit
import NotchlineCore

/// Owns the app's one notch window. While pinned it sits compact beside the notch, expands on
/// hover and returns to compact when the pointer leaves. The views observe the model, so
/// refreshes and location changes update the notch without rebuilding it.
@MainActor
final class NotchController {
    private typealias Notch = DynamicNotch<NotchExpandedView, NotchCompactLeadingView, NotchCompactTrailingView>

    /// Hover has to last this long before the notch expands, so passing through the menu bar does not open it.
    private static let expandDelay: Duration = .milliseconds(150)
    /// Grace period after the pointer leaves, so brief exits at the edge do not collapse it.
    private static let collapseDelay: Duration = .milliseconds(350)
    /// How long a new snow alert keeps the notch expanded.
    private static let alertDuration: Duration = .seconds(6)

    private let notch: Notch
    private var isPinned = false
    private var hoverTask: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []

    init(model: ConditionsModel, planner: PlannerModel, actions: PlannerActions) {
        notch = Notch(hoverBehavior: [.keepVisible, .increaseShadow], style: .auto) {
            NotchExpandedView(model: model, planner: planner, actions: actions)
        } compactLeading: {
            NotchCompactLeadingView(model: model)
        } compactTrailing: {
            NotchCompactTrailingView(model: model)
        }
        // Going straight between compact and expanded avoids a hidden step that ends the hover.
        notch.transitionConfiguration = DynamicNotchTransitionConfiguration(skipIntermediateHides: true)

        notch.$isHovering
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] hovering in self?.hoverChanged(hovering) }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.screensChanged() }
            .store(in: &subscriptions)
    }

    /// True when some display has a notch. Without one the notch window can only float in the
    /// expanded state, so pinning has nothing to show and the menu bar carries the conditions.
    static var hasNotchedScreen: Bool { notchedScreen != nil }

    func setPinned(_ pinned: Bool) {
        guard pinned != isPinned else { return }
        isPinned = pinned
        hoverTask?.cancel()
        Task {
            if pinned {
                await showCompact()
            } else {
                await notch.hide()
            }
        }
    }

    /// New snow alert: expand for a few seconds, then go back to compact (or hide when not pinned).
    /// Hovering while pinned takes over; otherwise the notch stays open until the pointer leaves.
    func showAlert() {
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            guard let self else { return }
            await self.notch.expand(on: self.screen)
            try? await Task.sleep(for: Self.alertDuration)
            while !Task.isCancelled && self.notch.isHovering {
                try? await Task.sleep(for: Self.collapseDelay)
            }
            guard !Task.isCancelled else { return }
            if self.isPinned {
                await self.showCompact()
            } else {
                await self.notch.hide()
            }
        }
    }

    private func hoverChanged(_ hovering: Bool) {
        guard isPinned else { return }
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: hovering ? Self.expandDelay : Self.collapseDelay)
            guard !Task.isCancelled, let self, self.isPinned, self.notch.isHovering == hovering else { return }
            if hovering {
                await self.notch.expand(on: self.screen)
            } else {
                await self.showCompact()
            }
        }
    }

    private func showCompact() async {
        guard let screen = Self.notchedScreen else {
            await notch.hide()
            return
        }
        await notch.compact(on: screen)
    }

    /// Displays were added, removed or rearranged. Rebuild the window on the right screen.
    private func screensChanged() {
        guard isPinned else { return }
        hoverTask?.cancel()
        Task {
            await notch.hide()
            await showCompact()
        }
    }

    private var screen: NSScreen {
        Self.notchedScreen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// The built-in notched display, wherever it sits in the arrangement.
    private static var notchedScreen: NSScreen? {
        NSScreen.screens.first { $0.auxiliaryTopLeftArea != nil && $0.auxiliaryTopRightArea != nil }
    }
}
