import Foundation

/// What the planner has learned from this Mac's archive: score weights fit to the user's ratings
/// and drive buffers tuned from logged and reported drives. Each part keeps the hand-tuned value
/// until there is enough data. Pure: the archive is read by the caller.
public struct PlannerLearning: Equatable, Sendable {
    public var groomed: WeightFit
    public var ungroomed: WeightFit
    public var buffers: TunedBuffers
    /// Records that couldn't be read.
    public var warnings: [String]

    /// Hand-tuned weights and the v1 buffer rule.
    public static let none = PlannerLearning(
        groomed: .handTuned(.groomed, ratedDays: 0), ungroomed: .handTuned(.ungroomed, ratedDays: 0),
        buffers: TunedBuffers(buffers: .rule, observations: [], tuned: []), warnings: [])

    public init(groomed: WeightFit, ungroomed: WeightFit, buffers: TunedBuffers, warnings: [String]) {
        self.groomed = groomed
        self.ungroomed = ungroomed
        self.buffers = buffers
        self.warnings = warnings
    }

    public static func learn(_ records: [PlannerDayRecord], settings: PlannerSettings) -> PlannerLearning {
        func fit(_ terrain: Terrain) -> WeightFit {
            WeightLearning.fit(WeightLearning.ratedDays(records, terrain: terrain, gustThresholdMph: settings.gustThresholdMph), terrain: terrain)
        }
        return PlannerLearning(
            groomed: fit(.groomed), ungroomed: fit(.ungroomed),
            buffers: BufferTuning.tune(BufferTuning.observations(records, settings: settings)), warnings: [])
    }

    public func fit(_ terrain: Terrain) -> WeightFit {
        terrain == .groomed ? groomed : ungroomed
    }

    /// The weights the planner scores with.
    public func weights(_ terrain: Terrain) -> ScoreWeights {
        fit(terrain).weights
    }
}

// MARK: - Weights

/// One rated day for one terrain: the factor values over that morning's best window, and the rating.
public struct RatedDay: Equatable, Sendable {
    public var locationID: String
    public var day: Date
    /// In `ScoreWeights.factorWeights` order.
    public var factors: [Double]
    public var rating: Int

    public init(locationID: String, day: Date, factors: [Double], rating: Int) {
        self.locationID = locationID
        self.day = day
        self.factors = factors
        self.rating = rating
    }
}

public struct WeightFit: Equatable, Sendable {
    public var terrain: Terrain
    public var ratedDays: Int
    /// What the planner scores with: the learned weights when they predicted held-out ratings
    /// better than the hand-tuned ones did, otherwise the hand-tuned weights.
    public var weights: ScoreWeights
    public var isLearned: Bool
    /// The fit to every rated day, nil below the minimum.
    public var candidate: ScoreWeights?
    /// Root mean square error in rating points, predicting each rated day from the others.
    public var learnedError: Double?
    public var handTunedError: Double?

    static func handTuned(_ terrain: Terrain, ratedDays: Int) -> WeightFit {
        WeightFit(terrain: terrain, ratedDays: ratedDays, weights: .handTuned(terrain), isLearned: false)
    }
}

/// Fits the five factor weights of each terrain to the user's 1 to 5 ratings. The model is linear:
/// rating = a + b × (weighted factor sum), with the weights kept non-negative and summing to 1 so
/// the score keeps its 0 to 100 scale. a and b only map the score onto ratings; the planner uses
/// the weights alone. A penalty keeps the weights near the hand-tuned ones, so a few odd days
/// can't swing them far.
public enum WeightLearning {
    public static let minimumRatedDays = 20
    /// The penalty per unit of squared weight change, in squared rating points.
    static let priorStrength = 1.0
    static let maxIterations = 2000
    static let tolerance = 1e-7
    /// Learned weights must predict held-out ratings at least this much better, in rating points,
    /// so noise alone doesn't replace the hand-tuned weights.
    static let minimumImprovement = 0.05

    /// Rated days for `terrain`, with factors recomputed from the stored morning forecast. Days
    /// whose every hour was vetoed are left out, since no weights would change their score.
    public static func ratedDays(_ records: [PlannerDayRecord], terrain: Terrain, gustThresholdMph: Double) -> [RatedDay] {
        let weights = ScoreWeights.handTuned(terrain)
        return records.compactMap { record in
            guard let rating = record.rating, rating.skied, let value = rating.rating(terrain), DayRating.scale.contains(value),
                  let morning = record.morning, let window = morning.plan.score.window(terrain) else { return nil }
            var sums = [Double](repeating: 0, count: ScoreWeights.factorNames.count)
            var duration = 0.0
            for hour in morning.plan.score.hours where hour.veto == nil
                && hour.interval.start >= window.interval.start && hour.interval.end <= window.interval.end {
                guard let forecast = morning.forecast.first(where: { $0.start <= hour.interval.start && hour.interval.start < $0.start.addingTimeInterval(3600) }) else { continue }
                let factors = SkiDayScorer.factors(forecast, freshSnowInches: hour.freshSnowInches, icy: hour.isIcy, gustThresholdMph: gustThresholdMph, weights: weights)
                for index in sums.indices { sums[index] += factors[index] * hour.interval.duration }
                duration += hour.interval.duration
            }
            guard duration > 0 else { return nil }
            return RatedDay(locationID: record.locationID, day: record.day, factors: sums.map { $0 / duration }, rating: value)
        }
    }

    /// Learned weights when there are enough rated days and they clearly beat the hand-tuned
    /// weights at predicting each day from the others; the hand-tuned weights otherwise.
    public static func fit(_ days: [RatedDay], terrain: Terrain) -> WeightFit {
        var result = WeightFit.handTuned(terrain, ratedDays: days.count)
        guard days.count >= minimumRatedDays else { return result }
        let handTuned = ScoreWeights.handTuned(terrain)
        let prior = handTuned.factorWeights.map { $0 / handTuned.total }
        let learned = fitWeights(days, prior: prior).map { ($0 * 1000).rounded() / 1000 }
        let candidate = handTuned.replacingFactorWeights(learned)
        result.candidate = candidate
        result.learnedError = leaveOneOutError(days, prior: prior, learn: true)
        result.handTunedError = leaveOneOutError(days, prior: prior, learn: false)
        if result.learnedError! <= result.handTunedError! - minimumImprovement {
            result.weights = candidate
            result.isLearned = true
        }
        return result
    }

    /// Projected gradient descent on the weights, refitting a and b by least squares each step.
    static func fitWeights(_ days: [RatedDay], prior: [Double]) -> [Double] {
        guard !days.isEmpty else { return prior }
        let count = Double(days.count)
        let meanNormSquared = days.reduce(0) { $0 + dot($1.factors, $1.factors) } / count
        var weights = prior
        for _ in 0..<maxIterations {
            let (a, b) = calibration(days, weights)
            var gradient = zip(weights, prior).map { 2 * priorStrength * ($0 - $1) }
            for day in days {
                let residual = a + b * dot(weights, day.factors) - Double(day.rating)
                for index in gradient.indices { gradient[index] += 2 * residual * b * day.factors[index] / count }
            }
            // A step under the inverse of the gradient's Lipschitz bound, so it can't overshoot.
            let step = 1 / (2 * (b * b * meanNormSquared + priorStrength))
            let next = projectToSimplex(zip(weights, gradient).map { $0 - step * $1 })
            let change = zip(next, weights).map { abs($0 - $1) }.max() ?? 0
            weights = next
            if change < tolerance { break }
        }
        return weights
    }

    /// Least squares a and b for rating = a + b × score, with b at least 0 so a higher score
    /// never means a worse day.
    static func calibration(_ days: [RatedDay], _ weights: [Double]) -> (a: Double, b: Double) {
        let scores = days.map { dot(weights, $0.factors) }
        let ratings = days.map { Double($0.rating) }
        let meanScore = scores.reduce(0, +) / Double(days.count)
        let meanRating = ratings.reduce(0, +) / Double(days.count)
        let variance = scores.reduce(0) { $0 + pow($1 - meanScore, 2) }
        let covariance = zip(scores, ratings).reduce(0) { $0 + ($1.0 - meanScore) * ($1.1 - meanRating) }
        guard variance > 1e-12, covariance > 0 else { return (meanRating, 0) }
        let b = covariance / variance
        return (meanRating - b * meanScore, b)
    }

    /// Each day predicted from a fit to the others, with the weights learned or held at `prior`.
    static func leaveOneOutError(_ days: [RatedDay], prior: [Double], learn: Bool) -> Double {
        let squared = days.indices.map { held -> Double in
            var training = days
            let test = training.remove(at: held)
            let weights = learn ? fitWeights(training, prior: prior) : prior
            let (a, b) = calibration(training, weights)
            let predicted = min(5, max(1, a + b * dot(weights, test.factors)))
            return pow(predicted - Double(test.rating), 2)
        }
        return sqrt(squared.reduce(0, +) / Double(days.count))
    }

    /// The nearest point with every value at least 0 and a sum of 1.
    static func projectToSimplex(_ values: [Double]) -> [Double] {
        let sorted = values.sorted(by: >)
        var cumulative = 0.0
        var theta = 0.0
        for (index, value) in sorted.enumerated() {
            cumulative += value
            let candidate = (cumulative - 1) / Double(index + 1)
            if value - candidate > 0 { theta = candidate }
        }
        return values.map { max(0, $0 - theta) }
    }

    static func dot(_ x: [Double], _ y: [Double]) -> Double {
        zip(x, y).reduce(0) { $0 + $1.0 * $1.1 }
    }
}

// MARK: - Drive buffers

/// One morning's drive: Apple's estimate the plan used, and what the drive turned out to take.
public struct DriveObservation: Equatable, Sendable {
    public enum Source: String, Sendable {
        /// From the left-home and on-the-lift times given with a rating.
        case reported
        /// Apple's live estimate logged nearest the planned departure.
        case logged
    }

    public var locationID: String
    public var day: Date
    public var condition: RoadCondition
    public var drawsCrowd: Bool
    public var isBusy: Bool
    /// Apple's estimate for the planned arrival, without buffers.
    public var predicted: TimeInterval
    public var observed: TimeInterval
    public var source: Source

    public init(locationID: String, day: Date, condition: RoadCondition, drawsCrowd: Bool, isBusy: Bool, predicted: TimeInterval, observed: TimeInterval, source: Source) {
        self.locationID = locationID
        self.day = day
        self.condition = condition
        self.drawsCrowd = drawsCrowd
        self.isBusy = isBusy
        self.predicted = predicted
        self.observed = observed
        self.source = source
    }

    /// How much longer the drive took than Apple's estimate.
    public var excess: TimeInterval { observed - predicted }
}

public struct TunedBuffers: Equatable, Sendable {
    /// The rule, with each part that had enough drives replaced.
    public var buffers: DriveBuffers
    public var observations: [DriveObservation]
    /// The parts that were tuned, by name ("snow", "crowds"), in a fixed order.
    public var tuned: [String]
}

/// A group of drives that share a condition, for reports.
public struct DriveGroup: Equatable, Sendable {
    public var name: String
    public var days: Int
    public var medianExcess: TimeInterval
}

/// Tunes the road and crowd buffers from observed drives. Road shares come from days that don't
/// draw a crowd. Crowd buffers come from crowd days, after taking off the road buffer.
public enum BufferTuning {
    public static let minimumDays = 5
    /// Buffers cover this share of observed drives, so the departure is early enough on most
    /// days rather than half of them.
    static let quantile = 0.75
    static let maxRoadShare = 1.0
    static let maxCrowd: TimeInterval = 90 * 60
    /// A reported drive outside this ratio to Apple's estimate is taken as a typo.
    static let plausibleRatio = 0.5...3.0
    /// A logged sample stands for the planned departure when it's within this of it.
    static let sampleTolerance: TimeInterval = 20 * 60
    static let roadConditions: [RoadCondition] = [.freezing, .snow, .heavySnow, .freezingRain]

    /// One per morning plan with a departure and a drive to compare: the reported drive when the
    /// rating gave both times, otherwise the logged sample nearest the planned departure. The
    /// headline terrain's departure stands for the day.
    public static func observations(_ records: [PlannerDayRecord], settings: PlannerSettings) -> [DriveObservation] {
        records.compactMap { record in
            guard let plan = record.morning?.plan,
                  let departure = plan.score.best.flatMap(plan.departure) ?? plan.groomed ?? plan.ungroomed else { return nil }
            let drive = departure.drive
            var observed: (TimeInterval, DriveObservation.Source)?
            if let rating = record.rating, rating.skied, let left = rating.leftHomeAt, let onLift = rating.onLiftAt {
                let arrivalToLift = TimeInterval(settings.settings(for: record.locationID).arrivalToLiftMinutes * 60)
                let actual = onLift.timeIntervalSince(left) - arrivalToLift
                if plausibleRatio.contains(actual / drive.driveTime) { observed = (actual, .reported) }
            }
            if observed == nil, let sample = record.travelTimes
                .filter({ abs($0.at.timeIntervalSince(drive.leaveAt)) <= sampleTolerance })
                .min(by: { abs($0.at.timeIntervalSince(drive.leaveAt)) < abs($1.at.timeIntervalSince(drive.leaveAt)) }) {
                observed = (sample.driveTime, .logged)
            }
            guard let (time, source) = observed else { return nil }
            return DriveObservation(
                locationID: record.locationID, day: record.day, condition: drive.roadCondition, drawsCrowd: plan.score.drawsCrowd,
                isBusy: plan.score.isBusy, predicted: drive.driveTime, observed: time, source: source)
        }
    }

    public static func tune(_ observations: [DriveObservation]) -> TunedBuffers {
        var buffers = DriveBuffers.rule
        var tuned: [String] = []
        let quiet = observations.filter { !$0.drawsCrowd }
        for condition in roadConditions {
            let shares = quiet.filter { $0.condition == condition }.map { $0.excess / $0.predicted }
            guard shares.count >= minimumDays, let share = percentile(shares, quantile) else { continue }
            buffers.setRoadShare(condition, (min(maxRoadShare, max(0, share)) * 100).rounded() / 100)
            tuned.append(PlannerFormat.roadCondition(condition))
        }
        for busy in [false, true] {
            let extras = observations.filter { $0.drawsCrowd && $0.isBusy == busy }
                .map { $0.excess - buffers.roadShare($0.condition) * $0.predicted }
            guard extras.count >= minimumDays, let extra = percentile(extras, quantile) else { continue }
            let buffer = (min(maxCrowd, max(0, extra)) / 300).rounded(.up) * 300
            if busy { buffers.busyCrowd = buffer } else { buffers.crowd = buffer }
            tuned.append(busy ? "weekend crowds" : "crowds")
        }
        return TunedBuffers(buffers: buffers, observations: observations, tuned: tuned)
    }

    /// Drives grouped as quiet days by road condition, then crowd days, for testing the crowd
    /// hypothesis: crowd days should run longer than quiet days in the same weather.
    public static func groups(_ observations: [DriveObservation]) -> [DriveGroup] {
        var groups: [(String, [DriveObservation])] = ([.clear] + roadConditions).map { condition in
            (PlannerFormat.roadCondition(condition), observations.filter { !$0.drawsCrowd && $0.condition == condition })
        }
        groups.append(("crowd, weekday", observations.filter { $0.drawsCrowd && !$0.isBusy }))
        groups.append(("crowd, weekend or holiday", observations.filter { $0.drawsCrowd && $0.isBusy }))
        return groups.compactMap { name, drives in
            percentile(drives.map(\.excess), 0.5).map { DriveGroup(name: name, days: drives.count, medianExcess: $0) }
        }
    }

    /// Linear between the nearest ranks; nil when empty.
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = p * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = min(sorted.count - 1, lower + 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (rank - Double(lower))
    }
}

extension PlannerFormat {
    /// One paragraph for Settings on what the planner has learned so far.
    public static func learning(_ learning: PlannerLearning) -> String {
        let terrains = [learning.groomed, learning.ungroomed].map { fit -> String in
            let name = fit.terrain.rawValue.capitalized
            if fit.isLearned { return "\(name) scores use weights learned from your \(fit.ratedDays) rated days." }
            if fit.ratedDays < WeightLearning.minimumRatedDays {
                return "\(name) scores use the default weights until you've rated \(WeightLearning.minimumRatedDays) days (\(fit.ratedDays) so far)."
            }
            return "\(name) scores use the default weights, which still predict your \(fit.ratedDays) ratings better than learned ones."
        }
        let tuned = learning.buffers.tuned
        let buffers = tuned.isEmpty
            ? "Drive buffers use the defaults until there are \(BufferTuning.minimumDays) logged or reported drives in the same conditions."
            : "Drive buffers for \(list(tuned)) are tuned from \(learning.buffers.observations.count) drives."
        return (terrains + [buffers]).joined(separator: " ")
    }

    /// "snow", "snow and crowds", "icy roads, snow and crowds"
    static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }
}
