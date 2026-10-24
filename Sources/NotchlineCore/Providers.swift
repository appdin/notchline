import Foundation

public protocol ObservedSnowProvider: Sendable {
    func fetch(for location: Location, now: Date) async throws -> ObservedSnow
}

public protocol SnowForecastProvider: Sendable {
    func fetch(for location: Location, now: Date) async throws -> SnowForecast
}

public protocol AvalancheProvider: Sendable {
    func fetch(for location: Location, now: Date) async throws -> DangerSummary
}

public enum ProviderError: Error, Equatable, CustomStringConvertible {
    case notConfigured(String)
    case http(status: Int, url: URL)
    case noData(String)
    case unexpectedResponse(String)

    public var description: String {
        switch self {
        case .notConfigured(let what): "not configured: \(what)"
        case .http(let status, let url): "HTTP \(status) from \(url.absoluteString)"
        case .noData(let what): "no data: \(what)"
        case .unexpectedResponse(let what): "unexpected response: \(what)"
        }
    }
}

/// Minimal HTTP abstraction so providers can be tested against fixtures.
public protocol HTTPClient: Sendable {
    func get(_ url: URL) async throws -> Data
}

public struct URLSessionHTTPClient: HTTPClient {
    public static let userAgent = "Notchline/0.1 (https://github.com/appdin/notchline)"

    private let session: URLSession

    public init(timeout: TimeInterval = 15) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpAdditionalHeaders = [
            "User-Agent": Self.userAgent,
            "Accept": "application/json, application/geo+json",
        ]
        session = URLSession(configuration: config)
    }

    public func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderError.http(status: http.statusCode, url: url)
        }
        return data
    }
}

/// Per-location memo for derived lookups (NWS gridpoint URL, avalanche zone) that rarely change.
actor LookupCache<Value: Sendable> {
    private var entries: [String: (value: Value, storedAt: Date)] = [:]
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 24 * 60 * 60) {
        self.ttl = ttl
    }

    func value(for key: String, now: Date, load: @Sendable () async throws -> Value) async throws -> Value {
        if let entry = entries[key], now.timeIntervalSince(entry.storedAt) < ttl {
            return entry.value
        }
        let value = try await load()
        entries[key] = (value, now)
        return value
    }
}
