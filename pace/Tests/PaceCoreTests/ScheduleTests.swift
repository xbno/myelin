import Foundation
import Testing
@testable import PaceCore

/// All dates in America/New_York, Geoff's zone. The account's week resets Fri 5:00 pm.
@Suite struct ScheduleTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    func d(_ y: Int, _ mo: Int, _ day: Int, _ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: day, hour: h, minute: mi))!
    }
    /// Fri 2026-09-11 5:00 pm ET; the window opens Fri 09-04 5:00 pm.
    var reset: Date { d(2026, 9, 11, 17) }
    func near(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool { abs(a - b) < eps }

    @Test func fiveEqualBlocksMonToFri() {
        let w = WeekLayout.make(windowEnd: reset, schedule: Schedule(), calendar: cal)
        #expect(w.blocks.count == 5)
        #expect(w.blocks.map(\.weekday) == [2, 3, 4, 5, 6])
        #expect(near(w.totalWorkingHours, 40))
        for b in w.blocks {
            #expect(near(b.share, 0.2))
            #expect(near(b.hours, 8))
        }
        #expect(w.blocks.first?.start == d(2026, 9, 7, 9))
        #expect(w.blocks.last?.end == d(2026, 9, 11, 17))
    }

    @Test func sevenBlocksWithWeekends() {
        var s = Schedule()
        s.includesWeekends = true
        let w = WeekLayout.make(windowEnd: reset, schedule: s, calendar: cal)
        #expect(w.blocks.count == 7)
        #expect(w.blocks.first?.weekday == 7) // Sat 09-05
        #expect(w.blocks.last?.weekday == 6)  // Fri 09-11
        #expect(near(w.blocks[0].share, 1.0 / 7))
    }

    @Test func resetInsideWorkingHoursMakesPartialEdgeBlocks() {
        let w = WeekLayout.make(windowEnd: d(2026, 9, 9, 14), schedule: Schedule(), calendar: cal)
        #expect(w.blocks.count == 6)
        #expect(near(w.blocks.first!.hours, 3))   // Wed 09-02, 2 to 5 pm
        #expect(near(w.blocks.last!.hours, 5))    // Wed 09-09, 9 am to 2 pm
        #expect(near(w.totalWorkingHours, 40))
        #expect(near(w.blocks.first!.share, 0.075))
        #expect(near(w.blocks.last!.share, 0.125))
    }

    @Test func weekTickIsPureWorkingTime() {
        let w = WeekLayout.make(windowEnd: reset, schedule: Schedule(), calendar: cal)
        #expect(near(w.tick(at: d(2026, 9, 5, 12)), 0))              // Saturday, frozen
        #expect(near(w.tick(at: d(2026, 9, 7, 9)), 0))               // Monday 9 am
        #expect(near(w.tick(at: d(2026, 9, 7, 20)), 20))             // Monday night
        #expect(near(w.tick(at: d(2026, 9, 8, 14, 52)), 100 * (8 + 5 + 52.0 / 60) / 40))
        #expect(near(w.tick(at: d(2026, 9, 11, 17)), 100))
        #expect(near(w.tick(at: d(2026, 9, 12, 9)), 100))            // after the reset
    }

    @Test func noWorkingHoursFallsBackToLinear() {
        let s = Schedule(workingWeekdays: [], startHour: 9, endHour: 17)
        let w = WeekLayout.make(windowEnd: reset, schedule: s, calendar: cal)
        #expect(w.blocks.isEmpty)
        #expect(near(w.tick(at: reset.addingTimeInterval(-3.5 * 86400)), 50))
    }

    @Test func sessionTick() {
        let m = Meter(kind: .session, percent: 41, resetsAt: reset, windowLength: 5 * 3600)
        #expect(near(SessionPace.tick(meter: m, now: reset.addingTimeInterval(-(3 * 3600 + 39 * 60)))!, 27))
        #expect(SessionPace.tick(meter: m, now: reset.addingTimeInterval(60)) == 100)
        let inactive = Meter(kind: .session, percent: 0, resetsAt: nil, windowLength: 5 * 3600)
        #expect(SessionPace.tick(meter: inactive, now: reset) == nil)
    }
}
