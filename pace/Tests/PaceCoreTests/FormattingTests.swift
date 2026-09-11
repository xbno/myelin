import Foundation
import Testing
@testable import PaceCore

@Suite struct FormattingTests {
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()
    func d(_ y: Int, _ mo: Int, _ day: Int, _ h: Int, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: day, hour: h, minute: mi))!
    }

    @Test func duration() {
        #expect(Fmt.duration(74.13 * 3600) == "74h")
        #expect(Fmt.duration(3 * 3600 + 39 * 60) == "3h 39m")
        #expect(Fmt.duration(39 * 60) == "39m")
        #expect(Fmt.duration(9 * 3600 + 59 * 60 + 40) == "10h")
        #expect(Fmt.duration(20) == "1m")
        #expect(Fmt.duration(0) == "0m")
    }

    @Test func hoursOnly() {
        #expect(Fmt.hoursOnly(74.13 * 3600) == "74h")
        #expect(Fmt.hoursOnly(3 * 3600 + 39 * 60) == "4h")
        #expect(Fmt.hoursOnly(39 * 60) == "39m")
    }

    @Test func clock() {
        let now = d(2026, 9, 8, 14, 52)
        #expect(Fmt.clock(d(2026, 9, 11, 17), now: now, calendar: cal) == "Fri 5:00 pm")
        #expect(Fmt.clock(d(2026, 9, 8, 18, 31), now: now, calendar: cal) == "6:31 pm")
    }

    @Test func ago() {
        #expect(Fmt.ago(12) == "12 s ago")
        #expect(Fmt.ago(190) == "3 min ago")
        #expect(Fmt.ago(7300) == "2 h ago")
    }
}
