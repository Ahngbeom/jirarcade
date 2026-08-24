import Testing
import Foundation
@testable import ArcadeCore

private let now = iso("2026-08-21T00:00:00Z")

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

/// `active` 하나에 상태 셋이 접히는 워크플로. 계층 줌이 풀어야 할 상황이며,
/// 실측한 조직에서 배포 파이프라인이 정확히 이 모양이었다(스펙 §1).
private let layeredWorkflow = WorkflowMap(statusToStage: [
    "To Do": .backlog,
    "Dev": .active,
    "Staging": .active,
    "Production": .active,
    "Verifying": .verify,
    "Done": .done,
])

private func snapshot(
    _ issues: [ObservedIssue],
    enteredAt: [String: Date] = [:],
    workflow: WorkflowMap = layeredWorkflow,
    zoom: Double = 1.0,
    rules: RuleSet = .default
) -> OrbitSnapshot {
    OrbitLayout.snapshot(
        issues: issues, statusEnteredAt: enteredAt, workflow: workflow,
        rules: rules, zoomProgress: zoom, now: now, calendar: utc
    )
}

private func system(_ result: OrbitSnapshot, _ statusName: String) -> OrbitSystem? {
    result.systems.first { $0.statusName == statusName }
}

// MARK: - 태양이 되는 것과 되지 않는 것

/// 상태 하나가 태양 하나다. 같은 `Stage`로 접히던 셋이 각자의 태양을 갖는다 —
/// 이것이 보드가 못 하는 일이고 이 화면이 존재하는 이유다.
@Test func makesOneSystemPerStatusNotPerStage() {
    let result = snapshot([
        issue(key: "DEMO-1", status: "Dev"),
        issue(key: "DEMO-2", status: "Staging"),
        issue(key: "DEMO-3", status: "Production"),
    ])

    #expect(result.systems.map(\.statusName) == ["Dev", "Production", "Staging"])
    #expect(result.systems.allSatisfy { $0.stage == .active })
}

/// 티켓이 없는 상태에는 태양이 없다. `BoardLayout`이 `done` 레인을 뺀 것과 같은
/// 이유다 — 영구히 빈 태양 열넷은 뭔가 들어와야 하는데 비어 있다는 잘못된 신호다.
@Test func skipsStatusesThatHaveNoIssues() {
    let result = snapshot([issue(key: "DEMO-1", status: "Dev")])

    #expect(result.systems.map(\.statusName) == ["Dev"])
}

/// 완료 상태의 티켓이 미러에 남아 있어도 태양이 생기지 않는다.
///
/// `BoardLayoutTests.dropsIssuesInTheDoneStage`와 이름이 같으면 모듈 전역
/// 네임스페이스에서 충돌한다(Swift Testing의 자유 함수는 파일로 나뉘지 않는다) —
/// `InOrbit` 접미사로 이 파일에서만 이름을 바꿨다.
@Test func dropsIssuesInTheDoneStageInOrbit() {
    let result = snapshot([issue(key: "DEMO-1", status: "Done")])

    #expect(result.systems.isEmpty)
    #expect(result.drifters.isEmpty)
}

/// 매핑되지 않은 상태의 티켓은 떠돌이가 된다. 그냥 버리면 화면에서 조용히 사라지고
/// 사용자는 티켓이 없어졌다고 생각한다.
@Test func sendsUnmappedIssuesToTheDriftRing() {
    let result = snapshot([
        issue(key: "DEMO-9", status: "Blocked"),
        issue(key: "DEMO-1", status: "Dev"),
    ])

    #expect(result.drifters.map(\.issue.key) == ["DEMO-9"])
    #expect(result.systems.map(\.statusName) == ["Dev"])
}

@Test func putsDriftersOnTheOutermostRing() {
    let result = snapshot([issue(key: "DEMO-9", status: "Blocked")])

    // 이 입력에는 매핑된 상태가 하나도 없어 `maxStatusCount`가 0이다.
    #expect(result.drifters.first?.radius == OrbitLayout.driftOrbit(maxStatusCount: 0))
}

// MARK: - 계층 줌

/// 줌아웃하면 같은 `Stage`의 태양들이 한 점으로 모인다. 태양이 사라지는 것이
/// 아니라 겹치는 것이다 — 그래서 줌 경계에서 화면이 갈아엎히지 않는다.
@Test func collapsesSystemsOfOneStageToASinglePointWhenZoomedOut() {
    let result = snapshot([
        issue(key: "DEMO-1", status: "Dev"),
        issue(key: "DEMO-2", status: "Staging"),
        issue(key: "DEMO-3", status: "Production"),
    ], zoom: 0)

    let centers = result.systems.map(\.center)
    #expect(centers.allSatisfy { $0 == OrbitLayout.stageCenter(.active, spacing: result.stageSpacing) })
}

/// 줌인하면 갈라진다. 갈라진 태양들은 서로 궤도가 닿지 않을 만큼 떨어져야 한다.
@Test func spreadsSystemsApartWhenZoomedIn() {
    let result = snapshot([
        issue(key: "DEMO-1", status: "Dev"),
        issue(key: "DEMO-2", status: "Staging"),
        issue(key: "DEMO-3", status: "Production"),
    ], zoom: 1)

    for outer in result.systems {
        for inner in result.systems where inner.statusName != outer.statusName {
            let dx = outer.center.x - inner.center.x
            let dy = outer.center.y - inner.center.y
            #expect((dx * dx + dy * dy).squareRoot() > 2.0,
                    "\(outer.statusName)과 \(inner.statusName)의 궤도가 닿는다")
        }
    }
}

/// 이웃한 `Stage`의 성계끼리 닿으면 안 된다. 성계 하나의 외곽 반경은
/// 태양 오프셋 + 궤도 최대 1.0이므로 중심 간 거리가 그 두 배를 넘어야 한다.
@Test func keepsNeighbouringStagesFromOverlapping() {
    for count in 1...10 {
        let spacing = OrbitLayout.stageSpacing(maxStatusCount: count)
        let backlog = OrbitLayout.stageCenter(.backlog, spacing: spacing)
        let active = OrbitLayout.stageCenter(.active, spacing: spacing)
        let dx = backlog.x - active.x
        let dy = backlog.y - active.y
        #expect((dx * dx + dy * dy).squareRoot()
                > 2 * OrbitLayout.systemExtent(count: count),
                "상태 \(count)개에서 이웃 Stage의 성계가 닿는다")
    }
}

/// 혼자인 상태는 줌과 무관하게 `Stage` 중심에 있다. 갈라질 상대가 없는데
/// 옆으로 밀려나면 줌할 때 이유 없이 흔들린다.
@Test func leavesALoneSystemAtItsStageCentre() {
    let result = snapshot([issue(key: "DEMO-1", status: "To Do")], zoom: 1)

    #expect(system(result, "To Do")?.center
            == OrbitLayout.stageCenter(.backlog, spacing: result.stageSpacing))
}

@Test func clampsZoomProgressToTheUnitRange() {
    #expect(snapshot([], zoom: -3).zoomProgress == 0)
    #expect(snapshot([], zoom: 9).zoomProgress == 1)
}

// MARK: - 반경은 보드 축과 같은 말을 한다

/// 궤도 반경은 보드 가로축과 **같은 함수**에서 온다. 다른 함수를 쓰면 두 화면이
/// 같은 티켓을 두고 서로 다른 말을 하게 된다.
@Test func derivesRadiusFromTheSameAxisTheBoardUses() {
    let entered = now.addingTimeInterval(-days(21))
    let result = snapshot([issue(key: "DEMO-1", status: "Dev")],
                          enteredAt: ["DEMO-1": entered])

    let expected = OrbitLayout.minimumRadius
        + (1 - OrbitLayout.minimumRadius) * BoardAxis.position(forDays: 21, rules: .default)
    #expect(abs((system(result, "Dev")?.planets.first?.radius ?? 0) - expected) < 1e-9)
}

/// 갓 들어온 티켓도 태양 중심에 박히지 않는다.
@Test func keepsFreshIssuesOffTheStarItself() {
    let result = snapshot([issue(key: "DEMO-1", status: "Dev",
                                 updated: now)])

    #expect(system(result, "Dev")?.planets.first?.radius == OrbitLayout.minimumRadius)
}

/// `RuleSet`은 설정 화면에서 JSON으로 편집할 수 있어 역전된 값이 올 수 있다.
/// `BoardAxis`가 이미 그것을 막고 있으므로 반경도 범위를 벗어나지 않아야 한다.
@Test func keepsRadiusInsideTheOrbitEvenWithInvertedRules() {
    var broken = RuleSet.default
    broken.staleDays = 90
    broken.bossDays = 2
    broken.raidDays = 1

    let result = snapshot([
        issue(key: "DEMO-1", status: "Dev", updated: now.addingTimeInterval(-days(500))),
        issue(key: "DEMO-2", status: "Dev", updated: now),
    ], rules: broken)

    for planet in system(result, "Dev")?.planets ?? [] {
        #expect(planet.radius >= OrbitLayout.minimumRadius)
        #expect(planet.radius <= 1.0 + OrbitLayout.planetArc * 2)
    }
}

/// 동심원은 보드 축의 눈금과 같은 값이다.
@Test func drawsRingsAtTheAxisTicks() {
    let result = snapshot([])

    #expect(result.rings.map(\.days) == BoardAxis.ticks(rules: .default).map(\.days))
    #expect(result.rings.last?.isTerminal == true)
    #expect(result.rings.first?.radius == OrbitLayout.minimumRadius)
}

// MARK: - 자리가 흔들리지 않는다

/// 동기화는 5분마다 돈다. 그때마다 배치가 바뀌면 어제 눈여겨본 티켓을 오늘 찾을 수 없다.
@Test func producesTheSameLayoutForTheSameInput() {
    let issues = (1...6).map { issue(key: "DEMO-\($0)", status: "Dev") }

    #expect(snapshot(issues) == snapshot(issues))
}

/// 입력 순서는 미러 딕셔너리 순회에서 오므로 불안정하다.
@Test func ignoresTheOrderIssuesArriveIn() {
    let issues = (1...6).map { issue(key: "DEMO-\($0)", status: "Dev") }

    #expect(snapshot(issues) == snapshot(issues.reversed()))
}

/// 티켓 하나가 완료돼 미러에서 빠져도 나머지는 제자리에 있어야 한다.
/// 인덱스 기반 균등 배분이었다면 여기서 전부 밀린다.
@Test func keepsOtherPlanetsStillWhenOneIssueDisappears() {
    let issues = (1...6).map { issue(key: "DEMO-\($0)", status: "Dev") }
    let before = snapshot(issues)
    let after = snapshot(issues.filter { $0.key != "DEMO-3" })

    for planet in system(after, "Dev")?.planets ?? [] {
        let old = system(before, "Dev")?.planets.first { $0.id == planet.id }
        #expect(old?.angle == planet.angle, "\(planet.id)의 각도가 움직였다")
        #expect(old?.radius == planet.radius, "\(planet.id)의 반경이 움직였다")
    }
}

/// 같은 상태에 같은 정체일 티켓이 몰려도 서로 가리지 않는다.
@Test func keepsCrowdedPlanetsFromOverlapping() {
    let crowd = (1...12).map { issue(key: "DEMO-\($0)", status: "Dev", updated: now) }
    let planets = system(snapshot(crowd), "Dev")?.planets ?? []

    #expect(planets.count == 12)
    for outer in planets {
        for inner in planets where inner.id != outer.id {
            let sameRing = abs(outer.radius - inner.radius) < OrbitLayout.planetArc
            let needed = OrbitPacker.minimumAngle(radius: max(outer.radius, inner.radius),
                                                  planetArc: OrbitLayout.planetArc)
            let apart = OrbitGeometry.angularDistance(outer.angle, inner.angle) >= needed
            #expect(!sameRing || apart, "\(outer.id)와 \(inner.id)가 겹친다")
        }
    }
}

// MARK: - 행성이 나르는 사실

@Test func carriesTheFactsTheCardNeeds() {
    let due = now.addingTimeInterval(days(2))
    let issues = [ObservedIssue(
        key: "DEMO-1", summary: "샘플", statusName: "Dev", issueType: "개선",
        priority: "Highest", assigneeAccountId: "acc-me", assigneeName: "bahn",
        dueDate: due, jiraUpdatedAt: now.addingTimeInterval(-days(30)),
        sprintCarryOvers: 4, firstSprintName: "DEMO 스프린트 (1)",
        latestSprintName: "DEMO 스프린트 (5)"
    )]
    let planet = system(snapshot(issues), "Dev")?.planets.first

    #expect(planet?.daysStagnant == 30)
    #expect(planet?.tier == .boss)
    #expect(planet?.dueState == .dueIn(days: 2))
    #expect(planet?.sizeFactor == OrbitGeometry.sizeFactor(forPriority: "Highest"))
    #expect(planet?.sprintCarryOvers == 4)
    #expect(planet?.firstSprintName == "DEMO 스프린트 (1)")
    #expect(planet?.isApproximate == true)
}

/// 관측 이력이 있으면 근사가 아니다. 보드 카드가 `~`를 붙이는 기준과 같아야 한다.
@Test func marksPlanetsAsExactWhenObservationHistoryExists() {
    let result = snapshot([issue(key: "DEMO-1", status: "Dev")],
                          enteredAt: ["DEMO-1": now.addingTimeInterval(-days(3))])

    #expect(system(result, "Dev")?.planets.first?.isApproximate == false)
}

// MARK: - 형제 성계가 겹치지 않는다 (수정 라운드 1 회귀 가드)

/// n=5부터 겹치기 시작하던 결함의 회귀 가드. 실측 조직의 active에는 상태가
/// 여덟 개 있으므로 이 구간이 이 화면의 정상 동작 범위다.
@Test func keepsSiblingSystemsApartAtEveryStatusCount() {
    for count in 2...12 {
        let orbit = OrbitLayout.statusOrbit(count: count)
        let neighbourDistance = 2 * orbit * sin(.pi / Double(count))
        #expect(neighbourDistance >= 2.0,
                "상태 \(count)개에서 이웃 태양이 \(neighbourDistance) 떨어져 궤도가 겹친다")
    }
}

/// 한 Stage에 여덟 상태가 접힌 실물 형태. 스펙 §1이 적은 그 조직의 active다.
@Test func spreadsEightStatusesOfOneStageWithoutOverlap() {
    let statuses = ["S1", "S2", "S3", "S4", "S5", "S6", "S7", "S8"]
    let crowded = WorkflowMap(statusToStage: Dictionary(
        uniqueKeysWithValues: statuses.map { ($0, Stage.active) }
    ))
    let result = snapshot(
        statuses.enumerated().map { issue(key: "DEMO-\($0.offset)", status: $0.element) },
        workflow: crowded, zoom: 1
    )

    #expect(result.systems.count == 8)
    for outer in result.systems {
        for inner in result.systems where inner.statusName != outer.statusName {
            let dx = outer.center.x - inner.center.x
            let dy = outer.center.y - inner.center.y
            #expect((dx * dx + dy * dy).squareRoot() >= 2.0,
                    "\(outer.statusName)과 \(inner.statusName)의 궤도가 겹친다")
        }
    }
}

/// 혼자인 상태는 여전히 Stage 중심에 있다 — 동적 반경이 그 성질을 깨지 않아야 한다.
@Test func stillLeavesALoneSystemAtItsStageCentre() {
    #expect(OrbitLayout.statusOrbit(count: 1) == 0)
}
