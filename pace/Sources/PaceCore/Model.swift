import Foundation

/// What a meter measures. Model-scoped weekly limits carry the model's display name.
public enum MeterKind: Equatable {
    case session
    case weekly
    /// A billing-cycle allowance rather than a rolling window — what Codex business plans
    /// report in place of the 5-hour and weekly windows.
    case monthly
    case weeklyModel(name: String)
}

/// One usage limit as the provider reports it. Provider-neutral: the UI only sees this.
public struct Meter: Equatable {
    public var kind: MeterKind
    public var percent: Double            // 0…100
    public var resetsAt: Date?            // nil when no window is active
    public var windowLength: TimeInterval // 5 h, 7 d, or a billing month
    public var locked: Bool
    /// What the percent is a percent *of*, when the provider counts in something the user
    /// recognises: "250 of 1000 credits". Shown as a caption; nil for plain windows.
    public var note: String?

    public init(kind: MeterKind, percent: Double, resetsAt: Date?, windowLength: TimeInterval,
                locked: Bool = false, note: String? = nil) {
        self.kind = kind
        self.percent = percent
        self.resetsAt = resetsAt
        self.windowLength = windowLength
        self.locked = locked
        self.note = note
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
    public var monthly: Meter? { meters.first { $0.kind == .monthly } }
    public var models: [Meter] { meters.filter { $0.modelName != nil } }

    /// The snapshot as it stands at `now`. A window that has reset since the fetch no longer
    /// holds the fetched numbers, so its meter reads as a window not yet started: 0%, no
    /// reset time. Without this an old snapshot draws last week's use against a tick pinned
    /// at the end of a window that is already over.
    public func asOf(_ now: Date) -> UsageSnapshot {
        var copy = self
        for i in copy.meters.indices {
            guard let reset = copy.meters[i].resetsAt, reset <= now else { continue }
            copy.meters[i].percent = 0
            copy.meters[i].resetsAt = nil
            copy.meters[i].locked = false
        }
        return copy
    }
}

public enum ProviderError: Error, Equatable {
    case notLoggedIn
    case tokenExpired
    case unavailable(String)                     // the CLI this provider reads through is missing
    case rateLimited(retryAfter: TimeInterval?)   // HTTP 429; keep the last snapshot and back off
    case http(Int)
    case badResponse(String)
    case transport(String)
}

public protocol UsageProvider {
    var id: String { get }
    var displayName: String { get }
    func fetch() async throws -> UsageSnapshot
}
