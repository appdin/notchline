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
    private let nws: NWSForecastProvider
    private let avalancheOrg: AvalancheOrgProvider

    public init(http: HTTPClient = URLSessionHTTPClient()) {
        snotel = SnotelProvider(http: http)
        nws = NWSForecastProvider(http: http)
        avalancheOrg = AvalancheOrgProvider(http: http)
    }

    public func providers(for location: Location) -> Providers {
        let observed: ObservedSnowProvider? = switch location.observedSnow {
        case .snotel: snotel
        // Open-Meteo modeled depth arrives in Phase 5.
        case .modeledOnly, nil: nil
        }
        switch location.country {
        case .us:
            return Providers(observed: observed, forecast: nws, avalanche: location.avalancheCenter == nil ? nil : avalancheOrg)
        case .ca:
            // Open-Meteo and Avalanche Canada arrive in Phase 5.
            return Providers(observed: observed, forecast: nil, avalanche: nil)
        }
    }
}
