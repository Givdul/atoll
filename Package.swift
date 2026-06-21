// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Atoll",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Atoll", targets: ["Atoll"])
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
        .testTarget(
            name: "AtollCoreTests",
            dependencies: ["AtollCore"],
            path: "Tests/AtollCoreTests"
        )
    ]
)
