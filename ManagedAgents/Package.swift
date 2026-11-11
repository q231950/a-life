// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ManagedAgents",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ManagedAgents", targets: ["ManagedAgents"]),
    ],
    targets: [
        .target(name: "ManagedAgents"),
        .testTarget(name: "ManagedAgentsTests", dependencies: ["ManagedAgents"]),
    ]
)
