import Foundation
import MapKit

public struct Coordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Rounded to about 10 m, for cache keys.
    var key: String { String(format: "%.4f,%.4f", latitude, longitude) }
}

extension Home {
    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
}

extension Location {
    public var coordinate: Coordinate { Coordinate(latitude: latitude, longitude: longitude) }
}

/// Driving times with predicted traffic. Behind a protocol so the planner's tests never call MapKit.
public protocol TravelTimeProvider: Sendable {
    /// Drive time from `origin` that arrives at `destination` by `arrival`.
    func travelTime(from origin: Coordinate, to destination: Coordinate, arrivingBy arrival: Date) async throws -> TimeInterval
    /// Drive time from `origin` leaving at `departure`. For leaving now, this is the live estimate
    /// with current traffic, which the travel-time log records.
    func travelTime(from origin: Coordinate, to destination: Coordinate, departingAt departure: Date) async throws -> TimeInterval
    /// A point halfway along the route by distance, usually well below a ski area, for road weather.
    func routeMidpoint(from origin: Coordinate, to destination: Coordinate) async throws -> Coordinate
}

/// Hourly weather at a point along the drive, for road buffers.
public protocol RoadWeatherProvider: Sendable {
    func hourly(at coordinate: Coordinate, calendar: Calendar, now: Date) async throws -> HourlyForecast
}

public enum TravelError: Error, Equatable, CustomStringConvertible {
    case noRoute(String)

    public var description: String {
        switch self {
        case .noRoute(let reason): "no route: \(reason)"
        }
    }
}

/// Keeps ETAs per target arrival for an hour and route midpoints for a day. Apple throttles
/// MapKit without publishing a limit, and a refresh asks for the same arrival more than once.
public struct CachedTravelTimes: TravelTimeProvider {
    private let inner: TravelTimeProvider
    private let etas = LookupCache<TimeInterval>(ttl: 60 * 60)
    private let midpoints = LookupCache<Coordinate>()
    private let now: @Sendable () -> Date

    public init(_ inner: TravelTimeProvider, now: @escaping @Sendable () -> Date = { Date() }) {
        self.inner = inner
        self.now = now
    }

    public func travelTime(from origin: Coordinate, to destination: Coordinate, arrivingBy arrival: Date) async throws -> TimeInterval {
        let key = "\(origin.key)|\(destination.key)|\(Int(arrival.timeIntervalSince1970))"
        return try await etas.value(for: key, now: now()) { try await inner.travelTime(from: origin, to: destination, arrivingBy: arrival) }
    }

    /// Not cached: the log asks for a new time each sample.
    public func travelTime(from origin: Coordinate, to destination: Coordinate, departingAt departure: Date) async throws -> TimeInterval {
        try await inner.travelTime(from: origin, to: destination, departingAt: departure)
    }

    public func routeMidpoint(from origin: Coordinate, to destination: Coordinate) async throws -> Coordinate {
        try await midpoints.value(for: "\(origin.key)|\(destination.key)", now: now()) { try await inner.routeMidpoint(from: origin, to: destination) }
    }
}

/// Apple Maps through MapKit: free, traffic aware, no key. Apple applies current road closures,
/// so a closed access road gives no route rather than a wrong time.
public struct MapKitTravelTimes: TravelTimeProvider {
    public init() {}

    public func travelTime(from origin: Coordinate, to destination: Coordinate, arrivingBy arrival: Date) async throws -> TimeInterval {
        let request = Self.request(from: origin, to: destination)
        request.arrivalDate = arrival
        return try await eta(request)
    }

    public func travelTime(from origin: Coordinate, to destination: Coordinate, departingAt departure: Date) async throws -> TimeInterval {
        let request = Self.request(from: origin, to: destination)
        request.departureDate = departure
        return try await eta(request)
    }

    private func eta(_ request: MKDirections.Request) async throws -> TimeInterval {
        try await withCheckedThrowingContinuation { continuation in
            MKDirections(request: request).calculateETA { response, error in
                if let time = response?.expectedTravelTime {
                    continuation.resume(returning: time)
                } else {
                    continuation.resume(throwing: TravelError.noRoute(Self.reason(error)))
                }
            }
        }
    }

    public func routeMidpoint(from origin: Coordinate, to destination: Coordinate) async throws -> Coordinate {
        try await withCheckedThrowingContinuation { continuation in
            MKDirections(request: Self.request(from: origin, to: destination)).calculate { response, error in
                guard let polyline = response?.routes.first?.polyline, polyline.pointCount > 0 else {
                    continuation.resume(throwing: TravelError.noRoute(Self.reason(error)))
                    return
                }
                continuation.resume(returning: Self.midpoint(of: polyline))
            }
        }
    }

    static func request(from origin: Coordinate, to destination: Coordinate) -> MKDirections.Request {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude)))
        request.transportType = .automobile
        return request
    }

    static func midpoint(of polyline: MKPolyline) -> Coordinate {
        let points = UnsafeBufferPointer(start: polyline.points(), count: polyline.pointCount)
        let half = zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) } / 2
        var travelled = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            let step = a.distance(to: b)
            if travelled + step >= half {
                let fraction = step > 0 ? (half - travelled) / step : 0
                let point = MKMapPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction).coordinate
                return Coordinate(latitude: point.latitude, longitude: point.longitude)
            }
            travelled += step
        }
        let last = points[points.count - 1].coordinate
        return Coordinate(latitude: last.latitude, longitude: last.longitude)
    }

    private static func reason(_ error: Error?) -> String {
        guard let error = error as NSError? else { return "Apple Maps returned no route" }
        return error.localizedFailureReason ?? error.localizedDescription
    }
}
