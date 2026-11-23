import SwiftUI

/// A smooth rendering of the reference mark on its original 12 × 10 grid.
struct AntigravityMark: View {
    private static let pixels = [
        "FF8E00 FF8E00 FF8E00 FF8E00 FF8E00 FF8E00 FF6200 FF6200 FF6200 FF6200 FF6200 FF6200",
        "FBC300 FBC300 FBC300 FBC300 FBC300 FF8600 FF5400 FF3000 FF3000 FF3000 FF3000 FF3000",
        "BCE700 BCE700 BCE700 BCE700 E0D700 FF9100 FF6800 FF5F00 FF2500 FF2500 FF2500 FF2500",
        "7DEC00 7DEC00 7DEC00 7DEC00 4ED900 EF8E00 FF5B00 FE2C00 FC0005 FC0005 FC0005 FC0005",
        "7CE500 7CE500 7CE500 4AE700 00D18C 0080DC 2D00DC 0400E6 8F00CE BF00B4 BF00B4 BF00B4",
        "6FEB00 6FEB00 6FEB00 00DE59 0087FF 0087FF 0059FF 0059FF 0500F6 6100DE 6100DE 6100DE",
        "00E90C 00E90C 00E90C 00D8CB 00D8CB 00D8CB 0056FF 0056FF 0056FF 0020FF 0020FF 0020FF",
        "00EC4F 00EC4F 00AEFD 00AAFC 00AAFC 00AAFC 0055FF 0055FF 0055FF 0059FF 002DFF 002DFF",
        "00ED86 00ED86 008AFF 008AFF 008AFF 008AFF 0063FF 0063FF 0063FF 0063FF 0056FF 0056FF",
        "0092FF 008AFF 008AFF 008AFF 008AFF 008AFF 0061FF 0061FF 0061FF 0061FF 0061FF 0061FF",
    ].map { $0.split(separator: " ").map { Color(hex: String($0)) } }

    var body: some View {
        Canvas { context, size in
            let scale = size.width / 14
            context.scaleBy(x: scale, y: scale)
            var mark = Path()
            mark.move(to: CGPoint(x: 1, y: 11))
            mark.addQuadCurve(to: CGPoint(x: 3.1, y: 6.3), control: CGPoint(x: 2.3, y: 9.6))
            mark.addQuadCurve(to: CGPoint(x: 6.3, y: 1.2), control: CGPoint(x: 4.1, y: 2.3))
            mark.addQuadCurve(to: CGPoint(x: 7.8, y: 1.4), control: CGPoint(x: 7, y: 0.7))
            mark.addQuadCurve(to: CGPoint(x: 10.8, y: 6.5), control: CGPoint(x: 10, y: 3.2))
            mark.addQuadCurve(to: CGPoint(x: 13, y: 11), control: CGPoint(x: 11.7, y: 9.8))
            mark.addLine(to: CGPoint(x: 11.4, y: 11))
            mark.addQuadCurve(to: CGPoint(x: 8.6, y: 7.1), control: CGPoint(x: 10, y: 9.8))
            mark.addQuadCurve(to: CGPoint(x: 5.4, y: 7.1), control: CGPoint(x: 7, y: 4.8))
            mark.addQuadCurve(to: CGPoint(x: 2.6, y: 11), control: CGPoint(x: 4, y: 9.8))
            mark.closeSubpath()

            var interior = context
            interior.clip(to: mark)
            for (y, row) in Self.pixels.enumerated() {
                for (x, color) in row.enumerated() {
                    let pixel = CGRect(x: x + 1, y: y + 1, width: 1, height: 1)
                    interior.fill(Path(pixel), with: .color(color), style: FillStyle(antialiased: false))
                }
            }
            context.stroke(mark, with: .color(.white),
                           style: StrokeStyle(lineWidth: 0.1 / scale, lineJoin: .round))
        }
        .frame(width: 16, height: 12 * 16 / 14.0)
    }
}
