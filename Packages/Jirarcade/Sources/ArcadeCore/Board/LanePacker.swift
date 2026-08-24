import Foundation

/// 축 위에서 겹치는 슬롯을 수직으로 쌓는다.
///
/// `public`이 아닌 이유: 이 계산은 `BoardLayout`이 쓰는 부품이고 바깥에서 직접 부를
/// 일이 없다. 테스트는 `@testable import`로 닿는다.
enum LanePacker {
    /// 들어갈 수 있는 **가장 낮은** 줄에 넣는다. 늘 새 줄을 만들면 레인이 필요 이상으로
    /// 높아지고, 늘 마지막 줄만 보면 앞줄의 빈자리가 영영 안 쓰인다.
    ///
    /// - Parameter minimumSpacing: 같은 줄에 놓이기 위한 최소 간격(축 대비 비율).
    ///   0이면 전부 한 줄에 놓인다.
    static func pack(_ slots: [BoardSlot], minimumSpacing: Double) -> [BoardSlot] {
        // 동률 타이브레이크가 필요한 이유: Swift의 `sorted(by:)`는 안정 정렬이 아니므로,
        // 같은 정체일 티켓 두 건의 상하 순서가 실행마다 뒤집힌다. 데이터는 틀어지지
        // 않지만 화면이 매 렌더마다 흔들리고 테스트가 비결정적이 된다.
        let ordered = slots.sorted {
            $0.position == $1.position
                ? $0.issue.key < $1.issue.key
                : $0.position < $1.position
        }

        // rowEnd[i] = i번 줄에 마지막으로 놓인 슬롯의 position.
        // ordered가 오름차순이므로 새 슬롯은 항상 그 값보다 크거나 같다.
        var rowEnd: [Double] = []
        var packed: [BoardSlot] = []
        packed.reserveCapacity(ordered.count)

        for slot in ordered {
            let row = rowEnd.firstIndex { slot.position - $0 >= minimumSpacing } ?? rowEnd.count
            if row == rowEnd.count {
                rowEnd.append(slot.position)
            } else {
                rowEnd[row] = slot.position
            }
            packed.append(slot.withRow(row))
        }
        return packed
    }
}

extension BoardSlot {
    /// `row`만 바꾼 사본. `BoardSlot`이 `let`뿐이므로 packing이 값을 다시 만든다.
    func withRow(_ row: Int) -> BoardSlot {
        BoardSlot(
            issue: issue, daysStagnant: daysStagnant, tier: tier,
            position: position, row: row,
            isApproximate: isApproximate, dueState: dueState,
            sprintCarryOvers: sprintCarryOvers,
            firstSprintName: firstSprintName, latestSprintName: latestSprintName
        )
    }
}
