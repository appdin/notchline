import Foundation

/// Every unit conversion in one place. The model stores inches, feet, °F and mph; sources and
/// metric display convert through here rather than with inline factors.
enum Convert {
    static func inches(fromMM mm: Double) -> Double { mm / 25.4 }
    static func inches(fromCM cm: Double) -> Double { cm / 2.54 }
    static func inches(fromM m: Double) -> Double { m * 100 / 2.54 }
    static func cm(fromInches inches: Double) -> Double { inches * 2.54 }
    static func feet(fromM m: Double) -> Double { m / 0.3048 }
    static func meters(fromFeet feet: Double) -> Double { feet * 0.3048 }
    static func miles(fromM m: Double) -> Double { m / 1609.344 }
    static func fahrenheit(fromC celsius: Double) -> Double { celsius * 9 / 5 + 32 }
    static func celsius(fromF fahrenheit: Double) -> Double { (fahrenheit - 32) * 5 / 9 }
    static func mph(fromKMH kmh: Double) -> Double { kmh / 1.609344 }
    static func kmh(fromMPH mph: Double) -> Double { mph * 1.609344 }
}

/// Piecewise linear lookup through `points` (sorted by x), flat beyond the ends. For rules of
/// thumb given as a few breakpoints, such as snow quality by temperature.
enum Piecewise {
    static func linear(_ x: Double, _ points: [(x: Double, y: Double)]) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        let upper = points.firstIndex { $0.x >= x }!
        let (a, b) = (points[upper - 1], points[upper])
        return a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x)
    }
}

/// Checks the unit a source declares for a value. Whenever a source labels its units, the
/// provider checks the label before converting, so a changed unit leaves the value out with a
/// warning instead of showing a wrong number. Sources that do not label units (the BC station
/// CSVs) document their assumed units where they are parsed.
enum UnitCheck {
    /// True when `declared` matches. Otherwise records a warning and returns false.
    static func matches(_ declared: String?, _ expected: String, field: String) -> Bool {
        guard declared != expected else { return true }
        ProviderWarnings.record("\(field) is in \(declared ?? "an undeclared unit"), expected \(expected); left out")
        return false
    }
}
