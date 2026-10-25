import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
    /// Requests part of the resource with an HTTP `Range` header such as `bytes=-49152`.
    /// Servers and clients that ignore ranges return the whole body, so callers must handle both.
    func get(_ url: URL, range: String) async throws -> Data
}

extension HTTPClient {
    public func get(_ url: URL, range: String) async throws -> Data {
        try await get(url)
    }
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
        try await send(URLRequest(url: url))
    }

    public func get(_ url: URL, range: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(range, forHTTPHeaderField: "Range")
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProviderError.http(status: http.statusCode, url: request.url!)
        }
        return data
    }
}

/// Retries a request once after a short pause when the failure looks transient: a 5xx or 429
/// response, a timeout or a dropped connection. Every source goes through this, since each has
/// shown brief outages (AWDB 500s and hangs, Open-Meteo 502s). Retries are recorded as warnings.
public struct RetryingHTTPClient: HTTPClient {
    private let inner: HTTPClient
    private let retries: Int
    private let delay: Duration

    public init(_ inner: HTTPClient, retries: Int = 1, delay: Duration = .seconds(2)) {
        self.inner = inner
        self.retries = retries
        self.delay = delay
    }

    public func get(_ url: URL) async throws -> Data {
        try await withRetry(url) { try await inner.get(url) }
    }

    public func get(_ url: URL, range: String) async throws -> Data {
        try await withRetry(url) { try await inner.get(url, range: range) }
    }

    private func withRetry(_ url: URL, _ request: () async throws -> Data) async throws -> Data {
        var attempt = 0
        while true {
            do {
                return try await request()
            } catch where attempt < retries && Self.isTransient(error) {
                attempt += 1
                ProviderWarnings.record("Retried \(url.host ?? url.absoluteString) after \(Self.describe(error))")
                try await Task.sleep(for: delay)
            }
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        if case .http(let status, _)? = error as? ProviderError {
            return status == 429 || (500...599).contains(status)
        }
        guard let urlError = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .badServerResponse].contains(urlError.code)
    }

    private static func describe(_ error: Error) -> String {
        if case .http(let status, _)? = error as? ProviderError { return "HTTP \(status)" }
        if let urlError = error as? URLError, urlError.code == .timedOut { return "a timeout" }
        return String(describing: error)
    }
}

/// Memo for values that are slow to fetch and change rarely: derived lookups (NWS gridpoint URL,
/// avalanche zone), file headers, and a response shared by two metrics. Concurrent callers for
/// the same key share one in-flight load, so a refresh never fetches the same thing twice.
/// Failed loads are not kept.
actor LookupCache<Value: Sendable> {
    private var entries: [String: (task: Task<Value, Error>, storedAt: Date)] = [:]
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 24 * 60 * 60) {
        self.ttl = ttl
    }

    func value(for key: String, now: Date, load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let entry = entries[key], now.timeIntervalSince(entry.storedAt) < ttl {
            return try await entry.task.value
        }
        let task = Task { try await load() }
        entries[key] = (task, now)
        do {
            return try await task.value
        } catch {
            if entries[key]?.task == task { entries[key] = nil }
            throw error
        }
    }

    /// Drops a stored value, for example a file header that no longer matches the data.
    func invalidate(_ key: String) {
        entries[key] = nil
    }
}
