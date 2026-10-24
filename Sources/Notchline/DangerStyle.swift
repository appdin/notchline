import NotchlineCore
import SwiftUI

extension DangerLevel {
    /// Standard danger scale colors, gray for no rating.
    var color: Color {
        switch self {
        case .noRating: .gray
        case .low: Color(red: 0.31, green: 0.72, blue: 0.29)
        case .moderate: Color(red: 1.0, green: 0.94, blue: 0.0)
        case .considerable: Color(red: 0.97, green: 0.58, blue: 0.11)
        case .high: Color(red: 0.93, green: 0.11, blue: 0.14)
        case .extreme: .black
        }
    }

    /// Text color that stays readable on `color`.
    var badgeTextColor: Color {
        switch self {
        case .low, .moderate, .considerable: .black
        case .noRating, .high, .extreme: .white
        }
    }

    /// `3`, or a dash for no rating.
    var badgeText: String {
        self == .noRating ? "–" : "\(rawValue)"
    }
}

struct DangerBadge: View {
    let level: DangerLevel

    var body: some View {
        Text(level.badgeText)
            .font(.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(level.badgeTextColor)
            .frame(minWidth: 18, minHeight: 18)
            .background(level.color, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(level == .extreme ? 0.6 : 0), lineWidth: 1))
    }
}
