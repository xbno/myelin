import Foundation

/// The OAuth material Claude Code keeps in the login keychain.
public struct ClaudeCodeCredentials: Equatable {
    public let accessToken: String
    public let expiresAt: Date?
    public let subscriptionType: String?

    public init(accessToken: String, expiresAt: Date?, subscriptionType: String?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
    }

    /// Parses the JSON stored in the keychain item.
    public static func parse(_ data: Data) throws -> ClaudeCodeCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw ProviderError.notLoggedIn
        }
        let expires = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return ClaudeCodeCredentials(accessToken: token, expiresAt: expires, subscriptionType: oauth["subscriptionType"] as? String)
    }

    /// "team" → "Team".
    public var planLabel: String? {
        guard let s = subscriptionType, let first = s.first else { return nil }
        return first.uppercased() + s.dropFirst()
    }
}

public enum KeychainReader {
    public static let service = "Claude Code-credentials"

    /// Reads the item with `/usr/bin/security`, the same tool Claude Code used to write it,
    /// which is why no keychain prompt appears. The app never writes or refreshes the token.
    public static func readClaudeCodeCredentials() throws -> ClaudeCodeCredentials {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { throw ProviderError.transport(error.localizedDescription) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ProviderError.notLoggedIn }
        return try ClaudeCodeCredentials.parse(data)
    }
}
