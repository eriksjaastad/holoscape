import XCTest
@testable import Holoscape

final class ChannelRecoveryActionTests: XCTestCase {
    func testBrokerHostRecoveryGuidancePreservesSessionInsteadOfSpawningReplacement() {
        let guidance = ChannelRecoveryAction.retryBrokerHost.operatorGuidance

        XCTAssertTrue(guidance.contains("Broker host is unavailable"), guidance)
        XCTAssertTrue(guidance.contains("preserved the broker session ID"), guidance)
        XCTAssertTrue(guidance.contains("will not spawn a replacement"), guidance)
    }

    func testStaleBrokerSessionRecoveryGuidanceNamesReplacementPersistence() {
        let guidance = ChannelRecoveryAction.recreateBrokerSession.operatorGuidance

        XCTAssertTrue(guidance.contains("stale or missing"), guidance)
        XCTAssertTrue(guidance.contains("replacement process"), guidance)
        XCTAssertTrue(guidance.contains("persists the new broker session ID"), guidance)
    }
}
