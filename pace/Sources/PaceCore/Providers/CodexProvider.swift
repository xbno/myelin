import Foundation

/// Reads Codex usage through the Codex CLI's app-server: a JSON-RPC service the CLI speaks
/// over stdio, where `account/rateLimits/read` returns the same numbers the Codex UI shows.
///
/// Going through the CLI rather than calling chatgpt.com directly is deliberate. The backend
/// sits behind a bot check that answers a plain URLSession request with an HTML 403, and the
/// CLI already owns the OAuth tokens and their refresh. Spawning it costs about a second,
/// which is nothing against a poll measured in minutes.
public struct CodexProvider: UsageProvider {
    public let id = "codex"
    public let displayName = "Codex"

    static let method = "account/rateLimits/read"
    static let clientName = "pace"
    static let clientVersion = "0.1"
    /// A window this short or shorter is the rolling session window; anything longer is the
    /// weekly one. Codex reports 300 minutes and 10080; plans differ in which they send.
    static let sessionCutoffMinutes: Double = 24 * 60

    /// A menu bar app started by launchd inherits almost no PATH, so `which codex` is no use.
    /// These are where the installers put it, most specific first.
    public static let searchPaths = [
        "~/.local/bin/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
        "~/.npm-global/bin/codex",
        "~/.bun/bin/codex",
        "/usr/bin/codex",
    ]

    public static var defaultAuthURL: URL {
        URL(fileURLWithPath: NSString(string: "~/.codex/auth.json").expandingTildeInPath)
    }

    let binary: URL?
    let authURL: URL
    let timeout: TimeInterval

    public init(binary: URL? = CodexProvider.locate(),
                authURL: URL = CodexProvider.defaultAuthURL,
                timeout: TimeInterval = 25) {
        self.binary = binary
        self.authURL = authURL
        self.timeout = timeout
    }

    /// `$CODEX_BIN` wins, so a non-standard install can be pointed at without a rebuild.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        if let override = environment["CODEX_BIN"], !override.isEmpty {
            let path = NSString(string: override).expandingTildeInPath
            return fileExists(path) ? URL(fileURLWithPath: path) : nil
        }
        for candidate in searchPaths {
            let path = NSString(string: candidate).expandingTildeInPath
            if fileExists(path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    public func fetch() async throws -> UsageSnapshot {
        guard let binary else {
            throw ProviderError.unavailable("Codex CLI not found")
        }
        // Cheap enough to check first, and it separates "never logged in" from a broken call.
        guard FileManager.default.fileExists(atPath: authURL.path) else {
            throw ProviderError.notLoggedIn
        }
        let result = try await Self.readRateLimits(binary: binary, timeout: timeout)
        return try Self.parse(result, fetchedAt: Date())
    }

    // MARK: - Transport

    private static func readRateLimits(binary: URL, timeout: TimeInterval) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            // The exchange blocks on pipe reads, so it stays off the cooperative pool.
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try exchange(binary: binary, timeout: timeout))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Writing to a pipe whose reader has exited raises SIGPIPE, which would take the app
    /// down. Ignoring it once turns that into the `write` error we already handle.
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    static func exchange(binary: URL, timeout: TimeInterval) throws -> [String: Any] {
        _ = ignoreSIGPIPE

        let process = Process()
        process.executableURL = binary
        process.arguments = ["app-server"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()   // app-server logs here; we want only the protocol

        do {
            try process.run()
        } catch {
            throw ProviderError.unavailable("could not run codex: \(error.localizedDescription)")
        }

        // `availableData` has no timeout of its own. The deadline is enforced by killing the
        // process, which closes the pipe and drops the read loop out at EOF.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer {
            watchdog.cancel()
            if process.isRunning { process.terminate() }
        }

        func send(_ message: [String: Any]) throws {
            guard var data = try? JSONSerialization.data(withJSONObject: message) else {
                throw ProviderError.badResponse("could not encode request")
            }
            data.append(0x0A)
            do {
                try input.fileHandleForWriting.write(contentsOf: data)
            } catch {
                throw ProviderError.transport("codex app-server closed its input")
            }
        }

        try send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                  "params": ["clientInfo": ["name": clientName, "version": clientVersion]]])
        try send(["jsonrpc": "2.0", "method": "initialized", "params": [:]])
        // Background poll: skip the separate reset-credit lookup the flag is there for.
        try send(["jsonrpc": "2.0", "id": 2, "method": method,
                  "params": ["excludeResetCreditDetails": true]])

        var buffer = Data()
        let handle = output.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }     // EOF: it exited, or the watchdog killed it
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = Data(buffer[buffer.index(after: newline)...])
                guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      (message["id"] as? Int) == 2 else { continue }
                if let failure = message["error"] as? [String: Any] { throw mapError(failure) }
                guard let result = message["result"] as? [String: Any] else {
                    throw ProviderError.badResponse("rate limit reply carried no result")
                }
                return result
            }
        }
        throw ProviderError.transport("codex app-server closed without answering")
    }

    /// The RPC carries backend failures as a message, so the kind has to be read out of it.
    static func mapError(_ failure: [String: Any]) -> ProviderError {
        let message = (failure["message"] as? String) ?? "unknown error"
        let lower = message.lowercased()
        if lower.contains("401") || lower.contains("unauthor") || lower.contains("expired")
            || lower.contains("logged in") || lower.contains("credential") {
            return .tokenExpired
        }
        if lower.contains("429") || lower.contains("too many requests") {
            return .rateLimited(retryAfter: nil)
        }
        return .badResponse(message)
    }

    // MARK: - Parsing

    /// `rateLimits` is the account's main bucket and becomes the session and week meters.
    /// `rateLimitsByLimitId` repeats that bucket and adds any others — a reserve pool, say —
    /// and those become model-style rows, the same shape Anthropic's per-model limits take.
    /// Convenience for callers holding the raw JSON rather than the decoded object.
    public static func parse(_ data: Data, fetchedAt: Date) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.badResponse("not a JSON object")
        }
        return try parse(root, fetchedAt: fetchedAt)
    }

    public static func parse(_ result: [String: Any], fetchedAt: Date) throws -> UsageSnapshot {
        guard let main = result["rateLimits"] as? [String: Any] else {
            throw ProviderError.badResponse("no rateLimits in response")
        }
        // Account-wide, so it only speaks for the main bucket — a separate reserve pool can
        // still be spendable while ordinary usage is blocked.
        let ordinaryBlocked = (result["ordinaryUsageAllowed"] as? Bool) == false
        let mainId = main["limitId"] as? String

        var meters: [Meter] = []
        for key in ["primary", "secondary"] {
            guard let window = main[key] as? [String: Any],
                  let parsed = self.window(window) else { continue }
            let kind: MeterKind = parsed.minutes <= sessionCutoffMinutes ? .session : .weekly
            // Both windows can describe the same span; the first one wins.
            guard !meters.contains(where: { $0.kind == kind }) else { continue }
            meters.append(Meter(kind: kind, percent: parsed.percent, resetsAt: parsed.resetsAt,
                                windowLength: parsed.length,
                                locked: locked(snapshot: main, percent: parsed.percent) || ordinaryBlocked))
        }

        if let buckets = result["rateLimitsByLimitId"] as? [String: [String: Any]] {
            for key in buckets.keys.sorted() {
                guard key != mainId, let bucket = buckets[key] else { continue }
                guard let window = (bucket["primary"] ?? bucket["secondary"]) as? [String: Any],
                      let parsed = self.window(window) else { continue }
                let name = (bucket["limitName"] as? String)
                    ?? (bucket["normalModelSlug"] as? String)
                    ?? key
                meters.append(Meter(kind: .weeklyModel(name: name), percent: parsed.percent,
                                    resetsAt: parsed.resetsAt, windowLength: parsed.length,
                                    locked: locked(snapshot: bucket, percent: parsed.percent)))
            }
        }

        guard !meters.isEmpty else { throw ProviderError.badResponse("no usable rate limit windows") }
        return UsageSnapshot(fetchedAt: fetchedAt, plan: planLabel(main["planType"] as? String), meters: meters)
    }

    /// `usedPercent` is the only required field; a window with no duration is taken as weekly,
    /// which is what every bucket observed without one has been.
    static func window(_ raw: [String: Any]) -> (percent: Double, resetsAt: Date?, length: TimeInterval, minutes: Double)? {
        guard let percent = number(raw["usedPercent"]) else { return nil }
        let minutes = number(raw["windowDurationMins"]) ?? (7 * 24 * 60)
        let resetsAt = number(raw["resetsAt"]).map { Date(timeIntervalSince1970: $0) }
        return (min(100, max(0, percent)), resetsAt, minutes * 60, minutes)
    }

    /// `rateLimitReachedType` is only set once the limit actually bites.
    static func locked(snapshot: [String: Any], percent: Double) -> Bool {
        if let reached = snapshot["rateLimitReachedType"], !(reached is NSNull) { return true }
        if (snapshot["spendControlReached"] as? Bool) == true { return true }
        return percent >= 100
    }

    static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    /// "prolite" → "Prolite".
    static func planLabel(_ plan: String?) -> String? {
        guard let plan, let first = plan.first else { return nil }
        return first.uppercased() + plan.dropFirst()
    }
}
