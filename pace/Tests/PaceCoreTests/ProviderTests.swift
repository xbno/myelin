import Foundation
import Testing
@testable import PaceCore

@Suite struct ProviderTests {
    func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "anthropic-usage-sample", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
    func utc(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    @Test func parsesLimitsArray() throws {
        let snap = try AnthropicProvider.parse(try fixture(), fetchedAt: Date(timeIntervalSince1970: 0), plan: "Team")
        #expect(snap.plan == "Team")
        #expect(snap.meters.count == 3)
        #expect(snap.session?.percent == 3)
        #expect(snap.session?.resetsAt == utc("2026-09-08T22:30:00Z"))   // rounded to the minute
        #expect(snap.session?.windowLength == 5.0 * 3600)
        #expect(snap.weekly?.percent == 4)
        #expect(snap.weekly?.resetsAt == utc("2026-09-11T21:00:00Z"))
        #expect(snap.models.first?.modelName == "Fable")
        #expect(snap.models.first?.percent == 3)
        #expect(snap.models.first?.windowLength == 7.0 * 86400)
        #expect(snap.weekly?.locked == false)
    }

    @Test func nullResetGivesInactiveSession() throws {
        let json = #"{"limits":[{"kind":"session","percent":0,"resets_at":null},{"kind":"weekly_all","percent":9,"resets_at":"2026-09-11T20:59:59+00:00"}]}"#
        let snap = try AnthropicProvider.parse(Data(json.utf8), fetchedAt: Date(), plan: nil)
        #expect(snap.session != nil)
        #expect(snap.session?.resetsAt == nil)
        #expect(snap.weekly?.resetsAt == utc("2026-09-11T21:00:00Z"))
    }

    @Test func fallsBackToLegacyFields() throws {
        let json = #"{"five_hour":{"utilization":12,"resets_at":"2026-09-08T22:29:59+00:00"},"seven_day":{"utilization":34,"resets_at":"2026-09-11T20:59:59+00:00","locked_reason":null},"seven_day_opus":{"utilization":50,"resets_at":"2026-09-11T20:59:59+00:00"},"seven_day_sonnet":null,"seven_day_oauth_apps":{"utilization":1}}"#
        let snap = try AnthropicProvider.parse(Data(json.utf8), fetchedAt: Date(), plan: nil)
        #expect(snap.session?.percent == 12)
        #expect(snap.session?.windowLength == 5.0 * 3600)
        #expect(snap.weekly?.percent == 34)
        #expect(snap.models.map(\.modelName) == ["Opus"])
    }

    @Test func lockedAtHundred() throws {
        let json = #"{"limits":[{"kind":"weekly_all","percent":100,"resets_at":"2026-09-11T20:59:59+00:00"}]}"#
        let snap = try AnthropicProvider.parse(Data(json.utf8), fetchedAt: Date(), plan: nil)
        #expect(snap.weekly?.locked == true)
    }

    @Test func emptyResponseThrows() {
        #expect(throws: ProviderError.self) {
            try AnthropicProvider.parse(Data("{}".utf8), fetchedAt: Date(), plan: nil)
        }
    }

    @Test func parseDateVariants() {
        #expect(AnthropicProvider.parseDate("2026-09-08T22:29:59.510646+00:00") == utc("2026-09-08T22:30:00Z"))
        #expect(AnthropicProvider.parseDate("2026-09-08T22:29:29+00:00") == utc("2026-09-08T22:29:00Z"))
        #expect(AnthropicProvider.parseDate("2026-09-08T22:29:59.5Z") == utc("2026-09-08T22:30:00Z"))
        #expect(AnthropicProvider.parseDate("nope") == nil)
    }

    @Test func credentialsParse() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"test-access-token","refreshToken":"r","expiresAt":1788911232908,"scopes":["user:inference"],"subscriptionType":"team","rateLimitTier":"default_claude_max_5x"}}"#
        let c = try ClaudeCodeCredentials.parse(Data(json.utf8))
        #expect(c.accessToken == "test-access-token")
        #expect(c.expiresAt == Date(timeIntervalSince1970: 1788911232.908))
        #expect(c.planLabel == "Team")
    }

    @Test func credentialsMissingTokenIsNotLoggedIn() {
        #expect(throws: ProviderError.notLoggedIn) {
            try ClaudeCodeCredentials.parse(Data("{}".utf8))
        }
    }

    @Test func fetchRejectsExpiredToken() async {
        let p = AnthropicProvider(credentials: {
            ClaudeCodeCredentials(accessToken: "x", expiresAt: Date(timeIntervalSinceNow: -60), subscriptionType: nil)
        }, refresh: {})
        await #expect(throws: ProviderError.tokenExpired) {
            _ = try await p.fetch()
        }
    }

    // MARK: - Token refresh

    final class Keychain {
        var expiresAt: Date?
        var refreshes = 0
        init(_ expiresAt: Date?) { self.expiresAt = expiresAt }
        func read() -> ClaudeCodeCredentials {
            ClaudeCodeCredentials(accessToken: "t", expiresAt: expiresAt, subscriptionType: nil)
        }
    }

    @Test func validTokenIsNotRefreshed() async throws {
        let now = Date()
        let kc = Keychain(now.addingTimeInterval(3600))
        let p = AnthropicProvider(credentials: kc.read, refresh: { kc.refreshes += 1 })
        _ = try await p.freshCredentials(now: now)
        #expect(kc.refreshes == 0)
    }

    @Test func expiredTokenIsRefreshedThenReadBack() async throws {
        let now = Date()
        let kc = Keychain(now.addingTimeInterval(-86400))
        let p = AnthropicProvider(credentials: kc.read, refresh: {
            kc.refreshes += 1
            kc.expiresAt = now.addingTimeInterval(8 * 3600)   // Claude Code wrote a new one
        })
        let creds = try await p.freshCredentials(now: now)
        #expect(kc.refreshes == 1)
        #expect(creds.expiresAt == now.addingTimeInterval(8 * 3600))
    }

    @Test func tokenAboutToExpireIsRefreshed() async throws {
        let now = Date()
        let kc = Keychain(now.addingTimeInterval(30))
        let p = AnthropicProvider(credentials: kc.read, refresh: { kc.refreshes += 1 })
        let creds = try await p.freshCredentials(now: now)
        #expect(kc.refreshes == 1)
        #expect(creds.expiresAt == now.addingTimeInterval(30))   // refresh did nothing; still usable
    }

    @Test func failedRefreshReadsAsExpired() async {
        let now = Date()
        let kc = Keychain(now.addingTimeInterval(-60))
        let p = AnthropicProvider(credentials: kc.read, refresh: { throw ProviderError.tokenExpired })
        await #expect(throws: ProviderError.tokenExpired) { try await p.freshCredentials(now: now) }
    }

    @Test func refreshDropsTheTokensThatBypassTheKeychain() {
        let env = ClaudeCLI.environment(from: ["CLAUDE_CODE_OAUTH_TOKEN": "x", "ANTHROPIC_API_KEY": "y", "HOME": "/h"])
        #expect(env == ["HOME": "/h"])
    }
}
