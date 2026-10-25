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
        /// Where Google Maps directions go.
        let latitude: Double
        let longitude: Double
    }

    let region: String
    let locations: [Entry]
}

/// What the screen asks about: one location, in the units and locale to show it in.
struct LocationRequest: Decodable {
    let locationID: String
    /// A `UnitPreference` raw value. Anything else means automatic.
    let units: String
    /// A locale identifier such as `en-US`, for times and weekday names.
    let locale: String
}

/// Everything the screen shows for one location.
struct LocationResponse: Encodable {
    let conditions: ConditionsSummary
    /// nil until the location has been planned this session, or when there was nothing to plan from.
    let planner: PlannerSummary?
    /// True once the location has been planned this session, so a nil `planner` means no hourly forecast.
    let planned: Bool
    /// Shown in place of the planner when it was planned with nothing to plan from.
    let plannerMessage: String?
    /// What the scores mean, one paragraph each.
    let scoreHelp = ScoreHelp.paragraphs
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

/// The catalog, service, snapshot cache, planner and latest plans shared by every call, so
/// provider caches and the session's state persist across calls.
final class Bridge: @unchecked Sendable {
    static let shared = Bridge()

    private let lock = NSLock()
    private var catalog: LocationCatalog?
    private var cache = ConditionsCache(store: nil)
    private let service = ConditionsService()
    private var planner: SkiDayPlanner?
    /// The latest plan per location this session. A nil value means there was nothing to plan from.
    private var plans: [String: SkiDayPlan?] = [:]

    func configure(_ catalog: LocationCatalog, confidence: Data, store: SnapshotStore) {
        // No travel: Android leaves the drive to Google Maps, so plans have no departures.
        let planner = SkiDayPlanner.live(travel: nil, table: { try ConfidenceTable.load(from: confidence) })
        lock.withLock {
            self.catalog = catalog
            self.planner = planner
            cache = ConditionsCache(store: store)
            plans = [:]
        }
    }

    func regions() throws -> [CatalogRegion] {
        try catalogOrThrow().byRegion.map { group in
            CatalogRegion(region: group.region, locations: group.locations.map {
                .init(id: $0.id, name: $0.name, defaultUnits: $0.defaultUnits, latitude: $0.latitude, longitude: $0.longitude)
            })
        }
    }

    /// The location's cached conditions and latest plan, without fetching or planning.
    func response(_ request: LocationRequest, now: Date = Date()) throws -> LocationResponse {
        let location = try location(request.locationID)
        let units = (UnitPreference(rawValue: request.units) ?? .automatic).resolve(for: location)
        let locale = Locale(identifier: request.locale)
        let (conditions, plan) = lock.withLock { (cache.conditions(for: location.id), plans[location.id]) }
        return LocationResponse(
            conditions: ConditionsSummary(location: location, conditions: conditions, units: units, now: now),
            planner: plan.flatMap { $0 }.map { PlannerSummary(plan: $0, location: location, now: now, locale: locale) },
            planned: plan != nil,
            plannerMessage: plan.map { $0 == nil ? PlannerSummary.noForecast : nil } ?? nil)
    }

    /// Refreshes the location's conditions. When a refresh for it is already running, returns at
    /// once with the cached conditions, marked as refreshing.
    func refresh(_ request: LocationRequest) async throws -> LocationResponse {
        let location = try location(request.locationID)
        if lock.withLock({ cache.beginRefresh(location.id) }) {
            let previous = lock.withLock { cache.snapshot(for: location.id) }
            let result = await service.refresh(location, previous: previous)
            lock.withLock { cache.finishRefresh(result) }
        }
        return try response(request)
    }

    /// Plans the location from its cached snapshot with the default planner settings.
    func plan(_ request: LocationRequest) async throws -> LocationResponse {
        let location = try location(request.locationID)
        let (snapshot, planner) = lock.withLock { (cache.snapshot(for: location.id), self.planner) }
        guard let planner else { throw BridgeError.notConfigured }
        var plan: SkiDayPlan?
        if let snapshot {
            let now = Date()
            plan = await planner.plan(snapshot, location: location, settings: .default, now: now)
        }
        lock.withLock { plans[location.id] = .some(plan) }
        return try response(request)
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

private func decodeRequest(_ env: UnsafeMutablePointer<JNIEnv?>, _ array: jbyteArray?) throws -> LocationRequest {
    try JSONDecoder().decode(LocationRequest.self, from: bytes(env, array))
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

/// `configure(locationsJson: ByteArray, confidenceJson: ByteArray, snapshotsDir: ByteArray): ByteArray`:
/// loads the location catalog and confidence table from the app's copies of `locations.json` and
/// `confidence.json`, keeps snapshots in `snapshotsDir`, and returns the catalog grouped by region as JSON.
@_cdecl("Java_com_appdin_notchline_core_NotchlineCore_configure")
public func configure(_ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?, _ locationsJSON: jbyteArray?, _ confidenceJSON: jbyteArray?, _ snapshotsDir: jbyteArray?) -> jbyteArray? {
    let directory = URL(filePath: string(env, snapshotsDir), directoryHint: .isDirectory)
    return respond(env) {
        let catalog = try LocationCatalog.load(from: bytes(env, locationsJSON))
        Bridge.shared.configure(catalog, confidence: bytes(env, confidenceJSON), store: SnapshotStore(directory: directory))
        return try Bridge.shared.regions()
    }
}

/// `conditions(request: ByteArray): ByteArray`: the location's cached conditions and latest plan
/// as `LocationResponse` JSON, without fetching. `request` is `LocationRequest` JSON.
@_cdecl("Java_com_appdin_notchline_core_NotchlineCore_conditions")
public func conditions(_ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?, _ request: jbyteArray?) -> jbyteArray? {
    respond(env) { try Bridge.shared.response(decodeRequest(env, request)) }
}

/// `refresh(request: ByteArray): ByteArray`: fetches the location's conditions and returns `LocationResponse` JSON.
@_cdecl("Java_com_appdin_notchline_core_NotchlineCore_refresh")
public func refresh(_ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?, _ request: jbyteArray?) -> jbyteArray? {
    respond(env) {
        let request = try decodeRequest(env, request)
        return try blocking { try await Bridge.shared.refresh(request) }
    }
}

/// `plan(request: ByteArray): ByteArray`: plans the location from its cached snapshot, fetching
/// the comparison models, and returns `LocationResponse` JSON.
@_cdecl("Java_com_appdin_notchline_core_NotchlineCore_plan")
public func plan(_ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?, _ request: jbyteArray?) -> jbyteArray? {
    respond(env) {
        let request = try decodeRequest(env, request)
        return try blocking { try await Bridge.shared.plan(request) }
    }
}
