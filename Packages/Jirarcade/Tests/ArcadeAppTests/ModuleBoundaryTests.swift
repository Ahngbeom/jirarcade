import Testing
import Foundation

/// 이 파일에서 패키지 루트(`Packages/Jirarcade/`)까지 올라간다.
/// .../Tests/ArcadeAppTests/ModuleBoundaryTests.swift 에서 세 번 올라가야 루트다.
private func packageRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ArcadeAppTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Jirarcade  ← 패키지 루트
}

private func sourcesDirectory() -> URL {
    packageRoot().appendingPathComponent("Sources")
}

private func testsDirectory() -> URL {
    packageRoot().appendingPathComponent("Tests")
}

private func swiftFiles(in directory: URL) -> [URL] {
    guard let e = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
    else { return [] }
    return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
}

@Test func arcadeAppNeverImportsSwiftUI() throws {
    let files = swiftFiles(in: sourcesDirectory().appendingPathComponent("ArcadeApp"))
    #expect(!files.isEmpty, "ArcadeApp 소스를 찾지 못했다 — 경로가 바뀌었나?")

    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("import SwiftUI"),
                "\(file.lastPathComponent)이 SwiftUI를 import한다 — 이 모듈은 화면을 몰라야 한다")
    }
}

@Test func viewsUseThemeTokensRatherThanColorLiterals() throws {
    let files = swiftFiles(in: sourcesDirectory().appendingPathComponent("ArcadeUI"))
    #expect(!files.isEmpty)

    // ArcadeTheme.swift는 팔레트를 Color로 바꾸는 유일한 곳이므로 예외다.
    let literals = ["Color.red", "Color.blue", "Color.green", "Color.black",
                    "Color.white", "Color.gray", "Color.orange", "Color.yellow"]

    for file in files where file.lastPathComponent != "ArcadeTheme.swift" {
        let text = try String(contentsOf: file, encoding: .utf8)
        for literal in literals {
            #expect(!text.contains(literal),
                    "\(file.lastPathComponent)에 \(literal)이 있다 — 반대 테마에서 깨진다")
        }
    }
}

@Test func onlyTheExampleJiraSiteAppearsAnywhere() throws {
    // 금지할 조직명을 목록으로 들고 있으면 이 파일 자체가 그 이름을 리포지토리에 남긴다.
    // 그래서 "무엇이 금지인가" 대신 "무엇만 허용인가"로 뒤집는다 —
    // 예시 사이트 외의 Jira 호스트가 보이면 실패한다. 미래의 다른 조직명도 이 방식이면 걸린다.
    let jiraHost = /[a-z0-9][a-z0-9.-]*\.atlassian\.net/
    let allowed = "example.atlassian.net"

    for directory in [sourcesDirectory(), testsDirectory()] {
        for file in swiftFiles(in: directory) {
            let text = try String(contentsOf: file, encoding: .utf8).lowercased()
            for match in text.matches(of: jiraHost) {
                #expect(String(match.output) == allowed,
                        "\(file.lastPathComponent)에 예시가 아닌 Jira 사이트가 있다: \(match.output)")
            }
        }
    }
}
