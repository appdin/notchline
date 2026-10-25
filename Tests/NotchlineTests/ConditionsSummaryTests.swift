import Foundation
import Testing
@testable import NotchlineCore

struct ConditionsCacheTests {
    let now = date("2026-10-24T20:30:00Z")

    func makeStore() -> SnapshotStore {
        SnapshotStore(directory: FileManager.default.temporaryDirectory.appending(path: "notchline-tests-\(UUID().uuidString)"))
    }

    @Test func storedSnapshotIsCachedUntilRefreshed() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let stored = ConditionsSnapshot(locationID: "mt-baker", fetchedAt: now.addingTimeInterval(-3600))
        try store.save(stored)

        var cache = ConditionsCache(store: store)
        let cached = cache.conditions(for: "mt-baker")
        #expect(cached.snapshot == stored)
        #expect(cached.isShowingCached)
        let other = cache.conditions(for: "crystal")
        #expect(!other.isShowingCached)

        let first = cache.beginRefresh("mt-baker")
        let second = cache.beginRefresh("mt-baker")
        #expect(first && !second)
        let refreshing = cache.conditions(for: "mt-baker")
        #expect(refreshing.isRefreshing)

        let fresh = ConditionsSnapshot(locationID: "mt-baker", fetchedAt: now)
        cache.finishRefresh(ConditionsResult(snapshot: fresh, errors: [.avalanche: "down"], warnings: [:], failedMetrics: [.avalanche]))
        let conditions = cache.conditions(for: "mt-baker")
        #expect(conditions.snapshot == fresh)
        #expect(!conditions.isShowingCached && !conditions.isRefreshing)
        #expect(conditions.errors == [.avalanche: "down"])
        #expect(store.load(locationID: "mt-baker") == fresh)
    }
}

struct ConditionsSummaryTests {
    let now = date("2026-10-24T20:30:00Z")

    var snapshot: ConditionsSnapshot {
        ConditionsSnapshot(
            locationID: "mt-baker",
            observed: ObservedSnow(depthInches: 61, snow24hInches: 8, observedAt: now.addingTimeInterval(-1800), stationName: "Wells Creek", stationElevationFt: 4040),
            forecast: SnowForecast(next24hInches: 4, issuedAt: nil, gridElevationFt: 4200, sourceName: "NWS", windNow: Wind(sustainedMph: 15, gustMph: 30, directionDegrees: 225), windPeak24h: Wind(sustainedMph: 20, gustMph: 40)),
            danger: DangerSummary(zoneName: "West Slopes North", overall: .considerable, upper: .considerable, middle: .moderate, lower: .low, validUntil: now.addingTimeInterval(3600)),
            staleMetrics: [.forecast],
            updatedAt: [.observed: now, .forecast: now.addingTimeInterval(-5 * 3600), .avalanche: now],
            fetchedAt: now)
    }

    func conditions(_ snapshot: ConditionsSnapshot?, cached: Bool = false) -> LocationConditions {
        LocationConditions(snapshot: snapshot, errors: [.forecast: "HTTP 503"], warnings: [.forecast: ["used Open-Meteo"]], isShowingCached: cached, isRefreshing: false)
    }

    @Test func metricsAndAvalancheFromASnapshot() throws {
        let summary = ConditionsSummary(location: try catalogLocation("mt-baker"), conditions: conditions(snapshot), units: .imperial, now: now)
        #expect(summary.status == "updated just now")
        #expect(summary.base.value == "61\"")
        #expect(summary.base.caption == "Wells Creek 4,040'")
        #expect(summary.last24h.value == "+8\"")
        #expect(summary.wind.title == "Wind mph")
        #expect(summary.wind.value == "15 G30")
        #expect(summary.wind.caption.hasPrefix("SW · peak 20 G40"))
        #expect(summary.avalanche.level == .considerable)
        #expect(summary.avalanche.headline == "West Slopes North: Considerable")
        #expect(summary.avalanche.bands == "Above TL 3 · Near TL 2 · Below TL 1")
        #expect(!summary.base.state.dimmed && summary.base.state.age == nil)
    }

    @Test func staleAndOutdatedMetricsAreDimmedWithTheirAge() throws {
        let summary = ConditionsSummary(location: try catalogLocation("mt-baker"), conditions: conditions(snapshot), units: .metric, now: now)
        #expect(summary.next24h.value == "+10 cm")
        #expect(summary.next24h.state.dimmed)
        #expect(summary.next24h.state.age == "5 h ago")
        #expect(summary.next24h.caption == "NWS grid 1,280 m · 5 h ago")
        #expect(summary.next24h.state.problems == ["HTTP 503", "used Open-Meteo"])
        #expect(summary.wind.title == "Wind km/h")
    }

    @Test func cachedSnapshotIsDimmedEverywhere() throws {
        let summary = ConditionsSummary(location: try catalogLocation("mt-baker"), conditions: conditions(snapshot, cached: true), units: .imperial, now: now)
        #expect(summary.base.state.dimmed && summary.avalanche.state.dimmed)
    }

    @Test func expiredDangerAndMissingData() throws {
        let location = try catalogLocation("mt-baker")
        let expired = ConditionsSummary(location: location, conditions: conditions(snapshot), units: .imperial, now: now.addingTimeInterval(7200))
        #expect(expired.avalanche.level == .noRating)
        #expect(expired.avalanche.headline == "West Slopes North: forecast expired")
        #expect(expired.avalanche.bands == nil)

        let empty = ConditionsSummary(location: location, conditions: conditions(nil), units: .imperial, now: now)
        #expect(empty.status == "no data yet")
        #expect(empty.base.value == nil && empty.base.caption == "unavailable")
        #expect(empty.avalanche.level == nil)
        #expect(empty.avalanche.headline == "Avalanche danger unavailable")
    }
}
