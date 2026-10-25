import Foundation

/// The conditions summary's display values: header, the snow, temperature and wind metrics and
/// the avalanche summary. Built once here so the Mac's views and the Android app show the same
/// strings with the same stale and outdated rules.
public struct ConditionsSummary: Encodable, Equatable, Sendable {
    public let locationName: String
    /// `updated 12 min ago`, `loading` or `no data yet`.
    public let status: String
    public let isRefreshing: Bool
    public let base: MetricSummary
    public let last24h: MetricSummary
    public let next24h: MetricSummary
    public let tempNow: MetricSummary
    public let highLow: MetricSummary
    public let wind: MetricSummary
    public let avalanche: AvalancheSummary

    public init(location: Location, conditions: LocationConditions, units: UnitSystem, now: Date) {
        let snapshot = conditions.snapshot
        func state(_ metric: Metric) -> MetricState {
            MetricState(metric, conditions: conditions, now: now)
        }

        locationName = location.name
        isRefreshing = conditions.isRefreshing
        if let updated = snapshot?.lastUpdated {
            status = "updated " + ConditionsFormat.age(since: updated, now: now)
        } else {
            status = conditions.isRefreshing ? "loading" : "no data yet"
        }

        let observed = snapshot?.observed
        base = MetricSummary(
            title: observed?.isModeled == true ? "Base (modeled)" : "Base",
            value: observed.map { ConditionsFormat.snow($0.depthInches, units) },
            detail: observed.map { "\($0.stationName) \(ConditionsFormat.elevation($0.stationElevationFt, units))" },
            state: state(.observed))
        last24h = MetricSummary(
            title: "Last 24h",
            value: observed.map { $0.snow24hInches.map { ConditionsFormat.newSnow($0, units) } ?? "–" },
            detail: observed.map { $0.snow24hInches == nil ? "no reading 24h ago" : "observed" },
            state: state(.observed))

        let forecast = snapshot?.forecast
        next24h = MetricSummary(
            title: "Next 24h",
            value: forecast.map { ConditionsFormat.newSnow($0.next24hInches, units) },
            detail: forecast.map { forecast in
                forecast.gridElevationFt.map { "\(forecast.sourceName == "NWS" ? "NWS grid" : forecast.sourceName) \(ConditionsFormat.elevation($0, units))" } ?? forecast.sourceName
            },
            state: state(.forecast))

        let current = snapshot?.currentTemp(now: now)
        let fromStation = current?.isForecast == false
        tempNow = MetricSummary(
            title: "Temp now",
            value: current.map { ConditionsFormat.degrees($0.tempF, units) + ConditionsFormat.temperatureScale(units) },
            detail: current.map { _ in
                fromStation ? observed?.stationName ?? "station" : "\(forecast?.sourceName ?? "") forecast"
            },
            state: state(fromStation ? .observed : .forecast))

        let tomorrow = forecast?.high.map { ConditionsFormat.highIsTomorrow($0, now: now, calendar: location.calendar) } ?? false
        let highLowValue: String? = forecast.flatMap { forecast in
            guard forecast.high != nil || forecast.low != nil else { return nil }
            let high = forecast.high.map { ConditionsFormat.degrees($0.tempF, units) } ?? "–"
            let low = forecast.low.map { ConditionsFormat.degrees($0.tempF, units) } ?? "–"
            return "\(high) / \(low)"
        }
        highLow = MetricSummary(
            title: tomorrow ? "Tmrw high / Low" : "High / Low",
            value: highLowValue,
            detail: highLowValue == nil ? nil : "forecast",
            state: state(.forecast))

        let windNow = forecast?.windNow
        var windDetail: [String] = []
        if let direction = windNow?.directionDegrees {
            windDetail.append(ConditionsFormat.compass(direction))
        }
        if let peak = forecast?.windPeak24h {
            windDetail.append("peak \(ConditionsFormat.wind(peak, units))")
        }
        wind = MetricSummary(
            title: "Wind \(ConditionsFormat.windUnit(units))",
            value: windNow.map { ConditionsFormat.wind($0, units) },
            detail: windNow == nil ? nil : windDetail.joined(separator: " · "),
            state: state(.forecast))

        avalanche = AvalancheSummary(snapshot: snapshot, state: state(.avalanche), now: now)
    }
}

/// Whether a metric's value is dimmed, how old it is and what went wrong fetching it.
public struct MetricState: Encodable, Equatable, Sendable {
    public let dimmed: Bool
    /// Shown when the value is stale or outdated.
    public let age: String?
    /// The last refresh's error, then the problems worked around. Shown as a tooltip on the Mac.
    public let problems: [String]

    init(_ metric: Metric, conditions: LocationConditions, now: Date) {
        problems = [conditions.errors[metric]].compactMap { $0 } + (conditions.warnings[metric] ?? [])
        guard let snapshot = conditions.snapshot else {
            dimmed = false
            age = nil
            return
        }
        let outdated = snapshot.isOutdated(metric, now: now)
        let showAge = outdated || snapshot.staleMetrics.contains(metric)
        dimmed = conditions.isShowingCached || outdated
        age = showAge ? snapshot.valueDate(for: metric).map { ConditionsFormat.age(since: $0, now: now) } : nil
    }
}

/// One metric cell: a title, a value and a caption under it.
public struct MetricSummary: Encodable, Equatable, Sendable {
    public let title: String
    public let value: String?
    /// The detail and the age, or `unavailable` when there is no value.
    public let caption: String
    public let state: MetricState

    init(title: String, value: String?, detail: String?, state: MetricState) {
        self.title = title
        self.value = value
        self.state = state
        caption = value == nil ? "unavailable" : [detail, state.age].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The avalanche danger line, with the expiry rule applied.
public struct AvalancheSummary: Encodable, Equatable, Sendable {
    /// nil when there is no danger to show, and `headline` says it is unavailable.
    public let level: DangerLevel?
    /// `Mt Baker: Considerable`, `Mt Baker: forecast expired` or `Avalanche danger unavailable`.
    public let headline: String
    /// `Above TL 3 · Near TL 2 · Below TL 1` when the forecast rates each band.
    public let bands: String?
    public let forecastURL: URL?
    public let state: MetricState

    init(snapshot: ConditionsSnapshot?, state: MetricState, now: Date) {
        self.state = state
        forecastURL = snapshot?.danger?.forecastURL
        guard let danger = snapshot?.danger(at: now) else {
            level = nil
            headline = "Avalanche danger unavailable"
            bands = nil
            return
        }
        level = danger.overall
        headline = "\(danger.zoneName): \(danger.isExpired(at: now) ? "forecast expired" : danger.overall.label)"
        if let upper = danger.upper, let middle = danger.middle, let lower = danger.lower {
            bands = "Above TL \(upper.badgeText) · Near TL \(middle.badgeText) · Below TL \(lower.badgeText)"
        } else {
            bands = nil
        }
    }
}
