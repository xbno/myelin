import Foundation

/// Gets Claude Code to refresh its own OAuth token. Claude Code refreshes only when it needs
/// a token, and `claude auth status` reads the keychain without refreshing, so the cheapest
/// trigger is the smallest real request: one word from Haiku, no tools, no settings, no
/// saved session. About 3 s, once per token lifetime (hours).
///
/// Pace never refreshes the token itself. Refresh tokens rotate, so a second refresher would
/// sooner or later spend the one Claude Code holds and sign it out. Here Claude Code does
/// the refresh and writes the new pair back to the keychain item Pace reads.
public enum ClaudeCLI {
    /// A menu bar app started by launchd inherits almost no PATH, so `which claude` is no use.
    public static let searchPaths = [
        "~/.local/bin/claude",
        "~/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "~/.npm-global/bin/claude",
        "~/.bun/bin/claude",
    ]

    static let refreshArguments = [
        "-p", "Reply with: ok", "--model", "haiku",
        "--tools", "", "--setting-sources", "", "--strict-mcp-config", "--no-session-persistence",
    ]

    /// Either of these makes Claude Code skip the keychain login, and then nothing refreshes.
    static let overridingVariables = ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY"]

    public static func locate(fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        for candidate in searchPaths {
            let path = NSString(string: candidate).expandingTildeInPath
            if fileExists(path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    static func environment(from base: [String: String]) -> [String: String] {
        var env = base
        for key in overridingVariables { env.removeValue(forKey: key) }
        return env
    }

    /// Runs the request and waits for it. Throws when the CLI is missing, or exits non-zero —
    /// most likely because the refresh token itself has run out and only a new login helps.
    public static func refreshToken(timeout: TimeInterval = 60) async throws {
        guard let binary = locate() else { throw ProviderError.unavailable("Claude Code CLI not found") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = binary
            process.arguments = refreshArguments
            process.environment = environment(from: ProcessInfo.processInfo.environment)
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            process.terminationHandler = { finished in
                watchdog.cancel()
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ProviderError.tokenExpired)
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ProviderError.unavailable("could not run claude: \(error.localizedDescription)"))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        }
    }
}
