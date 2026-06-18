// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Atoll",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Atoll", targets: ["Atoll"]),
        .library(name: "AtollCore", targets: ["AtollCore"])
    ],
    targets: [
        .target(
            name: "AtollCore",
            path: "Sources/AtollCore"
        ),
        .executableTarget(
            name: "Atoll",
            dependencies: ["AtollCore"],
            path: "Sources/Atoll",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "AtollScan",
            dependencies: ["AtollCore"],
            path: "Sources/AtollScan"
        ),
        .testTarget(
            name: "AtollCoreTests",
            dependencies: ["AtollCore"],
            path: "Tests/AtollCoreTests"
        )
    ]
)
