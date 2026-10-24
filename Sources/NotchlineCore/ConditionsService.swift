import Foundation

/// Result of one refresh: the merged snapshot plus why each failed metric failed.
public struct ConditionsResult: Sendable {
    public let snapshot: ConditionsSnapshot
    public let errors: [Metric: String]
    /// Problems worked around while still producing each metric (or while failing it), such as a
    /// fallback source, a retried request or an optional part that was unavailable.
    public let warnings: [Metric: [String]]
    /// Metrics that failed for a reason worth retrying, which excludes sources not configured for the location.
    public let failedMetrics: Set<Metric>
}

public struct ConditionsService: Sendable {
    private let factory: ProviderFactory

    public init(factory: ProviderFactory = ProviderFactory()) {
        self.factory = factory
    }

    /// Fetches all metrics concurrently. A metric that fails keeps its value from `previous`
    /// (if any) and is marked stale.
    public func refresh(_ location: Location, previous: ConditionsSnapshot? = nil, now: Date = Date()) async -> ConditionsResult {
        let providers = factory.providers(for: location)
        async let observed = Self.attempt(providers.observed, "observed snow") { try await $0.fetch(for: location, now: now) }
        async let forecast = Self.attempt(providers.forecast, "snow forecast") { try await $0.fetch(for: location, now: now) }
        async let danger = Self.attempt(providers.avalanche, "avalanche danger") { try await $0.fetch(for: location, now: now) }
        let results = await (observed, forecast, danger)
        var warnings: [Metric: [String]] = [:]
        for (metric, messages) in [(Metric.observed, results.0.1), (.forecast, results.1.1), (.avalanche, results.2.1)] where !messages.isEmpty {
            warnings[metric] = messages
        }

        let previous = previous?.locationID == location.id ? previous : nil
        var snapshot = ConditionsSnapshot(locationID: location.id, fetchedAt: now)
        var errors: [Metric: String] = [:]
        var failed: Set<Metric> = []

        func merge<T>(_ result: Result<T, Error>, _ metric: Metric, _ keyPath: WritableKeyPath<ConditionsSnapshot, T?>) {
            switch result {
            case .success(let value):
                snapshot[keyPath: keyPath] = value
                snapshot.updatedAt[metric] = now
            case .failure(let error):
                errors[metric] = String(describing: error)
                if case .notConfigured = error as? ProviderError {} else { failed.insert(metric) }
                if let previous, let old = previous[keyPath: keyPath] {
                    snapshot[keyPath: keyPath] = old
                    snapshot.staleMetrics.insert(metric)
                    snapshot.updatedAt[metric] = previous.updatedAt[metric] ?? previous.fetchedAt
                }
            }
        }
        merge(results.0.0, .observed, \.observed)
        merge(results.1.0, .forecast, \.forecast)
        merge(results.2.0, .avalanche, \.danger)
        return ConditionsResult(snapshot: snapshot, errors: errors, warnings: warnings, failedMetrics: failed)
    }

    private static func attempt<P: Sendable, T: Sendable>(
        _ provider: P?,
        _ what: String,
        _ body: @Sendable (P) async throws -> T
    ) async -> (Result<T, Error>, [String]) {
        guard let provider else { return (.failure(ProviderError.notConfigured(what)), []) }
        return await ProviderWarnings.collecting {
            do {
                return .success(try await body(provider))
            } catch {
                return .failure(error)
            }
        }
    }
}
