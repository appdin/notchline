import NotchlineCore
import SwiftUI

/// Header, the snow, temperature and wind metrics and the avalanche summary for the selected location.
struct ConditionsSummaryView: View {
    @ObservedObject var model: ConditionsModel
    let now: Date

    var body: some View {
        let summary = ConditionsSummary(location: model.location, conditions: model.conditions, units: model.units, now: now)
        VStack(alignment: .leading, spacing: 12) {
            header(summary)
            HStack(alignment: .top, spacing: 16) {
                MetricCell(metric: summary.base)
                MetricCell(metric: summary.last24h)
                MetricCell(metric: summary.next24h)
            }
            HStack(alignment: .top, spacing: 16) {
                MetricCell(metric: summary.tempNow)
                MetricCell(metric: summary.highLow)
                MetricCell(metric: summary.wind)
            }
            avalanche(summary.avalanche)
        }
    }

    private func header(_ summary: ConditionsSummary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(summary.locationName).font(.headline)
            Spacer()
            if summary.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Text(summary.status).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func avalanche(_ avalanche: AvalancheSummary) -> some View {
        if let level = avalanche.level {
            HStack(alignment: .top, spacing: 8) {
                DangerBadge(level: level)
                VStack(alignment: .leading, spacing: 2) {
                    Text(avalanche.headline).font(.subheadline)
                    if let bands = avalanche.bands {
                        Text(bands).font(.caption).foregroundStyle(.secondary)
                    }
                    if let age = avalanche.state.age {
                        Text(age).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .opacity(avalanche.state.dimmed ? 0.45 : 1)
            .help(avalanche.state.help)
        } else {
            Label(avalanche.headline, systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .help(avalanche.state.help)
        }
    }
}

struct MetricCell: View {
    let metric: MetricSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(metric.title).font(.caption).foregroundStyle(.secondary)
            Text(metric.value ?? "–")
                .font(.title2.weight(.semibold).monospacedDigit())
            Text(metric.caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(metric.state.dimmed ? 0.45 : 1)
        .help(metric.state.help)
    }
}

extension MetricState {
    /// The problems, one per line.
    var help: String {
        problems.joined(separator: "\n")
    }
}
