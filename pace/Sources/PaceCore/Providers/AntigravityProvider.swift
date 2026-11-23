import Foundation

/// Reads Antigravity quota by running `agy -p /usage --output-format json`. The CLI handles
/// `/usage` locally: no model turn, no conversation, about two seconds. It owns the login
/// and its refresh, so Pace never touches a token.
///
/// This replaced reading a cache that agy's status-line hook wrote. The hook only fires when
/// an interactive agy session redraws, so an idle terminal or work done in Gemini.app left
/// the numbers frozen for days.
public struct AntigravityProvider: UsageProvider {
    public let id = "gemini"
    public let displayName = "Antigravity"

    /// launchd gives a menu bar app almost no PATH, so the installer locations are searched.
    public static let searchPaths = [
        "~/.local/bin/agy",
        "/opt/homebrew/bin/agy",
        "/usr/local/bin/agy",
        "/Applications/Gemini.app/Contents/Helpers/agy",
    ]

    let pinnedBinary: URL?
    let planCacheURL: URL
    let timeout: TimeInterval

    public init(binary: URL? = nil,
                planCacheURL: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Caches/com.geoff.pace/antigravity.json"),
                timeout: TimeInterval = 30) {
        self.pinnedBinary = binary
        self.planCacheURL = planCacheURL
        self.timeout = timeout
    }

    /// `$AGY_BIN` wins, so a non-standard install can be pointed at without a rebuild.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> URL? {
        if let override = environment["AGY_BIN"], !override.isEmpty {
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
        guard let binary = pinnedBinary ?? Self.locate() else {
            throw ProviderError.unavailable("Antigravity CLI (agy) not found")
        }
        let timeout = self.timeout
        let data = try await withCheckedThrowingContinuation { continuation in
            // `run` blocks on the pipe, so it stays off the cooperative pool.
            DispatchQueue.global(qos: .utility).async {
                do { continuation.resume(returning: try Self.run(binary: binary, timeout: timeout)) }
                catch { continuation.resume(throwing: error) }
            }
        }
        return try Self.parse(data, fetchedAt: Date(), plan: cachedPlan())
    }

    /// `/usage` does not name the plan. The status-line hook, if still installed, recorded it.
    private func cachedPlan() -> String? {
        guard let data = try? Data(contentsOf: planCacheURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["plan_tier"] as? String
    }

    static func run(binary: URL, timeout: TimeInterval) throws -> Data {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-p", "/usage", "--output-format", "json",
                             "--print-timeout", "\(Int(timeout))s"]
        // Its working directory would otherwise be wherever Pace was launched from.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ProviderError.unavailable("could not run agy: \(error.localizedDescription)")
        }
        // Killing the process closes the pipe, which ends the read below at EOF.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 5, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard !data.isEmpty else { throw ProviderError.transport("agy /usage returned nothing") }
        return data
    }

    private struct Result: Decodable {
        let status: String?
        let response: String?
        let command: Command?
    }
    private struct Command: Decodable { let data: Payload? }
    private struct Payload: Decodable { let groups: [Group]? }
    private struct Group: Decodable { let buckets: [Bucket]? }
    private struct Bucket: Decodable {
        let id: String
        let remaining_fraction: Double?
        let reset_time: String?
    }

    public static func parse(_ data: Data, fetchedAt: Date, plan: String? = nil) throws -> UsageSnapshot {
        guard let result = try? JSONDecoder().decode(Result.self, from: data) else {
            throw ProviderError.badResponse("agy /usage output was not JSON")
        }
        guard result.status == "SUCCESS", let groups = result.command?.data?.groups else {
            let why = result.response?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if why.lowercased().contains("log in") || why.lowercased().contains("sign in") {
                throw ProviderError.notLoggedIn
            }
            throw ProviderError.badResponse(why.isEmpty ? "agy /usage failed" : why)
        }
        var meters: [Meter] = []
        for bucket in groups.flatMap({ $0.buckets ?? [] }) {
            let kind: MeterKind
            switch bucket.id {
            case "gemini-weekly": kind = .weekly
            case "gemini-5h": kind = .session
            // Claude and GPT models draw on their own pool with its own reset. Its 5-hour
            // window has no row to go in; the weekly one shows under Models.
            case "3p-weekly": kind = .weeklyModel(name: "Claude/GPT")
            default: continue
            }
            guard let fraction = bucket.remaining_fraction, (0...1).contains(fraction),
                  let reset = bucket.reset_time.flatMap({ try? Date($0, strategy: .iso8601) }) else { continue }
            meters.append(Meter(kind: kind, percent: 100 * (1 - fraction), resetsAt: reset,
                                windowLength: kind == .session ? 5 * 3600 : 7 * 86400, locked: fraction == 0))
        }
        guard !meters.isEmpty else { throw ProviderError.badResponse("no Gemini quota windows in agy /usage") }
        return UsageSnapshot(fetchedAt: fetchedAt, plan: plan, meters: meters)
    }
}
