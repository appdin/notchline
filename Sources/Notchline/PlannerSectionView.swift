import NotchlineCore
import SwiftUI

/// The ski day planner: a day picker, both scores, the best window and departure for each
/// terrain, confidence, and a link to rate a recent day, which nothing asks for.
struct PlannerSectionView: View {
    @ObservedObject var planner: PlannerModel
    @ObservedObject var model: ConditionsModel
    let actions: PlannerActions
    let now: Date

    @State private var selectedIndex = 0
    @State private var showsScoreHelp = false

    var body: some View {
        if planner.locationID == model.location.id || planner.isPlanning {
            VStack(alignment: .leading, spacing: 8) {
                header
                if showsScoreHelp {
                    ScoreHelpView()
                }
                content
                Button("Rate a day you skied…") { actions.rateADay() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private var summary: PlannerSummary? {
        planner.plan.map { PlannerSummary(plan: $0, location: model.location, now: now) }
    }

    private var days: [PlannerDaySummary] { summary?.days ?? [] }

    private var selectedDay: PlannerDaySummary? {
        days.isEmpty ? nil : days[min(selectedIndex, days.count - 1)]
    }

    /// The full title when the day buttons leave room for it, the short one otherwise.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            header(title: "Snow condition scores")
            header(title: "Snow scores")
        }
    }

    private func header(title: String) -> some View {
        HStack(alignment: .center, spacing: 4) {
            Text(title).font(.headline)
            Button {
                showsScoreHelp.toggle()
            } label: {
                Image(systemName: showsScoreHelp ? "questionmark.circle.fill" : "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(showsScoreHelp ? "Hide what the scores mean" : "What the scores mean")
            Spacer()
            if planner.isPlanning {
                ProgressView().controlSize(.small)
            }
            ForEach(days.indices, id: \.self) { index in
                DayButton(
                    title: days[index].title,
                    isSelected: index == min(selectedIndex, days.count - 1)
                ) { selectedIndex = index }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let day = selectedDay {
            dayView(day)
        } else if !planner.isPlanning {
            Text(PlannerSummary.noForecast)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func dayView(_ day: PlannerDaySummary) -> some View {
        if let reason = day.noScoreReason {
            Text(reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                ForEach(day.scores, id: \.terrain) { score in
                    ScoreLabel(score: score.score, terrain: score.terrain, isHeadline: score.isHeadline)
                }
                Spacer()
                if let confidence = day.confidence {
                    Text(confidence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(day.confidenceNotes.joined(separator: "\n"))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(day.rows, id: \.label) { row in
                    terrainRow(row)
                }
            }
            if summary?.needsHome == true {
                Button("Set home for departure times…") { actions.showSettings() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private func terrainRow(_ row: TerrainRowSummary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.label)
                    .font(.caption.weight(.semibold))
                    .frame(width: 70, alignment: .leading)
                Text(row.window)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let advice = row.advice {
                    Text(advice)
                        .font(.caption.weight(.semibold))
                }
            }
            ForEach(row.details, id: \.self) { detail in
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 70)
            }
        }
        .help(summary?.warnings.joined(separator: "\n") ?? "")
    }
}

/// What the scores mean and what goes into them. Shown inline rather than in a popover, since
/// moving the pointer into a popover would collapse the notch.
private struct ScoreHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(ScoreHelp.paragraphs, id: \.self) { Text($0) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(8)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct ScoreLabel: View {
    let score: Int
    let terrain: Terrain
    let isHeadline: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(score)")
                .font((isHeadline ? Font.title2 : .title3).weight(.semibold).monospacedDigit())
            Text(terrain.rawValue)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DayButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isSelected ? Color.primary.opacity(0.15) : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .primary : .secondary)
    }
}
