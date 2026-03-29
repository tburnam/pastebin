// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PasteBin",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "PasteBin",
            targets: ["PasteBin"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0")
    ],
    targets: [
        .executableTarget(
            name: "PasteBin",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "PasteBinTests",
            dependencies: ["PasteBin"],
            path: "Tests/PasteBinTests"
        )
    ]
)
