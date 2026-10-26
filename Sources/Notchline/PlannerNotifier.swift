import AppKit
import NotchlineCore
import os
@preconcurrency import UserNotifications

/// Delivers the planner's notifications through UNUserNotificationCenter. Each plan replaces every
/// pending planner notification, so a day that drops below the threshold loses its summary.
@MainActor
final class PlannerNotifier: NSObject {
    /// What a click on a notification asks the app to do.
    var onOpen: ((PlannerNotification.Kind, _ locationID: String, _ day: Date) -> Void)?

    private let logger = Logger(subsystem: "com.appdin.notchline", category: "notifications")
    private var askedForAuthorization = false

    /// The notification center needs an app bundle; `swift run` has none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    override init() {
        super.init()
        center?.delegate = self
    }

    func replace(with notifications: [PlannerNotification]) async {
        guard let center else { return }
        let pending = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(PlannerNotifications.idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard !notifications.isEmpty, await isAuthorized(center) else { return }
        for notification in notifications {
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.userInfo = [
                "kind": notification.kind.rawValue,
                "locationID": notification.locationID,
                "day": notification.day.timeIntervalSince1970,
            ]
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: notification.fireAt)
            let request = UNNotificationRequest(
                identifier: notification.id, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
            do {
                try await center.add(request)
            } catch {
                logger.error("Could not schedule \(notification.id, privacy: .public): \(error, privacy: .public)")
            }
        }
        logger.info("Scheduled \(notifications.count) planner notifications")
    }

    func removeAll() async {
        await replace(with: [])
    }

    /// Asks once per launch, the first time there is something to deliver. macOS shows its prompt only the first time.
    private func isAuthorized(_ center: UNUserNotificationCenter) async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined && !askedForAuthorization {
            askedForAuthorization = true
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                logger.error("Notification authorization failed: \(error, privacy: .public)")
                return false
            }
        }
        return status == .authorized || status == .provisional
    }
}

extension PlannerNotifier: UNUserNotificationCenterDelegate {
    /// A menu bar agent counts as frontmost, so without this macOS would hold every banner back.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let kind = (info["kind"] as? String).flatMap(PlannerNotification.Kind.init),
              let locationID = info["locationID"] as? String,
              let day = info["day"] as? TimeInterval else { return }
        await MainActor.run {
            onOpen?(kind, locationID, Date(timeIntervalSince1970: day))
        }
    }
}
