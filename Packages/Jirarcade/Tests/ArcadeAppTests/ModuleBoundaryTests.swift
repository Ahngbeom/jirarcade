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
    // 타입이 문맥에서 추론되는 `.init(red:)`, 인자가 줄바꿈으로 포맷된 경우를 모두
    // 놓친다(M8). `\s`가 개행도 포함하므로 정규식 하나로 이 변형들을 함께 잡는다.
    // `.init(red:` 쪽은 `Color(red:`/`Color.init(red:` 안의 `.init(red:`도 다시 잡지만,
    // 중복 매치는 해가 없다 — 이미 다른 규칙에도 걸릴 문자열을 한 번 더 확인할 뿐이다.
    // 색 공간 인자를 `.sRGB`/`.sRGBLinear`로 열거하면 `.displayP3`가 빠진다. 목록을
    // 늘리는 대신 "점 하나로 시작하는 아무 케이스"로 일반화해, 앞으로 추가될 색 공간도
    // 자동으로 걸리게 한다.
    let colorRedConstructor = /Color\s*\(\s*(\.\w+\s*,\s*)?red\s*:/
    let initRedConstructor = /\.init\s*\(\s*(\.\w+\s*,\s*)?red\s*:/

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

/// 토큰이 만료되면 재발급 페이지로 **그 자리에서** 갈 수 있어야 한다.
///
/// 같은 링크가 로그인 화면에도 있지만 거기 닿으려면 먼저 로그아웃해야 한다.
/// 만료는 사용자가 고를 수 있는 상황이 아니라 반드시 거쳐야 하는 길목이므로,
/// 그 길목에 링크가 없으면 재설정이 한 단계 길어진다.
///
/// ArcadeUI에는 테스트 타깃이 없어 뷰 배선은 소스 텍스트로 지킨다
/// (같은 파일의 색 리터럴 검사와 같은 방식이다).
@Test func theExpiredBannerLinksToTokenReissue() throws {
    let file = sourcesDirectory()
        .appendingPathComponent("ArcadeUI")
        .appendingPathComponent("RootView.swift")
    let text = try String(contentsOf: file, encoding: .utf8)

    let marker = "private var expiredBanner"
    let start = try #require(text.range(of: marker),
                             "expiredBanner를 찾지 못했다 — 이름이 바뀌었나?")
    // 배너 선언부터 다음 멤버 선언 전까지가 검사 범위다. 파일 어딘가에 링크가
    // 있기만 해서는 안 되고 **이 배너 안에** 있어야 한다.
    let rest = text[start.upperBound...]
    let end = rest.range(of: "\n    private ")?.lowerBound ?? rest.endIndex
    let banner = String(rest[..<end])

    #expect(banner.contains("AtlassianLinks.apiTokens"),
            "만료 배너에 토큰 재발급 링크가 없다 — 사용자가 로그아웃해야만 그 링크를 만난다")
}

/// 토큰 발급 URL은 한곳에서만 정의한다.
///
/// 로그인 화면과 만료 배너가 같은 곳을 가리켜야 하는데, 각자 리터럴을 들고 있으면
/// 한쪽만 고쳤을 때 사용자가 어느 경로로 왔느냐에 따라 다른 페이지에 도착한다.
@Test func theTokenPageURLIsDefinedInExactlyOnePlace() throws {
    let files = swiftFiles(in: sourcesDirectory())
    #expect(!files.isEmpty)

    let needle = "manage-profile/security/api-tokens"
    var holders: [String] = []
    for file in files where try String(contentsOf: file, encoding: .utf8).contains(needle) {
        holders.append(file.lastPathComponent)
    }

    #expect(holders == ["AtlassianLinks.swift"],
            "토큰 URL이 여러 곳에 있다: \(holders.sorted())")
}

/// 보드는 시트가 아니라 전체 화면으로 열려야 한다. 매일 여러 번 여는 화면이고
/// 시트 최소 폭(`LayoutTokens.SizeToken.sheetMinWidth`)으로는 레인 네 개와 축이
/// 들어가지 않는다.
@Test func theQuestBoardOpensFullScreen() throws {
    let file = sourcesDirectory()
        .appendingPathComponent("ArcadeUI")
        .appendingPathComponent("QuestBoard")
        .appendingPathComponent("QuestBoardCabinet.swift")
    let text = try String(contentsOf: file, encoding: .utf8)

    #expect(text.contains("var presentation: CabinetPresentation { .fullScreen }"),
            "퀘스트 보드가 전체 화면으로 열리지 않는다")
}

/// 티켓 URL도 토큰 페이지와 같은 규칙을 받는다 — 한곳에서만 만든다.
/// 카드와 실패 안내가 각자 문자열을 조립하면 한쪽만 고쳤을 때 다른 곳이 깨진다.
@Test func theIssueURLIsBuiltInExactlyOnePlace() throws {
    let files = swiftFiles(in: sourcesDirectory())
    #expect(!files.isEmpty)

    let needle = "/browse/"
    var holders: [String] = []
    for file in files where try String(contentsOf: file, encoding: .utf8).contains(needle) {
        holders.append(file.lastPathComponent)
    }

    #expect(holders == ["AtlassianLinks.swift"],
            "티켓 URL이 여러 곳에서 조립된다: \(holders.sorted())")
}

/// 매핑되지 않은 티켓을 보드가 반드시 보여준다. 어느 레인에도 들어가지 못하므로
/// 화면이 따로 다루지 않으면 조용히 사라지고, 사용자는 티켓이 없어졌다고 생각한다.
@Test func theBoardSurfacesUnmappedIssues() throws {
    let file = sourcesDirectory()
        .appendingPathComponent("ArcadeUI")
        .appendingPathComponent("QuestBoard")
        .appendingPathComponent("QuestBoardView.swift")
    let text = try String(contentsOf: file, encoding: .utf8)

    #expect(text.contains("unmappedIssues"),
            "보드가 BoardSnapshot.unmappedIssues를 읽지 않는다 — 티켓이 조용히 사라진다")
}

/// 매핑 마법사로 가는 길이 보드 안에 있어야 한다. 설정을 거치게 하면 사용자가
/// 문제를 본 자리에서 고칠 수 없다.
@Test func theUnmappedLaneLinksToTheMappingWizard() throws {
    let file = sourcesDirectory()
        .appendingPathComponent("ArcadeUI")
        .appendingPathComponent("QuestBoard")
        .appendingPathComponent("UnmappedLaneView.swift")
    let text = try String(contentsOf: file, encoding: .utf8)

    #expect(text.contains("reopenMapping"),
            "매핑되지 않은 레인에 마법사로 가는 길이 없다")
}

/// 활자 크기는 `ArcadeMetrics`를 통해서만 정한다.
///
/// 색 리터럴 검사와 같은 이유다: 하드코딩된 pt 값은 **좁은 창에서만** 맞다.
/// 하나라도 남으면 넓은 화면에서 그 자리만 작게 남는데, 그건 눈으로 훑어서는
/// 잡히지 않는다(개편 전 이 저장소에 9~13pt가 40군데 넘게 흩어져 있었다).
///
/// `ArcadeMetrics.swift`는 토큰을 `Font`로 바꾸는 유일한 곳이라 예외다.
@Test func viewsUseTheTypeScaleRatherThanHardcodedFontSizes() throws {
    let files = swiftFiles(in: sourcesDirectory().appendingPathComponent("ArcadeUI"))
    #expect(!files.isEmpty)

    // `.system(size:`는 명시적 pt, `.font(`는 `.callout`/`.caption` 같은 시스템
    // 스타일까지 잡는다. 후자도 밀도를 모르므로 넓은 화면에서 함께 자라지 않는다.
    let bannedSizing = /\.system\s*\(\s*size\s*:/
    let bannedFontModifier = /\.font\s*\(/

    for file in files where file.lastPathComponent != "ArcadeMetrics.swift" {
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains(bannedSizing),
                "\(file.lastPathComponent)에 하드코딩된 폰트 크기가 있다 — 넓은 화면에서 그 자리만 작게 남는다")
        #expect(!text.contains(bannedFontModifier),
                "\(file.lastPathComponent)이 .font()를 직접 쓴다 — arcadeType(_:_:)로 밀도를 반영해야 한다")
    }
}

/// 시트는 환경을 물려받지 않는다. 테마만 다시 주입하고 밀도를 빠뜨리면 시트 안쪽만
/// 최소 밀도(compact)로 떨어져, 같은 라벨이 본문과 시트에서 다른 크기로 보인다.
@Test func everySheetReinjectsBothTheThemeAndTheMetrics() throws {
    let files = swiftFiles(in: sourcesDirectory().appendingPathComponent("ArcadeUI"))
    #expect(!files.isEmpty)

    var checked = 0
    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        guard text.contains(".sheet(") else { continue }
        checked += 1
        #expect(text.contains("environment(\\.arcadeTheme"),
                "\(file.lastPathComponent)의 시트가 테마를 다시 주입하지 않는다")
        #expect(text.contains("environment(\\.arcadeMetrics"),
                "\(file.lastPathComponent)의 시트가 밀도를 다시 주입하지 않는다")
    }
    #expect(checked > 0, "시트를 쓰는 파일을 하나도 못 찾았다 — 검사가 무의미해졌다")
}

/// 만료 배너에서 **로그아웃하지 않고** 토큰만 갱신할 수 있어야 한다.
///
/// 로그아웃은 자격증명 항목을 통째로 지우므로(`CredentialStore.clear`) 사이트 주소와
/// 이메일까지 함께 사라진다 — 바뀐 것은 토큰 하나뿐인데 셋을 다시 입력하게 된다.
/// 갱신 경로가 사라지면 그 막다른 길로 되돌아간다.
@Test func theExpiredBannerOffersTokenRenewalWithoutSigningOut() throws {
    let file = sourcesDirectory()
        .appendingPathComponent("ArcadeUI")
        .appendingPathComponent("RootView.swift")
    let text = try String(contentsOf: file, encoding: .utf8)

    let marker = "private var expiredBanner"
    let start = try #require(text.range(of: marker),
                             "expiredBanner를 찾지 못했다 — 이름이 바뀌었나?")
    let rest = text[start.upperBound...]
    let end = rest.range(of: "\n    private ")?.lowerBound ?? rest.endIndex
    let banner = String(rest[..<end])

    #expect(banner.contains("TokenRenewalView"),
            "만료 배너에서 토큰 갱신 시트를 열 수 없다 — 로그아웃이 유일한 출구로 돌아간다")
}

/// 로그인 화면은 기억한 연결을 읽어 '토큰만 갱신' 모드로 떠야 한다.
/// 이 배선이 끊기면 Keychain 항목이 유실된 사용자가 빈 폼을 다시 만난다.
@Test func theSignInScreenReadsTheRememberedConnection() throws {
    let file = sourcesDirectory()
        .appendingPathComponent("ArcadeUI")
        .appendingPathComponent("SignInView.swift")
    let text = try String(contentsOf: file, encoding: .utf8)

    #expect(text.contains("model.signInHint"),
            "로그인 화면이 기억한 연결을 읽지 않는다 — 유실 시 빈 폼으로 돌아간다")
    #expect(text.contains("forgetAccount"),
            "'다른 계정으로 연결'이 없으면 기억한 연결에서 빠져나올 길이 없다")
}

/// 제품 이름을 화면에서 직접 쓰지 않는다.
///
/// 이름은 두 단어가 한 글자를 겹쳐 만들어졌고, 워드마크는 그 경첩 글자만 강조색으로
/// 칠해 그 사실을 보여준다(`ArcadeCore.Wordmark`). 어느 뷰든 이름을 문자열로 직접
/// 쓰는 순간 경첩 강조가 빠진 두 번째 워드마크가 생겨, 같은 이름이 화면마다 다르게
/// 보인다. 조립하는 곳은 `JirarcadeWordmark.swift` 하나여야 한다
/// (색 리터럴 검사가 `ArcadeTheme.swift`를 예외로 두는 것과 같은 방식이다).
@Test func noViewSpellsTheProductNameItself() throws {
    let files = swiftFiles(in: sourcesDirectory().appendingPathComponent("ArcadeUI"))
    #expect(!files.isEmpty)

    var holders: [String] = []
    for file in files where file.lastPathComponent != "JirarcadeWordmark.swift" {
        if try String(contentsOf: file, encoding: .utf8).contains("JIRARCADE") {
            holders.append(file.lastPathComponent)
        }
    }
    #expect(holders.isEmpty,
            "제품 이름을 직접 쓰는 뷰가 있다: \(holders.sorted()) — JirarcadeWordmark를 쓸 것")
}

/// 워드마크는 플로어 간판과 로그인 화면 **두 곳**에 뜬다.
///
/// 로그인 화면에서 빠지면 사용자가 이 앱에서 처음 보는 화면에만 워드마크가 없고,
/// 플로어에서 빠지면 매일 여는 화면에 제품 이름이 없다.
@Test func theWordmarkAppearsOnBothTheFloorAndTheSignInScreen() throws {
    for name in ["ArcadeFloorView.swift", "SignInView.swift"] {
        let file = sourcesDirectory().appendingPathComponent("ArcadeUI").appendingPathComponent(name)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("JirarcadeWordmark"), "\(name)에 워드마크가 없다")
    }
}

/// 아이콘 생성기도 색을 팔레트에서만 받는다.
///
/// `ArcadeUI`에 거는 것과 같은 규칙이다. 아이콘은 눈으로만 확인할 수 있는 산출물이라
/// 어긋남이 더 오래 숨는다 — hex를 하나 박아 두면 팔레트를 고쳐도 Dock의 아이콘만
/// 옛 색으로 남고, 누군가 앱을 열어보기 전까지 아무도 모른다.
@Test func theIconForgeTakesItsColorsFromThePaletteOnly() throws {
    let files = swiftFiles(in: sourcesDirectory().appendingPathComponent("IconForge"))
    #expect(!files.isEmpty, "IconForge 소스를 찾지 못했다 — 경로가 바뀌었나?")

    let hexLiteral = /#[0-9A-Fa-f]{6}\b/
    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains(hexLiteral),
                "\(file.lastPathComponent)에 하드코딩된 hex 색상이 있다 — PaletteTokens를 거칠 것")
        #expect(text.contains("PaletteTokens"),
                "\(file.lastPathComponent)이 팔레트를 읽지 않는다")
    }
}

/// 아이콘의 글자도 `Wordmark`에서 온다.
///
/// `"A"`를 직접 쓰면 이름이 바뀌었을 때 아이콘만 옛 글자를 들고 남는다.
/// 워드마크 조각이 이름을 이룬다는 것은 `WordmarkTests`가 이미 지키고 있다.
@Test func theIconLetterComesFromTheWordmark() throws {
    let file = sourcesDirectory()
        .appendingPathComponent("IconForge")
        .appendingPathComponent("IconForge.swift")
    let text = try String(contentsOf: file, encoding: .utf8)

    #expect(text.contains("Wordmark.hinge"),
            "아이콘이 경첩 글자를 직접 적고 있다 — Wordmark.hinge를 쓸 것")
}

/// 코드 주석은 설계문서의 **절 번호**를 인용하지 않는다.
///
/// 주석과 커밋 메시지는 수명이 다르다. 주석은 코드만 열어 본 사람에게 "왜 이 모양인가"를
/// 말해야 하고, 그 문장은 코드가 그대로인 한 참이어야 한다. 절 번호는 **코드를 아무도
/// 건드리지 않아도** 문서 개편만으로 거짓이 된다 — 그리고 거짓이 된 것을 아무도
/// 알아채지 못한다. 확인 비용을 줄이라고 붙인 참조가 오히려 늘리는 셈이다.
///
/// 인용 대신 그 절이 말하는 **이유**를 적는다. 문서 참조가 꼭 필요하면 커밋 메시지에
/// 남긴다 — 커밋은 시점의 기록이라 낡아도 거짓이 되지 않는다.
///
/// 한 번 정리했다가 다시 쌓인 적이 있어(30316ab가 새로 들어온 참조를 뺐지만 그 이전
/// 것들은 남았다) 사람의 기억이 아니라 이 시험이 지킨다.
@Test func codeCommentsDoNotCiteDesignDocSections() throws {
    let files = swiftFiles(in: sourcesDirectory())
    #expect(!files.isEmpty, "Sources를 찾지 못했다 — 경로가 바뀌었나?")

    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
        where line.contains("§") {
            Issue.record("""
                \(file.lastPathComponent):\(offset + 1)이 설계문서 절 번호를 인용한다 \
                — 절 번호 대신 그 절이 말하는 이유를 적는다.
                    \(line.trimmingCharacters(in: .whitespaces))
                """)
        }
    }
}

/// 저장소 루트(`Packages/Jirarcade/`의 두 단계 위).
private func repositoryRoot() -> URL {
    packageRoot().deletingLastPathComponent().deletingLastPathComponent()
}

private func markdownFiles() -> [URL] {
    let docs = repositoryRoot().appendingPathComponent("docs")
    guard let e = FileManager.default.enumerator(at: docs, includingPropertiesForKeys: nil)
    else { return [] }
    var files = e.compactMap { $0 as? URL }.filter { $0.pathExtension == "md" }
    files.append(repositoryRoot().appendingPathComponent("README.md"))
    return files
}

/// 문서에도 조직 특정 정보를 넣지 않는다.
///
/// 코드·테스트에만 걸려 있던 경계를 `docs/`까지 넓힌다. 문서는 실제 Jira를 쓰며 만들어져
/// 실제 티켓 키와 사이트가 자연스럽게 흘러들고, 이 저장소는 공개돼 있다.
///
/// **금지 목록이 아니라 허용 목록으로 쓴다** — 금지할 이름을 적어 두면 이 파일 자체가
/// 조직명을 저장소에 남긴다. `onlyTheExampleJiraSiteAppearsAnywhere`가 같은 이유로 같은
/// 모양을 쓴다.
///
/// 상태명과 실측 수치는 여기서 못 막는다. 유효한 상태명은 열거할 수 없고, 어떤 수치가
/// 조직을 드러내는지는 문맥이 정한다 — 그 둘은 README의 규칙과 리뷰가 지킨다.
@Test func documentsUseOnlyPlaceholderIdentifiers() throws {
    let files = markdownFiles()
    #expect(!files.isEmpty, "docs 아래에서 .md 파일을 하나도 못 찾았다 — 경로가 깨졌다는 뜻이다")

    let jiraHost = /[a-z0-9][a-z0-9.-]*\.atlassian\.net/
    let issueKey = /\b([A-Z][A-Z0-9]{1,9})-[0-9]{1,6}\b/
    // 우리 예시 키와, 문서가 실제로 인용하는 **공개** 트래커·표준의 키만 허용한다.
    // 앞의 것은 이 저장소가 지어낸 이름이고, 뒤의 것들은 누구나 열람하는 외부 자료다.
    let allowedKeyPrefixes: Set<String> = [
        "DEMO",      // 이 저장소의 예시 프로젝트
        "SE",        // Swift Evolution 제안
        "ECO",       // Atlassian 생태계 공개 트래커
        "OAUTH20",   // Atlassian OAuth 공개 트래커
        "UTF",       // 문자 인코딩
    ]

    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)

        for match in text.lowercased().matches(of: jiraHost) {
            #expect(String(match.output) == "example.atlassian.net",
                    "\(file.lastPathComponent)에 예시가 아닌 Jira 사이트가 있다: \(match.output)")
        }

        for match in text.matches(of: issueKey) {
            let prefix = String(match.output.1)
            #expect(allowedKeyPrefixes.contains(prefix), """
                \(file.lastPathComponent)에 예시가 아닌 티켓 키가 있다: \(match.output.0) \
                — 번호가 가짜여도 접두사가 조직을 가리킨다. DEMO-를 쓴다
                """)
        }
    }
}
