// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PasteBin",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(
            name: "PasteBin",
            targets: ["PasteBin"]
        )
    ],
    targets: [
        .executableTarget(
            name: "PasteBin",
            path: "Sources",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
