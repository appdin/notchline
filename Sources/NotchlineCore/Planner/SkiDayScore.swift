import Foundation

public enum Terrain: String, Codable, CaseIterable, Sendable {
    case groomed, ungroomed
}

/// Why a lift hour scores zero for both terrains.
public enum Veto: String, Codable, Sendable {
    case rain, wind, visibility
}

public struct HourScore: Codable, Equatable, Sendable {
    /// The part of the hour the lifts run.
    public var interval: DateInterval
    public var groomed: Int
    public var ungroomed: Int
    public var veto: Veto?
    /// Fresh snow still untracked at the start of the hour, in inches.
    public var freshSnowInches: Double
    /// Rain has refrozen into a crust that new snow has not yet covered.
    public var isIcy: Bool

    public func score(_ terrain: Terrain) -> Int {
        terrain == .groomed ? groomed : ungroomed
    }
}

/// The best stretch of a day for one terrain: hours close to the day's peak, contiguous.
public struct ScoreWindow: Codable, Equatable, Sendable {
    public var interval: DateInterval
    /// Mean score over the window, weighted by how much of each hour the lifts run.
    public var averageScore: Int
    public var peakScore: Int
}

public struct DayScore: Codable, Equatable, Sendable {
    /// Local midnight.
    public var day: Date
    /// Typical lift hours that day.
    public var liftHours: DateInterval
    public var hours: [HourScore]
    /// nil when every hour is vetoed or, today, already over.
    public var groomed: ScoreWindow?
    public var ungroomed: ScoreWindow?
    /// Snow since the last chair of the last skiable day, as of first chair.
    public var newSnowInches: Double
    /// A weekend or holiday.
    public var isBusy: Bool
    /// The forecast looks good enough to draw a crowd, so fresh snow goes faster.
    public var drawsCrowd: Bool
    /// How likely each score is to hold. Set by `ForecastConfidence.apply`, nil from the scorer.
    public var confidence: DayConfidence? = nil

    public func window(_ terrain: Terrain) -> ScoreWindow? {
        terrain == .groomed ? groomed : ungroomed
    }

    /// The terrain whose window scores higher, which the headline leads with. Ties go to ungroomed.
    public var best: Terrain? {
        switch (groomed, ungroomed) {
        case (nil, nil): nil
        case (_?, nil): .groomed
        case (nil, _?): .ungroomed
        case let (groomed?, ungroomed?): groomed.averageScore > ungroomed.averageScore ? .groomed : .ungroomed
        }
    }
}

public struct PlannerScores: Codable, Equatable, Sendable {
    /// Today and later days the hourly series covers, in order.
    public var days: [DayScore]
    /// Gaps in the forecast that were scored as neutral or left out.
    public var warnings: [String]
}

/// Factor weights for one terrain. The five weights sum to 1. Hand tuned for now, against two
/// Mt. Baker seasons; Phase 6 fits them to the user's ratings.
public struct ScoreWeights: Codable, Equatable, Sendable {
    public var freshSnow: Double
    public var snowQuality: Double
    public var surface: Double
    public var wind: Double
    public var light: Double
    /// How much fully flat light takes off the light factor, 0 to 1.
    public var flatLightSensitivity: Double
    /// The surface factor on a refrozen crust.
    public var icySurface: Double
    /// The score of a perfect hour. Below 100 for groomed runs, so that the best corduroy day
    /// still ranks under a deep powder day when the headline compares the two.
    public var ceiling: Double

    public init(freshSnow: Double, snowQuality: Double, surface: Double, wind: Double, light: Double, flatLightSensitivity: Double, icySurface: Double, ceiling: Double) {
        self.freshSnow = freshSnow
        self.snowQuality = snowQuality
        self.surface = surface
        self.wind = wind
        self.light = light
        self.flatLightSensitivity = flatLightSensitivity
        self.icySurface = icySurface
        self.ceiling = ceiling
    }

    /// Grooming flattens new snow, so it counts for little. Temperature, surface, wind and light
    /// make the day: a cold, calm, clear day with no new snow scores about 77.
    public static let groomed = ScoreWeights(freshSnow: 0.10, snowQuality: 0.25, surface: 0.20, wind: 0.20, light: 0.25, flatLightSensitivity: 0.3, icySurface: 0.2, ceiling: 85)
    /// New snow dominates, and flat light hides the terrain. With no new snow the best is about 35;
    /// 10" at first chair in falling snow is about 90.
    public static let ungroomed = ScoreWeights(freshSnow: 0.65, snowQuality: 0.10, surface: 0.05, wind: 0.10, light: 0.10, flatLightSensitivity: 0.5, icySurface: 0.1, ceiling: 100)

    public static func handTuned(_ terrain: Terrain) -> ScoreWeights {
        terrain == .groomed ? groomed : ungroomed
    }

    var total: Double { freshSnow + snowQuality + surface + wind + light }
}

/// Fixed thresholds behind the scores. Each is a rule of thumb, to revisit with rated days.
public enum ScoringRules {
    /// Precipitation counts as happening at this chance, or with a measurable amount.
    static let likelyPrecipitationPercent = 50.0
    static let measurableInches = 0.01
    /// Snow usually falls to about this far below the freezing level.
    static let snowLevelBelowFreezingLevelFt = 1000.0
    static let nearZeroVisibilityMiles = 0.1
    /// A wet surface at or below this refreezes into crust.
    static let refreezeF = 30.0
    /// New snow that buries a crust.
    static let crustCoverInches = 2.0
    /// A forecast this much new snow is the kind that brings a crowd.
    static let crowdDrawInches = 6.0
    /// Lift hours for half of the fresh snow to get tracked out on a quiet day.
    static let freshSnowHalfLifeHours = 3.0
    static let busyDayHalfLifeFactor = 0.5
    static let crowdDrawHalfLifeFactor = 0.67
    /// Hours within this many points of the day's peak extend its best window.
    static let windowMargin = 15
}

/// Groomed and ungroomed scores for every lift hour. Pure: no I/O, no clock.
public enum SkiDayScorer {
    /// Scores each day from the one containing `now` through the end of `hourly`. Earlier hours
    /// in the series still count toward new snow and crust. `priorSnowInches` is new snow from
    /// before the series starts, see `priorSnowInches(observed:hourly:)`.
    public static func score(
        _ hourly: HourlyForecast,
        location: Location,
        now: Date,
        gustThresholdMph: Double,
        priorSnowInches: Double = 0,
        weights: (Terrain) -> ScoreWeights = ScoreWeights.handTuned
    ) -> PlannerScores {
        guard location.liftHours != nil else {
            return PlannerScores(days: [], warnings: ["\(location.name) has no lift hours, so it has no ski day scores"])
        }
        let calendar = location.calendar
        let elevationFt = Double(location.forecastElevationFt)
        let hours = hourly.hours.sorted { $0.start < $1.start }
        guard let first = hours.first else {
            return PlannerScores(days: [], warnings: ["No hourly forecast to score"])
        }
        let today = calendar.startOfDay(for: now)
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"

        var surface = SurfaceState()
        var deposits: [(at: Date, inches: Double)] = priorSnowInches > 0 ? [(first.start, priorSnowInches)] : []
        var lastSkiableClose: Date?
        var days: [DayScore] = []
        var warnings: [String] = []

        let byDay = Dictionary(grouping: hours) { calendar.startOfDay(for: $0.start) }
        for day in byDay.keys.sorted() {
            let dayHours = byDay[day]!
            let lift = location.liftInterval(on: day)!
            let busy = BusyDays.isBusy(day, country: location.country, calendar: calendar)
            if let close = lastSkiableClose { deposits.removeAll { $0.at < close } }
            var missing: [String: Int] = [:]
            var scored: [HourScore] = []
            var halfLife: Double?
            var newSnow = 0.0
            var drawsCrowd = false

            for hour in dayHours {
                let raining = isRaining(hour, elevationFt: elevationFt)
                if raining {
                    // Rain ruins new snow.
                    deposits.removeAll()
                } else if let snow = hour.snowfallInches, snow > 0 {
                    deposits.append((hour.start, snow))
                }
                surface.update(raining: raining, snowInches: raining ? 0 : hour.snowfallInches ?? 0, tempF: hour.tempF)

                guard let open = DateInterval(start: hour.start, duration: 3600).intersection(with: lift), open.duration > 0 else { continue }
                if halfLife == nil {
                    newSnow = deposits.reduce(0) { $0 + $1.inches }
                    drawsCrowd = newSnow >= ScoringRules.crowdDrawInches
                    halfLife = ScoringRules.freshSnowHalfLifeHours
                        * (busy ? ScoringRules.busyDayHalfLifeFactor : 1)
                        * (drawsCrowd ? ScoringRules.crowdDrawHalfLifeFactor : 1)
                }
                let fresh = deposits.reduce(0) { total, deposit in
                    let tracked = max(0, open.start.timeIntervalSince(max(deposit.at, lift.start))) / 3600
                    return total + deposit.inches * pow(0.5, tracked / halfLife!)
                }
                if hour.tempF == nil { missing["temperature", default: 0] += 1 }
                if hour.wind == nil { missing["wind", default: 0] += 1 }
                if hour.snowfallInches == nil { missing["snowfall", default: 0] += 1 }
                if hour.skyCoverPercent == nil && hour.visibilityMiles == nil { missing["cloud cover", default: 0] += 1 }
                if hour.precipitationInches == nil && hour.precipitationProbability == nil && hour.rainInches == nil && hour.precipitationTypes.isEmpty {
                    missing["precipitation", default: 0] += 1
                }
                let veto = veto(hour, raining: raining, gustThresholdMph: gustThresholdMph)
                func score(_ terrain: Terrain) -> Int {
                    guard veto == nil else { return 0 }
                    return terrainScore(hour, freshSnowInches: fresh, icy: surface.isIcy, gustThresholdMph: gustThresholdMph, weights: weights(terrain))
                }
                scored.append(HourScore(interval: open, groomed: score(.groomed), ungroomed: score(.ungroomed), veto: veto, freshSnowInches: fresh, isIcy: surface.isIcy))
            }

            if scored.contains(where: { $0.veto == nil }) { lastSkiableClose = lift.end }
            guard day >= today else { continue }

            let name = dayFormatter.string(from: day)
            let starts = Set(dayHours.map(\.start))
            let floor = calendar.dateInterval(of: .hour, for: lift.start)!.start
            let gaps = stride(from: floor, to: lift.end, by: 3600).filter { !starts.contains($0) }.count
            if gaps > 0 { warnings.append("\(name): no forecast for \(gaps) lift \(gaps == 1 ? "hour" : "hours"), left out") }
            for (field, count) in missing.sorted(by: { $0.key < $1.key }) {
                warnings.append("\(name): no \(field) for \(count) lift \(count == 1 ? "hour" : "hours"), scored as neutral")
            }
            let ahead = scored.filter { $0.interval.end > now }
            days.append(DayScore(
                day: day,
                liftHours: lift,
                hours: scored,
                groomed: bestWindow(ahead, .groomed),
                ungroomed: bestWindow(ahead, .ungroomed),
                newSnowInches: newSnow,
                isBusy: busy,
                drawsCrowd: drawsCrowd))
        }
        return PlannerScores(days: days, warnings: warnings)
    }

    /// New snow that fell before `hourly` starts: the station's last 24 hours less what the
    /// series already counts between its start and the station reading.
    public static func priorSnowInches(observed: ObservedSnow?, hourly: HourlyForecast) -> Double {
        guard let observed, let snow24h = observed.snow24hInches, let start = hourly.hours.first?.start else { return 0 }
        let counted = hourly.hours
            .filter { $0.start >= start && $0.start < observed.observedAt }
            .reduce(0) { $0 + ($1.snowfallInches ?? 0) }
        return max(0, snow24h - counted)
    }

    // MARK: - Vetoes

    /// Rain at the forecast elevation, when precipitation is likely. Open-Meteo's rain amount
    /// decides on its own; otherwise a rain-only type, then the snow level, then the freezing
    /// level less the usual gap to the snow level.
    static func isRaining(_ hour: ForecastHour, elevationFt: Double) -> Bool {
        if let rain = hour.rainInches, rain >= ScoringRules.measurableInches { return true }
        let likely = (hour.precipitationInches ?? 0) >= ScoringRules.measurableInches
            || (hour.precipitationProbability ?? 0) >= ScoringRules.likelyPrecipitationPercent
        guard likely else { return false }
        let types = hour.precipitationTypes
        let rainType = !types.isDisjoint(with: [.rain, .freezingRain])
        if rainType && !types.contains(.snow) { return true }
        if let snowLevel = hour.snowLevelFt { return snowLevel > elevationFt }
        if hour.rainInches == nil, let freezingLevel = hour.freezingLevelFt, (hour.snowfallInches ?? 0) == 0 {
            return freezingLevel - ScoringRules.snowLevelBelowFreezingLevelFt > elevationFt
        }
        // Mixed rain and snow with no level to decide by is wet either way.
        return rainType
    }

    static func veto(_ hour: ForecastHour, raining: Bool, gustThresholdMph: Double) -> Veto? {
        if raining { return .rain }
        if let gust = hour.wind?.gustMph, gust > gustThresholdMph { return .wind }
        if let visibility = hour.visibilityMiles, visibility < ScoringRules.nearZeroVisibilityMiles { return .visibility }
        return nil
    }

    // MARK: - Factors, each 0 to 1

    static func terrainScore(_ hour: ForecastHour, freshSnowInches: Double, icy: Bool, gustThresholdMph: Double, weights: ScoreWeights) -> Int {
        let value = weights.freshSnow * freshSnowFactor(freshSnowInches)
            + weights.snowQuality * snowQualityFactor(hour.tempF)
            + weights.surface * (icy ? weights.icySurface : 1)
            + weights.wind * windFactor(hour.wind, gustThresholdMph: gustThresholdMph)
            + weights.light * lightFactor(hour, sensitivity: weights.flatLightSensitivity)
        return Int((weights.ceiling * value / weights.total).rounded())
    }

    /// Rises quickly, then levels off: 3" is 0.53, 6" is 0.78, 12" is 0.95.
    static func freshSnowFactor(_ inches: Double) -> Double {
        1 - exp(-max(0, inches) / 4)
    }

    /// Cold, dry snow is best; it gets heavy toward freezing and wet above it. Neutral when unknown.
    static func snowQualityFactor(_ tempF: Double?) -> Double {
        guard let tempF else { return 0.5 }
        return interpolate(tempF, [(-10, 0.7), (10, 1), (25, 1), (32, 0.6), (40, 0.2)])
    }

    /// The worse of sustained wind and gusts. Gusts approaching the lift-closure threshold make
    /// for a rough day even while lifts run.
    static func windFactor(_ wind: Wind?, gustThresholdMph: Double) -> Double {
        guard let wind else { return 0.7 }
        let sustained = interpolate(wind.sustainedMph, [(10, 1), (30, 0.3), (40, 0.1)])
        let gust = wind.gustMph.map { interpolate($0, [(20, 1), (max(21, gustThresholdMph), 0.4)]) } ?? 1
        return min(sustained, gust)
    }

    /// Flat light from cloud, fog or falling snow, whichever is worst. Half flat when unknown.
    static func lightFactor(_ hour: ForecastHour, sensitivity: Double) -> Double {
        let sources = [
            hour.skyCoverPercent.map { 0.7 * $0 / 100 },
            hour.visibilityMiles.map { interpolate($0, [(0.25, 1), (1, 0.5), (5, 0)]) },
            hour.snowfallInches.map { interpolate($0, [(0, 0), (0.5, 0.8)]) },
        ].compactMap { $0 }
        let flatness = hour.skyCoverPercent == nil && hour.visibilityMiles == nil ? max(0.5, sources.max() ?? 0) : sources.max() ?? 0
        return 1 - sensitivity * flatness
    }

    static func interpolate(_ x: Double, _ points: [(x: Double, y: Double)]) -> Double {
        Piecewise.linear(x, points)
    }

    // MARK: - Windows

    /// The contiguous run of hours that gains most from hours near the day's peak, where each
    /// hour adds its score less (peak - margin), weighted by how much of it the lifts run.
    /// Hours well below the peak end the run. Ties keep the earlier window.
    static func bestWindow(_ hours: [HourScore], _ terrain: Terrain) -> ScoreWindow? {
        bestWindows(hours, terrain).first
    }

    /// Every window tied for the most gain, earliest first, so departure planning can pick the
    /// shortest drive among them.
    public static func bestWindows(_ hours: [HourScore], _ terrain: Terrain) -> [ScoreWindow] {
        guard let peak = hours.map({ $0.score(terrain) }).max(), peak > 0 else { return [] }
        let cutoff = Double(peak - ScoringRules.windowMargin)
        var bestSum = 0.0
        var ranges: [ClosedRange<Int>] = []
        var runStart = 0
        var runSum = 0.0
        for (index, hour) in hours.enumerated() {
            let gain = (Double(hour.score(terrain)) - cutoff) * hour.interval.duration / 3600
            let continues = index > 0 && hours[index - 1].interval.end == hour.interval.start
            if !continues || runSum <= 0 {
                runStart = index
                runSum = 0
            }
            runSum += gain
            if runSum > bestSum + 1e-9 {
                bestSum = runSum
                ranges = [runStart...index]
            } else if abs(runSum - bestSum) <= 1e-9, bestSum > 0, !ranges.contains(where: { $0.lowerBound == runStart }) {
                // A tie that starts later; one that only extends an earlier run adds nothing new.
                ranges.append(runStart...index)
            }
        }
        return ranges.map { range in
            let window = hours[range]
            let duration = window.reduce(0) { $0 + $1.interval.duration }
            let weighted = window.reduce(0) { $0 + Double($1.score(terrain)) * $1.interval.duration }
            return ScoreWindow(
                interval: DateInterval(start: window.first!.interval.start, end: window.last!.interval.end),
                averageScore: Int((weighted / duration).rounded()),
                peakScore: window.map { $0.score(terrain) }.max()!)
        }
    }
}

/// Tracks rain then refreeze since the last snowfall. Enough new snow on a wet or icy surface buries it.
struct SurfaceState {
    private(set) var isIcy = false
    private var isWet = false
    private var snowOnTop = 0.0

    mutating func update(raining: Bool, snowInches: Double, tempF: Double?) {
        if raining {
            isWet = true
            snowOnTop = 0
        } else if isWet || isIcy {
            snowOnTop += snowInches
            if snowOnTop >= ScoringRules.crustCoverInches {
                isWet = false
                isIcy = false
            }
        }
        if isWet, let tempF, tempF <= ScoringRules.refreezeF {
            isIcy = true
            isWet = false
        }
    }
}
