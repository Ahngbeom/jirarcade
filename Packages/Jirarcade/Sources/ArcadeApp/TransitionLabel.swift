import Foundation
import JiraKit

public extension JiraTransition {
    /// 전이 메뉴에 보일 이름. **도착 상태가 전이 이름과 다르면 둘 다 보여준다.**
    ///
    /// Jira의 전이 이름(`name`)은 관리자가 붙인 **동작** 이름이고 도착 상태(`toStatusName`)는
    /// 그 **결과**다. 둘은 같을 수도 있고 전혀 다를 수도 있다 — 실물 워크플로에서 "검토 중"이라는
    /// 이름의 전이가 티켓을 "STAG 반영" 상태로 보내는 경우를 만났다.
    ///
    /// 전이 이름만 보여주면 사용자가 고른 것("검토 중")과 대기 배너에 뜨는 것("→ STAG 반영")이
    /// 어긋나 보이고, 무엇보다 **고르기 전에 어디로 가는지 알 수 없다.**
    ///
    /// 같을 때 한 번만 적는 이유: 대부분의 전이는 이름과 도착 상태가 같고, 그때 "완료 → 완료"는
    /// 읽는 사람에게 아무것도 더해주지 않으면서 목록만 어지럽힌다.
    var menuLabel: String {
        name == toStatusName ? name : "\(name) → \(toStatusName)"
    }
}
