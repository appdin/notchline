import Foundation

/// GeoJSON Polygon or MultiPolygon geometry, as [polygon][ring][position], positions [lon, lat].
public struct ZoneGeometry: Decodable, Sendable {
    public let polygons: [[[[Double]]]]

    enum CodingKeys: String, CodingKey { case type, coordinates }

    public init(polygons: [[[[Double]]]]) {
        self.polygons = polygons
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "Polygon":
            polygons = [try container.decode([[[Double]]].self, forKey: .coordinates)]
        case "MultiPolygon":
            polygons = try container.decode([[[[Double]]]].self, forKey: .coordinates)
        case let type:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unsupported geometry \(type)")
        }
    }

    /// True when the point is inside any polygon's outer ring and outside its holes.
    public func contains(latitude: Double, longitude: Double) -> Bool {
        polygons.contains { rings in
            guard let outer = rings.first, Self.ring(outer, contains: longitude, latitude) else { return false }
            return !rings.dropFirst().contains { Self.ring($0, contains: longitude, latitude) }
        }
    }

    /// Even-odd ray casting.
    static func ring(_ ring: [[Double]], contains x: Double, _ y: Double) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let (xi, yi) = (ring[i][0], ring[i][1])
            let (xj, yj) = (ring[j][0], ring[j][1])
            if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi) + xi {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
