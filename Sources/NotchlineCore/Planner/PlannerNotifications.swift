import Foundation

/// A notification the planner wants delivered. The Mac hands these to UNUserNotificationCenter and
/// Android to alarms, replacing every pending planner notification after each plan.
public struct PlannerNotification: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// The evening before a day that crosses the score threshold.
        case summary
    }

    /// Stable for a kind, location and day, so a later plan replaces it.
    public var id: String
    public var kind: Kind
    public var locationID: String
    /// Local midnight of the day it is about.
    public var day: Date
    public var fireAt: Date
    public var title: String
    public var body: String
}

public enum PlannerNotifications {
    /// Every planner notification ID starts with this, so the app can remove only its own.
    public static let idPrefix = "planner."

    /// The notifications for the selected location's plan: a summary at the evening summary time
    /// (in `userCalendar`, the Mac's or the phone's) the day before each day over the threshold,
    /// only when still ahead of `now`. A good score doesn't mean the user is going, so nothing
    /// reminds them to leave, and whether they skied doesn't follow from it either, so nothing
    /// asks for ratings. They rate when they choose.
    public static func schedule(_ plan: SkiDayPlan, location: Location, settings: PlannerSettings,
                                now: Date, userCalendar: Calendar = .current, locale: Locale = .current) -> [PlannerNotification] {
        guard settings.isEnabled else { return [] }
        let calendar = location.calendar
        let timeZone = calendar.timeZone
        let threshold = settings.notificationScoreThreshold
        let startOfToday = calendar.startOfDay(for: now)
        var notifications: [PlannerNotification] = []

        for day in plan.days {
            guard let best = day.score.best, let window = day.score.window(best), window.averageScore >= threshold else { continue }
            let key = PlannerArchive.dayKey(day.score.day, calendar: calendar)
            let headline = PlannerFormat.scores(day.score)

            if day.score.day > startOfToday {
                // Noon the day before, so the Mac's calendar finds the same date when its time zone differs.
                let dayBefore = LocalTime.time(12, on: calendar.date(byAdding: .day, value: -1, to: day.score.day)!, calendar)
                let fireAt = settings.eveningSummaryTime.date(on: dayBefore, calendar: userCalendar)
                if fireAt > now {
                    var lines: [String] = []
                    if let departure = day.departure(best) {
                        var leave = PlannerFormat.advice(departure.advice(now: fireAt), timeZone: timeZone, locale: locale)
                        if let overnight = departure.overnight, overnight.leaveAt > fireAt {
                            leave += ", " + PlannerFormat.overnight(overnight, now: fireAt, timeZone: timeZone, locale: locale)
                        }
                        lines.append(leave + ".")
                    } else {
                        // No home on the Mac, or Android, which leaves the drive to Google Maps.
                        lines.append("Be on the lift by \(PlannerFormat.time(window.interval.start, timeZone: timeZone, locale: locale)).")
                    }
                    if let confidence = day.score.confidence?.confidence(best) {
                        lines.append("Confidence \(confidence.percent)%.")
                    }
                    notifications.append(PlannerNotification(
                        id: "\(idPrefix)summary.\(location.id).\(key)", kind: .summary, locationID: location.id, day: day.score.day,
                        fireAt: fireAt, title: "Tomorrow at \(location.name): \(headline)", body: lines.joined(separator: " ")))
                }
            }
        }

        return notifications.sorted { $0.fireAt < $1.fireAt }
    }
}
