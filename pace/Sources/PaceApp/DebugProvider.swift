import Foundation
import PaceCore

/// Fake provider for manual checks, no network. Launch with
/// `PACE_DEBUG_STATE=sample .build/debug/PaceApp`; states: sample, nosession, stale,
/// loggedout, locked, allowance.
struct DebugProvider: UsageProvider {
    let id = "debug"
    let displayName = "Claude"
    let state: String

    static func fromEnvironment() -> DebugProvider? {
        guard let s = ProcessInfo.processInfo.environment["PACE_DEBUG_STATE"], !s.isEmpty else { return nil }
        return DebugProvider(state: s)
    }

    func fetch() async throws -> UsageSnapshot {
        let calendar = Calendar.current
        let reset = calendar.nextDate(after: Date(), matching: DateComponents(hour: 17, minute: 0, weekday: 6), matchingPolicy: .nextTime)!
        let week = 7.0 * 86400
        let five = 5.0 * 3600
        let sessionReset = Date().addingTimeInterval(3 * 3600 + 39 * 60)
        switch state {
        case "nosession":
            return UsageSnapshot(fetchedAt: Date(), plan: "Team", meters: [
                Meter(kind: .session, percent: 0, resetsAt: nil, windowLength: five),
                Meter(kind: .weekly, percent: 46, resetsAt: reset, windowLength: week),
                Meter(kind: .weeklyModel(name: "Fable"), percent: 28, resetsAt: reset, windowLength: week),
            ])
        case "stale":
            throw ProviderError.transport("debug: network down")
        case "loggedout":
            throw ProviderError.notLoggedIn
        case "allowance":
            // A billing-cycle plan whose cycle ENDS mid-week, so the current week is a
            // partial one and the absent-day dots are on screen without waiting for the
            // calendar to reach a month boundary.
            let endsWednesday = calendar.nextDate(
                after: Date(), matching: DateComponents(hour: 20, minute: 0, weekday: 4),
                matchingPolicy: .nextTime)!
            return UsageSnapshot(fetchedAt: Date(), plan: "Business", meters: [
                Meter(kind: .monthly, percent: 25, resetsAt: endsWednesday,
                      windowLength: 22 * 86400, note: "250 of 1000 credits"),
            ])
        case "locked":
            return UsageSnapshot(fetchedAt: Date(), plan: "Team", meters: [
                Meter(kind: .session, percent: 41, resetsAt: sessionReset, windowLength: five),
                Meter(kind: .weekly, percent: 100, resetsAt: reset, windowLength: week, locked: true),
                Meter(kind: .weeklyModel(name: "Fable"), percent: 28, resetsAt: reset, windowLength: week),
            ])
        default: // "sample": the mockup numbers
            return UsageSnapshot(fetchedAt: Date(), plan: "Team", meters: [
                Meter(kind: .session, percent: 41, resetsAt: sessionReset, windowLength: five),
                Meter(kind: .weekly, percent: 46, resetsAt: reset, windowLength: week),
                Meter(kind: .weeklyModel(name: "Fable"), percent: 28, resetsAt: reset, windowLength: week),
            ])
        }
    }
}
