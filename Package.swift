// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kea",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Kea",
            path: "Sources/Kea",
            // Same reasoning as the canvas app next door: the whole interface is
            // main-thread by nature, and Swift 6's strict isolation buys nothing
            // here but ceremony.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "KeaTests",
            dependencies: ["Kea"],
            path: "Tests/KeaTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
