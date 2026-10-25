import Foundation

/// The whole planner for one location: scores from the snapshot's hourly forecast, confidence
/// from the comparison models, then departures when there is a way to get drive times. The apps
/// and `notchline-fetch` all plan through it.
public struct SkiDayPlanner: Sendable {
    /// The comparison models' hourly series, keyed by model.
    public typealias ModelForecasts = @Sendable (Location, Date) async throws -> [String: HourlyForecast]

    /// nil plans without departures, as the Android app does.
    private let travel: TravelTimeProvider?
    private let roadWeather: RoadWeatherProvider?
    private let modelForecasts: ModelForecasts?
    private let table: ConfidenceTable?
    private let tableWarning: String?

    public init(travel: TravelTimeProvider?, roadWeather: RoadWeatherProvider?, modelForecasts: ModelForecasts?, table: ConfidenceTable?, tableWarning: String? = nil) {
        self.travel = travel
        self.roadWeather = roadWeather
        self.modelForecasts = modelForecasts
        self.table = table
        self.tableWarning = tableWarning
    }

    #if canImport(MapKit)
    /// Apple Maps drive times, Open-Meteo road weather and comparison models, and the bundled confidence table.
    public static func live(http: HTTPClient = RetryingHTTPClient(URLSessionHTTPClient())) -> SkiDayPlanner {
        live(travel: MapKitTravelTimes(), http: http)
    }
    #endif

    /// `travel` drive times with Open-Meteo road weather, or no departures when nil, plus
    /// Open-Meteo comparison models and the confidence table from `table`, normally the bundled one.
    public static func live(
        travel: TravelTimeProvider?,
        table loadTable: () throws -> ConfidenceTable = ConfidenceTable.bundled,
        http: HTTPClient = RetryingHTTPClient(URLSessionHTTPClient())
    ) -> SkiDayPlanner {
        let openMeteo = OpenMeteoProvider(http: http)
        var table: ConfidenceTable?
        var tableWarning: String?
        do {
            table = try loadTable()
        } catch {
            tableWarning = "No confidence table (\(error)); confidence uses the rule"
        }
        return SkiDayPlanner(
            travel: travel.map { CachedTravelTimes($0) as TravelTimeProvider },
            roadWeather: travel == nil ? nil : openMeteo.roadWeather,
            modelForecasts: { try await openMeteo.modelForecasts(for: $0, now: $1) },
            table: table, tableWarning: tableWarning)
    }

    /// The plan for `location`, or nil when the snapshot has no hourly forecast to score.
    public func plan(_ snapshot: ConditionsSnapshot, location: Location, settings: PlannerSettings, now: Date) async -> SkiDayPlan? {
        guard let hourly = snapshot.forecast?.hourly else { return nil }
        func score(_ series: HourlyForecast) -> PlannerScores {
            SkiDayScorer.score(
                series, location: location, now: now, gustThresholdMph: settings.gustThresholdMph,
                priorSnowInches: SkiDayScorer.priorSnowInches(observed: snapshot.observed, hourly: series))
        }
        var warnings = tableWarning.map { [$0] } ?? []
        var models: [HourlyForecast] = []
        if let modelForecasts {
            do {
                models = Array(try await modelForecasts(location, now).values)
            } catch {
                warnings.append("No comparison models (\(error)); confidence goes by lead alone")
            }
        }
        let scores = ForecastConfidence.apply(to: score(hourly), models: models.map(score), location: location, now: now, table: table)
        var plan: SkiDayPlan
        if let travel {
            plan = await DeparturePlanner(travel: travel, roadWeather: roadWeather)
                .plan(scores, hourly: hourly, location: location, settings: settings, now: now)
        } else {
            plan = SkiDayPlan(days: scores.days.map { PlannedDay(score: $0) }, warnings: scores.warnings)
        }
        plan.warnings += warnings
        return plan
    }
}
