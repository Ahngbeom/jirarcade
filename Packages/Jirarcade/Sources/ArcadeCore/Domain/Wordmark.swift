import Foundation

/// 제품 이름과, 그것을 화면에 그릴 때 쓰는 분해.
///
/// 이 이름은 두 단어를 이어 붙인 것이 아니라 **겹쳐** 만든 것이다. 앞 단어는 네 글자,
/// 뒤 단어는 여섯 글자인데 전체는 아홉 글자다 — 4 + 6 − 1. 가운데 한 글자를 두 단어가
/// 공유한다. 그 글자만 강조색으로 칠하면 한 단어 안에서 두 단어가 보인다.
///
/// 조각을 여기 두는 이유는 `PaletteTokens`·`LayoutTokens`와 같다: 판단(어디서 끊는가)은
/// 테스트가 있는 모듈에 두고 `ArcadeUI`는 색을 입히기만 한다. 뷰에서 문자열을 직접
/// 끊으면 그 전제가 맞는지 확인할 방법이 없다.
public enum Wordmark {
    public static let full = "JIRARCADE"

    /// 앞 단어에서 공유 글자를 뺀 부분.
    public static let head = "JIR"
    /// 앞 단어의 끝이자 뒤 단어의 시작인 글자. 이 한 글자만 강조색으로 칠한다.
    public static let hinge = "A"
    /// 뒤 단어에서 공유 글자를 뺀 부분.
    public static let tail = "RCADE"
}
