import Foundation
import Testing
@testable import PaceCore

@Suite struct CodexProviderTests {
    func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "codex-ratelimits-windowed", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// A synthetic payload with one weekly window and no session window.
    @Test func parsesWindowedPayload() throws {
        let snap = try CodexProvider.parse(try fixture(), fetchedAt: Date(timeIntervalSince1970: 0))
        #expect(snap.plan == "Pro")
        #expect(snap.meters.count == 2)
        // primary is the weekly window here, not a session one: 10080 minutes.
        #expect(snap.session == nil)
        #expect(snap.weekly?.percent == 40)
        #expect(snap.weekly?.windowLength == 7 * 86400)
        #expect(snap.weekly?.resetsAt == Date(timeIntervalSince1970: 1790026172))
        #expect(snap.weekly?.locked == false)
        // the second bucket becomes a model-style row
        #expect(snap.models.count == 1)
        #expect(snap.models.first?.modelName == "example-reserve")
        #expect(snap.models.first?.percent == 10)
        #expect(snap.models.first?.locked == false)
    }

    /// A business plan: no rolling windows at all, just a credit allowance for the billing
    /// cycle. The cycle is the calendar month ending at `resetsAt` (midnight UTC on the 1st).
    @Test func parsesTheBusinessCreditAllowance() throws {
        let url = try #require(Bundle.module.url(forResource: "codex-ratelimits-allowance",
                                                 withExtension: "json", subdirectory: "Fixtures"))
        let snap = try CodexProvider.parse(try Data(contentsOf: url),
                                           fetchedAt: Date(timeIntervalSince1970: 0))
        #expect(snap.plan == "Business")
        #expect(snap.session == nil)
        #expect(snap.weekly == nil)
        let month = try #require(snap.monthly)
        #expect(abs(month.percent - 25) < 0.0001)
        #expect(month.resetsAt == Date(timeIntervalSince1970: 1790812800))
        #expect(month.windowLength == 30 * 86400)   // September
        #expect(month.note == "250 of 1000 credits")
        #expect(month.locked == false)
        // The allowance repeats under its own limit id; it must not also become a model row.
        #expect(snap.models.isEmpty)
    }

    /// A plan that reports both windows: the short one is the session, the long one the week.
    @Test func classifiesWindowsByDuration() throws {
        let json = """
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":41,"windowDurationMins":300,"resetsAt":1790000000},
         "secondary":{"usedPercent":62,"windowDurationMins":10080,"resetsAt":1790026172},"planType":"pro"}}
        """
        let snap = try CodexProvider.parse(Data(json.utf8), fetchedAt: Date())
        #expect(snap.plan == "Pro")
        #expect(snap.session?.percent == 41)
        #expect(snap.session?.windowLength == 5 * 3600)
        #expect(snap.weekly?.percent == 62)
        #expect(snap.weekly?.windowLength == 7 * 86400)
    }

    /// Two windows of the same length would otherwise both claim the weekly slot.
    @Test func duplicateWindowKindKeepsTheFirst() throws {
        let json = """
        {"rateLimits":{"primary":{"usedPercent":10,"windowDurationMins":10080},
         "secondary":{"usedPercent":90,"windowDurationMins":10080}}}
        """
        let snap = try CodexProvider.parse(Data(json.utf8), fetchedAt: Date())
        #expect(snap.meters.count == 1)
        #expect(snap.weekly?.percent == 10)
    }

    /// `ordinaryUsageAllowed` is account-wide, so it locks the main bucket only — a separate
    /// reserve pool can still be spendable while ordinary usage is blocked.
    @Test func blockedOrdinaryUsageDoesNotLockOtherBuckets() throws {
        let json = """
        {"ordinaryUsageAllowed":false,
         "rateLimits":{"limitId":"codex","primary":{"usedPercent":30,"windowDurationMins":10080}},
         "rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":30,"windowDurationMins":10080}},
          "reserve":{"limitId":"reserve","limitName":"gpt-reserve","primary":{"usedPercent":5,"windowDurationMins":10080}}}}
        """
        let snap = try CodexProvider.parse(Data(json.utf8), fetchedAt: Date())
        #expect(snap.weekly?.locked == true)
        #expect(snap.models.first?.modelName == "gpt-reserve")
        #expect(snap.models.first?.locked == false)
    }

    @Test func bucketNameFallsBackToSlugThenId() throws {
        let json = """
        {"rateLimits":{"limitId":"codex","primary":{"usedPercent":1,"windowDurationMins":10080}},
         "rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":1}},
          "a":{"limitId":"a","normalModelSlug":"gpt-5.6-luna","primary":{"usedPercent":2}},
          "b":{"limitId":"b","primary":{"usedPercent":3}}}}
        """
        let snap = try CodexProvider.parse(Data(json.utf8), fetchedAt: Date())
        #expect(snap.models.map(\.modelName) == ["gpt-5.6-luna", "b"])
    }

    @Test func missingRateLimitsIsABadResponse() throws {
        #expect(throws: ProviderError.badResponse("no rateLimits in response")) {
            _ = try CodexProvider.parse(Data("{}".utf8), fetchedAt: Date())
        }
    }

    @Test func authFailuresReadAsExpiredTokens() {
        #expect(CodexProvider.mapError(["message": "request failed with status 401"]) == .tokenExpired)
        #expect(CodexProvider.mapError(["message": "not logged in"]) == .tokenExpired)
        #expect(CodexProvider.mapError(["message": "429 too many requests"]) == .rateLimited(retryAfter: nil))
        #expect(CodexProvider.mapError(["message": "kaboom"]) == .badResponse("kaboom"))
    }

    @Test func locateHonoursTheEnvironmentOverride() {
        let found = CodexProvider.locate(environment: ["CODEX_BIN": "/custom/codex"], fileExists: { $0 == "/custom/codex" })
        #expect(found?.path == "/custom/codex")
        // an override that does not exist does not silently fall back to the search paths
        let missing = CodexProvider.locate(environment: ["CODEX_BIN": "/nope/codex"], fileExists: { _ in false })
        #expect(missing == nil)
    }

    @Test func locateWalksTheSearchPaths() {
        let target = NSString(string: "/opt/homebrew/bin/codex").expandingTildeInPath
        let found = CodexProvider.locate(environment: [:], fileExists: { $0 == target })
        #expect(found?.path == target)
    }
}
