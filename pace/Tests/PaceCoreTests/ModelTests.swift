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

    @Test func windowsPastTheirResetReadAsNotStarted() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let s = UsageSnapshot(fetchedAt: now.addingTimeInterval(-6 * 86400), plan: nil, meters: [
            Meter(kind: .session, percent: 60, resetsAt: now.addingTimeInterval(-3600), windowLength: 5 * 3600),
            Meter(kind: .weekly, percent: 100, resetsAt: now, windowLength: 7 * 86400, locked: true),
            Meter(kind: .weeklyModel(name: "Fable"), percent: 7, resetsAt: now.addingTimeInterval(60), windowLength: 7 * 86400),
        ]).asOf(now)
        #expect(s.session?.percent == 0)
        #expect(s.session?.resetsAt == nil)
        #expect(s.weekly?.percent == 0)
        #expect(s.weekly?.locked == false)
        // Not reset yet: kept as fetched.
        #expect(s.models.first?.percent == 7)
        #expect(s.models.first?.resetsAt == now.addingTimeInterval(60))
    }
}
