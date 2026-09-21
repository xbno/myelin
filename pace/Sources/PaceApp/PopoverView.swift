import SwiftUI
import PaceCore

/// What opens on click. With one provider on it reads exactly as it always did: a USAGE
/// group and a MODELS group, each marked by a vertical word in the gutter. With two, a
/// second gutter goes outside those and names the account, so the rails read
/// CLAUDE → USAGE and CODEX → USAGE. A provider only grows a MODELS rail if it reports
/// per-model limits, which Codex does not.
struct PopoverView: View {
    @ObservedObject var store: UsageStore
    let openSettings: () -> Void
    let close: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
        // The provider gutter costs 20 pt, so the rows keep the column widths DESIGN.md
        // fixed instead of being squeezed. Without that gutter the old width is right.
        .frame(width: store.activeFeeds.count > 1 ? 384 : 360)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let palette = Palette(settings: store.settings, ink: .primary)
        let feeds = store.activeFeeds
        let perFeed = feeds.map { (feed: $0, rows: RowBuilder.rows(for: $0, store: store)) }
        let many = feeds.count > 1
        VStack(alignment: .leading, spacing: 0) {
            header
            if feeds.isEmpty {
                Text("no providers switched on — see Settings")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            ForEach(Array(perFeed.enumerated()), id: \.element.feed.id) { index, entry in
                if index > 0 { Divider().padding(.vertical, 7) }
                providerBlock(entry.feed, rows: entry.rows, now: now, palette: palette, named: many)
            }
            footer
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .font(.system(size: 12))
    }

    /// One account: its USAGE rail, then a MODELS rail only where per-model limits exist.
    /// `named` puts the whole block inside a second gutter carrying the provider's name —
    /// which is why the block itself no longer repeats that name as a heading.
    @ViewBuilder
    private func providerBlock(_ feed: ProviderFeed, rows: [RowModel], now: Date,
                               palette: Palette, named: Bool) -> some View {
        let models = rows.filter { $0.style == .model }
        let block = VStack(alignment: .leading, spacing: 0) {
            if named, let plan = feed.snapshot?.plan {
                Text(plan).font(.system(size: 10)).foregroundColor(.secondary).padding(.bottom, 3)
            }
            GutterGroup("usage") {
                usageSection(feed, rows: rows, now: now, palette: palette)
            }
            // Alone, the MODELS rail stays even when empty, as it always has. Sharing the
            // popover, it appears only where it means something, so Codex — which reports
            // no per-model limits — doesn't grow an empty rail.
            if !models.isEmpty || !named {
                Divider().padding(.vertical, 6)
                GutterGroup("models") {
                    HStack(spacing: 6) {
                        Text("WEEKLY").font(.system(size: 10, weight: .bold)).kerning(0.6).foregroundColor(.secondary)
                        Text("resets with Week").font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    if models.isEmpty {
                        Text("no per-model limits on this plan").font(.system(size: 11)).foregroundColor(.secondary).padding(.top, 2)
                    }
                    ForEach(models) { m in meterRow(m, palette: palette, letters: true) }
                }
            }
        }
        if named {
            GutterGroup(feed.displayName) { block }
        } else {
            block
        }
    }

    /// One provider's Session and Week, plus whatever is wrong with it.
    @ViewBuilder
    private func usageSection(_ feed: ProviderFeed, rows: [RowModel], now: Date,
                              palette: Palette) -> some View {
        let session = rows.first { $0.style == .session }
        let week = rows.first { $0.style == .week }
        // The whole cycle, in week blocks. Its current block is what the menu bar zooms
        // into as a Week row; here that week is simply visible inside the month, under
        // the tick, so the popover shows the month once rather than twice.
        let month = rows.first { $0.style == .month }
        VStack(alignment: .leading, spacing: 0) {
            if let s = session {
                sectionLine("Session", s, now: now)
                meterRow(s, palette: palette, letters: false)
                caption("one hour per block", legend: true, palette: palette)
            }
            if let w = week {
                sectionLine("Week", w, now: now).padding(.top, session == nil ? 0 : 6)
                meterRow(w, palette: palette, letters: true)
                caption("one working day per block · tick = now, \(Fmt.clock(now, now: now, calendar: store.calendar))",
                        legend: false, palette: palette)
            }
            if let m = month {
                sectionLine("Month", m, now: now).padding(.top, session == nil && week == nil ? 0 : 6)
                if let grid = m.grid {
                    monthRow(m, grid: grid, palette: palette)
                    caption("one working day per cell · tick = now, \(Fmt.clock(now, now: now, calendar: store.calendar))",
                            legend: false, palette: palette)
                } else {
                    meterRow(m, palette: palette, letters: true)
                    caption("one working week per block · tick = now, \(Fmt.clock(now, now: now, calendar: store.calendar))",
                            legend: false, palette: palette)
                }
                if let note = m.note { caption(note, legend: false, palette: palette) }
            }
            // Sits with the rows it explains. It used to be repeated verbatim as an
            // aggregate line under the header, which is where the doubled "Codex CLI not
            // found" came from; that line is gone, so this one also covers a provider
            // that still has a stale snapshot on screen.
            if let note = store.status(for: feed) {
                Text(note).font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
        }
    }

    private var header: some View {
        let feeds = store.activeFeeds
        let newest = feeds.compactMap { $0.snapshot?.fetchedAt }.max()
        let title = feeds.count == 1
            ? feeds[0].displayName + (feeds[0].snapshot?.plan.map { " · \($0)" } ?? "")
            : "Pace"
        return HStack(spacing: 6) {
            ClawdMark(color: Color(hex: AppSettings.claudeOrange), unit: 1.1)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)))
            Spacer()
            Text(newest.map { "updated \(Fmt.ago(store.now.timeIntervalSince($0)))" } ?? "no data yet")
                .font(.system(size: 10)).foregroundColor(.secondary)
            Button(action: openSettings) {
                Image(systemName: "gearshape").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundColor(.secondary)
            .help("Settings")
        }
        .padding(.bottom, 8)
    }

    private func sectionLine(_ title: String, _ r: RowModel, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).kerning(0.6).foregroundColor(.secondary)
            if r.active, let e = r.elapsed, let rem = r.remaining, let reset = r.resetsAt {
                // A billing cycle runs in days, where "480h" and a bare weekday both stop
                // meaning anything.
                let long = r.style == .month
                (Text("\(long ? Fmt.longSpan(e) : Fmt.duration(e)) elapsed").bold()
                 + Text(" · ")
                 + Text("\(long ? Fmt.longSpan(rem) : Fmt.duration(rem)) remaining").bold()
                 + Text(" · resets \(long ? Fmt.dayClock(reset, calendar: store.calendar) : Fmt.clock(reset, now: now, calendar: store.calendar))"))
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .lineLimit(1)
            } else if r.style == .session {
                Text("no active session").font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
        .padding(.bottom, 2)
    }

    /// Rows sit under a heading that names the account, so the label is just the window.
    private func meterRow(_ r: RowModel, palette: Palette, letters: Bool) -> some View {
        let label: String
        switch r.style {
        case .session: label = "Session"
        case .week: label = "Week"
        case .month, .monthWeek: label = r.label
        case .model: label = r.label
        }
        return HStack(alignment: .bottom, spacing: 4) {
            Text(label).lineLimit(1).minimumScaleFactor(0.75).frame(width: 60, alignment: .leading)
            BarView(blocks: r.blocks, fills: r.fills, tick: r.tick, unit: r.unit,
                    solid: r.solidColorHex.map { Color(hex: $0) }, palette: palette,
                    width: 130, height: 9, gap: 2, letters: letters, letterSize: 8.5, unitSize: 7, tickWidth: 1.5,
                    trackOpacity: 0.22,
                    trackColor: r.style == .model ? r.solidColorHex.map { Color(hex: $0) } : nil,
                    unitEmptyColor: .secondary,
                    hatched: store.settings.barStyle == .hatched)
            Text("\(Int(r.percent.rounded()))%").bold().monospacedDigit().lineLimit(1).frame(width: 40, alignment: .trailing)
            verdict(r, palette: palette).lineLimit(1).minimumScaleFactor(0.85).frame(width: 74, alignment: .leading)
        }
        .padding(.vertical, 3)
    }

    /// The cycle as a calendar. Same columns as every other row — name, mark, percent,
    /// verdict — so it lines up with the bars above it; only the mark is taller.
    private func monthRow(_ r: RowModel, grid: MonthGrid, palette: Palette) -> some View {
        HStack(alignment: .center, spacing: 4) {
            Text(r.label).lineLimit(1).frame(width: 60, alignment: .leading)
            MonthGridView(grid: grid, used: r.percent, tick: r.tick ?? 0, palette: palette,
                          exhausted: r.locked,
                          width: 130, hatched: store.settings.barStyle == .hatched)
            Text("\(Int(r.percent.rounded()))%").bold().monospacedDigit()
                .lineLimit(1).frame(width: 40, alignment: .trailing)
            verdict(r, palette: palette).lineLimit(1).minimumScaleFactor(0.85)
                .frame(width: 74, alignment: .leading)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func verdict(_ r: RowModel, palette: Palette) -> some View {
        if r.locked {
            Label("locked", systemImage: "lock.fill")
                .font(.system(size: 11, weight: .semibold)).foregroundColor(palette.over)
        } else if let s = r.state {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(palette.swatchColor(s)).frame(width: 7, height: 7)
                Text(Verdict.text(s))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(palette.verdictColor(s, onLightSurface: true))
            }
        } else if r.style == .session {
            Text("\(100 - Int(r.percent.rounded())) left").font(.system(size: 11)).foregroundColor(.secondary)
        }
    }

    private func caption(_ text: String, legend: Bool, palette: Palette) -> some View {
        HStack(spacing: 4) {
            Spacer().frame(width: 64)
            Text(text).font(.system(size: 9)).foregroundColor(.secondary)
            if legend {
                Text("·").font(.system(size: 9)).foregroundColor(.secondary)
                swatch(palette.used, "used")
                swatch(palette.unspent, "unspent")
                swatch(palette.over, "over")
            }
        }
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 2) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button("Settings…", action: openSettings).buttonStyle(.plain).foregroundColor(.accentColor)
            Button("Refresh") { store.refreshManually() }.buttonStyle(.plain).foregroundColor(.secondary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain).foregroundColor(.secondary)
        }
        .font(.system(size: 11))
        .padding(.top, 7)
        .overlay(alignment: .top) { Divider() }
        .padding(.top, 8)
    }
}

/// A section with a vertical word in the left gutter.
private struct GutterGroup<Content: View>: View {
    let word: String
    let content: Content

    init(_ word: String, @ViewBuilder content: () -> Content) {
        self.word = word
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(word.uppercased())
                .font(.system(size: 8.5, weight: .bold)).kerning(1.2).foregroundColor(.secondary)
                .fixedSize()
                .rotationEffect(.degrees(-90))
                .frame(width: 14)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 2) }
            VStack(alignment: .leading, spacing: 0) { content }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
