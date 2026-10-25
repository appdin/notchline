import Foundation

/// The whole planner for one location: scores from the snapshot's hourly forecast, confidence
/// from the comparison models, then departures, with whatever has been learned from ratings and drives. The app and `notchline-fetch` both plan through it.
public struct SkiDayPlanner: Sendable {
    /// The comparison models' hourly series, keyed by model.
    public typealias ModelForecasts = @Sendable (Location, Date) async throws -> [String: HourlyForecast]

    let travel: TravelTimeProvider
    private let roadWeather: RoadWeatherProvider?
    private let modelForecasts: ModelForecasts?
    private let table: ConfidenceTable?
    private let tableWarning: String?

    public init(travel: TravelTimeProvider, roadWeather: RoadWeatherProvider?, modelForecasts: ModelForecasts?, table: ConfidenceTable?, tableWarning: String? = nil) {
        self.travel = travel
        self.roadWeather = roadWeather
        self.modelForecasts = modelForecasts
        self.table = table
        self.tableWarning = tableWarning
    }

    /// Apple Maps drive times, Open-Meteo road weather and comparison models, and the bundled confidence table.
    public static func live(http: HTTPClient = RetryingHTTPClient(URLSessionHTTPClient())) -> SkiDayPlanner {
        let openMeteo = OpenMeteoProvider(http: http)
        var table: ConfidenceTable?
        var tableWarning: String?
        do {
            table = try ConfidenceTable.bundled()
        } catch {
            tableWarning = "No confidence table (\(error)); confidence uses the rule"
        }
        return SkiDayPlanner(
            travel: CachedTravelTimes(MapKitTravelTimes()),
            roadWeather: openMeteo.roadWeather,
            modelForecasts: { try await openMeteo.modelForecasts(for: $0, now: $1) },
            table: table, tableWarning: tableWarning)
    }

    /// The plan for `location`, or nil when the snapshot has no hourly forecast to score. The
    /// comparison models are scored with the same weights as the forecast.
    public func plan(_ snapshot: ConditionsSnapshot, location: Location, settings: PlannerSettings, now: Date, learning: PlannerLearning = .none) async -> SkiDayPlan? {
        guard let hourly = snapshot.forecast?.hourly else { return nil }
        func score(_ series: HourlyForecast) -> PlannerScores {
            SkiDayScorer.score(
                series, location: location, now: now, gustThresholdMph: settings.gustThresholdMph,
                priorSnowInches: SkiDayScorer.priorSnowInches(observed: snapshot.observed, hourly: series),
                weights: learning.weights)
        }
        var warnings = (tableWarning.map { [$0] } ?? []) + learning.warnings
        var models: [HourlyForecast] = []
        if let modelForecasts {
            do {
                models = Array(try await modelForecasts(location, now).values)
            } catch {
                warnings.append("No comparison models (\(error)); confidence goes by lead alone")
            }
        }
        let scores = ForecastConfidence.apply(to: score(hourly), models: models.map(score), location: location, now: now, table: table)
        var plan = await DeparturePlanner(travel: travel, roadWeather: roadWeather, buffers: learning.buffers.buffers)
            .plan(scores, hourly: hourly, location: location, settings: settings, now: now)
        plan.warnings += warnings
        return plan
    }
}
