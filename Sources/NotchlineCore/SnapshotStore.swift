import Foundation

/// Last good snapshot per location, stored as JSON files.
public struct SnapshotStore: Sendable {
    public let directory: URL

    /// ~/Library/Application Support/Notchline/snapshots
    public static func applicationSupport() throws -> SnapshotStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return SnapshotStore(directory: base.appending(path: "Notchline/snapshots", directoryHint: .isDirectory))
    }

    public init(directory: URL) {
        self.directory = directory
    }

    public func load(locationID: String) -> ConditionsSnapshot? {
        guard let data = try? Data(contentsOf: fileURL(locationID)) else { return nil }
        return try? Self.decoder.decode(ConditionsSnapshot.self, from: data)
    }

    public func save(_ snapshot: ConditionsSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(snapshot).write(to: fileURL(snapshot.locationID), options: .atomic)
    }

    private func fileURL(_ locationID: String) -> URL {
        directory.appending(path: "\(locationID).json")
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
