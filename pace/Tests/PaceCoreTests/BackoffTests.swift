import Foundation
import Testing
@testable import PaceCore

@Suite struct BackoffTests {
    @Test func doublesFromTheBaseAndCaps() {
        #expect(Backoff.delay(failures: 1, base: 120, cap: 1800) == 120)
        #expect(Backoff.delay(failures: 2, base: 120, cap: 1800) == 240)
        #expect(Backoff.delay(failures: 3, base: 120, cap: 1800) == 480)
        #expect(Backoff.delay(failures: 10, base: 120, cap: 1800) == 1800)
        #expect(Backoff.delay(failures: 0, base: 120, cap: 1800) == 120)
    }

    @Test func retryAfterWinsWhenLonger() {
        #expect(Backoff.delay(failures: 1, base: 120, cap: 1800, retryAfter: 600) == 600)
        #expect(Backoff.delay(failures: 1, base: 120, cap: 1800, retryAfter: 5) == 120)
        #expect(Backoff.delay(failures: 1, base: 120, cap: 1800, retryAfter: 9999) == 1800)
    }
}
