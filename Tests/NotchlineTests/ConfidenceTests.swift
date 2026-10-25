import Foundation
import Testing
@testable import NotchlineCore

struct ConfidenceTests {
    let gust = 45.0

    /// Clear, cold, calm hours at Mt. Baker from local midnight on 2027-01-12, edited by `edit`.
    private func hourly(days: Int = 2, _ edit: (Date, inout ForecastHour) -> Void = { _, _ in }) -> HourlyForecast {
        let start = date("2027-01-12T08:00:00Z")
        return HourlyForecast(hours: stride(from: start, to: start.addingTimeInterval(Double(days) * 24 * 3600), by: 3600).map { start in
            var hour = ForecastHour(
                start: start, tempF: 22, snowfallInches: 0, precipitationInches: 0, rainInches: 0, precipitationProbability: 0,
                skyCoverPercent: 0, wind: Wind(sustainedMph: 5, gustMph: 10))
            edit(start, &hour)
            return hour
        })
    }

    private func score(_ hourly: HourlyForecast) throws -> PlannerScores {
        SkiDayScorer.score(hourly, location: try catalogLocation("mt-baker"), now: date("2027-01-12T08:00:00Z"), gustThresholdMph: gust)
    }

    /// 8" overnight before the second day.
    private func snowy() -> HourlyForecast {
        hourly { start, hour in
            if start >= date("2027-01-13T08:00:00Z") && start < date("2027-01-13T16:00:00Z") { hour.snowfallInches = 1 }
        }
    }

    // MARK: - Rule

    @Test func ruleFallsWithLeadAndDisagreement() {
        #expect(ConfidenceRules.rulePercent(lead: 0, agreement: nil) == 90)
        #expect(ConfidenceRules.rulePercent(lead: 0, agreement: .agree) == 90)
        #expect(ConfidenceRules.rulePercent(lead: 1, agreement: .differ) == 70)
        #expect(ConfidenceRules.rulePercent(lead: 3, agreement: .disagree) == 50)
        #expect(ConfidenceRules.rulePercent(lead: 6, agreement: nil) == 80)
    }

    @Test func agreementFromSpread() {
        #expect(ModelAgreement(spread: 0) == .agree)
        #expect(ModelAgreement(spread: 9) == .agree)
        #expect(ModelAgreement(spread: 10) == .differ)
        #expect(ModelAgreement(spread: 25) == .disagree)
    }

    // MARK: - Table

    private let table = ConfidenceTable(seasons: [], holdMarginPoints: 15, cells: [
        .init(location: nil, terrain: .ungroomed, lead: 1, agreement: nil, days: 100, held: 70, meanError: 10),
        .init(location: nil, terrain: .ungroomed, lead: 1, agreement: .agree, days: 50, held: 45, meanError: 5),
        // Too few days to stand on its own.
        .init(location: nil, terrain: .ungroomed, lead: 1, agreement: .disagree, days: 10, held: 2, meanError: 30),
        .init(location: "mt-baker", terrain: .ungroomed, lead: 1, agreement: nil, days: 20, held: 20, meanError: 3),
    ])

    @Test func tableBlendsALocationTowardEveryLocation() {
        // (20 + 20 × 0.7) / (20 + 20)
        #expect(table.percent(location: "mt-baker", terrain: .ungroomed, lead: 1, agreement: nil) == 85)
        #expect(table.percent(location: "revelstoke", terrain: .ungroomed, lead: 1, agreement: nil) == 70)
        #expect(table.percent(location: "revelstoke", terrain: .ungroomed, lead: 1, agreement: .agree) == 90)
        // Few disagreeing days, so any agreement.
        #expect(table.percent(location: "mt-baker", terrain: .ungroomed, lead: 1, agreement: .disagree) == 85)
        #expect(table.percent(location: "mt-baker", terrain: .ungroomed, lead: 2, agreement: nil) == nil)
        #expect(table.percent(location: "mt-baker", terrain: .groomed, lead: 1, agreement: nil) == nil)
    }

    @Test func bundledTableCoversEveryLeadAndTerrain() throws {
        let table = try ConfidenceTable.bundled()
        #expect(table.holdMarginPoints == ConfidenceRules.holdMarginPoints)
        for terrain in Terrain.allCases {
            for lead in 0...ConfidenceRules.maxLead {
                let percent = try #require(table.percent(location: "revelstoke", terrain: terrain, lead: lead, agreement: nil))
                #expect((1...100).contains(percent))
            }
        }
    }

    // MARK: - Applying

    @Test func applySetsLeadSpreadAndRule() throws {
        let location = try catalogLocation("mt-baker")
        let main = try score(snowy())
        let agreeing = ForecastConfidence.apply(to: main, models: [main, main], location: location, now: date("2027-01-12T08:00:00Z"), table: nil)
        let today = try #require(agreeing.days.first?.confidence)
        let tomorrow = try #require(agreeing.days.last?.confidence)
        #expect(today.ungroomed == Confidence(percent: 90, lead: 0, modelSpread: 0, isMeasured: false))
        #expect(tomorrow.ungroomed == Confidence(percent: 85, lead: 1, modelSpread: 0, isMeasured: false))

        // One model without the storm disagrees about ungroomed tomorrow, much less about groomed.
        let dry = try score(hourly())
        let split = ForecastConfidence.apply(to: main, models: [main, dry], location: location, now: date("2027-01-12T08:00:00Z"), table: nil)
        let disagreeing = try #require(split.days.last?.confidence)
        #expect(try #require(disagreeing.ungroomed.modelSpread) >= ConfidenceRules.modelsDisagreePoints)
        #expect(disagreeing.ungroomed.percent == 55)
        #expect(disagreeing.groomed.percent > disagreeing.ungroomed.percent)

        let alone = ForecastConfidence.apply(to: main, models: [main], location: location, now: date("2027-01-12T08:00:00Z"), table: nil)
        #expect(alone.days.last?.confidence?.ungroomed.modelSpread == nil)
        #expect(alone.days.last?.confidence?.ungroomed.percent == 85)

        let measured = ForecastConfidence.apply(to: main, models: [], location: location, now: date("2027-01-12T08:00:00Z"), table: table)
        #expect(measured.days.last?.confidence?.ungroomed == Confidence(percent: 85, lead: 1, modelSpread: nil, isMeasured: true))
    }

    // MARK: - Open-Meteo models and previous runs

    @Test func splitsSuffixedSeriesAndComparesRainFromPrecipitation() async throws {
        let t0 = date("2027-01-12T08:00:00Z").timeIntervalSince1970
        let json: [String: Any] = [
            "elevation": 1372,
            "hourly_units": ["time": "unixtime", "snowfall_previous_day1_gfs_seamless": "cm", "temperature_2m_previous_day1_gfs_seamless": "°C",
                             "precipitation_previous_day1_gfs_seamless": "mm", "snowfall_previous_day1_icon_seamless": "cm"],
            "hourly": [
                "time": [t0, t0 + 3600, t0 + 7200],
                "snowfall_previous_day1_gfs_seamless": [0, 0, 0],
                "temperature_2m_previous_day1_gfs_seamless": [5, 5, 5],
                "precipitation_previous_day1_gfs_seamless": [0, 2.54, 0],
                "snowfall_previous_day1_icon_seamless": [0, 1, NSNull()],
            ],
        ]
        let responses = try OpenMeteoProvider.split(JSONSerialization.data(withJSONObject: json),
                                                    suffixes: ["gfs": "_previous_day1_gfs_seamless", "icon": "_previous_day1_icon_seamless"])
        let gfs = try #require(responses["gfs"])
        #expect(gfs.hourly.temperature_2m == [5, 5, 5])
        #expect(gfs.hourly.rain == nil)
        let icon = try #require(responses["icon"])
        #expect(icon.hourly.snowfall == [0, 1, nil])
        #expect(icon.hourly.temperature_2m == [nil, nil, nil])

        let (hourly, warnings) = await ProviderWarnings.collecting {
            OpenMeteoProvider.hourlyForecast(from: OpenMeteoProvider.comparable(gfs), calendar: pacific, starts: [date("2027-01-12T08:00:00Z")])
        }
        // Absent series are not unit mismatches.
        #expect(!warnings.contains { $0.contains("expected") })
        let hour = try #require(hourly?.hours.first)
        // 2.54 mm at 5 °C is all rain.
        #expect(abs((hour.rainInches ?? 0) - 0.1) < 0.0001)
        #expect(hour.precipitationTypes == [.rain])
        #expect(hour.precipitationProbability == nil)
    }

    @Test func previousRunsRequestsEachLeadsFields() async throws {
        let location = try catalogLocation("mt-baker")
        let t0 = date("2027-01-12T08:00:00Z").timeIntervalSince1970
        let times = (0..<25).map { t0 + Double($0) * 3600 }
        var hourly: [String: Any] = ["time": times]
        var units: [String: String] = [:]
        for model in ["best_match"] + OpenMeteoProvider.comparisonModels {
            hourly["snowfall_previous_day2_\(model)"] = times.map { _ in 0.5 }
            hourly["temperature_2m_previous_day2_\(model)"] = times.map { _ in -5 }
            units["snowfall_previous_day2_\(model)"] = "cm"
            units["temperature_2m_previous_day2_\(model)"] = "°C"
        }
        let body = try JSONSerialization.data(withJSONObject: ["elevation": 1372, "hourly_units": units, "hourly": hourly])
        let provider = OpenMeteoProvider(http: StubHTTPClient([("previous-runs-api.open-meteo.com/v1/forecast?latitude=48.8630&longitude=-121.6780&elevation=1372&hourly=snowfall_previous_day2,temperature_2m_previous_day2", .success(body))]))
        let runs = try await provider.previousRuns(for: location, from: date("2027-01-12T08:00:00Z"), through: date("2027-01-12T08:00:00Z"), lead: 2)
        #expect(runs.forecast.hours.count == 24)
        #expect(Set(runs.models.keys) == Set(OpenMeteoProvider.comparisonModels))
        #expect(runs.forecast.hours.first?.snowfallInches.map { abs($0 - 0.5 / 2.54) < 0.0001 } == true)
    }

    // MARK: - Backtest

    @Test func observedSeriesTakesStationSnowAndTemperature() throws {
        let location = try catalogLocation("mt-baker")
        // The forecast saw no storm. The station gained 6" overnight, reading at 4,040 ft.
        let forecast = hourly()
        var depth: [Date: Double] = [:]
        var temps: [Date: Double] = [:]
        for start in stride(from: date("2027-01-12T00:00:00Z"), to: date("2027-01-14T12:00:00Z"), by: 3600) {
            let ramp = start.timeIntervalSince(date("2027-01-13T04:00:00Z")) / (8 * 3600)
            depth[start] = 40 + 6 * min(1, max(0, ramp))
            temps[start] = 30
        }
        let station = StationHistory(stationName: "Wells Creek", elevationFt: 4040, depthInches: depth, tempF: temps)
        let observed = ConfidenceBacktest.observed(forecast, station: station, location: location)
        // The first day has no last chair before it.
        #expect(observed.coveredDays == [date("2027-01-13T08:00:00Z")])
        let overnight = observed.hourly.hours.filter { $0.start >= date("2027-01-12T23:30:00Z") && $0.start < date("2027-01-13T17:00:00Z") }
        #expect(abs(overnight.reduce(0) { $0 + ($1.snowfallInches ?? 0) } - 6) < 0.001)
        #expect(overnight.allSatisfy { $0.precipitationTypes == [.snow] })
        // 460 ft higher at 3.5 °F per 1,000 ft.
        #expect(observed.hourly.hours.allSatisfy { abs(($0.tempF ?? 0) - 28.39) < 0.01 })

        let day = try #require(try score(observed.hourly).days.last)
        #expect(abs(day.newSnowInches - 6) < 0.01)
        #expect(try #require(day.ungroomed).averageScore > (try score(forecast).days.last?.ungroomed?.averageScore ?? 0) + 15)
    }

    @Test func observedRainFollowsStationTemperature() throws {
        let location = try catalogLocation("mt-baker")
        let forecast = hourly { _, hour in hour.precipitationInches = 0.1 }
        let station = StationHistory(
            stationName: "Wells Creek", elevationFt: 4500,
            depthInches: Dictionary(uniqueKeysWithValues: stride(from: date("2027-01-12T00:00:00Z"), to: date("2027-01-14T12:00:00Z"), by: 3600).map { ($0, 40.0) }),
            tempF: Dictionary(uniqueKeysWithValues: stride(from: date("2027-01-12T00:00:00Z"), to: date("2027-01-14T12:00:00Z"), by: 3600).map { ($0, 40.0) }))
        let observed = ConfidenceBacktest.observed(forecast, station: station, location: location)
        let lift = observed.hourly.hours.filter { $0.start >= date("2027-01-13T17:00:00Z") && $0.start < date("2027-01-13T23:00:00Z") }
        #expect(lift.allSatisfy { $0.rainInches == 0.1 && $0.precipitationTypes == [.rain] })
        let day = try #require(try score(observed.hourly).days.last)
        #expect(day.hours.allSatisfy { $0.veto == .rain })
    }

    @Test func tableCountsHeldDaysByLocationAndAgreement() {
        func sample(_ location: String, _ forecast: Int, _ observed: Int, _ agreement: ModelAgreement?) -> ConfidenceBacktest.Sample {
            .init(location: location, day: date("2027-01-12T08:00:00Z"), terrain: .ungroomed, lead: 1, agreement: agreement, forecast: forecast, observed: observed)
        }
        let table = ConfidenceBacktest.table([
            sample("mt-baker", 80, 75, .agree),
            sample("mt-baker", 80, 60, .agree),
            sample("mt-baker", 40, 50, .disagree),
            sample("crystal", 30, 30, nil),
        ], seasons: ["2027-01-01...2027-04-15"])
        func cell(_ location: String?, _ agreement: ModelAgreement?) -> ConfidenceTable.Cell? {
            table.cells.first { $0.location == location && $0.agreement == agreement }
        }
        #expect(cell("mt-baker", nil).map { [$0.days, $0.held] } == [3, 2])
        #expect(cell("mt-baker", nil)?.meanError == 11.7)
        #expect(cell("mt-baker", .agree).map { [$0.days, $0.held] } == [2, 1])
        #expect(cell("crystal", nil).map { [$0.days, $0.held] } == [1, 1])
        #expect(cell(nil, nil).map { [$0.days, $0.held] } == [4, 3])
        #expect(cell(nil, .disagree).map { [$0.days, $0.held] } == [1, 1])
        #expect(table.cells.count == 7)
    }

    @Test func bcArchiveColumnKeepsOneStationInRange() throws {
        let csv = """
        DATE(UTC),1A01P Yellowhead Lake,3A20P Callaghan Creek
        2023-12-31 23:00,5,100
        2024-01-02 00:00,6,110
        2024-01-02 01:00,6,
        2025-01-01 00:00,0,0
        """
        let values = try BCSnowStationProvider.column(Data(csv.utf8), station: "3A20P",
                                                      in: DateInterval(start: date("2024-01-01T00:00:00Z"), end: date("2024-12-31T00:00:00Z")))
        #expect(values == [date("2024-01-02T00:00:00Z"): 110])
        #expect(throws: ProviderError.self) {
            try BCSnowStationProvider.column(Data(csv.utf8), station: "9Z99P", in: DateInterval(start: .distantPast, end: .distantFuture))
        }
    }
}
