import Foundation
import PaceCore

/// One block of a bar: its share of the budget and, for the popover, its day letter.
struct BlockSpec: Equatable {
    let share: Double
    let letter: String?
}

/// Everything a row needs to be drawn, in the menu bar or the popover. No AppKit.
struct RowModel: Identifiable {
    enum Style { case session, week, model }
    let id: String
    let providerID: String   // anthropic / codex
    let providerName: String
    let label: String        // Sess / Week / Codex / Fable
    let shortLabel: String   // S / W / X / F
    let style: Style
    let blocks: [BlockSpec]
    let fills: [FillRange]
    let tick: Double?
    let unit: String?
    let percent: Double
    let state: PaceState?
    let solidColorHex: String?
    let elapsed: TimeInterval?
    let remaining: TimeInterval?
    let resetsAt: Date?
    let active: Bool
    let locked: Bool
}

enum RowBuilder {
    static let dayLetters = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
    static let fiveBlocks = Array(repeating: BlockSpec(share: 0.2, letter: nil), count: 5)

    /// Labels stay fixed per provider rather than shifting when the other one is toggled,
    /// so a glance at the same row always means the same thing.
    static func sessionLabel(_ providerID: String) -> (String, String) {
        providerID == "codex" ? ("Cdx5h", "x") : ("Sess", "S")
    }

    static func weekLabel(_ providerID: String) -> (String, String) {
        providerID == "codex" ? ("Codex", "X") : ("Week", "W")
    }

    @MainActor static func rows(store: UsageStore) -> [RowModel] {
        store.activeFeeds.flatMap { rows(for: $0, store: store) }
    }

    @MainActor static func rows(for feed: ProviderFeed, store: UsageStore) -> [RowModel] {
        let now = store.now
        let settings = store.settings
        let band = settings.schedule.onPaceBand
        // Each provider's week is anchored on its own reset instant, so two accounts whose
        // weeks end on different days each get a bar that means something.
        let layout = store.weekLayout(for: feed)
        let weekBlocks = layout.map { $0.blocks.map { BlockSpec(share: $0.share, letter: dayLetters[$0.weekday - 1]) } } ?? fiveBlocks
        let weekTick = layout?.tick(at: now)
        let snapshot = feed.snapshot
        var out: [RowModel] = []

        // Session: five one-hour blocks, tick at elapsed time. Only when the plan has one —
        // Codex plans that report a weekly window alone get no session row at all.
        if let sessionMeter = snapshot?.session {
            let sessionTick = SessionPace.tick(meter: sessionMeter, now: now)
            let active = sessionMeter.resetsAt != nil
            let percent = sessionMeter.percent
            let (label, short) = sessionLabel(feed.id)
            out.append(RowModel(
                id: "\(feed.id)-session", providerID: feed.id, providerName: feed.displayName,
                label: label, shortLabel: short, style: .session,
                blocks: fiveBlocks,
                fills: active ? Fill.pace(used: percent, tick: sessionTick ?? 0) : [],
                tick: sessionTick, unit: "1h", percent: percent,
                state: active ? Verdict.state(used: percent, tick: sessionTick ?? 0, band: band) : nil,
                solidColorHex: nil,
                elapsed: sessionMeter.windowStart.map { now.timeIntervalSince($0) },
                remaining: sessionMeter.resetsAt.map { $0.timeIntervalSince(now) },
                resetsAt: sessionMeter.resetsAt, active: active, locked: sessionMeter.locked))
        } else if feed.id != "codex" {
            // Claude always shows the row, empty, because a session starts the moment you use it.
            let (label, short) = sessionLabel(feed.id)
            out.append(RowModel(
                id: "\(feed.id)-session", providerID: feed.id, providerName: feed.displayName,
                label: label, shortLabel: short, style: .session,
                blocks: fiveBlocks, fills: [], tick: nil, unit: "1h", percent: 0,
                state: nil, solidColorHex: nil, elapsed: nil, remaining: nil,
                resetsAt: nil, active: false, locked: false))
        }

        // Week: one block per working day, tick at working time elapsed.
        let weekMeter = snapshot?.weekly
        let weekPercent = weekMeter?.percent ?? 0
        let weekActive = weekMeter != nil && layout != nil
        let (weekText, weekShort) = weekLabel(feed.id)
        out.append(RowModel(
            id: "\(feed.id)-week", providerID: feed.id, providerName: feed.displayName,
            label: weekText, shortLabel: weekShort, style: .week,
            blocks: weekBlocks,
            fills: weekActive ? Fill.pace(used: weekPercent, tick: weekTick ?? 0) : [],
            tick: weekTick, unit: "1d", percent: weekPercent,
            state: weekActive ? Verdict.state(used: weekPercent, tick: weekTick ?? 0, band: band) : nil,
            solidColorHex: nil,
            elapsed: layout.map { now.timeIntervalSince($0.windowStart) },
            remaining: layout.map { $0.windowEnd.timeIntervalSince(now) },
            resetsAt: layout?.windowEnd, active: weekActive, locked: weekMeter?.locked ?? false))

        // Models: same blocks as the week, single color, no tick. For Codex these are the
        // extra limit buckets, which behave the same way — a weekly pool with its own percent.
        var models = snapshot?.models ?? []
        switch settings.modelRows.mode {
        case .all:
            break
        case .mostConstrained:
            let tick = weekTick ?? 0
            if let worst = models.max(by: { ($0.percent - tick) < ($1.percent - tick) }) { models = [worst] }
        case .fixed:
            models = models.filter { $0.modelName == settings.modelRows.fixedName }
        }
        out += models.map { meter -> RowModel in
            let name = meter.modelName ?? "Model"
            return RowModel(
                id: "\(feed.id)-model-\(name)", providerID: feed.id, providerName: feed.displayName,
                label: name, shortLabel: String(name.prefix(1)), style: .model,
                blocks: weekBlocks, fills: Fill.solid(used: meter.percent), tick: nil, unit: nil,
                percent: meter.percent,
                state: weekTick.map { Verdict.state(used: meter.percent, tick: $0, band: band) },
                solidColorHex: settings.modelColor(name),
                elapsed: nil, remaining: layout.map { $0.windowEnd.timeIntervalSince(now) },
                resetsAt: layout?.windowEnd, active: true, locked: meter.locked)
        }
        return out
    }
}
