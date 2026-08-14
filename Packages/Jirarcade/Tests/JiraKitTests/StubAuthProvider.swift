import Foundation
@testable import JiraKit

/// 401 복구 배선을 테스트하기 위한 스텁. `recoverFromUnauthorized` 호출 횟수를 센다.
final class StubAuthProvider: AuthProvider, @unchecked Sendable {
    let baseURL: URL
    private let recovers: Bool
    private var recoverCallCount = 0
    private let lock = NSLock()

    init(
        baseURL: URL = URL(string: "https://example.atlassian.net/rest/api/3")!,
        recovers: Bool
    ) {
        self.baseURL = baseURL
        self.recovers = recovers
    }

    var recoveryCallCount: Int { lock.withLock { recoverCallCount } }

    func authorize(_ request: inout URLRequest) async throws {
        request.setValue("Bearer stub-token", forHTTPHeaderField: "Authorization")
    }

    func recoverFromUnauthorized() async throws -> Bool {
        lock.withLock { recoverCallCount += 1 }
        return recovers
    }
}
