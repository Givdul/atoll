// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Skerry",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Skerry", targets: ["Skerry"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")
    ],
    targets: [
        .target(
            name: "SkerryCore",
            path: "Sources/SkerryCore"
        ),
        .executableTarget(
            name: "Skerry",
            dependencies: [
                "SkerryCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Skerry",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "SkerryCoreTests",
            dependencies: ["SkerryCore"],
            path: "Tests/SkerryCoreTests"
        )
    ]
)
