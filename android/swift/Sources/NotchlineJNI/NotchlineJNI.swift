import CJNI
import Dispatch
import Foundation
import NotchlineCore

// JNI entry points for com.appdin.notchline.core.NotchlineCore. Values cross as UTF-8 JSON in
// byte arrays rather than Java strings, since JNI strings are modified UTF-8 and break on emoji.
// Calls block the calling thread until the core's async work finishes, so Kotlin calls them off
// the main thread.

/// The response to `refresh`: the snapshot plus why each failed metric failed.
struct RefreshResponse: Encodable {
    let snapshot: ConditionsSnapshot
    let errors: [Metric: String]
    let warnings: [Metric: [String]]
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

/// The catalog and service shared by every call, so provider caches persist across refreshes.
final class Bridge: @unchecked Sendable {
    static let shared = Bridge()

    private let lock = NSLock()
    private var catalog: LocationCatalog?
    private let service = ConditionsService()

    func configure(_ catalog: LocationCatalog) {
        lock.withLock { self.catalog = catalog }
    }

    func refresh(locationID: String) async throws -> RefreshResponse {
        guard let catalog = lock.withLock({ catalog }) else { throw BridgeError.notConfigured }
        guard let location = catalog.location(id: locationID) else { throw BridgeError.unknownLocation(locationID) }
        let result = await service.refresh(location)
        return RefreshResponse(snapshot: result.snapshot, errors: result.errors, warnings: result.warnings)
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
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
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

// MARK: Entry points

/// `configure(locationsJson: ByteArray)`: loads the location catalog from the app's copy of `locations.json`.
@_cdecl("Java_com_appdin_notchline_core_NotchlineCore_configure")
public func configure(_ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?, _ locationsJSON: jbyteArray?) {
    do {
        Bridge.shared.configure(try LocationCatalog.load(from: bytes(env, locationsJSON)))
    } catch {
        raise(env, error)
    }
}

/// `refresh(locationId: ByteArray): ByteArray`: fetches a snapshot and returns `RefreshResponse` as JSON.
@_cdecl("Java_com_appdin_notchline_core_NotchlineCore_refresh")
public func refresh(_ env: UnsafeMutablePointer<JNIEnv?>, _ type: jclass?, _ locationID: jbyteArray?) -> jbyteArray? {
    let id = String(decoding: bytes(env, locationID), as: UTF8.self)
    do {
        let response = try blocking { try await Bridge.shared.refresh(locationID: id) }
        return byteArray(env, try encoder.encode(response))
    } catch {
        raise(env, error)
        return nil
    }
}
