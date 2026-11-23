import Foundation
import Testing
@testable import PaceCore

@Test func antigravityReadsGeminiWindowsFromUsageCommand() throws {
    let output = #"{"conversation_id":"","status":"SUCCESS","response":"...","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-weekly","window":"weekly","remaining_fraction":0.75,"reset_time":"2026-11-28T08:50:12Z"},{"id":"gemini-5h","window":"5h","remaining_fraction":0,"reset_time":"2026-11-23T19:30:57Z"}]},{"name":"Claude and GPT models","buckets":[{"id":"3p-weekly","remaining_fraction":1,"reset_time":"2026-11-30T17:30:53Z"}]}]}}}"#
    let now = Date(timeIntervalSince1970: 100)
    let snap = try AntigravityProvider.parse(Data(output.utf8), fetchedAt: now, plan: "Google AI Ultra")
    #expect(snap.weekly?.percent == 25)
    #expect(snap.weekly?.resetsAt == (try Date("2026-11-28T08:50:12Z", strategy: .iso8601)))
    #expect(snap.session?.locked == true)
    #expect(snap.session?.percent == 100)
    #expect(snap.fetchedAt == now)
    #expect(snap.plan == "Google AI Ultra")
    #expect(snap.models.first?.modelName == "Claude/GPT")
    #expect(snap.models.first?.percent == 0)
    #expect(snap.meters.count == 3)
}

@Test func antigravityRejectsFailedUsageCommand() {
    #expect(throws: ProviderError.self) {
        try AntigravityProvider.parse(Data(#"{"status":"ERROR","response":"boom"}"#.utf8), fetchedAt: Date())
    }
    #expect(throws: ProviderError.self) {
        try AntigravityProvider.parse(Data("not json".utf8), fetchedAt: Date())
    }
}
