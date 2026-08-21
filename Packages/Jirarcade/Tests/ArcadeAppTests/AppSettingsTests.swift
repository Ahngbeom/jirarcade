import Testing
import Foundation
@testable import ArcadeApp

@Test func defaultSettingsMatchSpec() {
    let s = AppSettings.default
    #expect(s.syncInterval == .seconds(300))          // 5분
    #expect(s.foregroundCooldown == .seconds(30))
    #expect(s.failuresBeforeSurfacing == 3)
    #expect(s.backoffSteps == [.seconds(5), .seconds(30), .seconds(120), .seconds(600)])
}

@Test func backoffClampsToTheLastStep() {
    let s = AppSettings.default
    #expect(s.backoffDelay(afterConsecutiveFailures: 1) == .seconds(5))
    #expect(s.backoffDelay(afterConsecutiveFailures: 4) == .seconds(600))
    #expect(s.backoffDelay(afterConsecutiveFailures: 99) == .seconds(600), "상한에 머문다")
}

@Test func zeroFailuresMeansNoBackoff() {
    #expect(AppSettings.default.backoffDelay(afterConsecutiveFailures: 0) == .zero)
}
