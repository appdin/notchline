import Foundation

/// Display strings shared by the menu and the notch.
public enum ConditionsFormat {
    /// Whole inches, or one decimal below an inch so light snowfall does not read as zero: `61"`, `0.4"`.
    public static func inches(_ value: Double) -> String {
        if value > 0 && value < 0.95 {
            return String(format: "%.1f\"", value)
        }
        return "\(Int(value.rounded()))\""
    }

    /// `+8"`
    public static func newSnow(_ value: Double) -> String {
        "+" + inches(value)
    }

    /// `4,040'`
    public static func feet(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic)) + "'"
    }

    /// Whole degrees: `28°`, `-4°`
    public static func degrees(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return "\(rounded == 0 ? 0 : rounded)°"
    }

    /// Sustained speed with gusts when there are any: `15 G30`, `5`
    public static func wind(_ wind: Wind) -> String {
        let sustained = Int(wind.sustainedMph.rounded())
        guard let gust = wind.gustMph.map({ Int($0.rounded()) }), gust > sustained else { return "\(sustained)" }
        return "\(sustained) G\(gust)"
    }

    /// 16-point compass direction the wind blows from: `SW`, `NNE`
    public static func compass(_ degrees: Double) -> String {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return points[Int((normalized / 22.5).rounded()) % 16]
    }

    /// True when the forecast high is for a later day than `now`, so it should read as tomorrow's.
    public static func highIsTomorrow(_ high: ForecastTemp, now: Date, calendar: Calendar = .current) -> Bool {
        high.period.start > now && !calendar.isDate(high.period.start, inSameDayAs: now)
    }

    /// `just now`, `12 min ago`, `3 h ago`, `2 d ago`
    public static func age(since date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        switch minutes {
        case ..<1: return "just now"
        case ..<120: return "\(minutes) min ago"
        case ..<(48 * 60): return "\(minutes / 60) h ago"
        default: return "\(minutes / (24 * 60)) d ago"
        }
    }
}
