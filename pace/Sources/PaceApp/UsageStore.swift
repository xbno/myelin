import AppKit
import Combine
import PaceCore

/// Owns the latest snapshot, the settings, and the clocks that drive re-rendering.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var lastError: ProviderError?
    @Published private(set) var staleSince: Date?
    @Published private(set) var now = Date()
    @Published var settings: AppSettings {
        didSet {
            settings.save()
            if settings.pollSeconds != oldValue.pollSeconds || settings.providerEnabled != oldValue.providerEnabled {
                restartPolling()
            }
        }
    }

    let provider: UsageProvider
    let calendar = Calendar.autoupdatingCurrent
    private var pollTimer: Timer?
    private var tickTimer: Timer?
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
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        restartPolling()
        Task { await refresh() }
    }

    private func restartPolling() {
        pollTimer?.invalidate()
        guard settings.providerEnabled else { return }
        let interval = TimeInterval(max(15, settings.pollSeconds))
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        guard settings.providerEnabled else { return }
        do {
            let fresh = try await provider.fetch()
            snapshot = fresh
            lastError = nil
            staleSince = nil
        } catch let error as ProviderError {
            lastError = error
            if staleSince == nil { staleSince = Date() }
        } catch {
            lastError = .transport(error.localizedDescription)
            if staleSince == nil { staleSince = Date() }
        }
        now = Date()
    }

    var isStale: Bool { staleSince != nil }
    var isLoggedOut: Bool { snapshot == nil && (lastError == .notLoggedIn || lastError == .tokenExpired) }

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
