// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Notchline",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Notchline", targets: ["Notchline"]),
        .executable(name: "notchline-fetch", targets: ["notchline-fetch"]),
        .library(name: "NotchlineCore", targets: ["NotchlineCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/MrKai77/DynamicNotchKit", exact: "1.1.0"),
    ],
    targets: [
        .target(
            name: "NotchlineCore",
            resources: [.copy("Resources/locations.json")]
        ),
        .executableTarget(
            name: "Notchline",
            dependencies: [
                "NotchlineCore",
                .product(name: "DynamicNotchKit", package: "DynamicNotchKit"),
            ]
        ),
        .executableTarget(
            name: "notchline-fetch",
            dependencies: ["NotchlineCore"]
        ),
        .testTarget(
            name: "NotchlineTests",
            dependencies: ["NotchlineCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
