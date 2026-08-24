import Foundation

/// 태양 하나를 도는 티켓.
///
/// `BoardSlot`과 나르는 사실이 겹치지만 합치지 않는다. 저쪽은 `position`·`row`라는
/// **직교 좌표**를 갖고 이쪽은 `radius`·`angle`이라는 **극좌표**를 갖는다. 하나로 묶으면
/// 두 좌표계가 한 타입에 섞이고, 어느 필드가 유효한지를 타입이 말해 주지 않는다.
public struct OrbitPlanet: Sendable, Equatable, Identifiable {
    public var id: String { issue.key }

    public let issue: ObservedIssue
    /// 클램프 전 **실제** 정체일. 반경은 접혀도 카드는 이 값을 그대로 적는다.
    public let daysStagnant: Int
    public let tier: StagnationTier
    /// 소속 태양 중심 기준 반경. 떠돌이는 원점 기준이다.
    public let radius: Double
    /// 라디안. `[0, 2π)`.
    public let angle: Double
    /// 행성 지름 배율. 우선순위에서 온다.
    public let sizeFactor: Double
    /// 관측 이력이 없어 `jiraUpdatedAt`으로 폴백했다.
    public let isApproximate: Bool
    public let dueState: DueState
    /// 표시 전용이며 채점에 쓰지 않는다.
    public let sprintCarryOvers: Int
    public let firstSprintName: String?
    public let latestSprintName: String?
}

/// 상태 하나 = 태양 하나.
public struct OrbitSystem: Sendable, Equatable, Identifiable {
    public var id: String { statusName }

    public let statusName: String
    public let stage: Stage
    /// `zoomProgress`가 이미 반영된 논리 좌표.
    public let center: OrbitPoint
    public let planets: [OrbitPlanet]
}

/// 등급 경계를 나타내는 동심원. 보드 축의 눈금(`AxisTick`)이 원이 된 것이다.
public struct OrbitRing: Sendable, Equatable {
    public let days: Int
    public let radius: Double
    /// 마지막 원인가. 그 너머가 접혀 있으므로 화면은 "45d+"처럼 적는다.
    public let isTerminal: Bool
}

public struct OrbitSnapshot: Sendable, Equatable {
    public let systems: [OrbitSystem]
    /// 어느 태양에도 속하지 못한 티켓. 성계 전체를 감싸는 바깥 고리를 떠돈다.
    public let drifters: [OrbitPlanet]
    public let rings: [OrbitRing]
    /// 0이면 `Stage` 넷으로 뭉쳐 보이고 1이면 상태별로 갈라진다.
    public let zoomProgress: Double
}

/// 미러와 워크플로를 궤도 좌표로 옮긴다. 순수 함수이며 화면을 모른다.
///
/// pt도 픽셀도 줌 배율도 제스처도 모른다 — 돌려주는 것은 **논리 좌표**이고
/// 1.0이 궤도 최대 반경이다. 픽셀로 옮기는 일은 `OrbitMetrics`가 한다.
public enum OrbitLayout {
    /// 정체 0일 티켓이 태양 중심에 박히지 않게 하는 하한.
    ///
    /// 하필 0.15인 이유: 그보다 작으면 갓 들어온 티켓 여럿이 좁은 원에 몰려
    /// `OrbitPacker`가 곧바로 반경을 밀어내기 시작한다.
    public static let minimumRadius = 0.15

    /// `Stage` 중심 사이의 거리.
    ///
    /// 줌인했을 때 한 성계가 차지하는 외곽 반경은 `statusOrbit`(1.5) + 궤도 최대(1.0)
    /// = 2.5다. 이웃한 두 성계가 닿지 않으려면 중심 간 거리가 5.0을 넘어야 하고,
    /// 여유 1.0을 더해 6.0으로 잡는다. **비교 대상은 궤도 반경이 아니라 성계의 외곽
    /// 반경이다** — 이걸 혼동하면 줌인에서 이웃 `Stage`의 행성끼리 겹친다.
    public static let stageSpacing = 6.0

    /// 상태 태양이 소속 `Stage` 중심에서 떨어지는 거리(줌 100% 기준).
    public static let statusOrbit = 1.5

    /// 떠돌이 고리의 반경. `Stage` 중심의 대각 거리(3√2 ≈ 4.24)에 외곽 반경 2.5를
    /// 더한 6.74보다 바깥이어야 성계 위를 지나가지 않는다.
    public static let driftOrbit = 8.0

    /// 행성 하나가 차지하는 호 길이(논리 단위). **줌과 무관한 상수다** —
    /// 줌에 따라 달라지면 확대할 때마다 배치가 다시 계산돼 행성이 미끄러진다.
    public static let planetArc = 0.12

    /// `Stage` 넷의 2×2 배치. 순서는 `BoardLayout.visibleStages`와 같아서
    /// 레인에서 궤도로 전환할 때 위아래 순서가 유지된다.
    public static func stageCenter(_ stage: Stage) -> OrbitPoint {
        let half = stageSpacing / 2
        return switch stage {
        case .backlog: OrbitPoint(x: -half, y: -half)
        case .active:  OrbitPoint(x:  half, y: -half)
        case .review:  OrbitPoint(x: -half, y:  half)
        case .verify:  OrbitPoint(x:  half, y:  half)
        // 보드와 같이 `done`은 그리지 않는다. 여기 닿는 경로는 없지만
        // 열거형이 늘어날 때 컴파일러가 알려주도록 케이스를 남긴다.
        case .done:    OrbitPoint(x: 0, y: 0)
        }
    }

    /// 정체일을 궤도 반경으로 옮긴다.
    ///
    /// **보드 축과 같은 함수를 쓴다.** 다른 함수를 쓰면 두 화면이 같은 티켓을 두고
    /// 서로 다른 말을 하고, 설정에서 `RuleSet`을 고쳤을 때 한쪽만 움직인다.
    /// 덤으로 구간별 선형 성질을 그대로 얻는다 — 단순 선형이면 0–7일 구간이 축의
    /// 15%에 불과해 대부분의 티켓이 태양에 달라붙는데, 안쪽일수록 원 둘레가 짧아
    /// 원에서는 그 문제가 더 심하다.
    public static func radius(forDays days: Int, rules: RuleSet) -> Double {
        minimumRadius + (1 - minimumRadius) * BoardAxis.position(forDays: days, rules: rules)
    }

    public static func snapshot(
        issues: [ObservedIssue],
        statusEnteredAt: [String: Date],
        workflow: WorkflowMap,
        rules: RuleSet,
        zoomProgress: Double,
        now: Date,
        calendar: Calendar
    ) -> OrbitSnapshot {
        let zoom = min(max(zoomProgress, 0), 1)
        let classifier = StagnationClassifier(rules: rules)

        func makePlanet(_ issue: ObservedIssue, seat: OrbitSeat) -> OrbitPlanet {
            let entered = statusEnteredAt[issue.key]
            return OrbitPlanet(
                issue: issue,
                daysStagnant: classifier.daysStagnant(
                    statusEnteredAt: entered, jiraUpdatedAt: issue.jiraUpdatedAt, now: now
                ),
                tier: classifier.classify(
                    statusEnteredAt: entered, jiraUpdatedAt: issue.jiraUpdatedAt, now: now
                ),
                radius: seat.radius,
                angle: seat.angle,
                sizeFactor: OrbitGeometry.sizeFactor(forPriority: issue.priority),
                isApproximate: classifier.isApproximate(statusEnteredAt: entered),
                dueState: BoardLayout.dueState(for: issue, now: now, calendar: calendar),
                sprintCarryOvers: issue.sprintCarryOvers,
                firstSprintName: issue.firstSprintName,
                latestSprintName: issue.latestSprintName
            )
        }

        var byStatus: [String: [ObservedIssue]] = [:]
        var stageOf: [String: Stage] = [:]
        var unmapped: [ObservedIssue] = []

        for issue in issues {
            guard let stage = workflow.stage(for: issue.statusName) else {
                unmapped.append(issue)
                continue
            }
            guard BoardLayout.visibleStages.contains(stage) else { continue }
            byStatus[issue.statusName, default: []].append(issue)
            stageOf[issue.statusName] = stage
        }

        // 상태명 오름차순으로 태양을 늘어놓는다. 딕셔너리 순회 순서를 쓰면
        // 같은 데이터가 실행마다 다른 배치를 낳는다.
        var systems: [OrbitSystem] = []
        for stage in BoardLayout.visibleStages {
            let names = byStatus.keys.filter { stageOf[$0] == stage }.sorted()
            for (index, name) in names.enumerated() {
                let center = statusCentre(
                    stage: stage, index: index, count: names.count, zoom: zoom
                )
                let seats = OrbitPacker.pack(
                    (byStatus[name] ?? []).map { issue in
                        OrbitSeat(
                            key: issue.key,
                            radius: radius(
                                forDays: classifier.daysStagnant(
                                    statusEnteredAt: statusEnteredAt[issue.key],
                                    jiraUpdatedAt: issue.jiraUpdatedAt, now: now
                                ),
                                rules: rules
                            ),
                            angle: OrbitGeometry.angle(forKey: issue.key)
                        )
                    },
                    planetArc: planetArc
                )
                let bySeatKey = Dictionary(
                    uniqueKeysWithValues: (byStatus[name] ?? []).map { ($0.key, $0) }
                )
                systems.append(OrbitSystem(
                    statusName: name,
                    stage: stage,
                    center: center,
                    planets: seats.compactMap { seat in
                        bySeatKey[seat.key].map { makePlanet($0, seat: seat) }
                    }
                ))
            }
        }

        let driftSeats = OrbitPacker.pack(
            unmapped.map {
                OrbitSeat(key: $0.key, radius: driftOrbit,
                          angle: OrbitGeometry.angle(forKey: $0.key))
            },
            planetArc: planetArc
        )
        let driftByKey = Dictionary(uniqueKeysWithValues: unmapped.map { ($0.key, $0) })

        return OrbitSnapshot(
            systems: systems,
            drifters: driftSeats.compactMap { seat in
                driftByKey[seat.key].map { makePlanet($0, seat: seat) }
            },
            rings: BoardAxis.ticks(rules: rules).map {
                OrbitRing(days: $0.days,
                          radius: minimumRadius + (1 - minimumRadius) * $0.position,
                          isTerminal: $0.isTerminal)
            },
            zoomProgress: zoom
        )
    }

    /// 상태 태양 하나의 자리. 줌아웃할수록 소속 `Stage` 중심으로 수렴한다.
    ///
    /// 혼자면 오프셋이 0이다 — 갈라질 상대가 없는데 옆으로 밀려나면 줌할 때
    /// 이유 없이 흔들린다.
    private static func statusCentre(
        stage: Stage, index: Int, count: Int, zoom: Double
    ) -> OrbitPoint {
        let base = stageCenter(stage)
        guard count > 1 else { return base }
        let angle = 2 * Double.pi * Double(index) / Double(count)
        return OrbitPoint(
            x: base.x + statusOrbit * cos(angle) * zoom,
            y: base.y + statusOrbit * sin(angle) * zoom
        )
    }
}
