import Foundation

/// When the user works. Weekdays use Calendar numbering: 1 = Sunday … 7 = Saturday.
public struct Schedule: Equatable, Codable {
    public var workingWeekdays: Set<Int>
    public var startHour: Int
    public var endHour: Int
    public var onPaceBand: Double

    public init(workingWeekdays: Set<Int> = [2, 3, 4, 5, 6], startHour: Int = 9, endHour: Int = 17, onPaceBand: Double = 5) {
        self.workingWeekdays = workingWeekdays
        self.startHour = startHour
        self.endHour = endHour
        self.onPaceBand = onPaceBand
    }

    public var includesWeekends: Bool {
        get { workingWeekdays.contains(1) && workingWeekdays.contains(7) }
        set {
            if newValue { workingWeekdays.formUnion([1, 7]) } else { workingWeekdays.subtract([1, 7]) }
        }
    }
}

/// One working day inside the weekly window, clipped to the window.
public struct DayBlock: Equatable {
    public let weekday: Int
    public let start: Date
    public let end: Date
    /// Fraction of the budget this day holds, 0…1. Proportional to its working hours.
    public internal(set) var share: Double

    public var hours: Double { end.timeIntervalSince(start) / 3600 }
}

/// The weekly window cut into working-day blocks. `windowEnd` is the reset instant.
public struct WeekLayout: Equatable {
    public let windowStart: Date
    public let windowEnd: Date
    public let blocks: [DayBlock]

    public var totalWorkingHours: Double { blocks.reduce(0) { $0 + $1.hours } }

    public static func make(windowEnd: Date, schedule: Schedule, calendar: Calendar) -> WeekLayout {
        let windowStart = windowEnd.addingTimeInterval(-7 * 86400)
        var blocks: [DayBlock] = []
        var day = calendar.startOfDay(for: windowStart)
        while day < windowEnd {
            let weekday = calendar.component(.weekday, from: day)
            if schedule.workingWeekdays.contains(weekday),
               let workStart = calendar.date(bySettingHour: schedule.startHour, minute: 0, second: 0, of: day),
               let workEnd = schedule.endHour >= 24
                    ? calendar.date(byAdding: .day, value: 1, to: day)
                    : calendar.date(bySettingHour: schedule.endHour, minute: 0, second: 0, of: day) {
                let start = max(workStart, windowStart)
                let end = min(workEnd, windowEnd)
                if end > start {
                    blocks.append(DayBlock(weekday: weekday, start: start, end: end, share: 0))
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        let total = blocks.reduce(0) { $0 + $1.hours }
        if total > 0 {
            for i in blocks.indices { blocks[i].share = blocks[i].hours / total }
        }
        return WeekLayout(windowStart: windowStart, windowEnd: windowEnd, blocks: blocks)
    }

    /// Percent of working time elapsed at `now`, 0…100. Moves only during working hours,
    /// so it is frozen overnight and, with weekends off, all weekend.
    /// Falls back to the wall-clock fraction when the schedule has no working hours at all.
    public func tick(at now: Date) -> Double {
        if now >= windowEnd { return 100 }
        if now <= windowStart { return 0 }
        let total = totalWorkingHours
        guard total > 0 else {
            return 100 * now.timeIntervalSince(windowStart) / windowEnd.timeIntervalSince(windowStart)
        }
        let elapsed = blocks.reduce(0.0) { acc, block in
            acc + max(0, min(now, block.end).timeIntervalSince(block.start)) / 3600
        }
        return min(100, max(0, 100 * elapsed / total))
    }
}

public enum SessionPace {
    /// Percent of the session window elapsed, or nil when no session is active.
    public static func tick(meter: Meter, now: Date) -> Double? {
        guard let start = meter.windowStart, let end = meter.resetsAt, end > start else { return nil }
        return min(100, max(0, 100 * now.timeIntervalSince(start) / end.timeIntervalSince(start)))
    }
}
