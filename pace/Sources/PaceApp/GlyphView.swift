import SwiftUI
import PaceCore

/// The menu bar glyph: the mark, then Sess / Week / model rows as 50×6 pt bars.
/// About 94×20 pt with the mark and word labels. A second provider's column is led by
/// its own mark, so the rows there say which window they are, not who they belong to.
struct GlyphView: View {
    let rows: [RowModel]
    let settings: AppSettings
    let ink: Color
    let hoursLeft: String?
    let dimmed: Bool
    /// Off-phase of the over-budget blink; true keeps the red bar red.
    var blinkOn: Bool = true

    private var labelWidth: CGFloat { settings.labelStyle == .words ? 22 : 7 }

    /// With a mark leading the Codex column, "Codex" next to the Codex mark would say it
    /// twice — so the row just names its window, as the Claude rows do. With marks switched
    /// off the provider-specific labels come back, because then nothing else tells the two
    /// columns apart.
    private func label(_ row: RowModel) -> String {
        let words = settings.labelStyle == .words
        guard settings.showMark, row.providerID == "codex", row.style != .model else {
            return words ? row.label : row.shortLabel
        }
        switch row.style {
        case .session: return words ? "Sess" : "S"
        default: return words ? "Week" : "W"
        }
    }

    /// Rows grouped by provider, in the order they arrive. Two providers stacked would be
    /// five rows tall — more than the menu bar gives us — so they sit side by side instead,
    /// which costs width the bar has and keeps each column at its original height.
    private var columns: [(id: String, rows: [RowModel])] {
        var order: [String] = []
        var grouped: [String: [RowModel]] = [:]
        for row in rows {
            if grouped[row.providerID] == nil { order.append(row.providerID) }
            grouped[row.providerID, default: []].append(row)
        }
        return order.map { (id: $0, rows: grouped[$0] ?? []) }
    }

    var body: some View {
        let palette = Palette(settings: settings, ink: ink)
        HStack(spacing: 6) {
            if settings.showMark {
                ClawdMark(color: Color(hex: AppSettings.claudeOrange))
            }
            ForEach(columns, id: \.id) { column in
                HStack(spacing: 3) {
                    if settings.showMark, column.id == "codex" {
                        // Sized to the Clawd mark opposite it. In the 6 pt label slot the
                        // prompt inside it would be four pixels of mush; out here it reads.
                        CodexMark(color: ink, unit: 0.85)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(column.rows) { row in
                            HStack(spacing: 2) {
                                Text(label(row))
                                    .font(.system(size: 6, weight: .semibold))
                                    .foregroundColor(ink.opacity(row.active ? 0.8 : 0.4))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                    .frame(width: labelWidth, height: 6, alignment: .leading)
                                BarView(blocks: row.blocks, fills: row.fills, tick: row.tick, unit: row.unit,
                                        solid: row.solidColorHex.map { Color(hex: $0) }, palette: palette, blinkOn: blinkOn,
                                        hatched: settings.barStyle == .hatched)
                            }
                        }
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
        let manyProviders = Set(rows.map(\.providerID)).count > 1
        for r in rows {
            let name: String
            switch r.style {
            case .session: name = "Session"
            case .week: name = "Week"
            case .model: name = r.label
            }
            var parts = [manyProviders ? "\(r.providerName) \(name)" : name]
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
