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

    /// Snow depth or amount from inches: `61"`, or `155 cm` in metric. One decimal below one unit.
    public static func snow(_ inches: Double, _ units: UnitSystem = .imperial) -> String {
        guard units == .metric else { return self.inches(inches) }
        let cm = Convert.cm(fromInches: inches)
        if cm > 0 && cm < 0.95 {
            return String(format: "%.1f cm", cm)
        }
        return "\(Int(cm.rounded())) cm"
    }

    /// `+8"`, `+20 cm`
    public static func newSnow(_ inches: Double, _ units: UnitSystem = .imperial) -> String {
        "+" + snow(inches, units)
    }

    /// `4,040'`
    public static func feet(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic)) + "'"
    }

    /// Elevation from feet: `4,040'`, or `1,231 m` in metric.
    public static func elevation(_ feet: Int, _ units: UnitSystem = .imperial) -> String {
        guard units == .metric else { return self.feet(feet) }
        return Int(Convert.meters(fromFeet: Double(feet)).rounded()).formatted(.number.grouping(.automatic)) + " m"
    }

    /// Whole degrees from °F, converted for metric: `28°`, `-4°`
    public static func degrees(_ fahrenheit: Double, _ units: UnitSystem = .imperial) -> String {
        let value = units == .metric ? Convert.celsius(fromF: fahrenheit) : fahrenheit
        let rounded = Int(value.rounded())
        return "\(rounded == 0 ? 0 : rounded)°"
    }

    /// `F` or `C`, to follow `degrees` where the scale needs saying.
    public static func temperatureScale(_ units: UnitSystem) -> String {
        units == .metric ? "C" : "F"
    }

    /// Sustained speed with gusts when there are any, from mph: `15 G30`, `5`, in km/h for metric.
    public static func wind(_ wind: Wind, _ units: UnitSystem = .imperial) -> String {
        let sustained = roundedSpeed(wind.sustainedMph, units)
        guard let gust = wind.gustMph.map({ roundedSpeed($0, units) }), gust > sustained else { return "\(sustained)" }
        return "\(sustained) G\(gust)"
    }

    /// A speed from mph, rounded, in km/h for metric: `45`, `72`
    public static func speed(_ mph: Double, _ units: UnitSystem = .imperial) -> String {
        "\(roundedSpeed(mph, units))"
    }

    private static func roundedSpeed(_ mph: Double, _ units: UnitSystem) -> Int {
        Int((units == .metric ? Convert.kmh(fromMPH: mph) : mph).rounded())
    }

    /// `mph` or `km/h`
    public static func windUnit(_ units: UnitSystem) -> String {
        units == .metric ? "km/h" : "mph"
    }

    /// 16-point compass direction the wind blows from: `SW`, `NNE`
    public static func compass(_ degrees: Double) -> String {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return points[Int((normalized / 22.5).rounded()) % 16]
    }

    /// True when the forecast high is for a later local day than `now` at the location, so it should read as tomorrow's.
    public static func highIsTomorrow(_ high: ForecastTemp, now: Date, calendar: Calendar) -> Bool {
        LocalTime.isLaterDay(high.period.start, than: now, calendar: calendar)
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
