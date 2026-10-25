import NotchlineCore
import SwiftUI

/// The ski day planner: a day picker, both scores, the best window and departure for each
/// terrain, confidence, and the "Did you ski?" question once a scored day is over.
struct PlannerSectionView: View {
    @ObservedObject var planner: PlannerModel
    @ObservedObject var model: ConditionsModel
    let actions: PlannerActions
    let now: Date

    @State private var selectedIndex = 0
    @State private var showsScoreHelp = false

    private var timeZone: TimeZone { model.location.calendar.timeZone }

    var body: some View {
        if planner.locationID == model.location.id || planner.isPlanning {
            VStack(alignment: .leading, spacing: 8) {
                header
                if showsScoreHelp {
                    ScoreHelpView()
                }
                content
                if let record = planner.pendingRating, record.locationID == model.location.id {
                    ratingPrompt(record)
                }
            }
        }
    }

    private var days: [PlannedDay] { planner.plan?.days ?? [] }

    private var selectedDay: PlannedDay? {
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
                    title: PlannerFormat.dayName(days[index].score.day, now: now, calendar: model.location.calendar),
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
            Text("No hourly forecast to plan from.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func dayView(_ day: PlannedDay) -> some View {
        let order: [Terrain] = day.score.best == .groomed ? [.groomed, .ungroomed] : [.ungroomed, .groomed]
        let scored = order.filter { day.score.window($0) != nil }
        if scored.isEmpty {
            Text(noScoreReason(day.score))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                ForEach(scored, id: \.self) { terrain in
                    ScoreLabel(score: day.score.window(terrain)!.averageScore, terrain: terrain, isHeadline: terrain == scored.first)
                }
                Spacer()
                if let best = day.score.best, let confidence = day.score.confidence?.confidence(best) {
                    Text("Confidence \(confidence.percent)%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(confidenceHelp(confidence))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                if scored.count == 2 && sameTrip(day) {
                    terrainRow(day, scored[0], label: "Both")
                } else {
                    ForEach(scored, id: \.self) { terrain in
                        terrainRow(day, terrain, label: terrain == .groomed ? "Groomed" : "Ungroomed")
                    }
                }
            }
            if planner.plan?.needsHome == true {
                Button("Set home for departure times…") { actions.showSettings() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    /// Both terrains aim for the same window with the same departure, so one row says it.
    private func sameTrip(_ day: PlannedDay) -> Bool {
        day.score.groomed?.interval == day.score.ungroomed?.interval
            && day.groomed?.drive.leaveAt == day.ungroomed?.drive.leaveAt
            && day.groomed?.overnight?.leaveAt == day.ungroomed?.overnight?.leaveAt
    }

    private func terrainRow(_ day: PlannedDay, _ terrain: Terrain, label: String) -> some View {
        let window = day.score.window(terrain)!
        let departure = day.departure(terrain)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .frame(width: 70, alignment: .leading)
                Text(PlannerFormat.window(window.interval, timeZone: timeZone))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let departure {
                    Text(PlannerFormat.advice(departure.advice(now: now), timeZone: timeZone))
                        .font(.caption.weight(.semibold))
                }
            }
            if let departure {
                Group {
                    Text(PlannerFormat.drive(departure.drive))
                    if let overnight = departure.overnight {
                        Text(PlannerFormat.overnight(overnight, now: now, timeZone: timeZone))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 70)
            }
        }
        .help(planner.plan?.warnings.joined(separator: "\n") ?? "")
    }

    private func ratingPrompt(_ record: PlannerDayRecord) -> some View {
        let when = model.location.calendar.isDate(record.day, inSameDayAs: now) ? "today" : "yesterday"
        return HStack(spacing: 6) {
            Image(systemName: "star.bubble")
                .foregroundStyle(.secondary)
            Text("Did you ski \(model.location.shortName) \(when)?")
                .font(.caption)
            Spacer()
            Button("Rate…") { actions.rate(record) }
            Button("No") { actions.didNotSki(record) }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func noScoreReason(_ score: DayScore) -> String {
        if model.location.calendar.isDate(score.day, inSameDayAs: now) && now >= score.liftHours.end {
            return "The lifts have closed for the day."
        }
        let vetoes = Set(score.hours.compactMap(\.veto))
        guard !vetoes.isEmpty else { return "No skiable hours left today." }
        let reasons = [Veto.rain, .wind, .visibility].filter(vetoes.contains).map { veto in
            switch veto {
            case .rain: "rain"
            case .wind: "wind holds"
            case .visibility: "no visibility"
            }
        }
        return "No skiable hours: " + reasons.joined(separator: ", ") + "."
    }

    private func confidenceHelp(_ confidence: Confidence) -> String {
        var lines = [confidence.isMeasured
            ? "How often forecasts this far ahead held, measured from past seasons."
            : "Estimated from how far ahead the day is."]
        if let spread = confidence.modelSpread {
            lines.append("Forecast models are within \(spread) points of each other.")
        }
        lines.append("Lift hours are typical, not this season's.")
        return lines.joined(separator: "\n")
    }
}

/// What the scores mean and what goes into them. Shown inline rather than in a popover, since
/// moving the pointer into a popover would collapse the notch.
private struct ScoreHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Each score, 0 to 100, rates the day's best window for groomed or ungroomed runs: the stretch of lift hours within 15 points of the day's peak. The higher of the two leads.")
            Text("Every lift hour is scored from fresh snow not yet tracked out, snow quality from temperature, a refrozen rain crust, wind and gusts, and flat light from cloud, fog or falling snow. Rain, gusts over the lift-hold threshold or near-zero visibility zero out the hour.")
            Text("Groomed runs depend mostly on temperature, surface, wind and light, and top out at 85 so a perfect corduroy day still ranks under a deep powder day. Ungroomed runs depend mostly on fresh snow, which gets tracked out faster on weekends, holidays and big powder days.")
            Text("Confidence is how likely the score is to hold by the day itself.")
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
