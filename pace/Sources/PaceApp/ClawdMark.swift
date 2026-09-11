import SwiftUI

/// The Claude Code mark on a 16×10 pixel grid, traced from the artwork.
struct ClawdMark: View {
    var color: Color
    var unit: CGFloat = 1.2

    static let cells: [(x: Int, y: Int, w: Int, h: Int)] = [
        (2, 0, 12, 2),                                   // head
        (2, 2, 2, 2), (5, 2, 6, 2), (12, 2, 2, 2),       // eye row, eyes are the gaps
        (0, 4, 16, 2),                                   // arms
        (2, 6, 12, 2),                                   // body
        (3, 8, 1, 2), (5, 8, 1, 2), (10, 8, 1, 2), (12, 8, 1, 2), // legs
    ]

    var body: some View {
        Canvas { context, _ in
            for c in Self.cells {
                let rect = CGRect(x: CGFloat(c.x) * unit, y: CGFloat(c.y) * unit,
                                  width: CGFloat(c.w) * unit, height: CGFloat(c.h) * unit)
                context.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: 16 * unit, height: 10 * unit)
    }
}
