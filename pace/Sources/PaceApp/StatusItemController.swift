import AppKit
import Combine
import SwiftUI
import PaceCore

/// Owns the status item. Renders the SwiftUI glyph to an image so every pixel and color
/// is under our control, sets the tooltip, and toggles the popover on click.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item: NSStatusItem
    private let popover = NSPopover()
    private let store: UsageStore
    private var cancellables = Set<AnyCancellable>()
    private var appearanceObservation: NSKeyValueObservation?
    private var blinkTimer: Timer?
    private var blinkOn = true
    private var lastIsDark = false
    var openSettings: () -> Void = {}

    init(store: UsageStore) {
        self.store = store
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Without an autosave name macOS forgets where the item sits, so every relaunch
        // re-places it — and a wide neighbour appearing can shove it behind the notch.
        item.autosaveName = "pace"
        super.init()
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.delegate = self
        // Without `.preferredContentSize` the popover keeps whatever height it measured
        // the first time it was shown. A second provider arriving makes the content taller
        // than that, and the overflow is cut off the TOP — the header goes missing while
        // the footer stays put. Tracking the content's own size is the whole fix.
        let hosting = NSHostingController(rootView: PopoverView(
            store: store,
            openSettings: { [weak self] in self?.popover.performClose(nil); self?.openSettings() },
            close: { [weak self] in self?.popover.performClose(nil) }))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.render() } }
            .store(in: &cancellables)
        lastIsDark = isDarkMenuBar
        if let button = item.button {
            // `effectiveAppearance` KVO fires on every redraw, not just real light/dark changes —
            // setting `.image` in render() would otherwise retrigger this observer in a tight loop.
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in
                    guard let self, self.isDarkMenuBar != self.lastIsDark else { return }
                    self.lastIsDark = self.isDarkMenuBar
                    self.render()
                }
            }
        }
        render()
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = item.button else { return }
        store.refreshManually()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private var isDarkMenuBar: Bool {
        item.button?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    func render() {
        let rows = RowBuilder.rows(store: store)
        let ink: Color = isDarkMenuBar ? .white : .black
        let hours = store.settings.showHoursLeft
            ? rows.first(where: { $0.style == .week })?.remaining.map(Fmt.hoursOnly)
            : nil
        updateBlink(hasOverage: rows.contains { $0.fills.contains { $0.color == .over } })
        let view = GlyphView(rows: rows, settings: store.settings, ink: ink, hoursLeft: hours,
                             dimmed: store.isStale, blinkOn: blinkOn)
        let renderer = ImageRenderer(content: view)
        renderer.scale = item.button?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return }
        image.isTemplate = false
        item.button?.image = image
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = Tooltip.text(rows: rows, store: store)
        dumpIfRequested(image)
    }

    /// Starts (or stops) the timer that alternates a red-over-budget bar with yellow, so a session
    /// or week that's over pace is hard to miss. Idle whenever nothing is over.
    private func updateBlink(hasOverage: Bool) {
        guard hasOverage else {
            blinkTimer?.invalidate()
            blinkTimer = nil
            blinkOn = true
            return
        }
        guard blinkTimer == nil else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.blinkOn.toggle()
                self.render()
            }
        }
    }

    /// Debug aids, both off unless the environment asks:
    /// `PACE_DEBUG_DUMP=/path/glyph.png` writes the rendered glyph on a menu-bar-dark background;
    /// `PACE_DEBUG_DUMP_POPOVER=/path/popover.png` renders the popover offscreen once data has arrived.
    private func dumpIfRequested(_ image: NSImage) {
        let env = ProcessInfo.processInfo.environment
        if let path = env["PACE_DEBUG_DUMP"], !path.isEmpty {
            let scale: CGFloat = 2
            let size = NSSize(width: image.size.width + 8, height: image.size.height + 8)
            let canvas = NSImage(size: size)
            canvas.lockFocus()
            (isDarkMenuBar ? NSColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 1) : NSColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1)).setFill()
            NSRect(origin: .zero, size: size).fill()
            image.draw(in: NSRect(x: 4, y: 4, width: image.size.width, height: image.size.height))
            canvas.unlockFocus()
            writePNG(canvas, to: path, scale: scale)
        }
        if let path = env["PACE_DEBUG_DUMP_POPOVER"], !path.isEmpty, store.hasData {
            let view = PopoverView(store: store, openSettings: {}, close: {})
                .background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let img = renderer.nsImage { writePNG(img, to: path, scale: 2) }
        }
        if let path = env["PACE_DEBUG_DUMP_SETTINGS"], !path.isEmpty, store.hasData, !settingsDumped {
            // A grouped Form is AppKit-backed, which ImageRenderer skips; draw it from an offscreen window instead.
            settingsDumped = true
            let hosting = NSHostingView(rootView: SettingsView(store: store))
            hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 980)
            let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 460, height: 980),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = hosting
            window.orderFront(nil)
            hosting.layoutSubtreeIfNeeded()
            if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            window.orderOut(nil)
        }
    }
    private var settingsDumped = false

    private func writePNG(_ image: NSImage, to path: String, scale: CGFloat) {
        let pixel = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(pixel.width), pixelsHigh: Int(pixel.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
