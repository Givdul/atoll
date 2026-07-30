// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Topside",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Topside", targets: ["Topside"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")
    ],
    targets: [
        .target(
            name: "TopsideCore",
            path: "Sources/TopsideCore"
        ),
        .executableTarget(
            name: "Topside",
            dependencies: [
                "TopsideCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Topside",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "TopsideCoreTests",
            dependencies: ["TopsideCore"],
            path: "Tests/TopsideCoreTests"
        )
    ]
)
