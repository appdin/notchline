// swift-tools-version: 6.0

import PackageDescription

// NotchlineCore built for Android, without the Mac app targets in the root package. The core and
// its tests are symlinks into the root package, so both platforms build the same sources.
let package = Package(
    name: "NotchlineAndroid",
    products: [
        .library(name: "NotchlineJNI", type: .dynamic, targets: ["NotchlineJNI"]),
    ],
    targets: [
        .target(
            name: "NotchlineCore",
            resources: [.copy("Resources/locations.json"), .copy("Resources/confidence.json")]
        ),
        .target(name: "CJNI"),
        .target(
            name: "NotchlineJNI",
            dependencies: ["NotchlineCore", "CJNI"],
            // A static FoundationNetworking brings in curl but not the TLS libraries curl needs.
            linkerSettings: [
                .linkedLibrary("ssl", .when(platforms: [.android])),
                .linkedLibrary("crypto", .when(platforms: [.android])),
                .linkedLibrary("z", .when(platforms: [.android])),
            ]
        ),
        .testTarget(
            name: "NotchlineTests",
            dependencies: ["NotchlineCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
