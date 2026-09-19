import SwiftUI
import PaceCore

/// What opens on click: USAGE (each provider's Session and Week) and MODELS groups with
/// vertical words in the gutter. With one provider on, it reads exactly as it always did;
/// with two, each block of rows is headed by the account it belongs to.
struct PopoverView: View {
    @ObservedObject var store: UsageStore
    let openSettings: () -> Void
    let close: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
        .frame(width: 360)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let palette = Palette(settings: store.settings, ink: .primary)
        let feeds = store.activeFeeds
        let perFeed = feeds.map { (feed: $0, rows: RowBuilder.rows(for: $0, store: store)) }
        let modelGroups = perFeed
            .map { (feed: $0.feed, rows: $0.rows.filter { $0.style == .model }) }
            .filter { !$0.rows.isEmpty }
        let many = feeds.count > 1
        VStack(alignment: .leading, spacing: 0) {
            header
            if store.hasData, let status = store.statusLine {
                Text(status).font(.system(size: 10)).foregroundColor(.secondary)
                    .lineLimit(3).padding(.bottom, 6)
            }
            GutterGroup("usage") {
                if feeds.isEmpty {
                    Text("no providers switched on — see Settings")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                ForEach(perFeed, id: \.feed.id) { entry in
                    usageSection(entry.feed, rows: entry.rows, now: now, palette: palette, named: many)
                }
            }
            Divider().padding(.vertical, 6)
            GutterGroup("models") {
                HStack(spacing: 6) {
                    Text("WEEKLY").font(.system(size: 10, weight: .bold)).kerning(0.6).foregroundColor(.secondary)
                    Text("resets with Week").font(.system(size: 11)).foregroundColor(.secondary)
                }
                if modelGroups.isEmpty {
                    Text("no per-model limits on this plan").font(.system(size: 11)).foregroundColor(.secondary).padding(.top, 2)
                }
                // Grouped by account, like usage above, so each row keeps its own short name.
                ForEach(modelGroups, id: \.feed.id) { entry in
                    if many {
                        Text(entry.feed.displayName.uppercased())
                            .font(.system(size: 10, weight: .bold)).kerning(0.6).foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                    ForEach(entry.rows) { m in meterRow(m, palette: palette, letters: true) }
                }
            }
            footer
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .font(.system(size: 12))
    }

    /// One provider's Session and Week, headed by its name once a second provider is on.
    @ViewBuilder
    private func usageSection(_ feed: ProviderFeed, rows: [RowModel], now: Date,
                              palette: Palette, named: Bool) -> some View {
        let session = rows.first { $0.style == .session }
        let week = rows.first { $0.style == .week }
        VStack(alignment: .leading, spacing: 0) {
            if named {
                HStack(spacing: 5) {
                    Text(feed.displayName.uppercased())
                        .font(.system(size: 10, weight: .bold)).kerning(0.6)
                    if let plan = feed.snapshot?.plan {
                        Text(plan).font(.system(size: 10))
                    }
                }
                .foregroundColor(.secondary)
                .padding(.top, 4)
            }
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
            if feed.snapshot == nil { statusNote(feed) }
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

    private func statusNote(_ feed: ProviderFeed) -> some View {
        Text(store.status(for: feed) ?? "Loading…")
            .font(.system(size: 11)).foregroundColor(.secondary).padding(.top, 4)
    }

    private func sectionLine(_ title: String, _ r: RowModel, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).kerning(0.6).foregroundColor(.secondary)
            if r.active, let e = r.elapsed, let rem = r.remaining, let reset = r.resetsAt {
                (Text("\(Fmt.duration(e)) elapsed").bold()
                 + Text(" · ")
                 + Text("\(Fmt.duration(rem)) remaining").bold()
                 + Text(" · resets \(Fmt.clock(reset, now: now, calendar: store.calendar))"))
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
