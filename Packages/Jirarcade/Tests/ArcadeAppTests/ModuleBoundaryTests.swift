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
    // "Color.xxx" 형태뿐 아니라, 습관적으로 손이 가는 시스템 색(.primary/.secondary)과
    // 토큰을 우회해 임의 색을 만드는 생성자(Color(nsColor:)/#colorLiteral)도 잡는다.
    let literals = ["Color.red", "Color.blue", "Color.green", "Color.black",
                    "Color.white", "Color.gray", "Color.orange", "Color.yellow",
                    ".primary", ".secondary",
                    "Color(nsColor:",
                    "#colorLiteral"]
    // 하드코딩된 hex 색상 문자열("#RRGGBB"). 팔레트의 hex는 ArcadeCore의 PaletteTokens에만
    // 있어야 하고, ArcadeUI는 ArcadeTheme.swift를 거쳐 Color로만 받아야 한다.
    let hexLiteral = /#[0-9A-Fa-f]{6}\b/
    // `"Color(red:"` 문자열 검사는 `Color(.sRGB, red: ...)`, `Color.init(red:)`,
    // 타입이 문맥에서 추론되는 `.init(red:)`, 인자가 줄바꿈으로 포맀된 경우를 모두
    // 놓친다(M8). `\s`가 개행도 포함하므로 정규식 하나로 이 변형들을 함께 잡는다.
    // `.init(red:` 쪽은 `Color(red:`/`Color.init(red:` 안의 `.init(red:`도 다시 잡지만,
    // 중복 매치는 해가 없다 — 이미 다른 규칙에도 걸릴 문자열을 한 번 더 확인할 뿐이다.
    let colorRedConstructor = /Color\s*\(\s*(\.sRGB(Linear)?\s*,\s*)?red\s*:/
    let initRedConstructor = /\.init\s*\(\s*(\.sRGB(Linear)?\s*,\s*)?red\s*:/

    for file in files where file.lastPathComponent != "ArcadeTheme.swift" {
        let text = try String(contentsOf: file, encoding: .utf8)
        for literal in literals {
            #expect(!text.contains(literal),
                    "\(file.lastPathComponent)에 \(literal)이 있다 — 반대 테마에서 깨진다")
        }
        #expect(!text.contains(hexLiteral),
                "\(file.lastPathComponent)에 하드코딩된 hex 색상이 있다 — 반대 테마에서 깨진다")
        #expect(!text.contains(colorRedConstructor),
                "\(file.lastPathComponent)에 Color(red:) 계열 생성자가 있다 — 반대 테마에서 깨진다")
        #expect(!text.contains(initRedConstructor),
                "\(file.lastPathComponent)에 .init(red:) 계열 생성자가 있다 — 반대 테마에서 깨진다")
    }
}

@Test func onlyTheExampleJiraSiteAppearsAnywhere() throws {
    // 금지할 조직명을 목록으로 들고 있으면 이 파일 자체가 그 이름을 리포지토리에 남긴다.
    // 그래서 "무엇이 금지인가" 대신 "무엇만 허용인가"로 뒤집는다 —
    // 예시 사이트 외의 Jira 호스트가 보이면 실패한다. 미래의 다른 조직명도 이 방식이면 걸린다.
    let jiraHost = /[a-z0-9][a-z0-9.-]*\.atlassian\.net/
    let allowed = "example.atlassian.net"

    let directories: [(name: String, url: URL)] = [
        ("Sources", sourcesDirectory()),
        ("Tests", testsDirectory()),
    ]

    for (name, directory) in directories {
        let files = swiftFiles(in: directory)
        // 이 assert가 없으면 경로가 깨져 빈 목록이 나올 때 아래 루프가 0번 돌고도
        // 조용히 통과한다 — "조직명이 없다"가 아니라 "파일을 못 찾았다"를 구분해야 한다.
        #expect(!files.isEmpty, "\(name) 아래에서 .swift 파일을 하나도 못 찾았다 — 경로가 깨졌다는 뜻이다")

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8).lowercased()
            for match in text.matches(of: jiraHost) {
                #expect(String(match.output) == allowed,
                        "\(file.lastPathComponent)에 예시가 아닌 Jira 사이트가 있다: \(match.output)")
            }
        }
    }
}
