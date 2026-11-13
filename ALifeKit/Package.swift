// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ALifeKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        // The wire format shared by the server and its clients.
        .library(name: "ALifeAPI", targets: ["ALifeAPI"]),
        // What a front end uses to talk to an a-life-server.
        .library(name: "ALifeClient", targets: ["ALifeClient"]),
    ],
    targets: [
        .target(name: "ALifeAPI"),
        .target(name: "ALifeClient", dependencies: ["ALifeAPI"]),
        .testTarget(name: "ALifeKitTests", dependencies: ["ALifeAPI", "ALifeClient"]),
    ]
)
