import AppKit

/// The standard About panel, with the data sources credited and linked in the credits.
@MainActor
enum AboutPanel {
    private static let sources: [(name: String, url: String, note: String)] = [
        ("National Weather Service", "https://www.weather.gov", "US forecasts"),
        ("USDA NRCS SNOTEL", "https://www.nrcs.usda.gov/wps/portal/wcc/home/", "US snow and temperature stations"),
        ("avalanche.org", "https://avalanche.org", "US avalanche forecasts"),
        ("Northwest Avalanche Center", "https://nwac.us", "Washington avalanche forecasts"),
        ("Avalanche Canada", "https://avalanche.ca", "BC avalanche forecasts"),
        ("Open-Meteo", "https://open-meteo.com", "BC forecasts, modeled snow depth and the US fallback"),
        ("BC Ministry of Environment", "https://www2.gov.bc.ca/gov/content/environment/air-land-water/water/water-science-data/water-data-tools/snow-survey-data", "BC snow weather stations"),
    ]

    private static let donations: [(name: String, url: String)] = [
        ("NWAC", "https://nwac.us/donate/"),
        ("Avalanche Canada", "https://avalanche.ca/donate"),
    ]

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits()])
    }

    private static func credits() -> NSAttributedString {
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let bold: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
        ]
        let text = NSMutableAttributedString()
        func append(_ string: String, _ attributes: [NSAttributedString.Key: Any] = body) {
            text.append(NSAttributedString(string: string, attributes: attributes))
        }
        func link(_ name: String, _ url: String) {
            var attributes = body
            attributes[.link] = URL(string: url)
            text.append(NSAttributedString(string: name, attributes: attributes))
        }

        append("Data from\n", bold)
        for source in sources {
            link(source.name, source.url)
            append(": \(source.note)\n")
        }
        append("\nNWAC and Avalanche Canada are nonprofits funded partly by donations. Donate to ")
        for (index, donation) in donations.enumerated() {
            if index > 0 { append(" or ") }
            link(donation.name, donation.url)
        }
        append(".\n\n")
        append("Avalanche danger here is a summary only. Read the full forecast before going into avalanche terrain.", bold)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        return text
    }
}
