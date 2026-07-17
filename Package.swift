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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")
    ],
    targets: [
        .target(
            name: "AtollCore",
            path: "Sources/AtollCore"
        ),
        .executableTarget(
            name: "Atoll",
            dependencies: [
                "AtollCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
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
