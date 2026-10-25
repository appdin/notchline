import Foundation

/// When the travel-time log samples Apple's live drive time from home: on the quarter hour through
/// each morning, while the Mac is awake. Every day counts, so quiet days give the baseline that
/// crowd and storm days are compared against.
public enum TravelLogRules {
    static let interval: TimeInterval = 15 * 60
    /// The morning runs from this long before first chair to `afterFirstChair` after it.
    static let beforeFirstChair: TimeInterval = 4 * 3600
    static let afterFirstChair: TimeInterval = 2 * 3600
    /// A sample this soon after the last one is skipped, as after waking or a replan.
    static let minimumGap: TimeInterval = 10 * 60

    /// The morning's logging window on `date`'s local day, nil when the location has no lift hours.
    public static func window(on date: Date, location: Location) -> DateInterval? {
        guard let lift = location.liftInterval(on: date) else { return nil }
        return DateInterval(start: lift.start.addingTimeInterval(-beforeFirstChair), end: lift.start.addingTimeInterval(afterFirstChair))
    }

    /// Whether to sample at `now`, given the day's last sample.
    public static func isDue(now: Date, location: Location, last: Date?) -> Bool {
        guard let window = window(on: now, location: location), window.contains(now) else { return false }
        return last.map { now.timeIntervalSince($0) >= minimumGap } ?? true
    }

    /// The next quarter hour after `now` inside a morning window, today's or tomorrow's.
    public static func nextSample(after now: Date, location: Location) -> Date? {
        let calendar = location.calendar
        let quarter = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / interval).rounded(.down) * interval + interval)
        for offset in 0...1 {
            let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
            guard let window = window(on: day, location: location) else { continue }
            let next = max(window.start, quarter)
            if next <= window.end { return next }
        }
        return nil
    }
}
