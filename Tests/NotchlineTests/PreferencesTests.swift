import Foundation
import Testing
@testable import NotchlineCore

struct UnitPreferenceTests {
    @Test func automaticFollowsTheCountry() throws {
        #expect(UnitPreference.automatic.resolve(for: try catalogLocation("mt-baker")) == .imperial)
        #expect(UnitPreference.automatic.resolve(for: try catalogLocation("whistler")) == .metric)
    }

    @Test func overrideIgnoresTheCountry() throws {
        #expect(UnitPreference.metric.resolve(for: try catalogLocation("mt-baker")) == .metric)
        #expect(UnitPreference.imperial.resolve(for: try catalogLocation("whistler")) == .imperial)
    }
}

struct SnowAlertTests {
    let now = date("2026-12-10T15:00:00Z")

    func snapshot(_ snow24h: Double?, location: String = "mt-baker", stale: Bool = false) -> ConditionsSnapshot {
        ConditionsSnapshot(
            locationID: location,
            observed: ObservedSnow(depthInches: 60, snow24hInches: snow24h, observedAt: now, stationName: "Wells Creek", stationElevationFt: 4040),
            staleMetrics: stale ? [.observed] : [],
            fetchedAt: now)
    }

    @Test func thresholdsAreRoundInEitherUnit() {
        #expect(SnowAlertLevel.moderate.thresholdInches(.imperial) == 6)
        #expect(SnowAlertLevel.off.thresholdInches(.metric) == nil)
        let cm = SnowAlertLevel.moderate.thresholdInches(.metric).map { ConditionsFormat.snow($0, .metric) }
        #expect(cm == "15 cm")
    }

    @Test func alertsAtTheThreshold() {
        #expect(SnowAlert.check(snapshot(6), thresholdInches: 6, last: nil, now: now) == SnowAlert(locationID: "mt-baker", snow24hInches: 6, at: now))
        #expect(SnowAlert.check(snapshot(5.9), thresholdInches: 6, last: nil, now: now) == nil)
        #expect(SnowAlert.check(snapshot(nil), thresholdInches: 6, last: nil, now: now) == nil)
        #expect(SnowAlert.check(snapshot(8), thresholdInches: nil, last: nil, now: now) == nil)
    }

    @Test func staleObservedSnowNeverAlerts() {
        #expect(SnowAlert.check(snapshot(10, stale: true), thresholdInches: 6, last: nil, now: now) == nil)
    }

    @Test func oneStormAlertsOnce() {
        let last = SnowAlert(locationID: "mt-baker", snow24hInches: 7, at: now.addingTimeInterval(-3600))
        #expect(SnowAlert.check(snapshot(9), thresholdInches: 6, last: last, now: now) == nil)
        // Another threshold's worth on top of the last alert alerts again.
        #expect(SnowAlert.check(snapshot(13), thresholdInches: 6, last: last, now: now) != nil)
    }

    @Test func aDayLaterOrAnotherLocationAlertsAgain() {
        let last = SnowAlert(locationID: "mt-baker", snow24hInches: 7, at: now.addingTimeInterval(-24 * 3600))
        #expect(SnowAlert.check(snapshot(7), thresholdInches: 6, last: last, now: now) != nil)
        let recent = SnowAlert(locationID: "mt-baker", snow24hInches: 7, at: now.addingTimeInterval(-60))
        #expect(SnowAlert.check(snapshot(7, location: "crystal"), thresholdInches: 6, last: recent, now: now) != nil)
    }
}

@MainActor
struct ModelUnitsTests {
    @Test func unitsFollowTheSelectedLocationUntilOverridden() throws {
        let model = ConditionsModel(catalog: try LocationCatalog.bundled(), selectedID: "mt-baker")
        #expect(model.units == .imperial)
        model.select("whistler")
        #expect(model.units == .metric)
        model.unitPreference = .imperial
        #expect(model.units == .imperial)
    }
}
