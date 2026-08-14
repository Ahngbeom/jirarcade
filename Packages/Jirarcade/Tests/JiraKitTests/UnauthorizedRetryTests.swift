import Testing
import Foundation
@testable import JiraKit

/// 스펙 §8.3: 401을 만나면 `AuthProvider.recoverFromUnauthorized()`로 갱신을 시도하고,
/// 성공하면 요청을 정확히 한 번만 재시도한다.
private let userBody = #"{"accountId":"acc-1","displayName":"demo"}"#

@Test func recoveryThenSuccessRetriesExactlyOnce() async throws {
    let stub = StubHTTPClient([
        .init(status: 401, body: Data(), headers: [:]),
        .init(status: 200, body: Data(userBody.utf8), headers: [:]),
    ])
    let auth = StubAuthProvider(recovers: true)
    let client = JiraClient(auth: auth, http: stub)

    let user = try await client.myself()

    #expect(user.accountId == "acc-1")
    #expect(auth.recoveryCallCount == 1)
    #expect(stub.sentRequests.count == 2)
}

/// 갱신이 성공했다고 보고해도 서버가 다시 401을 주면, 재시도는 딱 한 번만 일어나고
/// 그 결과로 던져야 한다 — 잘못 구현된 provider가 무한 재시도를 유발하면 안 된다.
@Test func recoverySucceedsButServerStill401sThrowsAfterExactlyTwoRequests() async {
    let stub = StubHTTPClient([
        .init(status: 401, body: Data(), headers: [:]),
        .init(status: 401, body: Data(), headers: [:]),
    ])
    let auth = StubAuthProvider(recovers: true)
    let client = JiraClient(auth: auth, http: stub)

    await #expect(throws: JiraError.unauthorized) {
        _ = try await client.myself()
    }

    #expect(stub.sentRequests.count == 2, "재시도는 최대 한 번이어야 한다")
}

@Test func recoveryReturningFalseThrowsImmediatelyWithoutRetry() async {
    let stub = StubHTTPClient(status: 401)
    let auth = StubAuthProvider(recovers: false)
    let client = JiraClient(auth: auth, http: stub)

    await #expect(throws: JiraError.unauthorized) {
        _ = try await client.myself()
    }

    #expect(auth.recoveryCallCount == 1)
    #expect(stub.sentRequests.count == 1)
}

@Test(arguments: [403, 500])
func nonUnauthorizedErrorsDoNotTriggerRecovery(status: Int) async {
    let stub = StubHTTPClient(status: status)
    let auth = StubAuthProvider(recovers: true)
    let client = JiraClient(auth: auth, http: stub)

    await #expect(throws: (any Error).self) {
        _ = try await client.myself()
    }

    #expect(auth.recoveryCallCount == 0)
    #expect(stub.sentRequests.count == 1)
}
