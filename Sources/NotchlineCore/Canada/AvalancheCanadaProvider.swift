import Foundation

/// Avalanche danger from Avalanche Canada's public forecast API, looked up by point.
///
/// Avalanche Canada regroups its subregions into forecast areas day to day, and names each area
/// by joining its subregion names (dozens off-season). That makes a poor label, so the zone is
/// shown as "Avalanche Canada" and the forecast link carries the detail.
public struct AvalancheCanadaProvider: AvalancheProvider {
    static let baseURL = URL(string: "https://api.avalanche.ca/forecasts/en/products/point")!
    public static let zoneName = "Avalanche Canada"

    private let http: HTTPClient

    public init(http: HTTPClient) {
        self.http = http
    }

    public func fetch(for location: Location, now: Date) async throws -> DangerSummary {
        try Self.parse(try await http.get(Self.requestURL(for: location)), calendar: location.calendar, now: now)
    }

    static func requestURL(for location: Location) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "lat", value: String(format: "%.4f", location.latitude)),
            URLQueryItem(name: "long", value: String(format: "%.4f", location.longitude)),
        ]
        return components.url!
    }

    static func parse(_ data: Data, calendar: Calendar, now: Date) throws -> DangerSummary {
        let product = try JSONDecoder().decode(Product.self, from: data)
        let report = product.report
        var summary = DangerSummary(
            zoneName: zoneName,
            overall: .noRating,
            issuedAt: report.dateIssued.flatMap(parseDate),
            validUntil: report.validUntil.flatMap(parseDate),
            forecastURL: product.url.flatMap(URL.init(string:)))
        guard let day = currentDay(report, calendar: calendar, now: now) else { return summary }
        let bands = [day.ratings.alp, day.ratings.tln, day.ratings.btl].map { level($0?.rating.value) }
        guard bands.contains(where: { $0 != .noRating }) else { return summary }
        summary.upper = bands[0]
        summary.middle = bands[1]
        summary.lower = bands[2]
        summary.overall = bands.max() ?? .noRating
        return summary
    }

    /// The rating for today in the location's time zone. Forecasts are published the afternoon
    /// before, so until the first day arrives the first day is the current one, as long as the
    /// product has not expired.
    static func currentDay(_ report: Product.Report, calendar: Calendar, now: Date) -> Product.Day? {
        let days = report.dangerRatings.compactMap { day in parseDate(day.date.value).map { (date: $0, day: day) } }
        if let today = days.first(where: { calendar.isDate($0.date, inSameDayAs: now) }) {
            return today.day
        }
        guard let first = days.min(by: { $0.date < $1.date }), first.date > now,
              let validUntil = report.validUntil.flatMap(parseDate), now <= validUntil else { return nil }
        return first.day
    }

    /// Avalanche Canada rating values: low, moderate, considerable, high, extreme, or
    /// norating, earlyseason, offseason and the like for no rating.
    static func level(_ value: String?) -> DangerLevel {
        switch value {
        case "low": .low
        case "moderate": .moderate
        case "considerable": .considerable
        case "high": .high
        case "extreme": .extreme
        default: .noRating
        }
    }

    /// Dates come with and without fractional seconds.
    static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? NWSForecastProvider.parseISODate(string)
    }

    struct Product: Decodable {
        struct Report: Decodable {
            let dateIssued: String?
            let validUntil: String?
            let dangerRatings: [Day]
        }
        struct Day: Decodable {
            struct Stamp: Decodable { let value: String }
            struct Ratings: Decodable {
                let alp: Band?
                let tln: Band?
                let btl: Band?
            }
            struct Band: Decodable {
                struct Rating: Decodable { let value: String? }
                let rating: Rating
            }
            let date: Stamp
            let ratings: Ratings
        }
        let url: String?
        let report: Report
    }
}
