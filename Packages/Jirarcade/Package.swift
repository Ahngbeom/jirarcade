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
            // 테스트가 `import JiraKit`을 하므로 명시적으로 건다. ArcadeCore를 통한
            // 전이 의존으로도 지금은 빌드되지만, ArcadeCore가 JiraKit을 떼는 순간
            // 이 타깃 전체가 한꺼번에 깨진다.
            dependencies: ["ArcadeCore", "JiraKit"],
            resources: [.process("Fixtures")]
        ),
        .target(name: "ArcadeApp", dependencies: ["ArcadeCore", "JiraKit"]),
        .target(name: "ArcadeUI", dependencies: ["ArcadeApp", "ArcadeCore"]),
        // 앱 아이콘을 그린다. `ArcadeCore`만 의존한다 — 아이콘은 팔레트와 기하의
        // 순수 함수여야 하고, 앱 상태나 화면을 알 이유가 없다.
        .executableTarget(name: "IconForge", dependencies: ["ArcadeCore"]),
        .executableTarget(name: "JirarcadeApp", dependencies: ["ArcadeUI", "ArcadeApp", "ArcadeCore", "JiraKit"]),
        // 같은 이유로 ArcadeCore와 JiraKit을 명시한다 — 테스트 파일들이 둘 다 직접 import한다.
        .testTarget(name: "ArcadeAppTests", dependencies: ["ArcadeApp", "ArcadeCore", "JiraKit"]),
    ]
)
