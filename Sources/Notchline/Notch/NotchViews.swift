import NotchlineCore
import SwiftUI

/// Left of the notch: snowflake and base depth, for example `❄ 61"`.
struct NotchCompactLeadingView: View {
    @ObservedObject var model: ConditionsModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 4) {
                Image(systemName: "snowflake")
                Text(model.snapshot?.observed.map { ConditionsFormat.snow($0.depthInches, model.units) } ?? "–")
                    .monospacedDigit()
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .opacity(isDimmed(.observed, model: model, now: context.date) ? 0.5 : 1)
        }
    }
}

/// Right of the notch: current temperature and the overall avalanche danger badge, or a gray dash for no rating.
struct NotchCompactTrailingView: View {
    @ObservedObject var model: ConditionsModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HStack(spacing: 6) {
                if let current = model.snapshot?.currentTemp(now: context.date) {
                    Text(ConditionsFormat.degrees(current.tempF, model.units))
                        .monospacedDigit()
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .opacity(isDimmed(current.isForecast ? .forecast : .observed, model: model, now: context.date) ? 0.5 : 1)
                }
                DangerBadge(level: model.snapshot?.danger(at: context.date)?.overall ?? .noRating)
                    .opacity(isDimmed(.avalanche, model: model, now: context.date) ? 0.5 : 1)
            }
        }
    }
}

/// Shown below the notch on hover: the same summary as the menu, plus sources and the forecast link.
struct NotchExpandedView: View {
    @ObservedObject var model: ConditionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                ConditionsSummaryView(model: model, now: context.date)
            }
            footer
        }
        .frame(width: 360, alignment: .leading)
        .environment(\.colorScheme, .dark)
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(sources)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
            if let url = model.snapshot?.danger?.forecastURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Forecast", systemImage: "arrow.up.right")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var sources: String {
        var names: [String] = []
        if model.snapshot?.observed != nil {
            switch model.location.observedSnow {
            case .snotel: names.append("USDA NRCS SNOTEL")
            case .bcSnowStations: names.append("BC ENV snow stations")
            case .modeledOnly: names.append(OpenMeteoProvider.sourceName)
            case nil: break
            }
        }
        if let forecast = model.snapshot?.forecast, !names.contains(forecast.sourceName) {
            names.append(forecast.sourceName)
        }
        if model.snapshot?.danger != nil {
            if let center = model.location.avalancheCenter {
                names.append("\(center) via avalanche.org")
            } else if model.location.country == .ca {
                names.append(AvalancheCanadaProvider.zoneName)
            }
        }
        return names.isEmpty ? "" : "Data: " + names.joined(separator: ", ")
    }
}

/// Dimmed while showing a cached snapshot or a value older than the outdated threshold.
@MainActor
private func isDimmed(_ metric: Metric, model: ConditionsModel, now: Date) -> Bool {
    guard let snapshot = model.snapshot else { return false }
    return model.isShowingCached || snapshot.isOutdated(metric, now: now)
}
