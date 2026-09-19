import SwiftUI
import PaceCore

/// Blocks with rounded corners, clipped multi-color fills, an optional unit label in the
/// first block, optional day letters above, and a tick at a percent position.
struct BarView: View {
    let blocks: [BlockSpec]
    let fills: [FillRange]
    let tick: Double?
    let unit: String?
    let solid: Color?
    let palette: Palette
    /// While false, `.over` (red) fills draw as `.unspent` (yellow) instead — the blink's off-phase.
    var blinkOn: Bool = true
    var width: CGFloat = 50
    var height: CGFloat = 6
    var gap: CGFloat = 1
    var letters = false
    var letterSize: CGFloat = 8.5
    var unitSize: CGFloat = 5
    var tickWidth: CGFloat = 1.2
    var trackOpacity: Double = 0.45
    var trackColor: Color? = nil
    var unitEmptyColor: Color? = nil
    var hatchSpacing: CGFloat = 2.5
    var hatchLineWidth: CGFloat = 0.9
    /// False paints the track and the unspent span as flat tint instead of hatching.
    var hatched: Bool = true

    private var letterBand: CGFloat { letters ? letterSize + 1.5 : 0 }

    /// The two regions that are not flat color — the unused ("track") part of a block and
    /// the unspent-but-not-yet-due part — are painted through here, so `hatched` switches both.
    private func paint(_ context: GraphicsContext, in shape: Path, rect: CGRect, color: Color) {
        guard hatched else {
            context.fill(shape, with: .color(color))
            return
        }
        drawHatch(context, in: shape, rect: rect, color: color)
    }

    /// 45° diagonal lines. Breaking these into dashes reads as a dot grid at menu bar
    /// size, so the lines stay unbroken.
    private func drawHatch(_ context: GraphicsContext, in shape: Path, rect: CGRect, color: Color) {
        var clipped = context
        clipped.clip(to: shape)
        var lines = Path()
        var x = -rect.height
        while x < rect.width {
            lines.move(to: CGPoint(x: rect.minX + x, y: rect.maxY))
            lines.addLine(to: CGPoint(x: rect.minX + x + rect.height, y: rect.minY))
            x += hatchSpacing
        }
        clipped.stroke(lines, with: .color(color), lineWidth: hatchLineWidth)
    }

    private struct BlockGeometry {
        let x: CGFloat
        let width: CGFloat
        let lo: Double
        let hi: Double
    }

    private var geometry: [BlockGeometry] {
        let n = blocks.count
        guard n > 0 else { return [] }
        let usable = width - gap * CGFloat(n - 1)
        var out: [BlockGeometry] = []
        var x: CGFloat = 0
        var lo = 0.0
        for b in blocks {
            let w = usable * CGFloat(b.share)
            let hi = lo + b.share * 100
            out.append(BlockGeometry(x: x, width: w, lo: lo, hi: hi))
            x += w + gap
            lo = hi
        }
        return out
    }

    var body: some View {
        Canvas { context, _ in
            let top = letterBand
            let radius = min(1.5, height / 3)
            let track = (trackColor ?? palette.ink).opacity(trackOpacity)
            let geo = geometry
            guard !geo.isEmpty else {
                let rect = CGRect(x: 0, y: top, width: width, height: height)
                paint(context, in: Path(roundedRect: rect, cornerRadius: radius), rect: rect, color: track)
                return
            }
            for (i, g) in geo.enumerated() {
                let rect = CGRect(x: g.x, y: top, width: g.width, height: height)
                let shape = Path(roundedRect: rect, cornerRadius: radius)
                paint(context, in: shape, rect: rect, color: track)

                var inner = context
                inner.clip(to: shape)
                var covered = 0.0
                let span = max(1e-9, g.hi - g.lo)
                for f in fills {
                    let a = max(f.from, g.lo)
                    let b = min(f.to, g.hi)
                    guard b > a + 1e-9 else { continue }
                    covered += (b - a) / span
                    let fx = g.x + g.width * CGFloat((a - g.lo) / span)
                    let fw = g.width * CGFloat((b - a) / span)
                    let fillRect = CGRect(x: fx, y: top, width: fw, height: height)
                    if f.color == .unspent {
                        paint(inner, in: Path(fillRect), rect: fillRect, color: palette.unspent)
                    } else {
                        let color = (f.color == .over && !blinkOn) ? palette.unspent : palette.color(for: f.color, solid: solid)
                        inner.fill(Path(fillRect), with: .color(color))
                    }
                }
                if i == 0, let unit {
                    let color = covered >= 0.5 ? Color.white : (unitEmptyColor ?? palette.ink.opacity(0.85))
                    context.draw(Text(unit).font(.system(size: unitSize, weight: .bold)).foregroundColor(color),
                                 at: CGPoint(x: g.x + g.width / 2, y: top + height / 2))
                }
                if letters, let letter = blocks[i].letter {
                    context.draw(Text(letter).font(.system(size: letterSize, weight: .semibold)).foregroundColor(palette.ink.opacity(0.7)),
                                 at: CGPoint(x: g.x + g.width / 2, y: letterSize / 2))
                }
            }
            if let t = tick {
                let px: CGFloat
                if let g = geo.first(where: { t >= $0.lo && t <= $0.hi }) {
                    px = g.x + g.width * CGFloat((t - g.lo) / max(1e-9, g.hi - g.lo))
                } else {
                    px = t <= 0 ? 0 : width
                }
                var line = Path()
                line.move(to: CGPoint(x: px, y: top - 2.5))
                line.addLine(to: CGPoint(x: px, y: top + height + 2.5))
                context.stroke(line, with: .color(palette.ink), lineWidth: tickWidth)
            }
        }
        .frame(width: width, height: height + letterBand)
    }
}
