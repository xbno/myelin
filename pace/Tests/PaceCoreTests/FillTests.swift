import Testing
@testable import PaceCore

@Suite struct FillTests {
    @Test func overGivesUsedThenOver() {
        #expect(Fill.pace(used: 46, tick: 34) == [
            FillRange(from: 0, to: 34, color: .used),
            FillRange(from: 34, to: 46, color: .over),
        ])
    }

    @Test func underGivesUsedThenUnspent() {
        #expect(Fill.pace(used: 28, tick: 34) == [
            FillRange(from: 0, to: 28, color: .used),
            FillRange(from: 28, to: 34, color: .unspent),
        ])
    }

    @Test func equalGivesUsedOnly() {
        #expect(Fill.pace(used: 40, tick: 40) == [FillRange(from: 0, to: 40, color: .used)])
    }

    @Test func zeroGivesNothing() {
        #expect(Fill.pace(used: 0, tick: 0).isEmpty)
    }

    @Test func usageBeforeTheWeekStartsIsAllOver() {
        #expect(Fill.pace(used: 5, tick: 0) == [FillRange(from: 0, to: 5, color: .over)])
    }

    @Test func clampsAbove100() {
        #expect(Fill.pace(used: 130, tick: 50) == [
            FillRange(from: 0, to: 50, color: .used),
            FillRange(from: 50, to: 100, color: .over),
        ])
    }

    @Test func solid() {
        #expect(Fill.solid(used: 28) == [FillRange(from: 0, to: 28, color: .solid)])
        #expect(Fill.solid(used: 0).isEmpty)
    }

    @Test func verdictBand() {
        #expect(Verdict.state(used: 39, tick: 34, band: 5) == .onPace)
        #expect(Verdict.state(used: 40, tick: 34, band: 5) == .over(6))
        #expect(Verdict.state(used: 25, tick: 34, band: 5) == .under(9))
        #expect(Verdict.state(used: 34.4, tick: 34, band: 0) == .onPace)
    }

    @Test func verdictText() {
        #expect(Verdict.text(.onPace) == "on pace")
        #expect(Verdict.text(.over(9)) == "+9 over")
        #expect(Verdict.text(.under(9)) == "\u{2212}9 under")
    }
}
