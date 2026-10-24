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
