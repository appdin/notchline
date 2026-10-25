import Foundation

/// The worst driving weather forecast along the drive, sampled at the resort and partway along the route.
public enum RoadCondition: String, Codable, Comparable, Sendable {
    case clear, freezing, snow, heavySnow, freezingRain

    private var rank: Int {
        switch self {
        case .clear: 0
        case .freezing: 1
        case .snow: 2
        case .heavySnow: 3
        case .freezingRain: 4
        }
    }

    public static func < (lhs: RoadCondition, rhs: RoadCondition) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// One drive from home to the lot.
public struct DriveLeg: Codable, Equatable, Sendable {
    public var leaveAt: Date
    public var lotArrival: Date
    /// Apple Maps' estimate with predicted traffic for that arrival.
    public var driveTime: TimeInterval
    public var roadCondition: RoadCondition
    public var roadBuffer: TimeInterval
    public var crowdBuffer: TimeInterval
}

public struct Departure: Codable, Equatable, Sendable {
    public var terrain: Terrain
    /// The window this aims for. When planned late, the part of the best window still reachable.
    public var window: ScoreWindow
    public var drive: DriveLeg
    /// Driving up the evening before, when the location allows overnight parking and the morning
    /// departure is before 6 AM.
    public var overnight: DriveLeg?
    /// First chair that day.
    public var firstChair: Date
    /// The best window's start when its departure had already passed, so this leaves now for the rest.
    public var missedLiftTime: Date?

    /// When to be on the lift.
    public var liftTime: Date { window.interval.start }

    /// What to tell the user at `now`.
    public func advice(now: Date) -> DepartureAdvice {
        let wait = drive.leaveAt.timeIntervalSince(now)
        if missedLiftTime != nil || wait < -DepartureRules.leaveNowTolerance {
            return .goAnyway(firstChairPassed: (missedLiftTime ?? liftTime) <= firstChair)
        }
        if wait <= DepartureRules.leaveNowTolerance { return .leaveNow }
        if wait <= DepartureRules.soon {
            // Rounded down, so the user leaves a little early rather than late.
            return .leaveIn(minutes: max(5, Int(wait / 60) / 5 * 5))
        }
        return .leaveAt(drive.leaveAt)
    }
}

public enum DepartureAdvice: Equatable, Sendable {
    case leaveAt(Date)
    case leaveIn(minutes: Int)
    case leaveNow
    /// The planned departure has passed. `firstChairPassed` when the best window started at first chair.
    case goAnyway(firstChairPassed: Bool)
}

/// Each day's scores with the departure for each terrain.
public struct PlannedDay: Codable, Equatable, Sendable {
    public var score: DayScore
    public var groomed: Departure?
    public var ungroomed: Departure?

    public func departure(_ terrain: Terrain) -> Departure? {
        terrain == .groomed ? groomed : ungroomed
    }
}

public struct SkiDayPlan: Codable, Equatable, Sendable {
    public var days: [PlannedDay]
    public var warnings: [String]
    /// No home is set, so there are scores but no departures.
    public var needsHome = false
}

/// Fixed rules for v1. Phase 6 tunes the buffers from logged drive times.
public enum DepartureRules {
    /// Departures this close are given as "leave in N min".
    static let soon: TimeInterval = 60 * 60
    /// Within this of the departure, "leave now".
    static let leaveNowTolerance: TimeInterval = 5 * 60
    /// Departures before this local hour offer driving up the night before.
    static let earlyMorningHour = 6
    /// Driving up the night before aims to reach the lot by this local hour.
    static let overnightArrivalHour = 21
    /// Extra time on days the forecast draws a crowd, for traffic on the access road and the lot.
    static let crowdBuffer: TimeInterval = 20 * 60
    static let busyCrowdBuffer: TimeInterval = 30 * 60
    /// Snowfall rates, in inches an hour, that slow the roads.
    static let snowingInchesPerHour = 0.1
    static let heavySnowInchesPerHour = 1.0
    static let freezingF = 32.0

    /// Share of the drive time added for each road condition.
    static func roadBufferShare(_ condition: RoadCondition) -> Double {
        switch condition {
        case .clear: 0
        case .freezing: 0.1
        case .snow: 0.3
        case .heavySnow, .freezingRain: 0.5
        }
    }
}

/// Turns scored days into departures: Apple Maps drive time for the target arrival, plus road and
/// crowd buffers. The arithmetic is pure; travel times and road weather come through protocols.
public struct DeparturePlanner: Sendable {
    private let travel: TravelTimeProvider
    private let roadWeather: RoadWeatherProvider?

    public init(travel: TravelTimeProvider, roadWeather: RoadWeatherProvider?) {
        self.travel = travel
        self.roadWeather = roadWeather
    }

    public func plan(_ scores: PlannerScores, hourly: HourlyForecast, location: Location, settings: PlannerSettings, now: Date) async -> SkiDayPlan {
        var warnings = scores.warnings
        var days = scores.days.map { PlannedDay(score: $0, groomed: nil, ungroomed: nil) }
        guard let home = settings.home else {
            warnings.append("Set a home address in Settings to get departure times")
            return SkiDayPlan(days: days, warnings: warnings, needsHome: true)
        }
        var samples = [hourly]
        if let roadWeather {
            do {
                let midpoint = try await travel.routeMidpoint(from: home.coordinate, to: location.coordinate)
                samples.append(try await roadWeather.hourly(at: midpoint, calendar: location.calendar, now: now))
            } catch {
                warnings.append("No road weather along the drive (\(error)); road buffers use the resort's weather only")
            }
        }
        let trip = Trip(
            travel: travel, home: home.coordinate, destination: location.coordinate, samples: samples,
            arrivalToLift: TimeInterval(settings.settings(for: location.id).arrivalToLiftMinutes * 60),
            overnightParking: settings.settings(for: location.id).overnightParkingAllowed,
            calendar: location.calendar, now: now)
        var failures: [String] = []
        for index in days.indices {
            for terrain in Terrain.allCases {
                do {
                    let departure = try await trip.departure(for: days[index].score, terrain: terrain)
                    if terrain == .groomed { days[index].groomed = departure } else { days[index].ungroomed = departure }
                } catch {
                    let message = "No drive time to \(location.name) from Apple Maps (\(error))"
                    if !failures.contains(message) { failures.append(message) }
                }
            }
        }
        return SkiDayPlan(days: days, warnings: warnings + failures)
    }

    /// Everything fixed for one location and home during one plan.
    struct Trip {
        let travel: TravelTimeProvider
        let home: Coordinate
        let destination: Coordinate
        let samples: [HourlyForecast]
        let arrivalToLift: TimeInterval
        let overnightParking: Bool
        let calendar: Calendar
        let now: Date

        func departure(for day: DayScore, terrain: Terrain) async throws -> Departure? {
            let crowd = day.drawsCrowd ? (day.isBusy ? DepartureRules.busyCrowdBuffer : DepartureRules.crowdBuffer) : 0
            let ahead = day.hours.filter { $0.interval.end > now }
            guard var (window, drive) = try await shortestDrive(SkiDayScorer.bestWindows(ahead, terrain), crowd: crowd) else { return nil }
            var missed: Date?
            if drive.leaveAt < now.addingTimeInterval(-DepartureRules.leaveNowTolerance) {
                // Too late for the best window's start. Leave now for what is still reachable.
                let soonest = try await leg(lotArrival: now.addingTimeInterval(drive.driveTime + drive.roadBuffer + crowd), crowd: crowd)
                let earliestLift = DeparturePlanner.roundedToFive(now.addingTimeInterval(soonest.lotArrival.timeIntervalSince(soonest.leaveAt) + arrivalToLift), .up)
                let reachable = ahead.compactMap { hour -> HourScore? in
                    guard hour.interval.end > earliestLift else { return nil }
                    var hour = hour
                    hour.interval = DateInterval(start: max(hour.interval.start, earliestLift), end: hour.interval.end)
                    return hour
                }
                guard let late = try await shortestDrive(SkiDayScorer.bestWindows(reachable, terrain), crowd: crowd) else { return nil }
                missed = window.interval.start
                (window, drive) = late
                drive.leaveAt = max(drive.leaveAt, now)
            }
            return Departure(
                terrain: terrain, window: window, drive: drive,
                overnight: try await overnight(before: day, morning: drive),
                firstChair: day.liftHours.start, missedLiftTime: missed)
        }

        /// Among tied windows, the one with the shortest drive. Ties go to the earlier window.
        func shortestDrive(_ windows: [ScoreWindow], crowd: TimeInterval) async throws -> (ScoreWindow, DriveLeg)? {
            var best: (ScoreWindow, DriveLeg)?
            for window in windows {
                let drive = try await leg(lotArrival: window.interval.start.addingTimeInterval(-arrivalToLift), crowd: crowd)
                if best == nil || drive.driveTime < best!.1.driveTime { best = (window, drive) }
            }
            return best
        }

        func leg(lotArrival: Date, crowd: TimeInterval) async throws -> DriveLeg {
            let driveTime = try await travel.travelTime(from: home, to: destination, arrivingBy: lotArrival)
            let condition = DeparturePlanner.roadCondition(during: DateInterval(start: lotArrival.addingTimeInterval(-driveTime), end: lotArrival), samples: samples)
            let buffer = DeparturePlanner.roadBuffer(driveTime: driveTime, condition: condition)
            return DriveLeg(
                leaveAt: DeparturePlanner.roundedToFive(lotArrival.addingTimeInterval(-driveTime - buffer - crowd), .down),
                lotArrival: lotArrival, driveTime: driveTime, roadCondition: condition, roadBuffer: buffer, crowdBuffer: crowd)
        }

        /// Reaching the lot by 9 PM the evening before, when the morning departure is before 6 AM.
        func overnight(before day: DayScore, morning: DriveLeg) async throws -> DriveLeg? {
            guard overnightParking, calendar.component(.hour, from: morning.leaveAt) < DepartureRules.earlyMorningHour,
                  calendar.isDate(morning.leaveAt, inSameDayAs: day.day) else { return nil }
            let dayBefore = calendar.date(byAdding: .day, value: -1, to: day.day)!
            let evening = LocalTime.time(DepartureRules.overnightArrivalHour, on: dayBefore, calendar)
            let drive = try await leg(lotArrival: evening, crowd: 0)
            return drive.leaveAt > now ? drive : nil
        }
    }

    /// Times given to the user fall on 5 minutes: departures round earlier, late lift times later.
    static func roundedToFive(_ date: Date, _ rule: FloatingPointRoundingRule) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 300).rounded(rule) * 300)
    }

    /// The worst condition in any sample over the hours the drive overlaps.
    static func roadCondition(during drive: DateInterval, samples: [HourlyForecast]) -> RoadCondition {
        samples.flatMap(\.hours)
            .filter { (DateInterval(start: $0.start, duration: 3600).intersection(with: drive)?.duration ?? 0) > 0 }
            .map(roadCondition)
            .max() ?? .clear
    }

    static func roadCondition(_ hour: ForecastHour) -> RoadCondition {
        let belowFreezing = hour.tempF.map { $0 <= DepartureRules.freezingF } ?? false
        let likely = (hour.precipitationProbability ?? 0) >= ScoringRules.likelyPrecipitationPercent
        let raining = (hour.rainInches ?? 0) >= ScoringRules.measurableInches || (likely && hour.precipitationTypes.contains(.rain))
        if (likely && hour.precipitationTypes.contains(.freezingRain)) || (raining && belowFreezing) { return .freezingRain }
        let snow = hour.snowfallInches ?? 0
        if snow >= DepartureRules.heavySnowInchesPerHour { return .heavySnow }
        if snow >= DepartureRules.snowingInchesPerHour || (likely && hour.precipitationTypes.contains(.snow)) { return .snow }
        return belowFreezing ? .freezing : .clear
    }

    /// A share of the drive time for the condition, rounded up to 5 minutes.
    static func roadBuffer(driveTime: TimeInterval, condition: RoadCondition) -> TimeInterval {
        let buffer = driveTime * DepartureRules.roadBufferShare(condition)
        return (buffer / 300).rounded(.up) * 300
    }
}

public enum PlannerFormat {
    /// "Leave at 7:00 AM", "Leave in 30 min", "Leave now", "Go anyway, first chair has passed"
    public static func advice(_ advice: DepartureAdvice, timeZone: TimeZone, locale: Locale = .current) -> String {
        switch advice {
        case .leaveAt(let date): "Leave at \(time(date, timeZone: timeZone, locale: locale))"
        case .leaveIn(let minutes): "Leave in \(minutes) min"
        case .leaveNow: "Leave now"
        case .goAnyway(let firstChairPassed): firstChairPassed ? "Go anyway, first chair has passed" : "Go anyway, the best of it has started"
        }
    }

    /// "or drive up tonight, leave at 6:40 PM"; "the night before" when that is not tonight.
    public static func overnight(_ drive: DriveLeg, now: Date, timeZone: TimeZone, locale: Locale = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let when = calendar.isDate(drive.leaveAt, inSameDayAs: now) ? "tonight" : "the night before"
        return "or drive up \(when), leave at \(time(drive.leaveAt, timeZone: timeZone, locale: locale))"
    }

    /// "92 ungroomed, 74 groomed", the better score first. Ties lead with ungroomed, as `DayScore.best` does.
    public static func scores(_ score: DayScore) -> String {
        let order: [Terrain] = score.best == .groomed ? [.groomed, .ungroomed] : [.ungroomed, .groomed]
        let parts = order.compactMap { terrain in score.window(terrain).map { "\($0.averageScore) \(terrain.rawValue)" } }
        return parts.isEmpty ? "no skiable hours" : parts.joined(separator: ", ")
    }

    /// "82 min drive", plus "+25 min snow" and "+20 min crowds" when there are buffers.
    public static func drive(_ drive: DriveLeg) -> String {
        var parts = ["\(Int((drive.driveTime / 60).rounded())) min drive"]
        if drive.roadBuffer > 0 { parts.append("+\(Int(drive.roadBuffer / 60)) min \(roadCondition(drive.roadCondition))") }
        if drive.crowdBuffer > 0 { parts.append("+\(Int(drive.crowdBuffer / 60)) min crowds") }
        return parts.joined(separator: " ")
    }

    static func roadCondition(_ condition: RoadCondition) -> String {
        switch condition {
        case .clear: "clear roads"
        case .freezing: "icy roads"
        case .snow: "snow"
        case .heavySnow: "heavy snow"
        case .freezingRain: "freezing rain"
        }
    }

    /// "Today", "Tomorrow", then the short weekday, for the day picker.
    public static func dayName(_ day: Date, now: Date, calendar: Calendar, locale: Locale = .current) -> String {
        let lead = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: day)).day ?? 0
        switch lead {
        case 0: return "Today"
        case 1: return "Tomorrow"
        default:
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate("EEE")
            return formatter.string(from: day)
        }
    }

    /// "8:30 – 11:00 AM"
    public static func window(_ interval: DateInterval, timeZone: TimeZone, locale: Locale = .current) -> String {
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: interval) ?? time(interval.start, timeZone: timeZone, locale: locale)
    }

    public static func time(_ date: Date, timeZone: TimeZone, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
