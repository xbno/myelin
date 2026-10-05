import Foundation
import PaceCore

/// One block of a bar: its share of the budget and, for the popover, its day letter.
struct BlockSpec: Equatable {
    let share: Double
    let letter: String?
}

/// A billing cycle laid out as a calendar: one cell per working day, weeks as rows,
/// weekdays as columns. `lower`/`upper` are where a day sits along the cycle, 0…1 of its
/// working hours — the same axis the linear bar's fill and tick are measured on, so a cell
/// is filled by re-expressing the cycle's used and tick percentages inside it.
struct MonthGrid: Equatable {
    struct Cell: Equatable {
        let lower: Double
        let upper: Double
    }
    /// Day letters in week order; a column per working weekday.
    let columns: [String]
    /// One row per week of the cycle. nil where the cycle does not cover that weekday —
    /// the days before it starts and after it ends.
    let rows: [[Cell?]]
}

/// Everything a row needs to be drawn, in the menu bar or the popover. No AppKit.
struct RowModel: Identifiable {
    enum Style {
        case session, week, model
        /// A billing-cycle allowance, one block per week of the cycle.
        case month
        /// That same allowance windowed to the week holding now — the month bar's current
        /// block, zoomed, so it can be read beside Claude's week in the menu bar.
        case monthWeek
    }
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
    /// "250 of 1000 credits" — what the percent is a percent of, when the provider counts
    /// in something the user recognises.
    var note: String? = nil
    /// Set on a month row: the popover draws the cycle as a calendar instead of a bar. The
    /// menu bar has no room for that and uses `blocks` — the same cycle, one block per week.
    var grid: MonthGrid? = nil
    /// Weekday columns the window does not reach, before and after its blocks. A cycle
    /// starting on a Tuesday leaves Monday absent in its first week. Drawn as dots, so a
    /// short week reads as short instead of as a stretched full one. Always at the edges:
    /// a window is contiguous, so it can only fall short at its start or its end.
    var absentLeading: Int = 0
    var absentTrailing: Int = 0
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
        let snapshot = feed.snapshot?.asOf(now)
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
                fills: active ? Fill.pace(used: percent, tick: sessionTick ?? 0,
                                          exhausted: sessionMeter.locked) : [],
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

        // Week: one block per working day, tick at working time elapsed. A provider that
        // reports an allowance and no weekly window gets the month rows below instead of an
        // empty Week row that could never fill.
        let monthLayout = store.monthLayout(for: feed)
        let monthMeter = snapshot?.monthly
        if let monthMeter, let monthLayout, snapshot?.weekly == nil {
            out += monthRows(feed: feed, meter: monthMeter, layout: monthLayout,
                             now: now, band: band, calendar: store.calendar)
            return out + modelRows(feed: feed, snapshot: snapshot, settings: settings,
                                   blocks: weekBlocks, tick: weekTick, layout: layout,
                                   now: now, band: band)
        }
        let weekMeter = snapshot?.weekly
        let weekPercent = weekMeter?.percent ?? 0
        let weekActive = weekMeter != nil && layout != nil
        let (weekText, weekShort) = weekLabel(feed.id)
        out.append(RowModel(
            id: "\(feed.id)-week", providerID: feed.id, providerName: feed.displayName,
            label: weekText, shortLabel: weekShort, style: .week,
            blocks: weekBlocks,
            fills: weekActive ? Fill.pace(used: weekPercent, tick: weekTick ?? 0,
                                          exhausted: weekMeter?.locked ?? false) : [],
            tick: weekTick, unit: "1d", percent: weekPercent,
            state: weekActive ? Verdict.state(used: weekPercent, tick: weekTick ?? 0, band: band) : nil,
            solidColorHex: nil,
            elapsed: layout.map { now.timeIntervalSince($0.windowStart) },
            remaining: layout.map { $0.windowEnd.timeIntervalSince(now) },
            resetsAt: layout?.windowEnd, active: weekActive, locked: weekMeter?.locked ?? false))

        // Models: same blocks as the week, single color, no tick. For Codex these are the
        // extra limit buckets, which behave the same way — a weekly pool with its own percent.
        return out + modelRows(feed: feed, snapshot: snapshot, settings: settings,
                               blocks: weekBlocks, tick: weekTick, layout: layout,
                               now: now, band: band)
    }

    @MainActor private static func modelRows(
        feed: ProviderFeed, snapshot: UsageSnapshot?, settings: AppSettings,
        blocks weekBlocks: [BlockSpec], tick weekTick: Double?, layout: WeekLayout?,
        now: Date, band: Double
    ) -> [RowModel] {
        var out: [RowModel] = []
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
                blocks: weekBlocks, fills: Fill.solid(used: meter.percent, exhausted: meter.locked),
                tick: nil, unit: nil,
                percent: meter.percent,
                state: weekTick.map { Verdict.state(used: meter.percent, tick: $0, band: band) },
                solidColorHex: settings.modelColor(name),
                elapsed: nil, remaining: layout.map { $0.windowEnd.timeIntervalSince(now) },
                resetsAt: layout?.windowEnd, active: true, locked: meter.locked)
        }
        return out
    }

    /// The allowance as two views of one number: the whole cycle in week blocks, and the
    /// block holding `now` on its own. Nothing here is measured over time — the week row is
    /// the month's used and tick percentages re-expressed against that week's slice of the
    /// cycle, which is why it needs no history and no weekly limit from the provider.
    @MainActor private static func monthRows(
        feed: ProviderFeed, meter: Meter, layout: WeekLayout,
        now: Date, band: Double, calendar: Calendar
    ) -> [RowModel] {
        let weeks = weekSlices(of: layout, calendar: calendar)
        guard !weeks.isEmpty else { return [] }
        let columns = orderedWeekdays(weeks: weeks, calendar: calendar)
        let used = meter.percent
        let tick = layout.tick(at: now)

        var out: [RowModel] = []

        // The current week, zoomed: the same bar clipped to one slice and re-normalised.
        if let index = weeks.firstIndex(where: { now >= $0.start && now < $0.end })
            ?? weeks.indices.last {
            let slice = weeks[index]
            let span = slice.upper - slice.lower
            func local(_ value: Double) -> Double {
                guard span > 0 else { return 0 }
                return min(100, max(0, 100 * (value / 100 - slice.lower) / span))
            }
            let total = slice.days.reduce(0.0) { $0 + $1.share }
            let blocks = slice.days.map {
                BlockSpec(share: total > 0 ? $0.share / total : 0, letter: dayLetters[$0.weekday - 1])
            }
            // Which weekday columns this week never reaches — Monday in a cycle that
            // starts on a Tuesday, Thursday and Friday in one ending on a Wednesday.
            let present = Set(slice.days.map(\.weekday))
            let lead = columns.prefix { !present.contains($0) }.count
            let trail = columns.reversed().prefix { !present.contains($0) }.count
            let localUsed = local(used), localTick = local(tick)
            out.append(RowModel(
                id: "\(feed.id)-month-week", providerID: feed.id, providerName: feed.displayName,
                label: "Week", shortLabel: "W", style: .monthWeek,
                blocks: blocks.isEmpty ? fiveBlocks : blocks,
                fills: Fill.pace(used: localUsed, tick: localTick, exhausted: meter.locked),
                tick: localTick, unit: "1d", percent: localUsed,
                state: Verdict.state(used: localUsed, tick: localTick, band: band),
                solidColorHex: nil,
                elapsed: now.timeIntervalSince(slice.start),
                remaining: slice.end.timeIntervalSince(now),
                resetsAt: slice.end, active: true, locked: meter.locked,
                absentLeading: lead, absentTrailing: trail))
        }

        out.append(RowModel(
            id: "\(feed.id)-month", providerID: feed.id, providerName: feed.displayName,
            label: "Month", shortLabel: "M", style: .month,
            blocks: weeks.enumerated().map { BlockSpec(share: $0.element.upper - $0.element.lower,
                                                       letter: "W\($0.offset + 1)") },
            fills: Fill.pace(used: used, tick: tick, exhausted: meter.locked),
            tick: tick, unit: "1w", percent: used,
            state: Verdict.state(used: used, tick: tick, band: band),
            solidColorHex: nil,
            elapsed: now.timeIntervalSince(layout.windowStart),
            remaining: layout.windowEnd.timeIntervalSince(now),
            resetsAt: layout.windowEnd, active: true, locked: meter.locked, note: meter.note,
            grid: grid(weeks: weeks, columns: columns)))
        return out
    }

    /// The same weeks as a calendar: a column per working weekday, a row per week, and a
    /// gap wherever the cycle does not reach that day.
    private static func grid(
        weeks: [(start: Date, end: Date, lower: Double, upper: Double, days: [DayBlock])],
        columns ordered: [Int]
    ) -> MonthGrid? {
        guard !ordered.isEmpty else { return nil }
        var rows: [[MonthGrid.Cell?]] = []
        for week in weeks {
            var cursor = week.lower
            var byWeekday: [Int: MonthGrid.Cell] = [:]
            for day in week.days {
                byWeekday[day.weekday] = MonthGrid.Cell(lower: cursor, upper: cursor + day.share)
                cursor += day.share
            }
            rows.append(ordered.map { byWeekday[$0] })
        }
        return MonthGrid(columns: ordered.map { dayLetters[$0 - 1] }, rows: rows)
    }

    /// Every weekday the cycle works, in week order from the calendar's own first day so
    /// Sunday-first locales line up. These are the calendar's columns.
    private static func orderedWeekdays(
        weeks: [(start: Date, end: Date, lower: Double, upper: Double, days: [DayBlock])],
        calendar: Calendar
    ) -> [Int] {
        let weekdays = Set(weeks.flatMap { $0.days.map(\.weekday) })
        return (0..<7)
            .map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
            .filter { weekdays.contains($0) }
    }

    /// The cycle's working days grouped into calendar weeks. `lower`/`upper` are where each
    /// week begins and ends along the cycle, 0…1 of its working hours — the axis both the
    /// fill and the tick are measured on.
    private static func weekSlices(of layout: WeekLayout, calendar: Calendar)
        -> [(start: Date, end: Date, lower: Double, upper: Double, days: [DayBlock])] {
        var out: [(start: Date, end: Date, lower: Double, upper: Double, days: [DayBlock])] = []
        var cursor = 0.0
        for day in layout.blocks {
            let week = calendar.dateInterval(of: .weekOfYear, for: day.start)
            let start = week?.start ?? day.start
            let end = week?.end ?? day.end
            if var last = out.last, last.start == start {
                last.upper += day.share
                last.days.append(day)
                out[out.count - 1] = last
            } else {
                out.append((start: start, end: end, lower: cursor,
                            upper: cursor + day.share, days: [day]))
            }
            cursor += day.share
        }
        return out
    }
}
