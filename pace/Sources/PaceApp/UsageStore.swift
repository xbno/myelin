import AppKit
import Combine
import PaceCore

/// Owns the latest snapshot, the settings, and the clocks that drive re-rendering.
/// Fetches are scheduled, not fired blindly: a failure backs the next attempt off,
/// and a 429 keeps the last good numbers on screen.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var lastError: ProviderError?
    @Published private(set) var nextFetchAt: Date?
    @Published private(set) var now = Date()
    @Published var settings: AppSettings {
        didSet {
            settings.save()
            if settings.pollSeconds != oldValue.pollSeconds || settings.providerEnabled != oldValue.providerEnabled {
                failures = 0
                nextFetchAt = Date()
            }
        }
    }

    /// Data older than this dims the glyph.
    static let staleAfter: TimeInterval = 15 * 60
    /// Manual refreshes, popover open or the Refresh button, are spaced at least this far apart.
    static let manualSpacing: TimeInterval = 30
    static let backoffCap: TimeInterval = 30 * 60

    let provider: UsageProvider
    let calendar = Calendar.autoupdatingCurrent
    private var failures = 0
    private var lastAttempt: Date?
    private var inFlight = false
    private var tickTimer: Timer?
    private var pollTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init(provider: UsageProvider, settings: AppSettings = .load()) {
        self.provider = provider
        self.settings = settings
    }

    func start() {
        // The tick moves with the clock even when nothing is fetched.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        // Cheap heartbeat; the real cadence is `nextFetchAt`.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollIfDue() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.nextFetchAt = Date()
                self?.pollIfDue()
            }
        }
        nextFetchAt = Date()
        pollIfDue()
    }

    private func pollIfDue() {
        guard settings.providerEnabled, !inFlight, let due = nextFetchAt, Date() >= due else { return }
        Task { await refresh() }
    }

    /// User-initiated. Skipped when an attempt ran under 30 s ago, or while a rate limit is in force.
    func refreshManually() {
        if let last = lastAttempt, Date().timeIntervalSince(last) < Self.manualSpacing { return }
        if case .rateLimited = lastError, let due = nextFetchAt, Date() < due { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard settings.providerEnabled, !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        lastAttempt = Date()
        let base = TimeInterval(max(15, settings.pollSeconds))
        do {
            snapshot = try await provider.fetch()
            lastError = nil
            failures = 0
            nextFetchAt = Date().addingTimeInterval(base)
        } catch {
            let providerError = (error as? ProviderError) ?? .transport(error.localizedDescription)
            lastError = providerError
            failures += 1
            var retryAfter: TimeInterval?
            if case .rateLimited(let r) = providerError { retryAfter = r }
            let delay = Backoff.delay(failures: failures, base: base, cap: Self.backoffCap, retryAfter: retryAfter)
            nextFetchAt = Date().addingTimeInterval(delay)
        }
        now = Date()
    }

    /// True with no data, or with data older than `staleAfter`. A transient failure alone does not dim.
    var isStale: Bool {
        guard let s = snapshot else { return true }
        return now.timeIntervalSince(s.fetchedAt) > Self.staleAfter
    }
    var staleSince: Date? { isStale ? snapshot?.fetchedAt : nil }
    var isLoggedOut: Bool { snapshot == nil && (lastError == .notLoggedIn || lastError == .tokenExpired) }

    /// One line for the tooltip, popover and settings. Nil when the last fetch succeeded.
    var statusLine: String? {
        if isLoggedOut { return "Open Claude Code and log in" }
        guard let error = lastError else { return nil }
        let next = nextFetchAt.map { "next try \(Fmt.clock($0, now: now, calendar: calendar))" } ?? ""
        let age = snapshot.map { "showing data from \(Fmt.clock($0.fetchedAt, now: now, calendar: calendar))" } ?? "no data yet"
        switch error {
        case .rateLimited: return "usage API rate limited · \(age) · \(next)"
        case .tokenExpired: return "token expired · \(age) · open Claude Code to refresh it"
        case .notLoggedIn: return "not logged in · open Claude Code"
        case .http(let code): return "usage API error \(code) · \(age) · \(next)"
        case .badResponse: return "unexpected API response · \(age) · \(next)"
        case .transport: return "offline · \(age) · \(next)"
        }
    }

    /// The reset instant the week bar is built around: the account's, or the next custom weekday/time.
    func weekWindowEnd() -> Date? {
        if settings.weekStart.useAccount { return snapshot?.weekly?.resetsAt }
        let c = settings.weekStart
        let components = DateComponents(hour: c.hour, minute: c.minute, weekday: c.weekday)
        return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
    }

    func weekLayout() -> WeekLayout? {
        guard let end = weekWindowEnd() else { return nil }
        return WeekLayout.make(windowEnd: end, schedule: settings.schedule, calendar: calendar)
    }
}
