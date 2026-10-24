import NotchlineCore
import SwiftUI

/// Header, the snow, temperature and wind metrics and the avalanche summary for the selected location.
struct ConditionsSummaryView: View {
    @ObservedObject var model: ConditionsModel
    let now: Date

    private var snapshot: ConditionsSnapshot? { model.snapshot }
    private var units: UnitSystem { model.units }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            HStack(alignment: .top, spacing: 16) {
                base
                last24h
                next24h
            }
            HStack(alignment: .top, spacing: 16) {
                tempNow
                highLow
                wind
            }
            avalanche
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.location.name).font(.headline)
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var status: String {
        if let updated = snapshot?.lastUpdated {
            return "updated " + ConditionsFormat.age(since: updated, now: now)
        }
        return model.isRefreshing ? "loading" : "no data yet"
    }

    private var base: some View {
        MetricCell(
            title: snapshot?.observed?.isModeled == true ? "Base (modeled)" : "Base",
            value: snapshot?.observed.map { ConditionsFormat.snow($0.depthInches, units) },
            detail: snapshot?.observed.map { "\($0.stationName) \(ConditionsFormat.elevation($0.stationElevationFt, units))" },
            state: state(for: .observed))
    }

    private var last24h: some View {
        let observed = snapshot?.observed
        return MetricCell(
            title: "Last 24h",
            value: observed.map { $0.snow24hInches.map { ConditionsFormat.newSnow($0, units) } ?? "–" },
            detail: observed.map { $0.snow24hInches == nil ? "no reading 24h ago" : "observed" },
            state: state(for: .observed))
    }

    private var next24h: some View {
        MetricCell(
            title: "Next 24h",
            value: snapshot?.forecast.map { ConditionsFormat.newSnow($0.next24hInches, units) },
            detail: snapshot?.forecast.map { forecast in
                forecast.gridElevationFt.map { "\(forecast.sourceName == "NWS" ? "NWS grid" : forecast.sourceName) \(ConditionsFormat.elevation($0, units))" } ?? forecast.sourceName
            },
            state: state(for: .forecast))
    }

    private var tempNow: some View {
        let current = snapshot?.currentTemp(now: now)
        let fromStation = current?.isForecast == false
        return MetricCell(
            title: "Temp now",
            value: current.map { ConditionsFormat.degrees($0.tempF, units) + ConditionsFormat.temperatureScale(units) },
            detail: current.map { _ in
                fromStation ? snapshot?.observed?.stationName ?? "station" : "\(snapshot?.forecast?.sourceName ?? "") forecast"
            },
            state: state(for: fromStation ? .observed : .forecast))
    }

    private var highLow: some View {
        let forecast = snapshot?.forecast
        let tomorrow = forecast?.high.map { ConditionsFormat.highIsTomorrow($0, now: now, calendar: model.location.calendar) } ?? false
        let value: String? = forecast.flatMap { forecast in
            guard forecast.high != nil || forecast.low != nil else { return nil }
            let high = forecast.high.map { ConditionsFormat.degrees($0.tempF, units) } ?? "–"
            let low = forecast.low.map { ConditionsFormat.degrees($0.tempF, units) } ?? "–"
            return "\(high) / \(low)"
        }
        return MetricCell(
            title: tomorrow ? "Tmrw high / Low" : "High / Low",
            value: value,
            detail: value == nil ? nil : "forecast",
            state: state(for: .forecast))
    }

    private var wind: some View {
        let forecast = snapshot?.forecast
        let windNow = forecast?.windNow
        var detail: [String] = []
        if let windNow {
            windNow.directionDegrees.map { detail.append(ConditionsFormat.compass($0)) }
        }
        if let peak = forecast?.windPeak24h {
            detail.append("peak \(ConditionsFormat.wind(peak, units))")
        }
        return MetricCell(
            title: "Wind \(ConditionsFormat.windUnit(units))",
            value: windNow.map { ConditionsFormat.wind($0, units) },
            detail: windNow == nil ? nil : detail.joined(separator: " · "),
            state: state(for: .forecast))
    }

    @ViewBuilder
    private var avalanche: some View {
        let state = state(for: .avalanche)
        if let danger = snapshot?.danger(at: now) {
            HStack(alignment: .top, spacing: 8) {
                DangerBadge(level: danger.overall)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(danger.zoneName): \(danger.isExpired(at: now) ? "forecast expired" : danger.overall.label)")
                        .font(.subheadline)
                    if let upper = danger.upper, let middle = danger.middle, let lower = danger.lower {
                        Text("Above TL \(upper.badgeText) · Near TL \(middle.badgeText) · Below TL \(lower.badgeText)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let age = state.age {
                        Text(age).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .opacity(state.dimmed ? 0.45 : 1)
            .help(state.help)
        } else {
            Label("Avalanche danger unavailable", systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .help(state.help)
        }
    }

    private func state(for metric: Metric) -> MetricState {
        guard let snapshot else {
            return MetricState(dimmed: false, age: nil, error: model.errors[metric], warnings: model.warnings[metric] ?? [])
        }
        let outdated = snapshot.isOutdated(metric, now: now)
        let showAge = outdated || snapshot.staleMetrics.contains(metric)
        return MetricState(
            dimmed: model.isShowingCached || outdated,
            age: showAge ? snapshot.valueDate(for: metric).map { ConditionsFormat.age(since: $0, now: now) } : nil,
            error: model.errors[metric],
            warnings: model.warnings[metric] ?? [])
    }
}

struct MetricState {
    var dimmed: Bool
    /// Shown when the value is stale or outdated.
    var age: String?
    var error: String?
    /// Problems worked around in the last refresh, shown as a tooltip.
    var warnings: [String] = []

    var help: String {
        ([error].compactMap { $0 } + warnings).joined(separator: "\n")
    }
}

struct MetricCell: View {
    let title: String
    let value: String?
    let detail: String?
    let state: MetricState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "–")
                .font(.title2.weight(.semibold).monospacedDigit())
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(state.dimmed ? 0.45 : 1)
        .help(state.help)
    }

    private var caption: String {
        guard value != nil else { return "unavailable" }
        return [detail, state.age].compactMap { $0 }.joined(separator: " · ")
    }
}
