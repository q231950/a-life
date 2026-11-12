// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "a-life-server",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.115.0"),
        // The wire format, shared with the front ends.
        .package(path: "../ALifeKit"),
    ],
    targets: [
        .executableTarget(
            name: "ALifeServer",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "ALifeAPI", package: "ALifeKit"),
            ]
        ),
        .testTarget(
            name: "ALifeServerTests",
            dependencies: [
                "ALifeServer",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "ALifeClient", package: "ALifeKit"),
            ],
            // XCTest's main-actor test classes predate strict concurrency.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
