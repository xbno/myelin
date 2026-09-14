import SwiftUI
import PaceCore

/// The menu bar glyph: the mark, then Sess / Week / model rows as 50×6 pt bars.
/// About 94×20 pt with the mark and word labels.
struct GlyphView: View {
    let rows: [RowModel]
    let settings: AppSettings
    let ink: Color
    let hoursLeft: String?
    let dimmed: Bool
    /// Off-phase of the over-budget blink; true keeps the red bar red.
    var blinkOn: Bool = true

    private var labelWidth: CGFloat { settings.labelStyle == .words ? 19 : 7 }

    var body: some View {
        let palette = Palette(settings: settings, ink: ink)
        HStack(spacing: 4) {
            if settings.showMark {
                ClawdMark(color: Color(hex: AppSettings.claudeOrange))
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(rows) { row in
                    HStack(spacing: 2) {
                        Text(settings.labelStyle == .words ? row.label : row.shortLabel)
                            .font(.system(size: 6, weight: .semibold))
                            .foregroundColor(ink.opacity(row.active ? 0.8 : 0.4))
                            .lineLimit(1)
                            .frame(width: labelWidth, height: 6, alignment: .leading)
                        BarView(blocks: row.blocks, fills: row.fills, tick: row.tick, unit: row.unit,
                                solid: row.solidColorHex.map { Color(hex: $0) }, palette: palette, blinkOn: blinkOn)
                    }
                }
            }
            if let hoursLeft {
                Text(hoursLeft)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(ink)
            }
        }
        .padding(.horizontal, 2)
        .opacity(dimmed ? 0.5 : 1)
        .fixedSize()
    }
}

enum Tooltip {
    @MainActor static func text(rows: [RowModel], store: UsageStore) -> String {
        var lines: [String] = []
        for r in rows {
            var parts = [r.label == "Sess" ? "Session" : r.label]
            if r.style == .session, !r.active {
                parts.append("no active session")
            }
            if r.active, r.style != .model, let e = r.elapsed, let rem = r.remaining {
                parts.append("\(Fmt.duration(e)) elapsed")
                parts.append("\(Fmt.duration(rem)) remaining")
            }
            if r.style == .model {
                parts.append("\(Int(r.percent.rounded()))% used")
                parts.append("resets with Week")
            } else if let reset = r.resetsAt, r.active {
                parts.append("resets \(Fmt.clock(reset, now: store.now, calendar: store.calendar))")
            }
            if r.locked { parts.append("locked") } else if let s = r.state { parts.append(Verdict.text(s)) }
            lines.append(parts.joined(separator: " · "))
        }
        if let status = store.statusLine { lines.append(status) }
        return lines.joined(separator: "\n")
    }
}
