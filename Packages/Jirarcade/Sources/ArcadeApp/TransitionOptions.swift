import Foundation
import JiraKit

/// `상태 옮기기` 메뉴가 지금 무엇을 보여줘야 하는가.
///
/// **왜 열거형인가:** 실제 상태는 셋인데(묻는 중 / 답을 받음 / 묻지 못함) 예전에는
/// `[JiraTransition]`과 `Bool` 둘로 그렸다. `try?`가 실패를 빈 배열로 뭉개는 바람에
/// 실패가 "옮길 수 있는 상태가 없습니다" 위로 접혔고, 메뉴가 "이 티켓은 못 옮깁니다"라고
/// 거짓말을 했다 — 진실은 "물어보지 못했습니다"였다. 사용자는 Jira에 가서 확인할 이유조차
/// 받지 못한다.
///
/// 셋을 셋으로 표현하면 접힐 자리가 없다.
public enum TransitionOptions: Sendable, Equatable {
    case loading
    /// 답을 받았다. 비어 있으면 **정말로** 옮길 수 있는 상태가 없다는 뜻이다.
    case ready([JiraTransition])
    /// 묻지 못했다. 문구는 앱이 짓는다 — Jira 응답 본문은 화면에 닿지 않는다.
    case failed(String)
}
