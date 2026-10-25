import Foundation

/// Hourly station readings over a backtest range, in inches and °F.
public struct StationHistory: Sendable {
    public var stationName: String
    public var elevationFt: Int
    public var depthInches: [Date: Double]
    public var tempF: [Date: Double]

    public init(stationName: String, elevationFt: Int, depthInches: [Date: Double], tempF: [Date: Double]) {
        self.stationName = stationName
        self.elevationFt = elevationFt
        self.depthInches = depthInches
        self.tempF = tempF
    }
}

/// Measures how often scores held: each day is scored from archived forecasts made 0 to 3 days
/// ahead and compared with a score of what happened. Pure; the fetching is in `notchline-fetch`.
public enum ConfidenceBacktest {
    /// Air cools about this much per 1,000 ft of climb, for moving station temperatures up to
    /// the forecast elevation.
    static let lapseFPerThousandFt = 3.5
    /// Depth at a time is the median of clean readings this close to it, which smooths the
    /// sensor's inch or so of noise.
    static let depthWindow: TimeInterval = 2 * 3600

    public struct Observed: Sendable {
        public var hourly: HourlyForecast
        /// Local days the station covered: depth at the last chair before, first chair and last
        /// chair, and temperature for at least half the lift hours.
        public var coveredDays: Set<Date>
    }

    /// What happened, as a series the scorer reads: the latest forecast for what stations do not
    /// measure (wind, cloud, precipitation), with the station's snow and temperature in place of
    /// the forecast's. Snow is the depth gained overnight (last chair to first chair) and during
    /// lift hours, spread over each stretch's hours as the forecast spread its snow, or evenly
    /// when the forecast had none. Where the station saw no new snow, the share of precipitation
    /// falling as rain follows the station's temperature.
    public static func observed(_ forecast: HourlyForecast, station: StationHistory, location: Location) -> Observed {
        let calendar = location.calendar
        let hours = forecast.hours.sorted { $0.start < $1.start }
        guard let first = hours.first, let last = hours.last else { return Observed(hourly: forecast, coveredDays: []) }

        let depthReadings = StationReadings.removeSpikes(
            station.depthInches.filter { $0.value >= 0 }.map { StationReadings.Reading(date: $0.key, value: $0.value) }.sorted { $0.date < $1.date })
        let tempReadings = StationReadings.removeSpikes(
            station.tempF.map { StationReadings.Reading(date: $0.key, value: $0.value) }.sorted { $0.date < $1.date },
            maxPerHour: StationReadings.maxDegreesPerHour)
        let temps = Dictionary(tempReadings.map { ($0.date, $0.value) }, uniquingKeysWith: { first, _ in first })
        let lapse = lapseFPerThousandFt * Double(location.forecastElevationFt - station.elevationFt) / 1000
        func depth(at date: Date) -> Double? {
            let near = depthReadings.filter { abs($0.date.timeIntervalSince(date)) <= depthWindow }.map(\.value)
            return near.isEmpty ? nil : StationReadings.median(of: near)
        }

        // Last chair and first chair of every day, so the stretches between them alternate
        // overnight and lift hours.
        var anchors: [Date] = []
        var day = calendar.startOfDay(for: first.start)
        while day <= last.start {
            if let lift = location.liftInterval(on: day) { anchors += [lift.start, lift.end] }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        var snow: [Date: Double] = [:]
        var gained: Set<Date> = []
        for (start, end) in zip(anchors, anchors.dropFirst()) {
            guard let before = depth(at: start), let after = depth(at: end) else { continue }
            gained.formUnion([start, end])
            let stretch = hours.filter { $0.start >= start && $0.start < end }
            guard !stretch.isEmpty else { continue }
            let gain = max(0, after - before)
            let forecastTotal = stretch.reduce(0) { $0 + max(0, $1.snowfallInches ?? 0) }
            for hour in stretch {
                snow[hour.start] = forecastTotal > 0 ? gain * max(0, hour.snowfallInches ?? 0) / forecastTotal : gain / Double(stretch.count)
            }
        }

        let observedHours = hours.map { hour -> ForecastHour in
            var hour = hour
            if let tempF = temps[hour.start] { hour.tempF = tempF - lapse }
            if let snowInches = snow[hour.start] {
                hour.snowfallInches = snowInches
                if snowInches > 0 {
                    hour.rainInches = 0
                } else if let precipitation = hour.precipitationInches, let tempF = hour.tempF, temps[hour.start] != nil {
                    hour.rainInches = precipitation * OpenMeteoProvider.rainShare(atC: Convert.celsius(fromF: tempF))
                }
                hour.precipitationTypes = []
                if snowInches > 0 { hour.precipitationTypes.insert(.snow) }
                if (hour.rainInches ?? 0) > 0 { hour.precipitationTypes.insert(.rain) }
            }
            return hour
        }

        var covered: Set<Date> = []
        day = calendar.startOfDay(for: first.start)
        while day <= last.start {
            defer { day = calendar.date(byAdding: .day, value: 1, to: day)! }
            guard let lift = location.liftInterval(on: day),
                  let index = anchors.firstIndex(of: lift.start), index > 0,
                  gained.isSuperset(of: [anchors[index - 1], lift.start, lift.end]) else { continue }
            let liftHours = hours.filter { $0.start >= lift.start && $0.start < lift.end }
            let withTemp = liftHours.filter { temps[$0.start] != nil }.count
            if !liftHours.isEmpty && 2 * withTemp >= liftHours.count { covered.insert(day) }
        }
        return Observed(hourly: HourlyForecast(hours: observedHours), coveredDays: covered)
    }

    /// One day's forecast and observed score for one terrain.
    public struct Sample: Sendable {
        public var location: String
        public var day: Date
        public var terrain: Terrain
        public var lead: Int
        public var agreement: ModelAgreement?
        public var forecast: Int
        public var observed: Int

        var error: Int { abs(forecast - observed) }
        var held: Bool { error <= ConfidenceRules.holdMarginPoints }
    }

    /// Samples for every covered day both scorings have. `forecast` and `models` come from runs
    /// made `lead` days ahead; `observed` from `observed(_:station:location:)`.
    public static func samples(location: Location, lead: Int, forecast: PlannerScores, models: [PlannerScores],
                               observed: PlannerScores, coveredDays: Set<Date>) -> [Sample] {
        let forecastScores = ForecastConfidence.windowScores(forecast)
        let observedScores = ForecastConfidence.windowScores(observed)
        let modelScores = models.map(ForecastConfidence.windowScores)
        return coveredDays.sorted().flatMap { day -> [Sample] in
            guard let predicted = forecastScores[day], let actual = observedScores[day] else { return [] }
            return Terrain.allCases.map { terrain in
                Sample(location: location.id, day: day, terrain: terrain, lead: lead,
                       agreement: ForecastConfidence.spread(modelScores, day: day, terrain: terrain).map(ModelAgreement.init(spread:)),
                       forecast: predicted[terrain]!, observed: actual[terrain]!)
            }
        }
    }

    /// Cells for each location and for all of them pooled, each by agreement and for any agreement.
    public static func table(_ samples: [Sample], seasons: [String]) -> ConfidenceTable {
        struct Key: Hashable {
            let location: String?
            let terrain: Terrain
            let lead: Int
            let agreement: ModelAgreement?
        }
        var groups: [Key: [Sample]] = [:]
        for sample in samples {
            for location in [sample.location, nil] {
                for agreement in Set([sample.agreement, nil]) {
                    groups[Key(location: location, terrain: sample.terrain, lead: sample.lead, agreement: agreement), default: []].append(sample)
                }
            }
        }
        let cells = groups.map { key, samples in
            ConfidenceTable.Cell(
                location: key.location, terrain: key.terrain, lead: key.lead, agreement: key.agreement,
                days: samples.count, held: samples.filter(\.held).count,
                meanError: (10 * Double(samples.reduce(0) { $0 + $1.error }) / Double(samples.count)).rounded() / 10)
        }
        .sorted { lhs, rhs in
            func order(_ cell: ConfidenceTable.Cell) -> [String] {
                [cell.location ?? "", cell.terrain.rawValue, "\(cell.lead)",
                 cell.agreement.map { "\(ModelAgreement.allCases.firstIndex(of: $0)! + 1)" } ?? "0"]
            }
            return order(lhs).lexicographicallyPrecedes(order(rhs))
        }
        return ConfidenceTable(seasons: seasons, holdMarginPoints: ConfidenceRules.holdMarginPoints, cells: cells)
    }
}
