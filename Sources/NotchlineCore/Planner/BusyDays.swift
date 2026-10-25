import Foundation

/// Days when more people ski, so fresh snow gets tracked out sooner: weekends and the holidays
/// that empty schools and offices in each country. Spring breaks vary by district and are left out.
public enum BusyDays {
    public static func isBusy(_ day: Date, country: Country, calendar: Calendar) -> Bool {
        calendar.isDateInWeekend(day) || isHoliday(day, country: country, calendar: calendar)
    }

    public static func isHoliday(_ day: Date, country: Country, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        guard let year = parts.year, let month = parts.month, let date = parts.day else { return false }
        // Christmas through New Year's Day, when most schools are out.
        if (month == 12 && date >= 24) || (month == 1 && date == 1) { return true }
        func nth(_ n: Int, _ weekday: Int, of month: Int) -> Int? {
            nthWeekday(n, weekday, month: month, year: year, calendar: calendar)
        }
        switch country {
        case .us:
            let thanksgiving = nth(4, 5, of: 11)
            return (month == 1 && date == nth(3, 2, of: 1))      // Martin Luther King Jr. Day
                || (month == 2 && date == nth(3, 2, of: 2))      // Presidents' Day
                || (month == 11 && (date == thanksgiving || date == thanksgiving.map { $0 + 1 }))
        case .ca:
            let easter = easterSunday(year: year, calendar: calendar)
            let offset = easter.flatMap { calendar.dateComponents([.day], from: $0, to: calendar.startOfDay(for: day)).day }
            return (month == 2 && date == nth(3, 2, of: 2))      // BC Family Day
                || offset == -2 || offset == 1                   // Good Friday, Easter Monday
        }
    }

    /// Day of the month of the `n`th `weekday` (1 is Sunday), for example the third Monday.
    static func nthWeekday(_ n: Int, _ weekday: Int, month: Int, year: Int, calendar: Calendar) -> Int? {
        calendar.date(from: DateComponents(year: year, month: month, weekday: weekday, weekdayOrdinal: n))
            .map { calendar.component(.day, from: $0) }
    }

    /// Gregorian Easter Sunday by the anonymous Gregorian algorithm.
    static func easterSunday(year: Int, calendar: Calendar) -> Date? {
        let a = year % 19, b = year / 100, c = year % 100
        let d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = (h + l - 7 * m + 114) % 31 + 1
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}
