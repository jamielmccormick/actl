// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "actl",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "actl-app", targets: ["ActlApp"]),
        .library(name: "ActlCore", targets: ["ActlCore"]),
    ],
    targets: [
        // Engine client, models, stores. No SwiftUI, fully testable.
        .target(name: "ActlCore"),
        // Fictional demo data that follows docs/engine-contract.md exactly.
        .target(name: "ActlFixtures", dependencies: ["ActlCore"], path: "Fixtures", sources: ["Fixtures.swift"], resources: [.copy("json")]),
        .executableTarget(name: "ActlApp", dependencies: ["ActlCore", "ActlFixtures"], resources: [.copy("Resources")]),
        .testTarget(name: "ActlCoreTests", dependencies: ["ActlCore", "ActlFixtures"]),
    ]
)
