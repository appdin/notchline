import Foundation
import Testing
@testable import NotchlineCore

enum Fixture {
    static func data(_ name: String, ext: String = "json") throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
        }
        return try Data(contentsOf: url)
    }

    /// A fixture's JSON with `edit` applied, for variants of live responses (for example an in-season rating).
    static func edited(_ name: String, _ edit: (inout Any) -> Void) throws -> Data {
        var json = try JSONSerialization.jsonObject(with: data(name))
        edit(&json)
        return try JSONSerialization.data(withJSONObject: json)
    }
}

/// Serves canned responses by matching a substring of the request URL. Unmatched requests fail.
struct StubHTTPClient: HTTPClient {
    var routes: [(match: String, response: Result<Data, ProviderError>)]

    init(_ routes: [(String, Result<Data, ProviderError>)]) {
        self.routes = routes.map { (match: $0.0, response: $0.1) }
    }

    func get(_ url: URL) async throws -> Data {
        guard let route = routes.first(where: { url.absoluteString.contains($0.match) }) else {
            throw ProviderError.http(status: 404, url: url)
        }
        return try route.response.get()
    }
}

func date(_ iso: String) -> Date {
    NWSForecastProvider.parseISODate(iso)!
}

func catalogLocation(_ id: String) throws -> Location {
    try #require(try LocationCatalog.bundled().location(id: id))
}
