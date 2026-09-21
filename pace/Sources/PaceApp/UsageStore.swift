import AppKit
import Combine
import PaceCore

/// One provider's data and its own fetch state. Providers fail independently — Codex can be
/// mid-backoff while Claude is answering — so the backoff counters live here, not in the store.
struct ProviderFeed: Identifiable {
    let provider: UsageProvider
    var snapshot: UsageSnapshot?
    var lastError: ProviderError?
    var nextFetchAt: Date?
    var failures = 0
    var lastAttempt: Date?
    var inFlight = false

    var id: String { provider.id }
    var displayName: String { provider.displayName }

    init(provider: UsageProvider) { self.provider = provider }

    var isLoggedOut: Bool {
        guard snapshot == nil, let error = lastError else { return false }
        switch error {
        case .notLoggedIn, .tokenExpired, .unavailable: return true
        default: return false
        }
    }
}

/// Owns every provider's latest snapshot, the settings, and the clocks that drive re-rendering.
/// Fetches are scheduled, not fired blindly: a failure backs that provider's next attempt off,
/// and a 429 keeps its last good numbers on screen.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var feeds: [ProviderFeed]
    @Published private(set) var now = Date()
    @Published var settings: AppSettings {
        didSet {
            settings.save()
            if settings.pollSeconds != oldValue.pollSeconds { retryAllNow() }
            for index in feeds.indices where isEnabled(feeds[index].id) != oldValue.isEnabled(feeds[index].id) {
                // Newly switched on: try at once rather than waiting out an old backoff.
                feeds[index].failures = 0
                feeds[index].nextFetchAt = Date()
            }
        }
    }

    /// Data older than this dims the glyph.
    static let staleAfter: TimeInterval = 15 * 60
    /// Manual refreshes, popover open or the Refresh button, are spaced at least this far apart.
    static let manualSpacing: TimeInterval = 30
    static let backoffCap: TimeInterval = 30 * 60

    let calendar = Calendar.autoupdatingCurrent
    private var tickTimer: Timer?
    private var pollTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init(providers: [UsageProvider], settings: AppSettings = .load()) {
        self.feeds = providers.map(ProviderFeed.init(provider:))
        self.settings = settings
    }

    // MARK: - Feeds

    func isEnabled(_ providerID: String) -> Bool { settings.isEnabled(providerID) }

    /// Enabled providers, in the order they were registered.
    var activeFeeds: [ProviderFeed] { feeds.filter { isEnabled($0.id) } }

    func feed(_ providerID: String) -> ProviderFeed? { feeds.first { $0.id == providerID } }

    /// The feed whose account anchors things that can only have one answer, like the week
    /// reset shown in settings: the first enabled one.
    var anchorFeed: ProviderFeed? { activeFeeds.first { $0.snapshot != nil } ?? activeFeeds.first }

    // MARK: - Lifecycle

    func start() {
        // The tick moves with the clock even when nothing is fetched.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        // Cheap heartbeat; the real cadence is each feed's `nextFetchAt`.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollIfDue() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.retryAllNow()
                self?.pollIfDue()
            }
        }
        retryAllNow()
        pollIfDue()
    }

    private func retryAllNow() {
        for index in feeds.indices {
            feeds[index].failures = 0
            feeds[index].nextFetchAt = Date()
        }
    }

    private func pollIfDue() {
        for feed in feeds where isEnabled(feed.id) && !feed.inFlight {
            guard let due = feed.nextFetchAt, Date() >= due else { continue }
            let id = feed.id
            Task { await refresh(id) }
        }
    }

    /// User-initiated. Per feed, skipped when an attempt ran under 30 s ago, or while that
    /// provider's rate limit is still in force.
    func refreshManually() {
        for feed in feeds where isEnabled(feed.id) {
            if let last = feed.lastAttempt, Date().timeIntervalSince(last) < Self.manualSpacing { continue }
            if case .rateLimited = feed.lastError, let due = feed.nextFetchAt, Date() < due { continue }
            let id = feed.id
            Task { await refresh(id) }
        }
    }

    func refreshAll() async {
        for feed in feeds where isEnabled(feed.id) {
            await refresh(feed.id)
        }
    }

    func refresh(_ providerID: String) async {
        guard let index = feeds.firstIndex(where: { $0.id == providerID }),
              isEnabled(providerID), !feeds[index].inFlight else { return }
        let provider = feeds[index].provider
        feeds[index].inFlight = true
        feeds[index].lastAttempt = Date()
        let base = TimeInterval(max(15, settings.pollSeconds))
        // Cleared here rather than on each path, so no exit can strand the feed mid-flight.
        defer {
            if let i = feeds.firstIndex(where: { $0.id == providerID }) { feeds[i].inFlight = false }
            now = Date()
        }
        do {
            let snapshot = try await provider.fetch()
            guard let index = feeds.firstIndex(where: { $0.id == providerID }) else { return }
            feeds[index].snapshot = snapshot
            feeds[index].lastError = nil
            feeds[index].failures = 0
            feeds[index].nextFetchAt = Date().addingTimeInterval(base)
        } catch {
            guard let index = feeds.firstIndex(where: { $0.id == providerID }) else { return }
            let providerError = (error as? ProviderError) ?? .transport(error.localizedDescription)
            feeds[index].lastError = providerError
            feeds[index].failures += 1
            var retryAfter: TimeInterval?
            if case .rateLimited(let r) = providerError { retryAfter = r }
            let delay = Backoff.delay(failures: feeds[index].failures, base: base,
                                      cap: Self.backoffCap, retryAfter: retryAfter)
            feeds[index].nextFetchAt = Date().addingTimeInterval(delay)
        }
    }

    // MARK: - Aggregate state

    var hasData: Bool { activeFeeds.contains { $0.snapshot != nil } }

    /// True with no data at all, or when every enabled provider's data has gone stale.
    var isStale: Bool {
        let withData = activeFeeds.compactMap(\.snapshot)
        guard !withData.isEmpty else { return true }
        return withData.allSatisfy { now.timeIntervalSince($0.fetchedAt) > Self.staleAfter }
    }

    var staleSince: Date? {
        guard isStale else { return nil }
        return activeFeeds.compactMap { $0.snapshot?.fetchedAt }.max()
    }

    /// Every enabled provider is signed out or missing its CLI.
    var isLoggedOut: Bool {
        let active = activeFeeds
        return !active.isEmpty && active.allSatisfy(\.isLoggedOut)
    }

    /// One line per unhappy provider, named when more than one is enabled. Nil when all is well.
    var statusLine: String? {
        let lines = activeFeeds.compactMap { feed -> String? in
            guard let text = status(for: feed) else { return nil }
            return activeFeeds.count > 1 ? "\(feed.displayName): \(text)" : text
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The trouble with one provider, or nil when its last fetch succeeded.
    func status(for feed: ProviderFeed) -> String? {
        guard let error = feed.lastError else { return nil }
        let next = feed.nextFetchAt.map { "next try \(Fmt.clock($0, now: now, calendar: calendar))" } ?? ""
        let age = feed.snapshot.map { "showing data from \(Fmt.clock($0.fetchedAt, now: now, calendar: calendar))" } ?? "no data yet"
        let signIn = feed.id == "codex" ? "run codex to sign in" : "open Claude Code"
        switch error {
        case .rateLimited: return "usage API rate limited · \(age) · \(next)"
        case .tokenExpired: return "token expired · \(age) · \(signIn) to refresh it"
        case .notLoggedIn: return "not logged in · \(signIn)"
        case .unavailable(let what): return "\(what) · install it or turn this provider off"
        case .http(let code): return "usage API error \(code) · \(age) · \(next)"
        case .badResponse(let why): return "unexpected response · \(why) · \(next)"
        case .transport: return "offline · \(age) · \(next)"
        }
    }

    // MARK: - Week window

    /// The reset instant a provider's week bar is built around: that account's, or the next
    /// custom weekday and time, which is shared by every provider.
    func weekWindowEnd(for feed: ProviderFeed?) -> Date? {
        if settings.weekStart.useAccount { return feed?.snapshot?.weekly?.resetsAt }
        let c = settings.weekStart
        let components = DateComponents(hour: c.hour, minute: c.minute, weekday: c.weekday)
        return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime)
    }

    func weekLayout(for feed: ProviderFeed?) -> WeekLayout? {
        guard let end = weekWindowEnd(for: feed) else { return nil }
        return WeekLayout.make(windowEnd: end, schedule: settings.schedule, calendar: calendar)
    }

    /// The billing cycle cut into the same working-day blocks a week gets. The month bar
    /// groups them by week; the Codex "Week" row is this same layout windowed to the week
    /// holding `now`, so both rows are views of one fetched number.
    func monthLayout(for feed: ProviderFeed?) -> WeekLayout? {
        guard let meter = feed?.snapshot?.monthly,
              let end = meter.resetsAt, let start = meter.windowStart else { return nil }
        return WeekLayout.make(windowStart: start, windowEnd: end,
                               schedule: settings.schedule, calendar: calendar)
    }

    /// For the settings sheet, which shows a single reset: the anchor provider's.
    func weekWindowEnd() -> Date? { weekWindowEnd(for: anchorFeed) }
}
