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
    let label: String        // Sess / Week / Fable
    let shortLabel: String   // S / W / F
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

    @MainActor static func rows(store: UsageStore) -> [RowModel] {
        let now = store.now
        let settings = store.settings
        let band = settings.schedule.onPaceBand
        let layout = store.weekLayout()
        let weekBlocks = layout.map { $0.blocks.map { BlockSpec(share: $0.share, letter: dayLetters[$0.weekday - 1]) } } ?? fiveBlocks
        let weekTick = layout?.tick(at: now)

        // Session: five one-hour blocks, tick at elapsed time.
        let sessionMeter = store.snapshot?.session
        let sessionTick = sessionMeter.flatMap { SessionPace.tick(meter: $0, now: now) }
        let sessionActive = sessionMeter?.resetsAt != nil
        let sessionPercent = sessionMeter?.percent ?? 0
        let session = RowModel(
            id: "session", label: "Sess", shortLabel: "S", style: .session,
            blocks: fiveBlocks,
            fills: sessionActive ? Fill.pace(used: sessionPercent, tick: sessionTick ?? 0) : [],
            tick: sessionTick, unit: "1h", percent: sessionPercent,
            state: sessionActive ? Verdict.state(used: sessionPercent, tick: sessionTick ?? 0, band: band) : nil,
            solidColorHex: nil,
            elapsed: sessionMeter?.windowStart.map { now.timeIntervalSince($0) },
            remaining: sessionMeter?.resetsAt.map { $0.timeIntervalSince(now) },
            resetsAt: sessionMeter?.resetsAt, active: sessionActive, locked: sessionMeter?.locked ?? false)

        // Week: one block per working day, tick at working time elapsed.
        let weekMeter = store.snapshot?.weekly
        let weekPercent = weekMeter?.percent ?? 0
        let weekActive = weekMeter != nil && layout != nil
        let week = RowModel(
            id: "week", label: "Week", shortLabel: "W", style: .week,
            blocks: weekBlocks,
            fills: weekActive ? Fill.pace(used: weekPercent, tick: weekTick ?? 0) : [],
            tick: weekTick, unit: "1d", percent: weekPercent,
            state: weekActive ? Verdict.state(used: weekPercent, tick: weekTick ?? 0, band: band) : nil,
            solidColorHex: nil,
            elapsed: layout.map { now.timeIntervalSince($0.windowStart) },
            remaining: layout.map { $0.windowEnd.timeIntervalSince(now) },
            resetsAt: layout?.windowEnd, active: weekActive, locked: weekMeter?.locked ?? false)

        // Models: same blocks as the week, single color, no tick.
        var models = store.snapshot?.models ?? []
        switch settings.modelRows.mode {
        case .all:
            break
        case .mostConstrained:
            let tick = weekTick ?? 0
            if let worst = models.max(by: { ($0.percent - tick) < ($1.percent - tick) }) { models = [worst] }
        case .fixed:
            models = models.filter { $0.modelName == settings.modelRows.fixedName }
        }
        let modelRows = models.map { meter -> RowModel in
            let name = meter.modelName ?? "Model"
            return RowModel(
                id: "model-\(name)", label: name, shortLabel: String(name.prefix(1)), style: .model,
                blocks: weekBlocks, fills: Fill.solid(used: meter.percent), tick: nil, unit: nil, percent: meter.percent,
                state: weekTick.map { Verdict.state(used: meter.percent, tick: $0, band: band) },
                solidColorHex: settings.modelColor(name),
                elapsed: nil, remaining: layout.map { $0.windowEnd.timeIntervalSince(now) },
                resetsAt: layout?.windowEnd, active: true, locked: meter.locked)
        }
        return [session, week] + modelRows
    }
}
