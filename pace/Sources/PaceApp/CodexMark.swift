import SwiftUI

/// The Codex mark on a 14×14 grid: a lobed outline around a `>_` prompt.
///
/// Traced by eye, not from the vector artwork. At the size the gutter uses it, each lobe is
/// well under a point across, so a polar wobble reads the same as the original and costs a
/// few lines instead of an imported asset. Monochrome, like the Clawd mark beside it — the
/// caller picks the ink so it follows the popover between light and dark.
struct CodexMark: View {
    var color: Color
    var unit: CGFloat = 1

    private static let lobes: CGFloat = 8
    private static let radius: CGFloat = 5.6
    private static let wobble: CGFloat = 0.33

    var body: some View {
        Canvas { context, size in
            let mid = CGPoint(x: size.width / 2, y: size.height / 2)
            var cloud = Path()
            let steps = 240
            for step in 0...steps {
                let angle = 2 * CGFloat.pi * CGFloat(step) / CGFloat(steps)
                let r = (Self.radius + Self.wobble * cos(Self.lobes * angle)) * unit
                let point = CGPoint(x: mid.x + r * cos(angle), y: mid.y + r * sin(angle))
                if step == 0 { cloud.move(to: point) } else { cloud.addLine(to: point) }
            }
            cloud.closeSubpath()
            context.stroke(cloud, with: .color(color),
                           style: StrokeStyle(lineWidth: 1.2 * unit, lineJoin: .round))

            var prompt = Path()
            prompt.move(to: CGPoint(x: 5.0 * unit, y: 5.2 * unit))
            prompt.addLine(to: CGPoint(x: 7.2 * unit, y: 7.0 * unit))
            prompt.addLine(to: CGPoint(x: 5.0 * unit, y: 8.8 * unit))
            prompt.move(to: CGPoint(x: 8.0 * unit, y: 8.9 * unit))
            prompt.addLine(to: CGPoint(x: 9.9 * unit, y: 8.9 * unit))
            context.stroke(prompt, with: .color(color),
                           style: StrokeStyle(lineWidth: 1.25 * unit, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 14 * unit, height: 14 * unit)
    }
}
