import Foundation

/// How likely one terrain's score for a day is to hold.
public struct Confidence: Codable, Equatable, Sendable {
    /// 0 to 100.
    public var percent: Int
    /// Days after today, 0 for today.
    public var lead: Int
    /// Points between the highest and lowest comparison model's score. nil without the models.
    public var modelSpread: Int?
    /// From the backtest table rather than the fallback rule.
    public var isMeasured: Bool
}

public struct DayConfidence: Codable, Equatable, Sendable {
    public var groomed: Confidence
    public var ungroomed: Confidence

    public func confidence(_ terrain: Terrain) -> Confidence {
        terrain == .groomed ? groomed : ungroomed
    }
}

/// How far apart the comparison models' scores for a day are.
public enum ModelAgreement: String, Codable, CaseIterable, Sendable {
    case agree, differ, disagree

    public init(spread: Int) {
        self = spread >= ConfidenceRules.modelsDisagreePoints ? .disagree : spread >= ConfidenceRules.modelsDifferPoints ? .differ : .agree
    }
}

public enum ConfidenceRules {
    /// A score holds when the forecast is within this many points of what happened. The same
    /// margin that bounds the best window, since a smaller miss would not change the plan.
    public static let holdMarginPoints = ScoringRules.windowMargin
    static let modelsDifferPoints = 10
    static let modelsDisagreePoints = 25
    /// Days past +3 are scored like +3.
    static let maxLead = 3
    /// The fallback when no measured figure exists, by lead, before disagreement. Rounded from
    /// the 2024 to 2026 backtest, where disagreement cost far more than lead time.
    static let ruleLeadPercent = [90, 85, 80, 80]
    static func rulePenalty(_ agreement: ModelAgreement) -> Int {
        switch agreement {
        case .agree: 0
        case .differ: 15
        case .disagree: 30
        }
    }
    /// Days of the pooled rate a location's own rate is blended with, so a location with few
    /// measured days leans on every location's.
    static let pooledWeightDays = 20.0

    /// The rule: lower further out, and lower again when the models disagree.
    public static func rulePercent(lead: Int, agreement: ModelAgreement?) -> Int {
        ruleLeadPercent[min(max(lead, 0), maxLead)] - (agreement.map(rulePenalty) ?? 0)
    }
}

/// How often scores held in the backtest, by location, terrain, lead and model agreement.
/// Written by `scripts/backtest-confidence.sh`, shipped in the app's resources.
public struct ConfidenceTable: Codable, Equatable, Sendable {
    public struct Cell: Codable, Equatable, Sendable {
        /// nil for every location pooled.
        public var location: String?
        public var terrain: Terrain
        public var lead: Int
        /// nil for every level of agreement together.
        public var agreement: ModelAgreement?
        public var days: Int
        /// Days the forecast was within the hold margin of what happened.
        public var held: Int
        /// Mean points between forecast and what happened.
        public var meanError: Double

        public init(location: String?, terrain: Terrain, lead: Int, agreement: ModelAgreement?, days: Int, held: Int, meanError: Double) {
            self.location = location
            self.terrain = terrain
            self.lead = lead
            self.agreement = agreement
            self.days = days
            self.held = held
            self.meanError = meanError
        }

        var rate: Double { Double(held) / Double(days) }
    }

    /// Date ranges backtested, "yyyy-MM-dd...yyyy-MM-dd".
    public var seasons: [String]
    public var holdMarginPoints: Int
    public var cells: [Cell]

    public init(seasons: [String], holdMarginPoints: Int, cells: [Cell]) {
        self.seasons = seasons
        self.holdMarginPoints = holdMarginPoints
        self.cells = cells
    }

    /// The bundled `confidence.json`, found the same way as `locations.json`.
    public static func bundled() throws -> ConfidenceTable {
        let url = Bundle.main.url(forResource: "confidence", withExtension: "json")
            ?? Bundle.module.url(forResource: "confidence", withExtension: "json")
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        return try JSONDecoder().decode(ConfidenceTable.self, from: Data(contentsOf: url))
    }

    func cell(_ location: String?, _ terrain: Terrain, _ lead: Int, _ agreement: ModelAgreement?) -> Cell? {
        cells.first { $0.location == location && $0.terrain == terrain && $0.lead == lead && $0.agreement == agreement && $0.days > 0 }
    }

    /// The location's measured rate blended toward every location's, or every location's alone
    /// when the location has no station. Without enough days at that level of agreement, the
    /// rate for any agreement. nil when the table has nothing for the lead.
    public func percent(location: String, terrain: Terrain, lead: Int, agreement: ModelAgreement?) -> Int? {
        let lead = min(max(lead, 0), ConfidenceRules.maxLead)
        let levels = agreement.map { [$0, nil] } ?? [nil]
        for level in levels {
            guard let pooled = cell(nil, terrain, lead, level), Double(pooled.days) >= ConfidenceRules.pooledWeightDays else { continue }
            let weight = ConfidenceRules.pooledWeightDays
            let local = cell(location, terrain, lead, level)
            let rate = local.map { (Double($0.held) + weight * pooled.rate) / (Double($0.days) + weight) } ?? pooled.rate
            return Int((100 * rate).rounded())
        }
        return nil
    }
}

public enum ForecastConfidence {
    /// Sets each day's confidence from its lead and how far apart the comparison models' scores
    /// are. `models` are the comparison models' series scored like the main one; with fewer than
    /// two covering a day, that day has no spread. Measured rates come from `table` (normally
    /// `ConfidenceTable.bundled()`) when it has them, the rule otherwise.
    public static func apply(to scores: PlannerScores, models: [PlannerScores], location: Location, now: Date,
                             table: ConfidenceTable?) -> PlannerScores {
        let calendar = location.calendar
        let today = calendar.startOfDay(for: now)
        let modelScores = models.map(windowScores)
        var scores = scores
        for index in scores.days.indices {
            let day = scores.days[index].day
            let lead = calendar.dateComponents([.day], from: today, to: day).day ?? 0
            func confidence(_ terrain: Terrain) -> Confidence {
                let spread = spread(modelScores, day: day, terrain: terrain)
                let agreement = spread.map(ModelAgreement.init(spread:))
                if let measured = table?.percent(location: location.id, terrain: terrain, lead: lead, agreement: agreement) {
                    return Confidence(percent: measured, lead: lead, modelSpread: spread, isMeasured: true)
                }
                return Confidence(percent: ConfidenceRules.rulePercent(lead: lead, agreement: agreement), lead: lead, modelSpread: spread, isMeasured: false)
            }
            scores.days[index].confidence = DayConfidence(groomed: confidence(.groomed), ungroomed: confidence(.ungroomed))
        }
        return scores
    }

    /// Points between the highest and lowest model's score, nil with fewer than two models.
    static func spread(_ modelScores: [[Date: [Terrain: Int]]], day: Date, terrain: Terrain) -> Int? {
        let values = modelScores.compactMap { $0[day]?[terrain] }
        return values.count >= 2 ? values.max()! - values.min()! : nil
    }

    /// Each day's best-window average by terrain, 0 when every hour is vetoed.
    static func windowScores(_ scores: PlannerScores) -> [Date: [Terrain: Int]] {
        Dictionary(scores.days.map { day in
            (day.day, Dictionary(uniqueKeysWithValues: Terrain.allCases.map { ($0, day.window($0)?.averageScore ?? 0) }))
        }, uniquingKeysWith: { first, _ in first })
    }
}
