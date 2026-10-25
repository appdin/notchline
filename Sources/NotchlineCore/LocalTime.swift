import Foundation

/// Local-day periods in a location's calendar. Every provider and view that needs "today",
/// "daytime" or "overnight" uses these, so the answer follows the location's time zone and its
/// daylight saving changes rather than a fixed UTC offset or the Mac's own time zone.
public enum LocalTime {
    /// Local hours bounding the daytime high and the overnight low, close to the NWS periods.
    static let dayStartHour = 7
    static let dayEndHour = 19

    /// Today's daytime period, or tomorrow's once today's has ended.
    public static func daytime(containingOrAfter now: Date, calendar: Calendar) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let period = period(on: today, from: dayStartHour, to: dayEndHour, calendar: calendar)
        guard now >= period.end else { return period }
        return self.period(on: calendar.date(byAdding: .day, value: 1, to: today)!, from: dayStartHour, to: dayEndHour, calendar: calendar)
    }

    /// The overnight period that has not ended: the current one before morning, otherwise tonight's.
    public static func overnight(containingOrAfter now: Date, calendar: Calendar) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let lastNight = period(on: yesterday, from: dayEndHour, to: 24 + dayStartHour, calendar: calendar)
        return now < lastNight.end ? lastNight : period(on: today, from: dayEndHour, to: 24 + dayStartHour, calendar: calendar)
    }

    /// Days the ski day planner covers: today and the next three.
    public static let plannerDayCount = 4

    /// Start of each local hour from midnight today through the end of the last planner day.
    /// Stepping by elapsed hours keeps daylight saving days at 23 or 25 hours.
    public static func plannerHours(from now: Date, calendar: Calendar) -> [Date] {
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: plannerDayCount, to: today)!
        return Array(stride(from: today, to: end, by: 3600))
    }

    /// True when `date` falls on a later local day than `now`.
    public static func isLaterDay(_ date: Date, than now: Date, calendar: Calendar) -> Bool {
        calendar.startOfDay(for: date) > calendar.startOfDay(for: now)
    }

    static func period(on midnight: Date, from startHour: Int, to endHour: Int, calendar: Calendar) -> DateInterval {
        DateInterval(start: time(startHour, on: midnight, calendar), end: time(endHour, on: midnight, calendar))
    }

    /// `hour` o'clock local time counting from the day starting at `midnight`, so 31 is 07:00 the next day.
    static func time(_ hour: Int, on midnight: Date, _ calendar: Calendar) -> Date {
        let day = calendar.date(byAdding: .day, value: hour / 24, to: midnight)!
        return calendar.date(bySettingHour: hour % 24, minute: 0, second: 0, of: day)!
    }
}

/// A local wall-clock time such as first chair, written "HH:mm" in JSON and settings.
public struct ClockTime: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let hour: Int
    public let minute: Int

    public init?(hour: Int, minute: Int) {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        self.hour = hour
        self.minute = minute
    }

    /// Parses "HH:mm", for example "08:30".
    public init?(_ string: String) {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.count == 2 }), let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return nil
        }
        self.init(hour: hour, minute: minute)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let time = ClockTime(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected HH:mm, got \(string)")
        }
        self = time
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public var description: String { String(format: "%02d:%02d", hour, minute) }

    /// This time on the local day containing `day`.
    public func date(on day: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: calendar.startOfDay(for: day))!
    }

    public static func < (lhs: ClockTime, rhs: ClockTime) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }
}
