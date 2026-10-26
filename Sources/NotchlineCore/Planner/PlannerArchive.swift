import Foundation

/// How the user rated a day they skied. Ratings are 1 to 5 and given only for the terrain they
/// skied. The training data for learned weights (Phase 6).
public struct DayRating: Codable, Equatable, Sendable {
    /// False only in records from when the app asked "Did you ski?" and the user said no. The app
    /// no longer asks, so new ratings are all true.
    public var skied: Bool
    public var groomed: Int?
    public var ungroomed: Int?
    /// Optional, as the user reports them.
    public var leftHomeAt: Date?
    public var onLiftAt: Date?
    public var ratedAt: Date

    public static let scale = 1...5

    public init(skied: Bool, groomed: Int? = nil, ungroomed: Int? = nil, leftHomeAt: Date? = nil, onLiftAt: Date? = nil, ratedAt: Date) {
        self.skied = skied
        self.groomed = groomed
        self.ungroomed = ungroomed
        self.leftHomeAt = leftHomeAt
        self.onLiftAt = onLiftAt
        self.ratedAt = ratedAt
    }

    public func rating(_ terrain: Terrain) -> Int? {
        terrain == .groomed ? groomed : ungroomed
    }
}

/// The plan and forecast for a day as they stood the morning of, before first chair.
public struct MorningPlan: Codable, Equatable, Sendable {
    public var plannedAt: Date
    public var plan: PlannedDay
    /// That local day's forecast hours.
    public var forecast: [ForecastHour]

    public init(plannedAt: Date, plan: PlannedDay, forecast: [ForecastHour]) {
        self.plannedAt = plannedAt
        self.plan = plan
        self.forecast = forecast
    }
}

/// A day's scores as forecast one or two days ahead, the latest plan at that lead.
public struct EarlierForecast: Codable, Equatable, Sendable {
    public var lead: Int
    public var plannedAt: Date
    public var groomed: Int?
    public var ungroomed: Int?
    public var confidence: DayConfidence?
}

/// What the planner said about one day at one location, and how the user rated it.
public struct PlannerDayRecord: Codable, Equatable, Sendable {
    public var locationID: String
    /// Local midnight.
    public var day: Date
    public var morning: MorningPlan?
    /// At most one per lead, 1 and 2.
    public var earlier: [EarlierForecast]
    public var rating: DayRating?

    public init(locationID: String, day: Date, morning: MorningPlan? = nil, earlier: [EarlierForecast] = [], rating: DayRating? = nil) {
        self.locationID = locationID
        self.day = day
        self.morning = morning
        self.earlier = earlier
        self.rating = rating
    }

    /// The headline terrain's best-window score that morning, nil when every hour was vetoed.
    public var morningScore: Int? {
        guard let score = morning?.plan.score, let best = score.best else { return nil }
        return score.window(best)?.averageScore
    }
}

/// Planner records per location and day, as JSON files: what each plan said and how the user
/// rated the day. Kept on this Mac only.
public struct PlannerArchive: Sendable {
    /// Leads whose scores are kept for each day, so later phases can see what drew a crowd.
    static let earlierLeads = 1...2

    public let directory: URL

    /// ~/Library/Application Support/Notchline/planner
    public static func applicationSupport() throws -> PlannerArchive {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return PlannerArchive(directory: base.appending(path: "Notchline/planner", directoryHint: .isDirectory))
    }

    public init(directory: URL) {
        self.directory = directory
    }

    /// The stored record, nil when there is none. Throws when a record can't be read.
    public func load(locationID: String, day: Date, calendar: Calendar) throws -> PlannerDayRecord? {
        let url = fileURL(locationID, day: day, calendar: calendar)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Self.decoder.decode(PlannerDayRecord.self, from: Data(contentsOf: url))
    }

    public func save(_ record: PlannerDayRecord, calendar: Calendar) throws {
        let url = fileURL(record.locationID, day: record.day, calendar: calendar)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(record).write(to: url, options: .atomic)
    }

    /// Stores today's plan as the morning plan until first chair, and the scores of the next two
    /// days at their leads. A morning plan made after first chair is kept only when there is none,
    /// so the record stays the forecast as it stood before the lifts opened. It records what the
    /// planner forecast, not what the user saw or did: planning runs on a timer whether or not
    /// anyone looks, and says nothing about whether the user went.
    public func record(_ plan: SkiDayPlan, hourly: HourlyForecast, location: Location, now: Date) throws {
        let calendar = location.calendar
        let today = calendar.startOfDay(for: now)
        for day in plan.days {
            let lead = calendar.dateComponents([.day], from: today, to: day.score.day).day ?? 0
            var record = try load(locationID: location.id, day: day.score.day, calendar: calendar)
                ?? PlannerDayRecord(locationID: location.id, day: day.score.day)
            if lead == 0 {
                guard record.morning == nil || now < day.score.liftHours.start else { continue }
                record.morning = MorningPlan(plannedAt: now, plan: day, forecast: hourly.hours(on: day.score.day, calendar: calendar))
            } else if Self.earlierLeads.contains(lead) {
                record.earlier.removeAll { $0.lead == lead }
                record.earlier.append(EarlierForecast(
                    lead: lead, plannedAt: now, groomed: day.score.groomed?.averageScore,
                    ungroomed: day.score.ungroomed?.averageScore, confidence: day.score.confidence))
                record.earlier.sort { $0.lead < $1.lead }
            } else {
                continue
            }
            try save(record, calendar: calendar)
        }
    }

    /// How many days, today included, the user can pick from to rate.
    public static let ratableDayCount = 7

    /// Today and the days before it, `count` in all, newest first, for rating a day when the user
    /// chooses. Days with no stored record come back as empty ones, since the user may have skied
    /// a day the planner never planned.
    public func recentDays(location: Location, now: Date, count: Int = ratableDayCount) throws -> [PlannerDayRecord] {
        let calendar = location.calendar
        let today = calendar.startOfDay(for: now)
        return try (0..<count).map { back in
            let day = calendar.date(byAdding: .day, value: -back, to: today)!
            return try load(locationID: location.id, day: day, calendar: calendar) ?? PlannerDayRecord(locationID: location.id, day: day)
        }
    }

    /// Sets the rating on the stored record for that day.
    public func rate(_ record: PlannerDayRecord, _ rating: DayRating, calendar: Calendar) throws {
        var stored = try load(locationID: record.locationID, day: record.day, calendar: calendar) ?? record
        stored.rating = rating
        try save(stored, calendar: calendar)
    }

    private func fileURL(_ locationID: String, day: Date, calendar: Calendar) -> URL {
        directory.appending(path: locationID, directoryHint: .isDirectory).appending(path: "\(Self.dayKey(day, calendar: calendar)).json")
    }

    /// yyyy-MM-dd in the location's calendar.
    static func dayKey(_ day: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// The strings for rating one of the `recentDays`.
public struct RatingPrompt: Codable, Equatable, Sendable {
    /// Local midnight of the day, to hand back with the rating.
    public let day: Date
    /// `Today`, `Yesterday`, then the short weekday, for picking the day.
    public let dayLabel: String
    /// `How was Mt. Baker Ski Area on Sunday, Oct 25?`
    public let title: String
    /// What the planner forecast that morning, and how to rate.
    public let note: String

    public init(_ record: PlannerDayRecord, location: Location, now: Date, locale: Locale = .current) {
        day = record.day
        let calendar = location.calendar
        let back = calendar.dateComponents([.day], from: record.day, to: calendar.startOfDay(for: now)).day ?? 0
        dayLabel = back == 0 ? "Today" : back == 1 ? "Yesterday" : PlannerFormat.dayName(record.day, now: now, calendar: calendar, locale: locale)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = location.calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        title = "How was \(location.name) on \(formatter.string(from: record.day))?"
        let rate = "Rate only what you skied, 1 for poor to 5 for great."
        note = record.morning.map { "The planner forecast \(PlannerFormat.scores($0.plan.score)). \(rate)" } ?? rate
    }
}
