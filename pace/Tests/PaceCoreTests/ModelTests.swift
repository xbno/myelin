import Foundation
import Testing
@testable import PaceCore

@Suite struct ModelTests {
    @Test func windowStartIsResetMinusLength() {
        let reset = Date(timeIntervalSince1970: 1_000_000)
        let m = Meter(kind: .session, percent: 10, resetsAt: reset, windowLength: 5 * 3600)
        #expect(m.windowStart == reset.addingTimeInterval(-5 * 3600))
    }

    @Test func snapshotAccessors() {
        let s = UsageSnapshot(fetchedAt: Date(), plan: "Team", meters: [
            Meter(kind: .weekly, percent: 4, resetsAt: nil, windowLength: 7 * 86400),
            Meter(kind: .session, percent: 3, resetsAt: nil, windowLength: 5 * 3600),
            Meter(kind: .weeklyModel(name: "Fable"), percent: 3, resetsAt: nil, windowLength: 7 * 86400),
        ])
        #expect(s.session?.percent == 3)
        #expect(s.weekly?.percent == 4)
        #expect(s.models.map(\.kind) == [.weeklyModel(name: "Fable")])
        #expect(s.models.first?.modelName == "Fable")
        #expect(s.session?.windowStart == nil)
    }
}
