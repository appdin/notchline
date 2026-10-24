import Foundation

public struct Providers: Sendable {
    public var observed: ObservedSnowProvider?
    public var forecast: SnowForecastProvider?
    public var avalanche: AvalancheProvider?

    public init(observed: ObservedSnowProvider?, forecast: SnowForecastProvider?, avalanche: AvalancheProvider?) {
        self.observed = observed
        self.forecast = forecast
        self.avalanche = avalanche
    }
}

/// Picks provider implementations for a location. Providers are created once and shared so their
/// lookup caches persist across refreshes.
public struct ProviderFactory: Sendable {
    private let snotel: SnotelProvider
    private let bcStations: BCSnowStationProvider
    private let nws: NWSForecastProvider
    private let openMeteo: OpenMeteoProvider
    private let avalancheOrg: AvalancheOrgProvider
    private let avalancheCanada: AvalancheCanadaProvider

    public init(http: HTTPClient = RetryingHTTPClient(URLSessionHTTPClient())) {
        snotel = SnotelProvider(http: http)
        bcStations = BCSnowStationProvider(http: http)
        nws = NWSForecastProvider(http: http)
        openMeteo = OpenMeteoProvider(http: http)
        avalancheOrg = AvalancheOrgProvider(http: http)
        avalancheCanada = AvalancheCanadaProvider(http: http)
    }

    public func providers(for location: Location) -> Providers {
        let observed: ObservedSnowProvider? = switch location.observedSnow {
        case .snotel: snotel
        case .bcSnowStations: bcStations
        case .modeledOnly: openMeteo.modeledSnow
        case nil: nil
        }
        switch location.country {
        case .us:
            return Providers(
                observed: observed,
                forecast: FallbackForecastProvider(primary: nws, fallback: openMeteo.forecast),
                avalanche: location.avalancheCenter == nil ? nil : avalancheOrg)
        case .ca:
            return Providers(observed: observed, forecast: openMeteo.forecast, avalanche: avalancheCanada)
        }
    }
}

/// Uses `fallback` when `primary` fails, for example Open-Meteo when NWS is down.
struct FallbackForecastProvider: SnowForecastProvider {
    let primary: SnowForecastProvider
    let fallback: SnowForecastProvider

    func fetch(for location: Location, now: Date) async throws -> SnowForecast {
        do {
            return try await primary.fetch(for: location, now: now)
        } catch let primaryError {
            do {
                let forecast = try await fallback.fetch(for: location, now: now)
                ProviderWarnings.record("Primary forecast failed (\(primaryError)); showing \(forecast.sourceName)")
                return forecast
            } catch {
                ProviderWarnings.record("Fallback forecast also failed: \(error)")
                throw primaryError
            }
        }
    }
}

