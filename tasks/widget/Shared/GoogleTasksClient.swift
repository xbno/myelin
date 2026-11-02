import Foundation

// MARK: - Models

struct GTaskList: Codable, Identifiable, Hashable {
    let id: String
    let title: String
}

struct GTask: Codable, Identifiable, Hashable {
    let id: String
    let title: String?
    let status: String?
    let due: String?      // RFC 3339, date part only is meaningful
    let parent: String?
    let position: String?
    let notes: String?
}

/// Contents of bridge.json in the tasks/ folder (the Apps Script web app URL and its secret).
struct BridgeConfig: Codable {
    var url: String
    var secret: String
}

enum GTasksError: LocalizedError {
    case notConnected
    case badConfig
    case http(Int)
    case badResponse(String)
    case api(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected. Open the GTasks app and import bridge.json."
        case .badConfig:
            return "bridge.json needs both url and secret. Run `uv run server.py bridge-url <URL>` first."
        case .http(let code):
            return "Bridge HTTP \(code)."
        case .badResponse(let start):
            return "Bridge returned non-JSON (is the web app deployed with access \"Anyone\"?): \(start)"
        case .api(let message):
            return "Google Tasks error: \(message)"
        }
    }
}

// MARK: - Shared storage (App Group)

enum SharedStore {
    /// "<TEAMID>.gtasks.widget", expanded from $(TeamIdentifierPrefix) in each target's Info.plist.
    static var groupID: String {
        Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String ?? "gtasks.widget"
    }

    static var defaults: UserDefaults? { UserDefaults(suiteName: groupID) }

    private static let key = "bridge"

    static func loadConfig() -> BridgeConfig? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(BridgeConfig.self, from: data)
    }

    static func saveConfig(_ config: BridgeConfig) {
        if let data = try? JSONEncoder().encode(config) {
            defaults?.set(data, forKey: key)
        }
    }

    static func clear() {
        defaults?.removeObject(forKey: key)
    }

    static func importBridgeJSON(_ data: Data) throws -> BridgeConfig {
        let config = try JSONDecoder().decode(BridgeConfig.self, from: data)
        guard !config.url.isEmpty, !config.secret.isEmpty, URL(string: config.url) != nil else {
            throw GTasksError.badConfig
        }
        saveConfig(config)
        return config
    }
}

// MARK: - Client (talks to the Apps Script bridge)

struct GoogleTasksClient {
    func lists() async throws -> [GTaskList] {
        struct Page: Decodable {
            let items: [GTaskList]?
            let nextPageToken: String?
        }
        var out: [GTaskList] = []
        var pageToken: String? = nil
        repeat {
            var args: [String: Any] = ["maxResults": 100]
            if let pageToken { args["pageToken"] = pageToken }
            let page: Page = try await call("tasklists.list", args)
            out += page.items ?? []
            pageToken = page.nextPageToken
        } while pageToken != nil
        return out
    }

    /// Open (not completed) tasks in one list.
    func openTasks(listID: String) async throws -> [GTask] {
        struct Page: Decodable {
            let items: [GTask]?
            let nextPageToken: String?
        }
        var out: [GTask] = []
        var pageToken: String? = nil
        repeat {
            var args: [String: Any] = [
                "tasklist": listID,
                "maxResults": 100,
                "showCompleted": false,
                "showHidden": false,
            ]
            if let pageToken { args["pageToken"] = pageToken }
            let page: Page = try await call("tasks.list", args)
            out += page.items ?? []
            pageToken = page.nextPageToken
        } while pageToken != nil
        return out
    }

    func complete(listID: String, taskID: String) async throws {
        let _: GTask = try await call("tasks.patch", [
            "tasklist": listID,
            "task": taskID,
            "body": ["status": "completed"],
        ])
    }

    // MARK: plumbing

    /// POST {secret, op, args}. Apps Script replies 302 to the result; URLSession follows it as a GET.
    private func call<T: Decodable>(_ op: String, _ args: [String: Any]) async throws -> T {
        guard let config = SharedStore.loadConfig() else { throw GTasksError.notConnected }
        guard let url = URL(string: config.url) else { throw GTasksError.badConfig }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "secret": config.secret,
            "op": op,
            "args": args,
        ])

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GTasksError.http(http.statusCode)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw GTasksError.badResponse(String(decoding: data.prefix(120), as: UTF8.self))
        }
        if let message = object["error"] as? String {
            throw GTasksError.api(message)
        }
        let result = object["result"] as? [String: Any] ?? [:]
        let resultData = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder().decode(T.self, from: resultData)
    }
}
