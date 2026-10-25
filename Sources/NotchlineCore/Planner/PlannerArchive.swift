import Foundation

/// How the user rated a day the planner scored. Ratings are 1 to 5 and given only for the terrain
/// they skied. The training data for learned weights (Phase 6).
public struct DayRating: Codable, Equatable, Sendable {
    /// False when the user said they didn't ski that day, which stops the planner asking.
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

    public static func didNotSki(at date: Date) -> DayRating {
        DayRating(skied: false, ratedAt: date)
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

/// Apple Maps' live drive time from home, leaving at `at`, as the travel-time log recorded it.
public struct TravelSample: Codable, Equatable, Sendable {
    public var at: Date
    /// Home when the sample was taken, so samples from an earlier home can be left out.
    public var home: Coordinate
    public var driveTime: TimeInterval

    public init(at: Date, home: Coordinate, driveTime: TimeInterval) {
        self.at = at
        self.home = home
        self.driveTime = driveTime
    }
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
    /// The morning's logged drive times, oldest first.
    public var travelTimes: [TravelSample]

    public init(locationID: String, day: Date, morning: MorningPlan? = nil, earlier: [EarlierForecast] = [], rating: DayRating? = nil, travelTimes: [TravelSample] = []) {
        self.locationID = locationID
        self.day = day
        self.morning = morning
        self.earlier = earlier
        self.rating = rating
        self.travelTimes = travelTimes
    }

    /// Records from before the travel-time log have no samples.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        locationID = try container.decode(String.self, forKey: .locationID)
        day = try container.decode(Date.self, forKey: .day)
        morning = try container.decodeIfPresent(MorningPlan.self, forKey: .morning)
        earlier = try container.decode([EarlierForecast].self, forKey: .earlier)
        rating = try container.decodeIfPresent(DayRating.self, forKey: .rating)
        travelTimes = try container.decodeIfPresent([TravelSample].self, forKey: .travelTimes) ?? []
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
    /// so the record stays what the user saw before setting out.
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

    /// The day to ask "Did you ski?" about: today once its last chair has passed, otherwise
    /// yesterday. Only days with a morning plan and no rating yet.
    public func pendingRating(location: Location, now: Date) throws -> PlannerDayRecord? {
        let calendar = location.calendar
        let today = calendar.startOfDay(for: now)
        if let record = try load(locationID: location.id, day: today, calendar: calendar), let morning = record.morning {
            if now >= morning.plan.score.liftHours.end { return record.rating == nil ? record : nil }
        } else if let lastChair = location.liftInterval(on: now)?.end, now >= lastChair {
            return nil
        }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        guard let record = try load(locationID: location.id, day: yesterday, calendar: calendar),
              record.morning != nil, record.rating == nil else { return nil }
        return record
    }

    /// Sets the rating on the stored record for that day.
    public func rate(_ record: PlannerDayRecord, _ rating: DayRating, calendar: Calendar) throws {
        var stored = try load(locationID: record.locationID, day: record.day, calendar: calendar) ?? record
        stored.rating = rating
        try save(stored, calendar: calendar)
    }

    /// Adds a logged drive time to the record for the sample's local day.
    public func log(_ sample: TravelSample, location: Location) throws {
        let calendar = location.calendar
        let day = calendar.startOfDay(for: sample.at)
        var record = try load(locationID: location.id, day: day, calendar: calendar) ?? PlannerDayRecord(locationID: location.id, day: day)
        record.travelTimes.append(sample)
        record.travelTimes.sort { $0.at < $1.at }
        try save(record, calendar: calendar)
    }

    /// Every stored record at every location, for learning. A record that can't be read is left
    /// out with a warning rather than stopping the rest.
    public func allRecords() throws -> (records: [PlannerDayRecord], warnings: [String]) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return ([], []) }
        var records: [PlannerDayRecord] = []
        var warnings: [String] = []
        for folder in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            for file in try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path })
            where file.pathExtension == "json" {
                do {
                    records.append(try Self.decoder.decode(PlannerDayRecord.self, from: Data(contentsOf: file)))
                } catch {
                    warnings.append("Could not read \(folder.lastPathComponent)/\(file.lastPathComponent) (\(error))")
                }
            }
        }
        return (records, warnings)
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
