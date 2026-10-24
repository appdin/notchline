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
