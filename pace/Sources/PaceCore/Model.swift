import Foundation

/// What a meter measures. Model-scoped weekly limits carry the model's display name.
public enum MeterKind: Equatable {
    case session
    case weekly
    case weeklyModel(name: String)
}

/// One usage limit as the provider reports it. Provider-neutral: the UI only sees this.
public struct Meter: Equatable {
    public var kind: MeterKind
    public var percent: Double            // 0…100
    public var resetsAt: Date?            // nil when no window is active
    public var windowLength: TimeInterval // 5 h or 7 d
    public var locked: Bool

    public init(kind: MeterKind, percent: Double, resetsAt: Date?, windowLength: TimeInterval, locked: Bool = false) {
        self.kind = kind
        self.percent = percent
        self.resetsAt = resetsAt
        self.windowLength = windowLength
        self.locked = locked
    }

    public var windowStart: Date? { resetsAt?.addingTimeInterval(-windowLength) }

    public var modelName: String? {
        if case .weeklyModel(let name) = kind { return name }
        return nil
    }
}

public struct UsageSnapshot: Equatable {
    public var fetchedAt: Date
    public var plan: String?
    public var meters: [Meter]

    public init(fetchedAt: Date, plan: String?, meters: [Meter]) {
        self.fetchedAt = fetchedAt
        self.plan = plan
        self.meters = meters
    }

    public var session: Meter? { meters.first { $0.kind == .session } }
    public var weekly: Meter? { meters.first { $0.kind == .weekly } }
    public var models: [Meter] { meters.filter { $0.modelName != nil } }
}

public enum ProviderError: Error, Equatable {
    case notLoggedIn
    case tokenExpired
    case http(Int)
    case badResponse(String)
    case transport(String)
}

public protocol UsageProvider {
    var id: String { get }
    var displayName: String { get }
    func fetch() async throws -> UsageSnapshot
}
