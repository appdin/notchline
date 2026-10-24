import Foundation

/// Observed snow depth and air temperature from BC Ministry of Environment automated snow weather stations.
/// https://www2.gov.bc.ca/gov/content/environment/air-land-water/water/water-science-data/water-data-tools/snow-survey-data/automated-snow-weather-station-data
///
/// The data is one CSV per element covering every station since October 1, one column per station,
/// one row per hour in UTC. The files grow to megabytes over a season, so only the header and the
/// last few dozen rows are requested.
public struct BCSnowStationProvider: ObservedSnowProvider {
    static let baseURL = URL(string: "https://www.env.gov.bc.ca/wsd/data_searches/snow/asws/data/")!
    /// Snow depth in cm. The files do not label their units, so cm and °C are assumptions taken
    /// from the BC ENV data documentation and checked against known depths in Phase 6.
    static let depthFile = "SD.csv"
    /// Air temperature in °C.
    static let temperatureFile = "TA.csv"
    /// The header lists every station by ID and name, a few KB.
    static let headerRange = "bytes=0-16383"
    /// Enough rows for 30 hours even when every station reports, at well under 1 KB a row.
    static let tailRange = "bytes=-49152"

    private let http: HTTPClient
    /// Headers change only when stations are added or removed, so they are kept for a day and
    /// refetched early if the rows stop lining up with them.
    private let headers = LookupCache<Data>()

    public init(http: HTTPClient) {
        self.http = http
    }

    public func fetch(for location: Location, now: Date) async throws -> ObservedSnow {
        guard case .bcSnowStations(let stations)? = location.observedSnow, !stations.isEmpty else {
            throw ProviderError.notConfigured("BC snow stations for \(location.id)")
        }
        let depth = try await table(Self.depthFile, now: now)
        // Temperature is optional. A failure leaves the forecast temperature to fill in.
        var temperature: Table?
        do {
            temperature = try await table(Self.temperatureFile, now: now)
        } catch {
            ProviderWarnings.record("Station air temperature unavailable: \(error)")
        }
        return try await StationReadings.firstCurrent(stations, now: now) { station in
            try Self.observation(station: station, depth: depth, temperature: temperature, now: now)
        }
    }

    private func table(_ file: String, now: Date) async throws -> Table {
        let url = Self.baseURL.appendingPathComponent(file)
        let http = self.http
        let loadHeader: @Sendable () async throws -> Data = { try await http.get(url, range: Self.headerRange) }
        async let tail = http.get(url, range: Self.tailRange)
        let table = try Self.parseTable(header: try await headers.value(for: file, now: now, load: loadHeader), tail: try await tail)
        guard table.mismatchedRows > 0 else { return table }
        // A station was added or removed since the header was cached.
        await headers.invalidate(file)
        let fresh = try Self.parseTable(header: try await headers.value(for: file, now: now, load: loadHeader), tail: try await tail)
        guard fresh.mismatchedRows == 0 else {
            throw ProviderError.unexpectedResponse("\(file) rows do not match its header")
        }
        return fresh
    }

    static func observation(station: BCSnowStation, depth: Table, temperature: Table?, now: Date) throws -> ObservedSnow {
        let latestAllowed = now.addingTimeInterval(60 * 60)
        let depthReadings = try depth.readings(station: station.id)
            .filter { $0.value >= 0 && $0.date <= latestAllowed }
            .map { StationReadings.Reading(date: $0.date, value: Convert.inches(fromCM: $0.value)) }
        var temperatureReadings: [StationReadings.Reading] = []
        if let temperature {
            do {
                temperatureReadings = try temperature.readings(station: station.id)
            } catch {
                ProviderWarnings.record("\(station.name) air temperature unavailable: \(error)")
            }
        }
        let temps = temperatureReadings
            .filter { $0.date <= latestAllowed }
            .map { StationReadings.Reading(date: $0.date, value: Convert.fahrenheit(fromC: $0.value)) }
        return try StationReadings.observation(
            depth: depthReadings,
            airTemp: temps,
            stationName: station.name,
            stationElevationFt: station.elevationFt,
            stationID: station.id)
    }

    struct Table {
        /// Station ID (the first word of each column header) to column index.
        let columns: [String: Int]
        let rows: [(date: Date, fields: [Substring])]
        /// Rows whose field count differs from the header's, a sign the header is out of date.
        var mismatchedRows = 0

        func readings(station id: String) throws -> [StationReadings.Reading] {
            guard let column = columns[id] else {
                throw ProviderError.noData("station \(id) in BC snow station data")
            }
            return rows.compactMap { row in
                guard column < row.fields.count, let value = Double(row.fields[column]) else { return nil }
                return StationReadings.Reading(date: row.date, value: value)
            }
        }
    }

    /// `header` must start at the beginning of the file. `tail` may start mid-row, so its first line
    /// is dropped; when a server ignores the range, that line is the header instead.
    static func parseTable(header: Data, tail: Data) throws -> Table {
        guard let headerLine = TextResponse.firstCompleteLine(header), headerLine.hasPrefix("DATE(UTC)") else {
            throw ProviderError.unexpectedResponse("BC snow station header")
        }
        var columns: [String: Int] = [:]
        let titles = TextResponse.fields(headerLine)
        for (index, title) in titles.enumerated().dropFirst() {
            if let id = title.split(separator: " ").first {
                columns[String(id)] = index
            }
        }
        let formatter = utcFormatter()
        let rows = TextResponse.lines(tail)
            .dropFirst()
            .compactMap { line -> (date: Date, fields: [Substring])? in
                let fields = TextResponse.fields(line)
                guard let first = fields.first, let date = formatter.date(from: String(first)) else { return nil }
                return (date, Array(fields))
            }
        return Table(columns: columns, rows: rows, mismatchedRows: rows.filter { $0.fields.count != titles.count }.count)
    }

    static func utcFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }
}
