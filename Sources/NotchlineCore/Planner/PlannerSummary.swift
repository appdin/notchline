import Foundation

/// The planner section's display values for each planned day: both scores, the best window and
/// departure for each terrain, and confidence. Built once here so the Mac's planner section and
/// the Android app show the same strings.
public struct PlannerSummary: Encodable, Equatable, Sendable {
    public let days: [PlannerDaySummary]
    /// From scoring, confidence and departures, worth showing beside the rows.
    public let warnings: [String]
    /// No home is set, so there are scores but no departures.
    public let needsHome: Bool

    public init(plan: SkiDayPlan, location: Location, now: Date, locale: Locale = .current) {
        days = plan.days.map { PlannerDaySummary($0, location: location, now: now, locale: locale) }
        warnings = plan.warnings
        needsHome = plan.needsHome
    }

    /// Shown in place of the days when there is no plan.
    public static let noForecast = "No hourly forecast to plan from."
}

public struct PlannerDaySummary: Encodable, Equatable, Sendable {
    /// `Today`, `Tomorrow`, then the short weekday.
    public let title: String
    /// Scored terrains, the headline first. Empty when no hour is skiable.
    public let scores: [TerrainScoreSummary]
    /// `Confidence 72%` for the headline terrain.
    public let confidence: String?
    /// What the confidence is based on, one line each.
    public let confidenceNotes: [String]
    /// One row per scored terrain, or one `Both` row when both aim for the same trip.
    public let rows: [TerrainRowSummary]
    /// Why nothing scored, in place of the scores and rows.
    public let noScoreReason: String?
    /// When to be on the lift for the headline terrain's best window: `8:30 AM`.
    public let liftTime: String?

    init(_ day: PlannedDay, location: Location, now: Date, locale: Locale) {
        let score = day.score
        let timeZone = location.calendar.timeZone
        title = PlannerFormat.dayName(score.day, now: now, calendar: location.calendar, locale: locale)

        let order: [Terrain] = score.best == .groomed ? [.groomed, .ungroomed] : [.ungroomed, .groomed]
        let scored = order.filter { score.window($0) != nil }
        scores = scored.map { TerrainScoreSummary(terrain: $0, score: score.window($0)!.averageScore, isHeadline: $0 == scored.first) }

        let headline = score.best.flatMap { score.confidence?.confidence($0) }
        confidence = headline.map { "Confidence \($0.percent)%" }
        confidenceNotes = headline.map(Self.notes) ?? []

        func row(_ terrain: Terrain, label: String) -> TerrainRowSummary {
            let departure = day.departure(terrain)
            var details: [String] = []
            if let departure {
                details.append(PlannerFormat.drive(departure.drive))
                if let overnight = departure.overnight {
                    details.append(PlannerFormat.overnight(overnight, now: now, timeZone: timeZone, locale: locale))
                }
            }
            return TerrainRowSummary(
                label: label,
                window: PlannerFormat.window(score.window(terrain)!.interval, timeZone: timeZone, locale: locale),
                advice: departure.map { PlannerFormat.advice($0.advice(now: now), timeZone: timeZone, locale: locale) },
                details: details)
        }
        if scored.count == 2 && Self.sameTrip(day) {
            rows = [row(scored[0], label: "Both")]
        } else {
            rows = scored.map { row($0, label: $0 == .groomed ? "Groomed" : "Ungroomed") }
        }

        noScoreReason = scored.isEmpty ? Self.noScoreReason(score, location: location, now: now) : nil
        liftTime = scored.first.map { PlannerFormat.time(score.window($0)!.interval.start, timeZone: timeZone, locale: locale) }
    }

    /// Both terrains aim for the same window with the same departure, so one row says it.
    private static func sameTrip(_ day: PlannedDay) -> Bool {
        day.score.groomed?.interval == day.score.ungroomed?.interval
            && day.groomed?.drive.leaveAt == day.ungroomed?.drive.leaveAt
            && day.groomed?.overnight?.leaveAt == day.ungroomed?.overnight?.leaveAt
    }

    private static func noScoreReason(_ score: DayScore, location: Location, now: Date) -> String {
        if location.calendar.isDate(score.day, inSameDayAs: now) && now >= score.liftHours.end {
            return "The lifts have closed for the day."
        }
        let vetoes = Set(score.hours.compactMap(\.veto))
        guard !vetoes.isEmpty else { return "No skiable hours left today." }
        let reasons = [Veto.rain, .wind, .visibility].filter(vetoes.contains).map { veto in
            switch veto {
            case .rain: "rain"
            case .wind: "wind holds"
            case .visibility: "no visibility"
            }
        }
        return "No skiable hours: " + reasons.joined(separator: ", ") + "."
    }

    private static func notes(_ confidence: Confidence) -> [String] {
        var lines = [confidence.isMeasured
            ? "How often forecasts this far ahead held, measured from past seasons."
            : "Estimated from how far ahead the day is."]
        if let spread = confidence.modelSpread {
            lines.append("Forecast models are within \(spread) points of each other.")
        }
        lines.append("Lift hours are typical, not this season's.")
        return lines
    }
}

public struct TerrainScoreSummary: Encodable, Equatable, Sendable {
    public let terrain: Terrain
    /// 0 to 100.
    public let score: Int
    public let isHeadline: Bool
}

public struct TerrainRowSummary: Encodable, Equatable, Sendable {
    /// `Groomed`, `Ungroomed` or `Both`.
    public let label: String
    /// The best window: `8:30 – 11:00 AM`.
    public let window: String
    /// `Leave at 7:00 AM` and the like. nil without a departure.
    public let advice: String?
    /// The drive and the overnight option, one line each.
    public let details: [String]
}

/// What the scores mean and what goes into them, one paragraph each.
public enum ScoreHelp {
    public static let paragraphs = [
        "Each score, 0 to 100, rates the day's best window for groomed or ungroomed runs: the stretch of lift hours within 15 points of the day's peak. The higher of the two leads.",
        "Every lift hour is scored from fresh snow not yet tracked out, snow quality from temperature, a refrozen rain crust, wind and gusts, and flat light from cloud, fog or falling snow. Rain, gusts over the lift-hold threshold or near-zero visibility zero out the hour.",
        "Groomed runs depend mostly on temperature, surface, wind and light, and top out at 85 so a perfect corduroy day still ranks under a deep powder day. Ungroomed runs depend mostly on fresh snow, which gets tracked out faster on weekends, holidays and big powder days.",
        "Confidence is how likely the score is to hold by the day itself.",
    ]
}
