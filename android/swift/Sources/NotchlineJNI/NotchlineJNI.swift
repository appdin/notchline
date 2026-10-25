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

/// What the app asks about: one location, in the units, locale and time zone to show it in.
struct LocationRequest: Decodable {
    let locationID: String
    /// A `UnitPreference` raw value. Anything else means automatic.
    let units: String
    /// A locale identifier such as `en-US`, for times and weekday names.
    let locale: String
    /// The phone's time zone ID. The evening summary fires at its time in this zone.
    let timeZone: String
    /// The planner settings the app has. Those it leaves out keep their defaults.
    let planner: PlannerSettings
    /// The rating to store, for `rate` only.
    let rating: RatingRequest?

    /// The phone's calendar, for when the evening summary fires.
    var userCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        return calendar
    }
}

/// A rating for one of the `ratableDays`.
struct RatingRequest: Decodable {
    /// The `RatingPrompt`'s `day`.
    let day: Date
    let groomed: Int?
    let ungroomed: Int?
}

/// A planner notification for the app to post at `fireAtMillis`, replacing the ones before.
struct ScheduledNotification: Encodable {
    let id: String
    /// Always `summary`: Android plans no departures.
    let kind: String
    let locationID: String
    let fireAtMillis: Int64
    let title: String
    let body: String

    init(_ notification: PlannerNotification) {
        id = notification.id
        kind = notification.kind.rawValue
        locationID = notification.locationID
        fireAtMillis = Int64((notification.fireAt.timeIntervalSince1970 * 1000).rounded())
        title = notification.title
        body = notification.body
    }
}

/// Everything the app shows for one location.
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
    /// From `plan` only: every planner notification for the location, to replace those scheduled before.
    let notifications: [ScheduledNotification]?
}

enum BridgeError: Error, CustomStringConvertible {
    case notConfigured
    case unknownLocation(String)
    case noRating

    var description: String {
        switch self {
        case .notConfigured: "configure was not called with the location catalog"
        case .unknownLocation(let id): "unknown location \(id)"
        case .noRating: "rate was called without a rating"
        }
    }
}

/// A recent day the user can rate, when they choose to.
struct RatableDay: Encodable {
    let prompt: RatingPrompt
    /// The rating already stored, to start from.
    let rating: DayRating?
}

/// The catalog, service, snapshot cache, planner, archive and latest plans shared by every
/// call, so provider caches and the session's state persist across calls.
final class Bridge: @unchecked Sendable {
    static let shared = Bridge()

    private let lock = NSLock()
    private var catalog: LocationCatalog?
    private var cache = ConditionsCache(store: nil)
    private let service = ConditionsService()
    private var planner: SkiDayPlanner?
    private var archive: PlannerArchive?
    /// The latest plan per location this session. A nil value means there was nothing to plan from.
    private var plans: [String: SkiDayPlan?] = [:]

    func configure(_ catalog: LocationCatalog, confidence: Data, store: SnapshotStore, archive: PlannerArchive) {
        // No travel: Android leaves the drive to Google Maps, so plans have no departures.
        let planner = SkiDayPlanner.live(travel: nil, table: { try ConfidenceTable.load(from: confidence) })
        lock.withLock {
            self.catalog = catalog
            self.planner = planner
            self.archive = archive
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
    func response(_ request: LocationRequest, notifications: [PlannerNotification]? = nil, now: Date = Date()) throws -> LocationResponse {
        let location = try location(request.locationID)
        let units = (UnitPreference(rawValue: request.units) ?? .automatic).resolve(for: location)
        let locale = Locale(identifier: request.locale)
        let (conditions, plan) = lock.withLock { (cache.conditions(for: location.id), plans[location.id]) }
        return LocationResponse(
            conditions: ConditionsSummary(location: location, conditions: conditions, units: units, now: now),
            planner: plan.flatMap { $0 }.map { PlannerSummary(plan: $0, location: location, now: now, locale: locale) },
            planned: plan != nil,
            plannerMessage: plan.map { $0 == nil ? PlannerSummary.noForecast : nil } ?? nil,
            notifications: notifications?.map(ScheduledNotification.init))
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

    /// Plans the location from its cached snapshot, records the plan for ratings as the Mac's
    /// `PlannerModel` does, and returns the evening summaries to schedule.
    func plan(_ request: LocationRequest) async throws -> LocationResponse {
        let location = try location(request.locationID)
        let (snapshot, planner, archive) = lock.withLock { (cache.snapshot(for: location.id), self.planner, self.archive) }
        guard let planner, let archive else { throw BridgeError.notConfigured }
        let now = Date()
        var plan: SkiDayPlan?
        if let snapshot {
            plan = await planner.plan(snapshot, location: location, settings: request.planner, now: now)
            if let result = plan, let hourly = snapshot.forecast?.hourly {
                do {
                    try archive.record(result, hourly: hourly, location: location, now: now)
                } catch {
                    plan?.warnings.append("Could not save the plan for ratings (\(error))")
                }
            }
        }
        let notifications = plan.map {
            PlannerNotifications.schedule($0, location: location, settings: request.planner, now: now,
                                          userCalendar: request.userCalendar, locale: Locale(identifier: request.locale))
        } ?? []
        lock.withLock { plans[location.id] = .some(plan) }
        return try response(request, notifications: notifications, now: now)
    }

    /// Today and the six days before it, for the user to pick one to rate.
    func ratableDays(_ request: LocationRequest) throws -> [RatableDay] {
        let location = try location(request.locationID)
        guard let archive = lock.withLock({ self.archive }) else { throw BridgeError.notConfigured }
        let now = Date()
        let locale = Locale(identifier: request.locale)
        return try archive.recentDays(location: location, now: now, count: PlannerArchive.ratableDayCount).map { record in
            RatableDay(prompt: RatingPrompt(record, location: location, now: now, locale: locale), rating: record.rating)
        }
    }

    /// Stores the request's rating on that day's record.
    func rate(_ request: LocationRequest) throws -> LocationResponse {
        let location = try location(request.locationID)
        guard let archive = lock.withLock({ self.archive }) else { throw BridgeError.notConfigured }
        guard let rating = request.rating else { throw BridgeError.noRating }
        let calendar = location.calendar
        let record = try archive.load(locationID: location.id, day: rating.day, calendar: calendar)
            ?? PlannerDayRecord(locationID: location.id, day: rating.day)
        let now = Date()
        try archive.rate(record, DayRating(skied: true, groomed: rating.groomed, ungroomed: rating.ungroomed, ratedAt: now), calendar: calendar)
        return try response(request, now: now)
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

private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}()

private func decodeRequest(_ env: UnsafeMutablePointer<JNIEnv?>, _ array: jbyteArray?) throws -> LocationRequest {
    try decoder.decode(LocationRequest.self, from: bytes(env, array))
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

/// `configure(locationsJson: ByteArray, confidenceJson: ByteArray, filesDir: ByteArray): ByteArray`:
/// loads the location catalog and confidence table from the app's copies of `locations.json` and
/// `confidence.json`, keeps snapshots and planner records under `filesDir`, and returns the
/// catalog grouped by region as JSON.
@_cdecl("Java_com_appdin_notchline_core_NotchlineCore_configure")
public func configure(_ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?, _ locationsJSON: jbyteArray?, _ confidenceJSON: jbyteArray?, _ filesDir: jbyteArray?) -> jbyteArray? {
    let files = URL(filePath: string(env, filesDir), directoryHint: .isDirectory)
    return respond(env) {
        let catalog = try LocationCatalog.load(from: bytes(env, locationsJSON))
        Bridge.shared.configure(
            catalog, confidence: bytes(env, confidenceJSON),
            store: SnapshotStore(directory: files.appending(path: "snapshots", directoryHint: .isDirectory)),
            archive: PlannerArchive(directory: files.appending(path: "planner", directoryHint: .isDirectory)))
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
/// the comparison models, and returns `LocationResponse` JSON with the notifications to schedule.
@_cdecl("Java_com_appdin_notchline_core_NotchlineCore_plan")
public func plan(_ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?, _ request: jbyteArray?) -> jbyteArray? {
    respond(env) {
        let request = try decodeRequest(env, request)
        return try blocking { try await Bridge.shared.plan(request) }
    }
}

/// `rate(request: ByteArray): ByteArray`: stores the request's rating and returns `LocationResponse` JSON.
@_cdecl("Java_com_appdin_notchline_core_NotchlineCore_rate")
public func rate(_ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?, _ request: jbyteArray?) -> jbyteArray? {
    respond(env) { try Bridge.shared.rate(decodeRequest(env, request)) }
}

/// `ratableDays(request: ByteArray): ByteArray`: recent days to rate as a `RatableDay` JSON array, newest first.
@_cdecl("Java_com_appdin_notchline_core_NotchlineCore_ratableDays")
public func ratableDays(_ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?, _ request: jbyteArray?) -> jbyteArray? {
    respond(env) { try Bridge.shared.ratableDays(decodeRequest(env, request)) }
}
