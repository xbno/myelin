import Foundation

/// Reads the same private endpoint that powers `/usage` in Claude Code, with Claude Code's token.
public struct AnthropicProvider: UsageProvider {
    public let id = "anthropic"
    public let displayName = "Claude"
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let legacyModelKeys = ["opus", "sonnet", "haiku", "fable"]

    /// A token this close to expiry is refreshed first, so it cannot run out mid-request.
    static let refreshMargin: TimeInterval = 60

    private let credentials: () throws -> ClaudeCodeCredentials
    private let refresh: () async throws -> Void
    private let session: URLSession

    public init(credentials: @escaping () throws -> ClaudeCodeCredentials = KeychainReader.readClaudeCodeCredentials,
                refresh: @escaping () async throws -> Void = { try await ClaudeCLI.refreshToken() },
                session: URLSession = .shared) {
        self.credentials = credentials
        self.refresh = refresh
        self.session = session
    }

    /// The keychain token, refreshed by Claude Code first when it has run out or nearly has.
    /// Still expired after that means the refresh failed, and only a new login helps.
    func freshCredentials(now: Date = Date()) async throws -> ClaudeCodeCredentials {
        let creds = try credentials()
        guard let expires = creds.expiresAt, expires < now.addingTimeInterval(Self.refreshMargin) else { return creds }
        try? await refresh()
        let again = try credentials()
        if let expires = again.expiresAt, expires < now { throw ProviderError.tokenExpired }
        return again
    }

    public func fetch() async throws -> UsageSnapshot {
        let creds = try await freshCredentials()
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 20
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("pace/0.1", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ProviderError.badResponse("no HTTP response") }
        if http.statusCode == 401 { throw ProviderError.tokenExpired }
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw ProviderError.rateLimited(retryAfter: retryAfter)
        }
        guard http.statusCode == 200 else { throw ProviderError.http(http.statusCode) }
        return try Self.parse(data, fetchedAt: Date(), plan: creds.planLabel)
    }

    /// Prefers the `limits` array; falls back to the older `five_hour` / `seven_day*` fields.
    public static func parse(_ data: Data, fetchedAt: Date, plan: String?) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.badResponse("not a JSON object")
        }
        var meters: [Meter] = []
        if let limits = root["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let kind = limit["kind"] as? String else { continue }
                let percent = (limit["percent"] as? Double) ?? 0
                let resets = (limit["resets_at"] as? String).flatMap(parseDate)
                let locked = percent >= 100 || (limit["severity"] as? String) == "locked"
                switch kind {
                case "session":
                    meters.append(Meter(kind: .session, percent: percent, resetsAt: resets, windowLength: 5 * 3600, locked: locked))
                case "weekly_all":
                    meters.append(Meter(kind: .weekly, percent: percent, resetsAt: resets, windowLength: 7 * 86400, locked: locked))
                case "weekly_scoped":
                    let scope = limit["scope"] as? [String: Any]
                    let model = scope?["model"] as? [String: Any]
                    let name = (model?["display_name"] as? String) ?? "Model"
                    meters.append(Meter(kind: .weeklyModel(name: name), percent: percent, resetsAt: resets, windowLength: 7 * 86400, locked: locked))
                default:
                    continue
                }
            }
        } else {
            func legacy(_ key: String, kind: MeterKind, windowLength: TimeInterval) -> Meter? {
                guard let d = root[key] as? [String: Any] else { return nil }
                let percent = (d["utilization"] as? Double) ?? 0
                let resets = (d["resets_at"] as? String).flatMap(parseDate)
                let reason = d["locked_reason"]
                let locked = percent >= 100 || (reason != nil && !(reason is NSNull))
                return Meter(kind: kind, percent: percent, resetsAt: resets, windowLength: windowLength, locked: locked)
            }
            if let s = legacy("five_hour", kind: .session, windowLength: 5 * 3600) { meters.append(s) }
            if let w = legacy("seven_day", kind: .weekly, windowLength: 7 * 86400) { meters.append(w) }
            for key in legacyModelKeys {
                let name = key.prefix(1).uppercased() + key.dropFirst()
                if let m = legacy("seven_day_\(key)", kind: .weeklyModel(name: name), windowLength: 7 * 86400) { meters.append(m) }
            }
        }
        guard !meters.isEmpty else { throw ProviderError.badResponse("no limits in response") }
        return UsageSnapshot(fetchedAt: fetchedAt, plan: plan, meters: meters)
    }

    /// ISO 8601 with any fractional precision and an offset or Z. Rounded to the minute,
    /// which is how claude.ai displays it.
    public static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX",
                       "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
                       "yyyy-MM-dd'T'HH:mm:ss.SXXXXX",
                       "yyyy-MM-dd'T'HH:mm:ssXXXXX"] {
            f.dateFormat = format
            if let d = f.date(from: s) {
                return Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 60).rounded() * 60)
            }
        }
        return nil
    }
}
