import CJNI
import Dispatch
import Foundation
import NotchlineCore

// JNI entry points for com.appdin.notchline.core.NotchlineCore. Values cross as UTF-8 JSON in
// byte arrays rather than Java strings, since JNI strings are modified UTF-8 and break on emoji.
// Calls block the calling thread until the core's async work finishes, so Kotlin calls them off
// the main thread.

/// A catalog region for the location picker.
struct CatalogRegion: Encodable {
    struct Entry: Encodable {
        let id: String
        let name: String
        /// What automatic units resolve to here, for the units setting's label.
        let defaultUnits: UnitSystem
    }

    let region: String
    let locations: [Entry]
}

enum BridgeError: Error, CustomStringConvertible {
    case notConfigured
    case unknownLocation(String)

    var description: String {
        switch self {
        case .notConfigured: "configure was not called with the location catalog"
        case .unknownLocation(let id): "unknown location \(id)"
        }
    }
}

/// The catalog, service and snapshot cache shared by every call, so provider caches and the
/// session's refresh state persist across calls.
final class Bridge: @unchecked Sendable {
    static let shared = Bridge()

    private let lock = NSLock()
    private var catalog: LocationCatalog?
    private var cache = ConditionsCache(store: nil)
    private let service = ConditionsService()

    func configure(_ catalog: LocationCatalog, store: SnapshotStore) {
        lock.withLock {
            self.catalog = catalog
            cache = ConditionsCache(store: store)
        }
    }

    func regions() throws -> [CatalogRegion] {
        try catalogOrThrow().byRegion.map { group in
            CatalogRegion(region: group.region, locations: group.locations.map { .init(id: $0.id, name: $0.name, defaultUnits: $0.defaultUnits) })
        }
    }

    /// The location's conditions from the cache, without fetching.
    func summary(locationID: String, units: UnitPreference, now: Date = Date()) throws -> ConditionsSummary {
        let location = try location(locationID)
        let conditions = lock.withLock { cache.conditions(for: location.id) }
        return ConditionsSummary(location: location, conditions: conditions, units: units.resolve(for: location), now: now)
    }

    /// Refreshes the location and returns its conditions. When a refresh for it is already
    /// running, returns the cached conditions at once, marked as refreshing.
    func refresh(locationID: String, units: UnitPreference) async throws -> ConditionsSummary {
        let location = try location(locationID)
        if lock.withLock({ cache.beginRefresh(location.id) }) {
            let previous = lock.withLock { cache.snapshot(for: location.id) }
            let result = await service.refresh(location, previous: previous)
            lock.withLock { cache.finishRefresh(result) }
        }
        return try summary(locationID: locationID, units: units)
    }

    private func catalogOrThrow() throws -> LocationCatalog {
        guard let catalog = lock.withLock({ catalog }) else { throw BridgeError.notConfigured }
        return catalog
    }

    private func location(_ id: String) throws -> Location {
        guard let location = try catalogOrThrow().location(id: id) else { throw BridgeError.unknownLocation(id) }
        return location
    }
}

/// Holds a task's result for the thread waiting on it. The semaphore orders the write before the read.
private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// Runs `work` to completion on the concurrency runtime and waits for it on this JVM thread.
private func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
        do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.result!.get()
}

private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()

// MARK: JNI helpers

private func bytes(_ env: UnsafeMutablePointer<JNIEnv?>, _ array: jbyteArray?) -> Data {
    guard let array else { return Data() }
    let jni = env.pointee!.pointee
    let count = Int(jni.GetArrayLength(env, array))
    var data = Data(count: count)
    data.withUnsafeMutableBytes { buffer in
        jni.GetByteArrayRegion(env, array, 0, jsize(count), buffer.baseAddress?.assumingMemoryBound(to: jbyte.self))
    }
    return data
}

private func byteArray(_ env: UnsafeMutablePointer<JNIEnv?>, _ data: Data) -> jbyteArray? {
    let jni = env.pointee!.pointee
    guard let array = jni.NewByteArray(env, jsize(data.count)) else { return nil }
    data.withUnsafeBytes { buffer in
        jni.SetByteArrayRegion(env, array, 0, jsize(data.count), buffer.baseAddress?.assumingMemoryBound(to: jbyte.self))
    }
    return array
}

/// Throws an IllegalStateException in Java with `error` as its message.
private func raise(_ env: UnsafeMutablePointer<JNIEnv?>, _ error: Error) {
    let jni = env.pointee!.pointee
    guard let type = jni.FindClass(env, "java/lang/IllegalStateException") else { return }
    _ = jni.ThrowNew(env, type, String(describing: error))
}

private func string(_ env: UnsafeMutablePointer<JNIEnv?>, _ array: jbyteArray?) -> String {
    String(decoding: bytes(env, array), as: UTF8.self)
}

/// Encodes `body`'s result as JSON for Java, or throws its error there and returns nil.
private func respond(_ env: UnsafeMutablePointer<JNIEnv?>, _ body: () throws -> some Encodable) -> jbyteArray? {
    do {
        return byteArray(env, try encoder.encode(body()))
    } catch {
        raise(env, error)
        return nil
    }
}

// MARK: Entry points

/// `configure(locationsJson: ByteArray, snapshotsDir: ByteArray): ByteArray`: loads the location
/// catalog from the app's copy of `locations.json`, keeps snapshots in `snapshotsDir`, and
/// returns the catalog grouped by region as JSON.
@_cdecl("Java_com_appdin_notchline_core_NotchlineCore_configure")
public func configure(_ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?, _ locationsJSON: jbyteArray?, _ snapshotsDir: jbyteArray?) -> jbyteArray? {
    let directory = URL(filePath: string(env, snapshotsDir), directoryHint: .isDirectory)
    return respond(env) {
        Bridge.shared.configure(try LocationCatalog.load(from: bytes(env, locationsJSON)), store: SnapshotStore(directory: directory))
        return try Bridge.shared.regions()
    }
}

/// `conditions(locationId: ByteArray, units: ByteArray): ByteArray`: the location's cached
/// conditions as `ConditionsSummary` JSON, without fetching. `units` is a `UnitPreference`.
@_cdecl("Java_com_appdin_notchline_core_NotchlineCore_conditions")
public func conditions(_ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?, _ locationID: jbyteArray?, _ units: jbyteArray?) -> jbyteArray? {
    let id = string(env, locationID)
    let units = UnitPreference(rawValue: string(env, units)) ?? .automatic
    return respond(env) { try Bridge.shared.summary(locationID: id, units: units) }
}

/// `refresh(locationId: ByteArray, units: ByteArray): ByteArray`: fetches the location and
/// returns its conditions as `ConditionsSummary` JSON.
@_cdecl("Java_com_appdin_notchline_core_NotchlineCore_refresh")
public func refresh(_ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?, _ locationID: jbyteArray?, _ units: jbyteArray?) -> jbyteArray? {
    let id = string(env, locationID)
    let units = UnitPreference(rawValue: string(env, units)) ?? .automatic
    return respond(env) { try blocking { try await Bridge.shared.refresh(locationID: id, units: units) } }
}
