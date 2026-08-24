import Testing
@testable import ArcadeCore

/// 세 조각은 이름을 정확히 이룬다. 하나라도 어긋나면 화면에 틀린 철자가 뜬다.
@Test func theWordmarkPiecesSpellTheProductName() {
    #expect(Wordmark.head + Wordmark.hinge + Wordmark.tail == Wordmark.full)
}

/// 경첩 글자가 **정말로** 두 단어가 공유하는 글자인가.
///
/// 이 디자인의 전제다. 강조할 글자를 눈대중으로 골랐다면 앞 단어나 뒤 단어 중 하나가
/// 어긋나고, 그러면 강조는 근거 없는 장식이 된다. 이름이 바뀌면 이 테스트가 먼저 깨져
/// "왜 저 글자만 색이 다른가"를 다시 판단하게 만든다.
@Test func theHingeLetterIsSharedByBothWords() {
    #expect(Wordmark.head + Wordmark.hinge == "JIRA")
    #expect(Wordmark.hinge + Wordmark.tail == "ARCADE")
    // 겹치는 글자가 정확히 하나라는 사실을 길이로도 고정한다.
    #expect("JIRA".count + "ARCADE".count - Wordmark.hinge.count == Wordmark.full.count)
}

/// 경첩은 한 글자다. 여러 글자를 칠하면 두 단어의 경계가 흐려진다.
@Test func theHingeIsASingleLetter() {
    #expect(Wordmark.hinge.count == 1)
}
