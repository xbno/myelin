import Foundation
import Testing
@testable import recorder

/// The system channel is never the local user (their voice arrives on the mic
/// channel), so a platform hint naming them must not label remote speech.
@Suite struct MeetHintsTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func hints(localUser: String?) -> MeetHints {
        let h = MeetHints()
        h.localUserName = localUser
        return h
    }

    @Test func hintNamingTheLocalUserIsDropped() {
        let h = hints(localUser: "Geoff Counihan")
        h.record(names: ["Geoff Counihan"], at: t0)
        h.record(names: [], at: t0.addingTimeInterval(2))
        #expect(h.query(w0: t0, w1: t0.addingTimeInterval(2)) == nil)
    }

    @Test func localUserMatchIgnoresCase() {
        let h = hints(localUser: "Geoff Counihan")
        h.record(names: ["geoff counihan"], at: t0)
        h.record(names: [], at: t0.addingTimeInterval(2))
        #expect(h.query(w0: t0, w1: t0.addingTimeInterval(2)) == nil)
    }

    @Test func remoteNameStillApplies() {
        let h = hints(localUser: "Geoff Counihan")
        h.record(names: ["Alice"], at: t0)
        h.record(names: [], at: t0.addingTimeInterval(2))
        #expect(h.query(w0: t0, w1: t0.addingTimeInterval(2)) == "Alice")
    }

    @Test func mixedHintKeepsTheRemoteName() {
        let h = hints(localUser: "Geoff Counihan")
        h.record(names: ["Geoff Counihan", "Alice"], at: t0)
        h.record(names: [], at: t0.addingTimeInterval(2))
        #expect(h.query(w0: t0, w1: t0.addingTimeInterval(2)) == "Alice")
    }
}
