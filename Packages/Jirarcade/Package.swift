// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Jirarcade",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "JiraKit", targets: ["JiraKit"]),
        .library(name: "ArcadeCore", targets: ["ArcadeCore"]),
        .library(name: "ArcadeApp", targets: ["ArcadeApp"]),
        .library(name: "ArcadeUI", targets: ["ArcadeUI"]),
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
        .target(name: "ArcadeApp", dependencies: ["ArcadeCore", "JiraKit"]),
        .target(name: "ArcadeUI", dependencies: ["ArcadeApp", "ArcadeCore"]),
        .executableTarget(name: "JirarcadeApp", dependencies: ["ArcadeUI", "ArcadeApp", "ArcadeCore", "JiraKit"]),
        .testTarget(name: "ArcadeAppTests", dependencies: ["ArcadeApp"]),
    ]
)
