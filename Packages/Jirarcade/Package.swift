// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Jirarcade",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "JiraKit", targets: ["JiraKit"]),
        .library(name: "ArcadeCore", targets: ["ArcadeCore"]),
    ],
    targets: [
        .target(name: "JiraKit"),
        .target(name: "ArcadeCore", dependencies: ["JiraKit"]),
        .testTarget(name: "JiraKitTests", dependencies: ["JiraKit"]),
        .testTarget(
            name: "ArcadeCoreTests",
            dependencies: ["ArcadeCore"],
            resources: [.process("Fixtures")]
        ),
    ]
)
