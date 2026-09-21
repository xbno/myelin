import SwiftUI
import PaceCore

/// A billing cycle drawn as a calendar: a column per working weekday, a row per week, one
/// cell per working day.
///
/// Every cell is a one-block `BarView`, so the palette, hatching, corner radius and tick are
/// the ones the linear bars already use — a cell is not a new kind of mark, it is the same
/// bar over a shorter span. The cycle's used and tick percentages are re-expressed inside
/// each cell, which is what makes the calendar and the linear month bar two views of one
/// number rather than two measurements.
struct MonthGridView: View {
    let grid: MonthGrid
    let used: Double
    let tick: Double
    let palette: Palette
    var width: CGFloat = 130
    var cellHeight: CGFloat = 7
    var gap: CGFloat = 2
    var hatched: Bool = true

    private var cellWidth: CGFloat {
        let n = CGFloat(max(1, grid.columns.count))
        return (width - gap * (n - 1)) / n
    }

    /// Where `percent` of the whole cycle falls inside this one day, 0…100.
    private func local(_ percent: Double, _ cell: MonthGrid.Cell) -> Double {
        let span = cell.upper - cell.lower
        guard span > 0 else { return 0 }
        return min(100, max(0, 100 * (percent / 100 - cell.lower) / span))
    }

    /// Only the day holding now carries the tick, as only one block does in a bar.
    private func holdsNow(_ cell: MonthGrid.Cell) -> Bool {
        let t = tick / 100
        return t >= cell.lower && t < cell.upper
    }

    var body: some View {
        VStack(alignment: .leading, spacing: gap) {
            HStack(spacing: gap) {
                ForEach(Array(grid.columns.enumerated()), id: \.offset) { _, letter in
                    Text(letter)
                        .font(.system(size: 7.5))
                        .foregroundColor(.secondary)
                        .frame(width: cellWidth)
                }
            }
            ForEach(Array(grid.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: gap) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        if let cell {
                            BarView(blocks: [BlockSpec(share: 1, letter: nil)],
                                    fills: Fill.pace(used: local(used, cell), tick: local(tick, cell)),
                                    tick: holdsNow(cell) ? local(tick, cell) : nil,
                                    unit: nil, solid: nil, palette: palette,
                                    width: cellWidth, height: cellHeight, gap: 0,
                                    tickWidth: 1.2, trackOpacity: 0.22, hatched: hatched)
                        } else {
                            Color.clear.frame(width: cellWidth, height: cellHeight)
                        }
                    }
                }
            }
        }
    }
}
