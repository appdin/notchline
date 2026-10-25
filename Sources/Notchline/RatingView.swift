import AppKit
import NotchlineCore
import SwiftUI

/// Rates one of the location's recent days, when the user chooses to: a day picker, then
/// groomed, ungroomed or both from 1 to 5, and optionally when the user left home and got on the
/// lift. Nothing asks for ratings. A day already rated starts from its rating, and saving
/// replaces it. Times are in the location's time zone.
struct RatingView: View {
    /// Newest first, today included.
    let days: [PlannerDayRecord]
    let location: Location
    let onSave: (PlannerDayRecord, DayRating) -> Void

    @State private var selectedIndex = 0

    var body: some View {
        let record = days[min(selectedIndex, days.count - 1)]
        let now = Date()
        VStack(spacing: 0) {
            Picker("Day", selection: $selectedIndex) {
                ForEach(days.indices, id: \.self) { index in
                    let prompt = RatingPrompt(days[index], location: location, now: now)
                    Text(days[index].rating == nil ? prompt.dayLabel : "\(prompt.dayLabel) ✓").tag(index)
                }
            }
            .pickerStyle(.menu)
            .padding([.horizontal, .top], 20)
            // A new form per day, so each starts from that day's record.
            DayRatingForm(record: record, location: location, prompt: RatingPrompt(record, location: location, now: now)) { rating in
                onSave(record, rating)
            }
            .id(record.day)
        }
        .environment(\.timeZone, location.calendar.timeZone)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DayRatingForm: View {
    let record: PlannerDayRecord
    let location: Location
    let prompt: RatingPrompt
    let onSave: (DayRating) -> Void

    @State private var groomed: Int?
    @State private var ungroomed: Int?
    @State private var includeLeftHome: Bool
    @State private var leftHomeAt: Date
    @State private var includeOnLift: Bool
    @State private var onLiftAt: Date

    init(record: PlannerDayRecord, location: Location, prompt: RatingPrompt, onSave: @escaping (DayRating) -> Void) {
        self.record = record
        self.location = location
        self.prompt = prompt
        self.onSave = onSave
        let rating = record.rating
        let plan = record.morning?.plan
        let departure = plan?.score.best.flatMap { plan?.departure($0) }
        let firstChair = plan?.score.liftHours.start ?? ClockTime(hour: 9, minute: 0)!.date(on: record.day, calendar: location.calendar)
        _groomed = State(initialValue: rating?.groomed)
        _ungroomed = State(initialValue: rating?.ungroomed)
        _includeLeftHome = State(initialValue: rating?.leftHomeAt != nil)
        _leftHomeAt = State(initialValue: rating?.leftHomeAt ?? departure?.drive.leaveAt ?? firstChair.addingTimeInterval(-2 * 3600))
        _includeOnLift = State(initialValue: rating?.onLiftAt != nil)
        _onLiftAt = State(initialValue: rating?.onLiftAt ?? departure?.liftTime ?? firstChair)
    }

    var body: some View {
        Form {
            Section {
                ratingPicker("Groomed", selection: $groomed)
                ratingPicker("Ungroomed", selection: $ungroomed)
            } header: {
                Text(prompt.title)
            } footer: {
                Text(prompt.note)
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
    }

    private func ratingPicker(_ title: String, selection: Binding<Int?>) -> some View {
        Picker(title, selection: selection) {
            Text("Didn't ski").tag(Int?.none)
            ForEach(Array(DayRating.scale), id: \.self) { Text("\($0)").tag(Int?.some($0)) }
        }
        .pickerStyle(.segmented)
    }
}

/// Hosts RatingView in its own window, opened from the planner section in the notch or the menu.
@MainActor
final class RatingWindowController {
    private var window: NSWindow?

    func show(days: [PlannerDayRecord], location: Location, onSave: @escaping (PlannerDayRecord, DayRating) -> Void) {
        let view = RatingView(days: days, location: location) { [weak self] record, rating in
            onSave(record, rating)
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
        window?.title = "Rate a day at \(location.shortName)"
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
