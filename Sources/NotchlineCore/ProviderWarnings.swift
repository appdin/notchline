import Foundation

/// Problems a provider worked around while still returning a value: an optional part that
/// failed, a fallback source, a retried request, a field in an unexpected unit. Providers record
/// them here instead of discarding the error, and `ConditionsService` collects them
/// per metric so the UI and the fetch command can show them.
///
/// The log is a task-local, so code deep in a provider (or a request it shares with another
/// metric) records without passing a log around. Outside a collecting task, recording does nothing.
public enum ProviderWarnings {
    @TaskLocal static var log: WarningLog?

    static func record(_ message: String) {
        log?.append(message)
    }

    /// Runs `body` and returns what it recorded alongside its result.
    static func collecting<T: Sendable>(_ body: () async -> T) async -> (T, [String]) {
        let log = WarningLog()
        let value = await $log.withValue(log) { await body() }
        return (value, log.messages)
    }
}

final class WarningLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        if !items.contains(message) { items.append(message) }
    }

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}
