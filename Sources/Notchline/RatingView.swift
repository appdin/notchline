import AppKit
import NotchlineCore
import SwiftUI

/// Rates a day the planner scored: groomed, ungroomed or both from 1 to 5, and optionally when
/// the user left home and got on the lift. Times are in the location's time zone.
struct RatingView: View {
    let record: PlannerDayRecord
    let location: Location
    let onSave: (DayRating) -> Void

    @State private var groomed: Int?
    @State private var ungroomed: Int?
    @State private var includeLeftHome = false
    @State private var leftHomeAt: Date
    @State private var includeOnLift = false
    @State private var onLiftAt: Date

    init(record: PlannerDayRecord, location: Location, onSave: @escaping (DayRating) -> Void) {
        self.record = record
        self.location = location
        self.onSave = onSave
        let plan = record.morning?.plan
        let departure = plan?.score.best.flatMap { plan?.departure($0) }
        let firstChair = plan?.score.liftHours.start ?? ClockTime(hour: 9, minute: 0)!.date(on: record.day, calendar: location.calendar)
        _leftHomeAt = State(initialValue: departure?.drive.leaveAt ?? firstChair.addingTimeInterval(-2 * 3600))
        _onLiftAt = State(initialValue: departure?.liftTime ?? firstChair)
    }

    var body: some View {
        Form {
            Section {
                ratingPicker("Groomed", selection: $groomed)
                ratingPicker("Ungroomed", selection: $ungroomed)
            } header: {
                Text(title)
            } footer: {
                Text(forecastNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("I left home at", isOn: $includeLeftHome)
                if includeLeftHome {
                    DatePicker("Left home", selection: $leftHomeAt, displayedComponents: .hourAndMinute)
                }
                Toggle("I was on the lift at", isOn: $includeOnLift)
                if includeOnLift {
                    DatePicker("On the lift", selection: $onLiftAt, displayedComponents: .hourAndMinute)
                }
            } footer: {
                Text("Optional. Ratings stay on this Mac and teach the planner what you like.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("I didn't ski") { onSave(.didNotSki(at: Date())) }
                Spacer()
                Button("Save") {
                    onSave(DayRating(
                        skied: true, groomed: groomed, ungroomed: ungroomed,
                        leftHomeAt: includeLeftHome ? leftHomeAt : nil, onLiftAt: includeOnLift ? onLiftAt : nil,
                        ratedAt: Date()))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(groomed == nil && ungroomed == nil)
            }
        }
        .formStyle(.grouped)
        .environment(\.timeZone, location.calendar.timeZone)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func ratingPicker(_ title: String, selection: Binding<Int?>) -> some View {
        Picker(title, selection: selection) {
            Text("Didn't ski").tag(Int?.none)
            ForEach(Array(DayRating.scale), id: \.self) { Text("\($0)").tag(Int?.some($0)) }
        }
        .pickerStyle(.segmented)
    }

    private var title: String {
        let formatter = DateFormatter()
        formatter.timeZone = location.calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEEMMMd")
        return "How was \(location.name) on \(formatter.string(from: record.day))?"
    }

    private var forecastNote: String {
        guard let score = record.morning?.plan.score else { return "Rate only what you skied, 1 for poor to 5 for great." }
        return "The planner forecast \(PlannerFormat.scores(score)). Rate only what you skied, 1 for poor to 5 for great."
    }
}

/// Hosts RatingView in its own window, opened from the notch, the menu or a notification.
@MainActor
final class RatingWindowController {
    private var window: NSWindow?

    func show(record: PlannerDayRecord, location: Location, onSave: @escaping (DayRating) -> Void) {
        let view = RatingView(record: record, location: location) { [weak self] rating in
            onSave(rating)
            self?.window?.close()
        }
        let controller = NSHostingController(rootView: view)
        if let window {
            window.contentViewController = controller
        } else {
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.title = "Rate \(location.shortName)"
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
